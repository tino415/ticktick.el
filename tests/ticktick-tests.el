;;; ticktick-tests.el --- Tests against recorded TickTick responses  -*- lexical-binding: t; -*-

;;; Commentary:
;; Replays real API responses recorded from a dedicated `Ticktick.el' project
;; through a local WireMock instance, so the sync logic can be exercised
;; without touching the live service.  Expects WireMock on TICKTICK_TEST_PORT.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ticktick)

(defconst ticktick-test-project-id "6a7f04002eaa111364cd1f51")

;; Ids as recorded.  The comments are the ground truth the fixtures encode.
(defconst ticktick-test-active      "6a7f041b8bba511364cd1f5f") ; status 0
(defconst ticktick-test-completed   "6a7f042b90ee111364cd2027") ; status 2
(defconst ticktick-test-wont-do     "6a7f04232ef8511364cd1fce") ; status -1
(defconst ticktick-test-parent      "6a7f0459012ad11364cd20ae") ; has childIds
(defconst ticktick-test-sub-active  "6a7f045c6cca911364cd20ba") ; status 0
(defconst ticktick-test-sub-done    "6a7f046c2bb4111364cd2141") ; status 2
(defconst ticktick-test-deleted     "6a7f0477246a511364cd21c8") ; really deleted
(defconst ticktick-test-checklist   "6a7f048b7b68911364cd2283") ; kind CHECKLIST
(defconst ticktick-test-note        "6a7f04a47d3ed11364cd2381") ; kind NOTE

(defvar ticktick-test--dir nil)
(defvar ticktick-test--deleted-from-org nil)

(defun ticktick-test--org-file (ids)
  "Write a sync file containing a heading for each of IDS."
  (with-temp-file ticktick-sync-file
    (insert "* \U0001F3D7Ticktick.el\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
            ticktick-test-project-id "\n:END:\n")
    (dolist (id ids)
      (insert (format "** TODO task %s\n:PROPERTIES:\n:TICKTICK_ID: %s\n\
:TICKTICK_ETAG: stale\n:END:\nbody of %s\n" id id id))))
  ticktick-sync-file)

(defun ticktick-test--org-contents ()
  (with-temp-buffer (insert-file-contents ticktick-sync-file) (buffer-string)))

(defmacro ticktick-test--with-env (&rest body)
  "Run BODY against the stub server with throwaway files and a fake token."
  `(let* ((port (or (getenv "TICKTICK_TEST_PORT") "4123"))
          (ticktick--api-base-url (concat "http://localhost:" port))
          (ticktick-test--dir (make-temp-file "ticktick-test-" t))
          (ticktick-dir ticktick-test--dir)
          (ticktick-sync-file (expand-file-name "ticktick.org" ticktick-test--dir))
          (ticktick-token-file (expand-file-name "token" ticktick-test--dir))
          (ticktick-token (list :access_token "fake" :expires_in 99999
                                :created_at (float-time)))
          (ticktick--sync-state (list :api-task-ids nil :org-task-ids nil
                                      :task-project-map nil))
          (ticktick-test--deleted-from-org nil))
     (with-temp-file ticktick-token-file (prin1 ticktick-token (current-buffer)))
     (cl-letf (((symbol-function 'ticktick--delete-task-from-org)
                (lambda (id) (push id ticktick-test--deleted-from-org) t)))
       ,@body)))

;;; The server's answer to "does this task still exist?"

(ert-deftest ticktick-test-server-reports-active-task ()
  (ticktick-test--with-env
   (let ((res (ticktick--task-on-server ticktick-test-project-id
                                        ticktick-test-active)))
     (should (consp res))
     (should (equal (plist-get res :id) ticktick-test-active))
     (should (eql (plist-get res :status) 0)))))

(ert-deftest ticktick-test-server-reports-completed-task-as-alive ()
  "A completed task is still on the server; it must not read as deleted."
  (ticktick-test--with-env
   (let ((res (ticktick--task-on-server ticktick-test-project-id
                                        ticktick-test-completed)))
     (should (consp res))
     (should (eql (plist-get res :status) 2)))))

(ert-deftest ticktick-test-server-reports-wont-do-task-as-alive ()
  (ticktick-test--with-env
   (let ((res (ticktick--task-on-server ticktick-test-project-id
                                        ticktick-test-wont-do)))
     (should (consp res))
     (should (eql (plist-get res :status) -1)))))

(ert-deftest ticktick-test-server-reports-deleted-task-as-missing ()
  "A deleted task answers 200 with an empty body, not 404."
  (ticktick-test--with-env
   (should (eq (ticktick--task-on-server ticktick-test-project-id
                                         ticktick-test-deleted)
               'missing))))

;;; Classification

(ert-deftest ticktick-test-verify-separates-completed-from-deleted ()
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-completed ticktick-test-wont-do
                                  ticktick-test-sub-done ticktick-test-deleted))
   (let* ((res (ticktick--verify-api-deletions
                (list ticktick-test-completed ticktick-test-wont-do
                      ticktick-test-sub-done ticktick-test-deleted)))
          (deleted (plist-get res :deleted))
          (alive (mapcar #'car (plist-get res :alive))))
     (should (equal deleted (list ticktick-test-deleted)))
     (should (member ticktick-test-completed alive))
     (should (member ticktick-test-wont-do alive))
     (should (member ticktick-test-sub-done alive)))))

(ert-deftest ticktick-test-verify-skips-tasks-of-unknown-project ()
  "With no project for a task, it must be left alone rather than deleted."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((res (ticktick--verify-api-deletions (list ticktick-test-deleted))))
     (should (null (plist-get res :deleted)))
     (should (null (plist-get res :alive))))))

;;; The regression this all exists for

(ert-deftest ticktick-test-completing-a-task-is-not-a-deletion ()
  "Completing a task in the app must not remove it from Org.
The task drops out of the project listing, which used to be read as a
remote deletion."
  (ticktick-test--with-env
   (let ((known (list ticktick-test-active ticktick-test-completed
                      ticktick-test-wont-do ticktick-test-sub-done
                      ticktick-test-deleted)))
     (ticktick-test--org-file known)
     ;; last sync saw all of them, including the ones now filtered out
     (setq ticktick--sync-state (plist-put ticktick--sync-state
                                           :api-task-ids known))
     (setq ticktick-delete-behavior 'delete) ; no prompting in batch
     (ticktick-fetch-to-org)
     ;; only the genuinely deleted one may be removed
     (should (equal ticktick-test--deleted-from-org (list ticktick-test-deleted)))
     ;; and the completed task must survive, now marked DONE
     (let ((org (ticktick-test--org-contents)))
       (should (string-match-p (regexp-quote ticktick-test-completed) org))
       (should (string-match-p (regexp-quote ticktick-test-wont-do) org)))
     ;; still-existing tasks stay in the snapshot, so they are not
     ;; re-reported as deleted on the next sync
     (let ((snapshot (plist-get ticktick--sync-state :api-task-ids)))
       (should (member ticktick-test-completed snapshot))
       (should (member ticktick-test-wont-do snapshot))
       (should-not (member ticktick-test-deleted snapshot))))))

(ert-deftest ticktick-test-completed-task-becomes-done-in-org ()
  "The server's status must reach the org heading."
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-completed))
   (let ((task (ticktick--task-on-server ticktick-test-project-id
                                         ticktick-test-completed)))
     (ticktick--refresh-org-task ticktick-test-completed task)
     (let ((org (ticktick-test--org-contents)))
       (should (string-match-p "^\\*\\* DONE " org))))))

(provide 'ticktick-tests)
;;; ticktick-tests.el ends here
