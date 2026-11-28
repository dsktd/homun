;;; claude-approve-test.el --- ERT for claude-approve.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/claude-approve-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-approve)
(defvar claude-events--items)
(when (timerp claude-approve--timer) (cancel-timer claude-approve--timer))

(ert-deftest claude-approve-ignores-a-request-past-its-window ()
  (should-not (claude-approve--stale-p '((since . 1000) (timeout . 60)) 1060))
  (should (claude-approve--stale-p '((since . 1000) (timeout . 60)) 1061))
  ;; A request from an older hook names no window: the default applies
  (should-not (claude-approve--stale-p '((since . 1000)) 1060))
  (should (claude-approve--stale-p '((since . 1000)) 1061))
  (let* ((claude-approve-dir (file-name-as-directory (make-temp-file "approve" t)))
         (dir (expand-file-name "requests/" claude-approve-dir)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (with-temp-file (expand-file-name "1-1.json" dir)
            (insert (format "{\"id\":\"1-1\",\"tool\":\"Bash\",\"since\":%d,\"timeout\":60}"
                            (floor (float-time)))))
          (with-temp-file (expand-file-name "2-2.json" dir)
            (insert "{\"id\":\"2-2\",\"tool\":\"Bash\",\"since\":1000,\"timeout\":60}"))
          (should (equal (mapcar (lambda (r) (alist-get 'id r)) (claude-approve--requests))
                         '("1-1"))))
      (delete-directory claude-approve-dir t))))

(ert-deftest claude-approve-answered-request-leaves-the-card ()
  (let* ((claude-approve-dir (file-name-as-directory (make-temp-file "approve" t)))
         (req (expand-file-name "requests/" claude-approve-dir))
         (ans (expand-file-name "answers/" claude-approve-dir)))
    (unwind-protect
        (progn
          (make-directory req t)
          (make-directory ans t)
          (with-temp-file (expand-file-name "1-1.json" req)
            (insert (format "{\"id\":\"1-1\",\"tool\":\"Bash\",\"since\":%d,\"timeout\":300}"
                            (floor (float-time)))))
          (should (claude-approve--requests))
          (with-temp-file (expand-file-name "1-1" ans) (insert "allow"))
          (should-not (claude-approve--requests))
          ;; The answer stays for the hook while its request file exists
          (claude-approve--cleanup nil)
          (should (file-exists-p (expand-file-name "1-1" ans)))
          (delete-file (expand-file-name "1-1.json" req))
          (claude-approve--cleanup nil)
          (should-not (file-exists-p (expand-file-name "1-1" ans))))
      (delete-directory claude-approve-dir t))))

(ert-deftest claude-isolation-services-dir-is-scratch ()
  "Guard: under tests/el/run.sh no test can touch the real ~/claude/.services."
  (should (string-prefix-p "/var/tmp/homun-test-home-" (expand-file-name "~/claude/.services/"))))

(ert-deftest claude-approve-agent-names-who-asks ()
  (should (equal (claude-approve--agent '((tool . "Bash") (agent . :null))) "main"))
  (should (equal (claude-approve--agent '((agent_name . "implementer"))) "implementer"))
  (should (equal (claude-approve--agent '((agent . ((id . "a1") (type . "builder"))))) "builder"))
  (should (equal (claude-approve--agent '((agent . "bolt"))) "bolt")))

(ert-deftest claude-approve-terminal-wait-reads-the-newest-events ()
  (let ((prompt '(:event "Notification" :kind "permission_prompt"))
        (tool '(:event "PostToolUse" :kind ""))
        (pre '(:event "PreToolUse" :kind "")))
    ;; Newest first
    (let ((claude-events--items (list prompt pre tool)))
      (should (claude-approve--terminal-wait)))
    (let ((claude-events--items (list tool prompt pre)))
      (should-not (claude-approve--terminal-wait)))
    (let ((claude-events--items (list pre)))
      (should-not (claude-approve--terminal-wait)))))

(defmacro claude-approve-test--with (&rest body)
  "BODY with a scratch approve spool, Stage and queue state; the spool has request
1-1 (a Bash command), and the card guard is off."
  `(let* ((claude-approve-dir (file-name-as-directory (make-temp-file "approve" t)))
          (homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-stage-actions (make-hash-table :test #'equal))
          (claude-approve-answer-function nil) (claude-approve-guard 0)
          (claude-approve--pending nil) (claude-approve--open nil) (claude-approve--waiting nil)
          (claude-approve--shown (make-hash-table :test 'equal))
          (claude-approve--previews (make-hash-table :test 'equal))
          (claude-approve--selection (widgetry-selection-create nil #'ignore)))
     (cl-letf (((symbol-function 'homun-stage-display) #'ignore)
               ((symbol-function 'homun-stage-render) #'ignore)
               ((symbol-function 'claude-approve--look-in) #'ignore))
       (make-directory (expand-file-name "requests/" claude-approve-dir) t)
       (claude-approve-test--request "1-1" "ls -l" "read-only")
       (unwind-protect (progn ,@body)
         (delete-directory claude-approve-dir t)
         (delete-directory homun-stage-dir t)))))

(defun claude-approve-test--request (id command &optional risk since)
  (with-temp-file (expand-file-name (format "requests/%s.json" id) claude-approve-dir)
    (insert (json-serialize `(:id ,id :tool "Bash" :summary ,command :input (:command ,command)
                                  :since ,(or since (floor (float-time))) :timeout 300
                                  ,@(when risk (list :risk risk)))))))

(defun claude-approve-test--answer (id)
  (let ((file (expand-file-name (concat "answers/" id) claude-approve-dir)))
    (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)))))

(defun claude-approve-test--node (id)
  (car (homun-stage--find (homun-stage-scene-root (gethash "approve" homun-stage-scenes)) id)))

(ert-deftest claude-approve-scene-is-a-valid-record ()
  (let* ((claude-approve--open '("2-2"))
         (edit '((id . "2-2") (tool . "Edit")
                 (input . ((file_path . "a.el") (old_string . "x\ny") (new_string . "z")))))
         (bash '((id . "1-1") (tool . "Bash") (summary . "ls\n-l")))
         (root (claude-approve-scene (list bash edit) 0)))
    (should (homun-stage-validate root))
    (should (equal (alist-get 'diff (car (homun-stage--find root "diff-2-2"))) "a.el\n-x\n-y\n+z\n"))
    (should-not (homun-stage--find root "diff-1-1"))
    (should (equal (mapcar (lambda (r) (alist-get 'id r)) (alist-get 'requests root)) '("1-1" "2-2")))))

(ert-deftest claude-approve-card-answers-once-and-goes ()
  (claude-approve-test--with
   (claude-approve--draw-1)
   (should (equal (homun-stage-scene-lifetime (gethash "approve" homun-stage-scenes)) "system"))
   (should (claude-approve-test--node "approve-1-1-allow"))
   (funcall (gethash "approve-1-1-allow" homun-stage-actions))
   (should (equal (claude-approve-test--answer "1-1") "allow"))
   ;; The card left with the answer, and the journal has one line
   (should-not (gethash "approve" homun-stage-scenes))
   (should-not (gethash "approve-1-1-allow" homun-stage-actions))
   (should (= 1 (length (with-temp-buffer
                          (insert-file-contents (expand-file-name "journal.jsonl" claude-approve-dir))
                          (split-string (buffer-string) "\n" t)))))))

(ert-deftest claude-approve-new-card-ignores-presses ()
  (claude-approve-test--with
   (let ((claude-approve-guard 10))
     (claude-approve--draw-1)
     (should-not (claude-approve-test--node "approve-1-1-allow"))
     (should (claude-approve-test--node "wait-1-1"))
     (funcall (gethash "approve-1-1-allow" homun-stage-actions))
     (should-not (claude-approve-test--answer "1-1"))
     ;; The guard is per request: a redraw keeps the first-shown time
     (puthash "1-1" (- (float-time) 11) claude-approve--shown)
     (claude-approve--draw-1)
     (should (claude-approve-test--node "approve-1-1-allow"))
     (funcall (gethash "approve-1-1-allow" homun-stage-actions))
     (should (equal (claude-approve-test--answer "1-1") "allow")))))

(ert-deftest claude-approve-risky-allow-needs-a-hold ()
  (claude-approve-test--with
   (claude-approve-test--request "2-2" "rm -rf x" "destructive")
   (claude-approve-test--request "3-3" "make")
   (claude-approve--draw-1)
   (should-not (alist-get 'confirm (claude-approve-test--node "approve-1-1-allow")))
   (should (equal (alist-get 'confirm (claude-approve-test--node "approve-2-2-allow")) "hold"))
   ;; No class from the hook: unclassified, held
   (should (equal (alist-get 'confirm (claude-approve-test--node "approve-3-3-allow")) "hold"))
   (funcall (gethash "approve-1-1-tick" homun-stage-actions) t)
   (claude-approve--redraw)
   (should-not (alist-get 'confirm (claude-approve-test--node "approve-sel-allow")))
   (funcall (gethash "approve-2-2-tick" homun-stage-actions) t)
   (claude-approve--redraw)
   (should (equal (alist-get 'confirm (claude-approve-test--node "approve-sel-allow")) "hold"))
   (funcall (gethash "approve-sel-allow" homun-stage-actions))
   (should (equal (claude-approve-test--answer "1-1") "allow"))
   (should (equal (claude-approve-test--answer "2-2") "allow"))
   (should-not (claude-approve-test--answer "3-3"))))

(ert-deftest claude-approve-card-exists-iff-pending ()
  "#253: a card answered elsewhere, expired or gone leaves at the next look."
  (claude-approve-test--with
   (claude-approve-test--request "2-2" "make")
   (claude-approve-test--request "3-3" "make")
   (claude-approve--draw-1)
   (should (claude-approve-test--node "line-3-3"))
   (delete-file (expand-file-name "requests/1-1.json" claude-approve-dir))
   (make-directory (expand-file-name "answers/" claude-approve-dir) t)
   (write-region "deny" nil (expand-file-name "answers/2-2" claude-approve-dir))
   (claude-approve-test--request "3-3" "make" nil 1000)
   (claude-approve--draw-1)
   (should-not (gethash "approve" homun-stage-scenes))
   (should-not (seq-filter (lambda (k) (string-prefix-p "approve-" k)) (hash-table-keys homun-stage-actions)))
   (should (zerop (hash-table-count claude-approve--shown)))))

(ert-deftest claude-approve-quiet-marker-follows-the-setting ()
  (claude-approve-test--with
   (let ((marker (expand-file-name "answers/quiet" claude-approve-dir)))
     (unwind-protect
         (progn (setq claude-approve-quiet t)
                (should (file-exists-p marker))
                (let ((claude-approve-quiet nil)) (should (file-exists-p marker))))
       (setq claude-approve-quiet nil))
     (should-not (file-exists-p marker)))))

(ert-deftest claude-approve-ticker-lists-auto-allows ()
  (claude-approve-test--with
   (write-region (concat (json-serialize `(:time ,(format-time-string "%FT%TZ" nil t) :id "9-9" :answer "allow"
                                          :via "auto" :summary "git log" :agent "main"))
                         "\n"
                         (json-serialize '(:time "2020-01-01T00:00:00Z" :id "8-8" :answer "allow"
                                           :via "auto" :summary "old" :agent "main"))
                         "\n")
                 nil (expand-file-name "journal.jsonl" claude-approve-dir))
   (should (equal (claude-approve--ticker-text) "auto: main git log"))
   (claude-approve--draw-1)
   (should (equal (alist-get 'text (claude-approve-test--node "ticker")) "auto: main git log"))))

(ert-deftest claude-approve-remote-answer-is-routed-not-written ()
  (claude-approve-test--with
   (let ((sent nil))
     (setq claude-approve-answer-function (lambda (id v) (push (list id v) sent)))
     (claude-approve-answer "1-1" "deny")
     (should (equal sent '(("1-1" "deny"))))
     (should-not (file-exists-p (expand-file-name "answers/1-1" claude-approve-dir)))
     (should-not (file-exists-p (expand-file-name "journal.jsonl" claude-approve-dir))))))

(provide 'claude-approve-test)
;;; claude-approve-test.el ends here

(ert-deftest claude-approve-code-is-formatted-and-fontified ()
  (let* ((cmd "echo 'a && b' && ls -l | wc -l; true")
         (sh `((id . "x") (tool . "Bash") (summary . ,cmd) (input . ((command . ,cmd)))))
         (el `((id . "y") (tool . "eval") (input . ((code . "(let ((a 1)) (message \"%s\" a) (when a (list a a a a a a a a a a a a a a a a a a a a)))")))))
         (before (copy-tree sh)) (shown (claude-approve--code-text sh))
         (shown-el (claude-approve--code-text el)))
    (should (equal sh before))
    (should (equal (string-replace "\n  " " " shown) cmd))
    (should (string-match-p "&&\n  ls" shown))
    (should (text-property-not-all 0 (length shown) 'face nil shown))
    (should (string-match-p "\n" (string-trim shown-el)))
    (should (text-property-not-all 0 (length shown-el) 'face nil shown-el))
    (let ((claude-approve--open '("x")))
      (should (equal (alist-get 'text (car (homun-stage--find (claude-approve-scene (list sh) 0) "code-x")))
                     shown)))))
