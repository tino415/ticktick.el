;;; record.el --- Re-record the test fixtures from a live account  -*- lexical-binding: t; -*-

;;; Commentary:
;; Regenerates everything under tests/wiremock/ from a real TickTick account.
;; Not part of the test run -- the recorded fixtures are committed, and the
;; suite replays them offline.  Re-record only when the API changes or the
;; fixtures need to cover something new.
;;
;; Set up a project in TickTick holding one task per case you want covered
;; (active, completed, won't-do, deleted, a parent with subtasks, a checklist,
;; a note), then from a session where `ticktick-authorize' has already run:
;;
;;   M-x load-file RET tests/record.el RET
;;   M-x ticktick-record-fixtures RET
;;
;; Only the target project is written out, so an account's other projects
;; never end up in the repository.
;;
;; Ids of deleted tasks cannot be discovered from the API -- they appear only
;; as entries in some parent's `childIds'.  To cover the deleted case, make the
;; task a subtask, note its id, then delete it.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'request)
(require 'ticktick)

(defvar ticktick-record-project-regexp "[Tt]ick[Tt]ick\\.el"
  "Regexp matching the name of the project to record.")

(defvar ticktick-record-dir
  (expand-file-name "wiremock/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding the WireMock root, i.e. mappings/ and __files/.")

(defun ticktick-record--files-dir ()
  (expand-file-name "__files/" ticktick-record-dir))

(defun ticktick-record--mappings-dir ()
  (expand-file-name "mappings/" ticktick-record-dir))

(defun ticktick-record--raw (method endpoint &optional data)
  "Call METHOD ENDPOINT with DATA, returning the response body as a string."
  (ticktick-ensure-token)
  (let (body)
    (request (concat ticktick--api-base-url endpoint)
      :type method
      :headers `(("Authorization" . ,(concat "Bearer "
                                             (plist-get ticktick-token :access_token)))
                 ("Content-Type" . "application/json"))
      :data (and data (json-encode data))
      :parser #'buffer-string
      :sync t
      :complete (cl-function
                 (lambda (&key response &allow-other-keys)
                   (setq body (request-response-data response)))))
    (or body "")))

(defun ticktick-record--save (name method endpoint body)
  "Write BODY as fixture NAME and a stub matching METHOD and ENDPOINT."
  (with-temp-file (expand-file-name name (ticktick-record--files-dir))
    (insert body))
  (with-temp-file (expand-file-name (format "%s.json" (file-name-base name))
                                    (ticktick-record--mappings-dir))
    (insert (json-encode
             `((request . ((method . ,method) (url . ,endpoint)))
               (response . ((status . 200)
                            (bodyFileName . ,name)
                            (headers . (("Content-Type" . "application/json"))))))))))

(defun ticktick-record--get (name endpoint)
  (let ((body (ticktick-record--raw "GET" endpoint)))
    (ticktick-record--save name "GET" endpoint body)
    body))

(defun ticktick-record--parse (s)
  (let ((json-object-type 'plist) (json-array-type 'list))
    (ignore-errors (json-read-from-string s))))

;;;###autoload
(defun ticktick-record-fixtures ()
  "Re-record every fixture under `ticktick-record-dir'."
  (interactive)
  (make-directory (ticktick-record--files-dir) t)
  (make-directory (ticktick-record--mappings-dir) t)
  (dolist (f (append (directory-files (ticktick-record--files-dir) t "\\.json\\'")
                     (directory-files (ticktick-record--mappings-dir) t "\\.json\\'")))
    (delete-file f))

  (let* ((all (ticktick-record--parse (ticktick-record--raw "GET" "/open/v1/project")))
         (target (cl-find-if (lambda (p)
                               (string-match-p ticktick-record-project-regexp
                                               (or (plist-get p :name) "")))
                             all)))
    (unless target
      (user-error "No project matching %s" ticktick-record-project-regexp))
    (let* ((pid (plist-get target :id))
           (ids nil))
      ;; The project list is trimmed to the target, so that recording from a
      ;; real account never commits the account's other project names.
      (ticktick-record--save "projects.json" "GET" "/open/v1/project"
                             (json-encode (vector target)))
      (ticktick-record--get "project.json" (format "/open/v1/project/%s" pid))

      ;; An empty inbox, so `ticktick-fetch-to-org' resolves its synthetic
      ;; inbox project without reaching the network.
      (ticktick-record--save "inbox-data.json" "GET" "/open/v1/project/inbox/data"
                             (json-encode '((project . ((id . "inbox") (name . "Inbox")))
                                            (tasks . []))))

      (let* ((data (ticktick-record--parse
                    (ticktick-record--get "project-data.json"
                                          (format "/open/v1/project/%s/data" pid)))))
        (dolist (tk (plist-get data :tasks))
          (push (plist-get tk :id) ids)
          ;; Children referenced here may not appear in the listing at all --
          ;; that is exactly how deleted and completed subtasks show up.
          (dolist (c (plist-get tk :childIds)) (push c ids))))

      (let ((endpoint "/open/v1/task/completed")
            (body `(("projectIds" . (,pid))
                    ("startDate" . "2020-01-01T00:00:00.000+0000")
                    ("endDate" . "2030-01-01T00:00:00.000+0000"))))
        (let ((res (ticktick-record--raw "POST" endpoint body)))
          (ticktick-record--save "completed.json" "POST" endpoint res)
          (dolist (tk (ticktick-record--parse res))
            (push (plist-get tk :id) ids))))

      ;; No status field: that is the only form that returns every state,
      ;; including won't-do.  See the notes in the test suite.
      (let ((endpoint "/open/v1/task/filter")
            (body `(("projectIds" . (,pid)))))
        (let ((res (ticktick-record--raw "POST" endpoint body)))
          (ticktick-record--save "filter-nostatus.json" "POST" endpoint res)
          (dolist (tk (ticktick-record--parse res))
            (push (plist-get tk :id) ids))))

      (setq ids (delete-dups (delq nil ids)))
      (dolist (id ids)
        (ticktick-record--get (format "task-%s.json" id)
                              (format "/open/v1/project/%s/task/%s" pid id)))

      (message "Recorded project %s and %d task(s) into %s"
               pid (length ids) ticktick-record-dir))))

(provide 'record)
;;; record.el ends here
