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

;;; Rewriting a heading in place

(defun ticktick-test--level-2-count ()
  "Number of level-2 headings in the sync file."
  (with-current-buffer (find-file-noselect ticktick-sync-file)
    (org-with-wide-buffer
     (let ((n 0))
       (goto-char (point-min))
       (while (outline-next-heading)
         (when (= (org-current-level) 2) (setq n (1+ n))))
       n))))

(ert-deftest ticktick-test-rewriting-a-task-keeps-later-headings ()
  "Updating a task must not swallow the heading that follows it.
The stored etags are stale, so every task in the listing takes the
rewrite path.  The note is deliberately first: it is the only task in
the fixtures with a non-empty body, and a rewritten heading can only
run into the next one when it has a body to run on from."
  (ticktick-test--with-env
   (let ((known (list ticktick-test-note ticktick-test-active
                      ticktick-test-sub-active ticktick-test-parent
                      ticktick-test-checklist)))
     (ticktick-test--org-file known)
     (should (= (ticktick-test--level-2-count) (length known)))
     (ticktick-fetch-to-org)
     ;; Every task must still be a heading of its own.
     (should (= (ticktick-test--level-2-count) (length known)))
     (let ((org (ticktick-test--org-contents)))
       ;; A glued heading shows up as text followed by stars mid-line.
       (should-not (string-match-p "[^\n]\\*\\* " org))
       (dolist (id known)
         (should (string-match-p (regexp-quote id) org))))
     ;; The sync metadata belongs to the task that was rewritten, not to
     ;; whichever entry point happened to land on afterwards.
     (with-current-buffer (find-file-noselect ticktick-sync-file)
       (org-with-wide-buffer
        (dolist (id known)
          (goto-char (ticktick--find-task-by-id-in-org id))
          (should (equal (org-entry-get nil "TICKTICK_ID") id))
          (should (org-entry-get nil "SYNC_CACHE"))))))))

;;; The project snapshot

(ert-deftest ticktick-test-snapshot-covers-every-task-state ()
  "The snapshot must see states the project listing leaves out.
The listing returns the 5 open tasks; the other 4 come from the filter
endpoint."
  (ticktick-test--with-env
   (let* ((tasks (ticktick--project-task-list ticktick-test-project-id))
          (ids (mapcar (lambda (tk) (plist-get tk :id)) tasks)))
     (should (= (length ids) (length (delete-dups (copy-sequence ids)))))
     (dolist (id (list ticktick-test-active ticktick-test-completed
                       ticktick-test-wont-do ticktick-test-sub-done))
       (should (member id ids))))))

(ert-deftest ticktick-test-snapshot-keeps-open-tasks-when-filter-is-empty ()
  "Open tasks come from the listing, so a truncated filter cannot lose them.
A busy project can exceed the filter endpoint's 200-task limit."
  (ticktick-test--with-env
   (cl-letf* ((real (symbol-function 'ticktick-request))
              ((symbol-function 'ticktick-request)
               (lambda (method endpoint &optional data)
                 (if (equal endpoint "/open/v1/task/filter")
                     nil                ; pretend the cap hid everything
                   (funcall real method endpoint data)))))
     (let ((ids (mapcar (lambda (tk) (plist-get tk :id))
                        (ticktick--project-task-list ticktick-test-project-id))))
       (should (member ticktick-test-active ids))
       (should (member ticktick-test-note ids))
       (should-not (member ticktick-test-completed ids))))))

;;; What reaches the org file

(ert-deftest ticktick-test-completed-tasks-are-not-imported-by-default ()
  "Finished tasks Org has never seen stay out of the file."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-import-completed-tasks nil))
     (ticktick-fetch-to-org))
   (let ((org (ticktick-test--org-contents)))
     (should (string-match-p (regexp-quote ticktick-test-active) org))
     (should-not (string-match-p (regexp-quote ticktick-test-completed) org))
     (should-not (string-match-p (regexp-quote ticktick-test-wont-do) org)))))

(ert-deftest ticktick-test-completed-tasks-are-imported-when-asked ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-import-completed-tasks t))
     (ticktick-fetch-to-org))
   (let ((org (ticktick-test--org-contents)))
     (should (string-match-p (regexp-quote ticktick-test-completed) org))
     (should (string-match-p "^\\*\\* DONE " org))
     (should (string-match-p (regexp-quote ticktick-test-wont-do) org))
     (should (string-match-p "^\\*\\* CANCELLED " org)))))

(ert-deftest ticktick-test-tracked-task-is-updated-when-completed ()
  "A task already in the file follows the server even when import is off."
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-completed))
   (let ((ticktick-import-completed-tasks nil))
     (ticktick-fetch-to-org))
   (let ((org (ticktick-test--org-contents)))
     (should (string-match-p (regexp-quote ticktick-test-completed) org))
     (should (string-match-p "^\\*\\* DONE " org)))))

(ert-deftest ticktick-test-wont-do-task-is-never-written-as-todo ()
  "Rendering status -1 as TODO would read as reopening it."
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-wont-do))
   (let ((ticktick-import-completed-tasks t))
     (ticktick-fetch-to-org))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-wont-do))
      (should (equal (org-get-todo-state) ticktick-wont-do-keyword))))))

;;; "Won't do" tasks

(ert-deftest ticktick-test-wont-do-keyword-is-registered-in-the-file ()
  "An unknown keyword would be read as part of the heading title."
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-wont-do))
   (let ((ticktick-import-completed-tasks t))
     (ticktick-fetch-to-org))
   (should (string-match-p "^#\\+TODO:.*CANCELLED"
                           (ticktick-test--org-contents)))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-wont-do))
      ;; the keyword must be a keyword, not the first word of the title
      (should (equal (org-get-todo-state) "CANCELLED"))
      (should-not (string-match-p "CANCELLED" (org-get-heading t t t t)))))))

(ert-deftest ticktick-test-wont-do-survives-the-round-trip ()
  "Reading the heading back must give status -1, not 2.
The keyword is a done-type one, so going by type alone would report a
cancelled task to TickTick as completed."
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-wont-do))
   (let ((ticktick-import-completed-tasks t))
     (ticktick-fetch-to-org))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-wont-do))
      (let ((task (ticktick--heading-to-task)))
        (should (equal (cdr (assoc "status" task)) -1))
        (should (equal (cdr (assoc "title" task)) "Test task won't do")))))))

(ert-deftest ticktick-test-done-and-open-still-round-trip ()
  "The new keyword must not disturb the two existing states."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-import-completed-tasks t))
     (ticktick-fetch-to-org))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-completed))
      (should (equal (cdr (assoc "status" (ticktick--heading-to-task))) 2))
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-active))
      (should (equal (cdr (assoc "status" (ticktick--heading-to-task))) 0))))))

;;; Checklists

(ert-deftest ticktick-test-checklist-items-become-checkboxes ()
  "A CHECKLIST task's items reach Org as a checkbox list, in order."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-checklist))
      (should (equal (org-entry-get nil "TICKTICK_KIND") "CHECKLIST"))
      (let ((body (buffer-substring-no-properties
                   (point) (org-entry-end-position))))
        ;; sortOrder, not the order the API happened to return them in
        (should (string-match-p "- \\[ \\] Check 1\n- \\[ \\] Check 2\n- \\[X\\] Check completed"
                                body)))))))

(ert-deftest ticktick-test-checkboxes-are-not-sent-as-the-description ()
  "The checkbox list renders the items; it is not the task's content.
Sending it back as the description would duplicate every item as text."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-checklist))
      (let ((content (cdr (assoc "content" (ticktick--heading-to-task)))))
        (should-not (string-match-p "Check 1" content))
        (should-not (string-match-p "\\[X\\]" content)))))))

(ert-deftest ticktick-test-plain-tasks-keep-checkbox-prose ()
  "Only a checklist's own list is stripped, not checkboxes a user wrote."
  (ticktick-test--with-env
   (with-temp-file ticktick-sync-file
     (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
             ticktick-test-project-id "\n:END:\n"
             "** TODO plain\n:PROPERTIES:\n:TICKTICK_ID: plain-1\n:END:\n"
             "notes\n- [ ] my own checkbox\n"))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org "plain-1"))
      (let ((content (cdr (assoc "content" (ticktick--heading-to-task)))))
        (should (string-match-p "my own checkbox" content)))))))

(ert-deftest ticktick-test-task-without-items-gets-no-kind-property ()
  "Ordinary tasks stay free of checklist bookkeeping."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-active))
      (should-not (org-entry-get nil "TICKTICK_KIND"))))))

;;; Nested headings

(defun ticktick-test--nested-file ()
  "Write a task with a nested heading under it, and return to the task."
  (with-temp-file ticktick-sync-file
    (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
            ticktick-test-project-id "\n:END:\n"
            "** TODO parent\n:PROPERTIES:\n:TICKTICK_ID: p-1\n"
            ":TICKTICK_ETAG: e1\n:END:\n"
            "parent body\n"
            "*** TODO child\n:PROPERTIES:\n:TICKTICK_ID: c-1\n"
            ":TICKTICK_ETAG: e2\n:END:\n"
            "child body\n")))

(defmacro ticktick-test--at-parent (&rest body)
  `(with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org "p-1"))
      ,@body)))

(ert-deftest ticktick-test-fold-sends-nested-heading-as-content ()
  (ticktick-test--with-env
   (ticktick-test--nested-file)
   (let ((ticktick-subheading-behavior 'fold))
     (ticktick-test--at-parent
      (let ((content (cdr (assoc "content" (ticktick--heading-to-task)))))
        (should (string-match-p "parent body" content))
        (should (string-match-p "child body" content)))))))

(ert-deftest ticktick-test-subtask-keeps-nested-heading-out-of-content ()
  (ticktick-test--with-env
   (ticktick-test--nested-file)
   (let ((ticktick-subheading-behavior 'subtask))
     (ticktick-test--at-parent
      (let ((content (cdr (assoc "content" (ticktick--heading-to-task)))))
        (should (string-match-p "parent body" content))
        (should-not (string-match-p "child body" content)))))))

(ert-deftest ticktick-test-fold-notices-an-edit-to-a-nested-heading ()
  "The whole point of #7: what is hashed must cover what is sent.
Under `fold' a nested heading is part of the description, so editing it
has to mark the task as needing a push."
  (ticktick-test--with-env
   (ticktick-test--nested-file)
   (let ((ticktick-subheading-behavior 'fold))
     (ticktick-test--at-parent
      (ticktick--update-sync-meta)
      (should-not (ticktick--should-sync-p))
      ;; edit the child's body, leaving the parent's own text alone
      (save-excursion
        (goto-char (point-max))
        (re-search-backward "^child body$")
        (end-of-line)
        (insert " changed"))
      (should (ticktick--should-sync-p))))))

(ert-deftest ticktick-test-fold-hash-ignores-a-nested-tasks-own-metadata ()
  "A child's property drawer must not leak into the parent's digest."
  (ticktick-test--with-env
   (ticktick-test--nested-file)
   (let ((ticktick-subheading-behavior 'fold))
     (ticktick-test--at-parent
      (let ((body (ticktick--subtree-body-for-hash)))
        (should (string-match-p "child body" body))
        (should-not (string-match-p "TICKTICK_ID" body))
        (should-not (string-match-p "TICKTICK_ETAG" body))
        (should-not (string-match-p ":PROPERTIES:" body)))))))

;;; Subtasks

(defun ticktick-test--level-of (id)
  "Outline level of the heading carrying ID, or nil."
  (with-current-buffer (find-file-noselect ticktick-sync-file)
    (org-with-wide-buffer
     (let ((pos (ticktick--find-task-by-id-in-org id)))
       (when pos (goto-char pos) (org-current-level))))))

(ert-deftest ticktick-test-fold-leaves-subtasks-flat ()
  "The default must keep every task at level 2, as it always has."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-subheading-behavior 'fold))
     (ticktick-fetch-to-org))
   (should (= (ticktick-test--level-of ticktick-test-parent) 2))
   (should (= (ticktick-test--level-of ticktick-test-sub-active) 2))))

(ert-deftest ticktick-test-subtask-nests-a-child-under-its-parent ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-subheading-behavior 'subtask))
     (ticktick-fetch-to-org))
   (should (= (ticktick-test--level-of ticktick-test-parent) 2))
   (should (= (ticktick-test--level-of ticktick-test-sub-active) 3))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-sub-active))
      ;; the link back is recorded, and the parent really is the parent
      (should (equal (org-entry-get nil "TICKTICK_PARENT_ID")
                     ticktick-test-parent))
      (org-up-heading-safe)
      (should (equal (org-entry-get nil "TICKTICK_ID") ticktick-test-parent))))))

(ert-deftest ticktick-test-subtask-orphan-stays-at-top-level ()
  "A child whose parent is not in the listing must still appear.
Its parent may be completed, deleted, or past the filter's limit."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-subheading-behavior 'subtask)
         (ticktick-import-completed-tasks t))
     (cl-letf* ((real (symbol-function 'ticktick--project-task-list))
                ((symbol-function 'ticktick--project-task-list)
                 (lambda (pid)
                   ;; drop the parent, keep the child pointing at it
                   (cl-remove-if (lambda (tk)
                                   (equal (plist-get tk :id) ticktick-test-parent))
                                 (funcall real pid)))))
       (ticktick-fetch-to-org)))
   (should (= (ticktick-test--level-of ticktick-test-sub-active) 2))))

(ert-deftest ticktick-test-subtask-mode-pushes-a-nested-heading-as-a-task ()
  "Under `subtask' a level-3 heading is pushed, carrying its parent's id."
  (ticktick-test--with-env
   (ticktick-test--nested-file)
   (let ((ticktick-subheading-behavior 'subtask)
         (created nil))
     (cl-letf (((symbol-function 'ticktick--create-task)
                (lambda (task project-id &optional parent-id)
                  (push (list (cdr (assoc "title" task)) project-id parent-id)
                        created)))
               ((symbol-function 'ticktick--update-task)
                (lambda (&rest _) nil)))
       ;; the child has no TICKTICK_ID of its own yet
       (with-current-buffer (find-file-noselect ticktick-sync-file)
         (org-with-wide-buffer
          (goto-char (ticktick--find-task-by-id-in-org "c-1"))
          (org-entry-delete nil "TICKTICK_ID")
          (save-buffer)))
       (ticktick-push-from-org)
       (should (equal created (list (list "child" ticktick-test-project-id "p-1"))))))))

(ert-deftest ticktick-test-fold-mode-does-not-push-nested-headings ()
  "Under `fold' a nested heading is description text, not a task."
  (ticktick-test--with-env
   (ticktick-test--nested-file)
   (let ((ticktick-subheading-behavior 'fold)
         (created nil))
     (cl-letf (((symbol-function 'ticktick--create-task)
                (lambda (task &rest _)
                  (push (cdr (assoc "title" task)) created)))
               ((symbol-function 'ticktick--update-task)
                (lambda (&rest _) nil)))
       (with-current-buffer (find-file-noselect ticktick-sync-file)
         (org-with-wide-buffer
          (goto-char (ticktick--find-task-by-id-in-org "c-1"))
          (org-entry-delete nil "TICKTICK_ID")
          (save-buffer)))
       (ticktick-push-from-org)
       (should (null created))))))

;;; Archived lists

(defmacro ticktick-test--with-archived-project (&rest body)
  "Run BODY with the test project reported as archived."
  `(cl-letf* ((real (symbol-function 'ticktick-request))
              ((symbol-function 'ticktick-request)
               (lambda (method endpoint &optional data)
                 (let ((res (funcall real method endpoint data)))
                   (if (equal endpoint "/open/v1/project")
                       (mapcar (lambda (p) (plist-put (copy-sequence p) :closed t))
                               res)
                     res)))))
     ,@body))

(ert-deftest ticktick-test-json-false-is-not-archived ()
  "JSON false parses to a truthy symbol, so it must be tested for."
  (should-not (ticktick--project-archived-p '(:id "x" :closed :json-false)))
  (should (ticktick--project-archived-p '(:id "x" :closed t)))
  (should-not (ticktick--project-archived-p '(:id "x"))))

(ert-deftest ticktick-test-archived-project-gets-tagged ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-archived-project-behavior 'tag))
     (ticktick-test--with-archived-project (ticktick-fetch-to-org)))
   (should (string-match-p "^\\* .*Ticktick\\.el.*:archived:"
                           (ticktick-test--org-contents)))))

(ert-deftest ticktick-test-unarchiving-removes-the-tag ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-archived-project-behavior 'tag))
     (ticktick-test--with-archived-project (ticktick-fetch-to-org))
     (should (string-match-p ":archived:" (ticktick-test--org-contents)))
     ;; now the server says it is open again
     (ticktick-fetch-to-org)
     (should-not (string-match-p ":archived:" (ticktick-test--org-contents))))))

(ert-deftest ticktick-test-project-is-found-despite-a-tag ()
  "Tagging the heading must not make the next sync create a second one."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-archived-project-behavior 'tag))
     (ticktick-test--with-archived-project (ticktick-fetch-to-org))
     (ticktick-fetch-to-org))
   (let ((headings 0))
     (dolist (line (split-string (ticktick-test--org-contents) "\n"))
       (when (string-match-p "^\\* .*Ticktick\\.el" line)
         (setq headings (1+ headings))))
     (should (= headings 1)))))

(ert-deftest ticktick-test-skip-leaves-archived-project-out ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (let ((ticktick-archived-project-behavior 'skip))
     (ticktick-test--with-archived-project (ticktick-fetch-to-org)))
   (should-not (string-match-p (regexp-quote ticktick-test-active)
                               (ticktick-test--org-contents)))))

(ert-deftest ticktick-test-archiving-a-list-is-not-a-deletion ()
  "Skipping a project must not make its tasks look deleted.
Their ids have to stay in the snapshot even though nothing is written."
  (ticktick-test--with-env
   (ticktick-test--org-file (list ticktick-test-active))
   (setq ticktick--sync-state
         (plist-put ticktick--sync-state :api-task-ids
                    (list ticktick-test-active)))
   (setq ticktick-delete-behavior 'delete)
   (let ((ticktick-archived-project-behavior 'skip))
     (ticktick-test--with-archived-project (ticktick-fetch-to-org)))
   (should (null ticktick-test--deleted-from-org))
   (should (member ticktick-test-active
                   (plist-get ticktick--sync-state :api-task-ids)))))

;;; Descriptions as markdown blocks

(ert-deftest ticktick-test-description-is-wrapped-in-a-src-block ()
  "The note fixture's body is markdown bullets, which Org would eat."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-note))
      (let ((body (buffer-substring-no-properties
                   (point) (org-entry-end-position))))
        (should (string-match-p "#\\+begin_src markdown" body))
        (should (string-match-p "#\\+end_src" body))
        ;; still escaped inside the block, so the bullets stay text
        (should (string-match-p "^,\\* link one" body)))))))

(ert-deftest ticktick-test-wrapped-description-round-trips ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-note))
      (let ((content (cdr (assoc "content" (ticktick--heading-to-task)))))
        (should (equal content "* link one\n* link two \n* link three")))))))

(ert-deftest ticktick-test-bare-description-still-reads-back ()
  "Files written before wrapping must keep working."
  (ticktick-test--with-env
   (with-temp-file ticktick-sync-file
     (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
             ticktick-test-project-id "\n:END:\n"
             "** TODO old\n:PROPERTIES:\n:TICKTICK_ID: old-1\n:END:\n"
             "just some text\n"))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org "old-1"))
      (should (equal (cdr (assoc "content" (ticktick--heading-to-task)))
                     "just some text"))))))

(ert-deftest ticktick-test-end-src-in-a-description-cannot-break-out ()
  (ticktick-test--with-env
   (let ((heading (ticktick--task-to-heading
                   '(:id "x" :title "T" :status 0 :priority 0 :etag "e"
                         :content "before\n#+end_src\nafter"))))
     ;; exactly one unescaped terminator: the block's own
     (let ((terminators 0)
           (start 0))
       (while (string-match "^#\\+end_src$" heading start)
         (setq terminators (1+ terminators)
               start (match-end 0)))
       (should (= terminators 1)))
     ;; the one in the description was commented out instead
     (should (string-match-p "^,#\\+end_src$" heading))
     ;; and it survives the trip back
     (should (equal (ticktick--unwrap-content
                     (ticktick--wrap-content
                      (org-escape-code-in-string "before\n#+end_src\nafter")))
                    (org-escape-code-in-string "before\n#+end_src\nafter"))))))

(ert-deftest ticktick-test-wrapping-does-not-change-the-digest ()
  "Gaining the block must not make a task look edited."
  (ticktick-test--with-env
   (with-temp-file ticktick-sync-file
     (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
             ticktick-test-project-id "\n:END:\n"
             "** TODO t\n:PROPERTIES:\n:TICKTICK_ID: t-1\n:END:\n"
             "some text\n"))
   (let (bare wrapped)
     (with-current-buffer (find-file-noselect ticktick-sync-file)
       (org-with-wide-buffer
        (goto-char (ticktick--find-task-by-id-in-org "t-1"))
        (setq bare (ticktick--subtree-body-for-hash))))
     (with-temp-file ticktick-sync-file
       (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
               ticktick-test-project-id "\n:END:\n"
               "** TODO t\n:PROPERTIES:\n:TICKTICK_ID: t-1\n:END:\n"
               "#+begin_src markdown\nsome text\n#+end_src\n"))
     (with-current-buffer (find-file-noselect ticktick-sync-file)
       (revert-buffer t t t)
       (org-with-wide-buffer
        (goto-char (ticktick--find-task-by-id-in-org "t-1"))
        (setq wrapped (ticktick--subtree-body-for-hash))))
     (should (equal bare wrapped)))))

;;; Notes

(ert-deftest ticktick-test-note-has-no-todo-keyword ()
  "A note is not something to be done."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-note))
      (should (equal (org-entry-get nil "TICKTICK_KIND") "NOTE"))
      (should-not (org-get-todo-state))
      ;; the title is the whole heading, not preceded by a keyword
      (should (equal (org-get-heading t t t t) "Note containing"))))))

(ert-deftest ticktick-test-ordinary-tasks-still-have-a-keyword ()
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-active))
      (should (equal (org-get-todo-state) "TODO"))))))

(ert-deftest ticktick-test-note-does-not-become-a-task-on-push ()
  "Pushing a note back must keep it a note."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-note))
      (should (equal (cdr (assoc "kind" (ticktick--heading-to-task))) "NOTE"))))))

(ert-deftest ticktick-test-a-keywordless-heading-is-pushed-as-a-note ()
  "Writing a plain heading in Org is how a note is created."
  (ticktick-test--with-env
   (with-temp-file ticktick-sync-file
     (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
             ticktick-test-project-id "\n:END:\n"
             "** just a thought\n:PROPERTIES:\n:TICKTICK_ID: n-1\n:END:\n"))
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org "n-1"))
      (let ((task (ticktick--heading-to-task)))
        (should (equal (cdr (assoc "kind" task)) "NOTE"))
        (should (equal (cdr (assoc "title" task)) "just a thought")))))))

(ert-deftest ticktick-test-checklist-stays-a-checklist-when-pushed ()
  "The note rule must not reclassify a checklist."
  (ticktick-test--with-env
   (ticktick-test--org-file nil)
   (ticktick-fetch-to-org)
   (with-current-buffer (find-file-noselect ticktick-sync-file)
     (org-with-wide-buffer
      (goto-char (ticktick--find-task-by-id-in-org ticktick-test-checklist))
      (should (equal (cdr (assoc "kind" (ticktick--heading-to-task)))
                     "CHECKLIST"))))))

(ert-deftest ticktick-test-notes-are-picked-up-for-pushing ()
  "Candidates are chosen by level and property, not by keyword."
  (ticktick-test--with-env
   (with-temp-file ticktick-sync-file
     (insert "* P\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
             ticktick-test-project-id "\n:END:\n"
             "** a note with no keyword\n:PROPERTIES:\n:TICKTICK_ID: n-2\n:END:\n"))
   (let (pushed)
     (cl-letf (((symbol-function 'ticktick--update-task)
                (lambda (task &rest _) (push (cdr (assoc "kind" task)) pushed)))
               ((symbol-function 'ticktick--create-task)
                (lambda (&rest _) nil)))
       (ticktick-push-from-org)
       (should (equal pushed '("NOTE")))))))

(provide 'ticktick-tests)
;;; ticktick-tests.el ends here
