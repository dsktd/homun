;;; claude-doctor-test.el --- tests for claude-doctor -*- lexical-binding: t -*-
(require 'ert)
(require 'claude-doctor)
(require 'homun-api)
(require 'homun-stage-store)

(defconst doctor-test-answer
  "{\"ts\":1,\"where\":\"editor\",\"counts\":{\"ok\":1,\"warn\":1,\"fail\":1,\"unknown\":0},\"checks\":[
{\"area\":\"Host\",\"id\":\"host.pin\",\"name\":\"pin\",\"status\":\"ok\",\"summary\":\"abc checked out\",\"hint\":\"\",\"open\":null,\"service\":null},
{\"area\":\"Services\",\"id\":\"service.proxy\",\"name\":\"proxy\",\"status\":\"fail\",\"summary\":\"stopped\",\"hint\":\"claude-services start proxy\",\"open\":\"/nonexistent/log\",\"service\":\"proxy\"},
{\"area\":\"Cockpit\",\"id\":\"cockpit.messages\",\"name\":\"*Messages* errors\",\"status\":\"warn\",\"summary\":\"2 in the last hour\",\"hint\":\"RET opens *Messages*\",\"open\":\"buffer:*Messages*\",\"service\":null},
{\"area\":\"Roles\",\"id\":\"mechanic.heartbeat\",\"name\":\"mechanic heartbeat\",\"status\":\"ok\",\"summary\":\"20 s ago\",\"hint\":\"\",\"open\":null,\"service\":null},
{\"area\":\"Roles\",\"id\":\"broker.x1\",\"name\":\"x1 session\",\"status\":\"fail\",\"summary\":\"service stopped\",\"hint\":\"claude-services logs x1\",\"open\":\"/nonexistent/log\",\"service\":\"x1\"}]}")

(defmacro doctor-test (&rest body)
  "Run BODY with the scene built from `doctor-test-answer': no command, no timer, no store."
  `(let ((claude-doctor--data (claude-doctor--parse doctor-test-answer))
         (claude-doctor--problem nil) (claude-doctor--timer nil)
         (homun-stage-dir (file-name-as-directory (make-temp-file "doctor-stage" t)))
         (homun-stage-scenes (make-hash-table :test #'equal)))
     (unwind-protect (progn ,@body)
       (claude-doctor--stop)
       (delete-directory homun-stage-dir t))))

(defun doctor-test-text ()
  (homun-stage-text (homun-stage-validate (claude-doctor-scene)) nil))

(defun doctor-test-row (id)
  "The row node of the check ID in the scene."
  (car (homun-stage--find (claude-doctor-scene) id)))

(defun doctor-test-buttons (id)
  (mapcar (lambda (c) (alist-get 'label c))
          (seq-filter (lambda (c) (equal (alist-get 'kind c) "button")) (alist-get 'children (doctor-test-row id)))))

(ert-deftest doctor-scene-shows-only-role-rows ()
  (doctor-test
   (let ((text (doctor-test-text)))
     (should (string-match-p "1 ok · 0 warn · 1 fail · 0 unknown · seen from editor" text))
     (should (string-match-p "x1 session +service stopped" text))
     (should (string-match-p "\n      claude-services logs x1" text))
     (dolist (gone '("pin" "proxy" "Messages"))
       (should-not (string-match-p gone text))))
   (let ((dot (car (alist-get 'children (doctor-test-row "broker.x1")))))
     (should (equal (alist-get 'face dot) "err")))
   (claude-doctor--show-scene)
   (should (gethash claude-doctor-scene homun-stage-scenes))
   (should (equal (homun-stage-scene-lifetime (gethash claude-doctor-scene homun-stage-scenes)) "system"))))

(ert-deftest doctor-restart-on-a-failing-role-row ()
  (doctor-test
   ;; Refresh, a Restart and an Open on the failing session's row; a Restart on the mechanic's
   (should (equal (doctor-test-buttons "broker.x1") '("Restart" "Open")))
   (should (equal (doctor-test-buttons "mechanic.heartbeat") '("Restart")))
   (should (gethash "restart-role-mechanic.heartbeat" homun-stage-actions))
   (should (gethash "restart-broker.x1" homun-stage-actions))
   (should (equal (claude-doctor--role-of '((id . "mechanic.heartbeat"))) "mechanic"))))

(ert-deftest doctor-restart-is-a-request-to-the-host ()
  (let* ((dir (file-name-as-directory (make-temp-file "doctor-test" t)))
         (claude-doctor-host-dir dir))
    (unwind-protect
        (progn
          (should-error (claude-doctor--request "service" nil) :type 'user-error)
          (make-directory (expand-file-name "requests/cockpit" dir) t)
          (let* ((id (claude-doctor--request "service" '((action . "restart") (name . "proxy"))))
                 (row (claude-doctor--parse
                       (with-temp-buffer
                         (insert-file-contents (expand-file-name (format "requests/cockpit/%s.json" id) dir))
                         (buffer-string)))))
            (should (equal (alist-get 'kind row) "service"))
            (should (equal (alist-get 'id row) id))
            (should (equal (alist-get 'args row) '((action . "restart") (name . "proxy"))))
            (should (equal (alist-get 'kind (claude-doctor--parse
                                             (with-temp-buffer
                                               (insert-file-contents
                                                (expand-file-name (format "requests/cockpit/%s.json"
                                                                          (claude-doctor--request "side" '((action . "restart") (role . "mechanic"))))
                                                                  dir))
                                               (buffer-string))))
                           "side"))))
      (delete-directory dir t))))

(ert-deftest doctor-open-row ()
  (should-error (claude-doctor--open "/nonexistent/log") :type 'user-error)
  (let ((file (make-temp-file "doctor-log")))
    (unwind-protect
        (progn (with-temp-file file (insert "first\nlast\n"))
               (with-current-buffer (claude-doctor--tail file)
                 (should buffer-read-only)
                 (should (string-match-p "last\n\\'" (buffer-string)))
                 (kill-buffer)))
      (delete-file file))))

(ert-deftest doctor-messages-errors-counted-once-seen ()
  (let ((claude-doctor--mark nil) (claude-doctor--errors nil) (inhibit-message t))
    (message "Error before the first look")
    (should (= (alist-get 'errors_1h (claude-doctor-probe)) 0))
    (message "fine")
    (message "Error running timer: (void-function nope)")
    (message "error in process sentinel: x")
    (let ((probe (claude-doctor-probe)))
      (should (= (alist-get 'errors_1h probe) 2))
      (should (string-match-p "process sentinel" (alist-get 'last_error probe)))
      (should (json-serialize probe)))
    (should (= (alist-get 'errors_1h (claude-doctor-probe)) 2))
    ;; older than an hour: gone
    (setcar (car claude-doctor--errors) (- (float-time) 4000))
    (should (= (alist-get 'errors_1h (claude-doctor-probe)) 1))))

(ert-deftest doctor-timer-only-while-shown ()
  (doctor-test
   (cl-letf (((symbol-function 'claude-doctor-refresh) #'ignore))
     (should-not claude-doctor--timer)
     (claude-doctor--start)
     (should (timerp claude-doctor--timer))
     ;; batch: no window shows the scene, so the tick ends the timer
     (claude-doctor--tick)
     (should-not claude-doctor--timer))))

(ert-deftest doctor-api-entries ()
  (let ((claude-doctor-command (list "sh" "-c" (format "printf '%%s' %s" (shell-quote-argument doctor-test-answer)))))
    (let ((all (homun-api-call '("doctor" "get")))
          (bad (homun-api-call '("doctor" "get" "problems" "yes"))))
      (should (string-prefix-p "ok\n" all))
      (should (= (length (alist-get 'checks (claude-doctor--parse (substring all 3)))) 5))
      (should (equal (mapcar (lambda (c) (alist-get 'id c))
                             (alist-get 'checks (claude-doctor--parse (substring bad 3))))
                     '("service.proxy" "cockpit.messages" "broker.x1"))))
    (should (alist-get 'pid (claude-doctor--parse (substring (homun-api-call '("daemon" "get" "view" "probe")) 3))))))
