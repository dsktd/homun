;;; claude-phone-seen-test.el --- ERT for the Board's unseen dots and the detail's swipe -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/claude-phone-seen-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'claude-remote)
(require 'claude-remote-home)
(require 'claude-remote-swipe)

(defun claude-phone-seen-test--task (title state &optional last)
  (list :kind "subagent" :title title :state state :last (or last "tool: ls") :age "1m"))

(defmacro claude-phone-seen-test--with (tasks &rest body)
  "Run BODY with the glance holding TASKS and a fresh seen file."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "seen" t))
          (claude-phone-seen-file (expand-file-name "seen" dir))
          (claude-phone--seen nil) (claude-phone--seen-loaded nil)
          (claude-phone-glance (list :tasks (vconcat ,tasks)))
          (claude-remote-home--view 'board) (claude-remote-home--detail nil)
          (claude-remote-home-buffer "*homun-seen-test*"))
     (unwind-protect
         (cl-letf (((symbol-function 'claude-remote-act) #'ignore)
                   ((symbol-function 'claude-remote-home) (lambda () (get-buffer-create claude-remote-home-buffer))))
           ,@body)
       (kill-buffer (get-buffer-create claude-remote-home-buffer))
       (delete-directory dir t))))

(defun claude-phone-seen-test--dots ()
  "The number of unseen dots on the Board for the current glance."
  (with-temp-buffer
    (claude-phone--board claude-phone-glance nil)
    (how-many " ●" (point-min) (point-max))))

(ert-deftest claude-phone-seen-new-task-has-a-dot-and-opening-clears-it ()
  (let ((a (claude-phone-seen-test--task "a" "running")) (b (claude-phone-seen-test--task "b" "running")))
    (claude-phone-seen-test--with (list a b)
      (should (= 2 (claude-phone-seen-test--dots)))
      (claude-remote-home-task a)
      (should (= 1 (claude-phone-seen-test--dots)))
      (should-not (claude-phone-task-unseen-p a))
      (should (claude-phone-task-unseen-p b)))))

(ert-deftest claude-phone-seen-change-brings-the-dot-back ()
  (let ((a (claude-phone-seen-test--task "a" "running")))
    (claude-phone-seen-test--with (list a)
      (claude-remote-home-task a)
      (should (= 0 (claude-phone-seen-test--dots)))
      (setq claude-phone-glance (list :tasks (vector (claude-phone-seen-test--task "a" "running" "tool: Bash"))))
      (should (= 1 (claude-phone-seen-test--dots)))
      (setq claude-phone-glance (list :tasks (vector (claude-phone-seen-test--task "a" "done"))))
      (should (= 1 (claude-phone-seen-test--dots))))))

(ert-deftest claude-phone-seen-survives-a-restart-and-ignores-a-damaged-file ()
  (let ((a (claude-phone-seen-test--task "a" "running")))
    (claude-phone-seen-test--with (list a)
      (claude-remote-home-task a)
      (setq claude-phone--seen nil claude-phone--seen-loaded nil) ; a new Emacs reads the file
      (should-not (claude-phone-task-unseen-p a))
      (with-temp-file claude-phone-seen-file (insert "((\"a\" . 3) garbage"))
      (setq claude-phone--seen nil claude-phone--seen-loaded nil)
      (should (claude-phone-task-unseen-p a))
      (with-temp-file claude-phone-seen-file (insert "(1 (\"a\" . 3) (\"b|c\" . \"s\"))"))
      (setq claude-phone--seen nil claude-phone--seen-loaded nil)
      (should (equal '(("b|c" . "s")) (claude-phone--seen))))))

(ert-deftest claude-phone-seen-forgets-tasks-that-left-the-board ()
  (let ((a (claude-phone-seen-test--task "a" "running")) (b (claude-phone-seen-test--task "b" "running")))
    (claude-phone-seen-test--with (list a b)
      (claude-remote-home-task a)
      (claude-remote-home-task b)
      (should (= 2 (length (claude-phone--seen))))
      (setq claude-phone-glance (list :tasks (vector b)))
      (claude-remote-home-task b)
      (should (= 1 (length (claude-phone--seen)))))))

(ert-deftest claude-phone-seen-unwritable-file-is-a-message-not-an-error ()
  (let ((a (claude-phone-seen-test--task "a" "running")))
    (claude-phone-seen-test--with (list a)
      (let ((claude-phone-seen-file "/proc/no/such/dir/seen"))
        (claude-remote-home-task a)
        (should-not (claude-phone-task-unseen-p a))))))

;;; Swipe

(ert-deftest claude-phone-swipe-direction-needs-distance-and-a-flat-path ()
  (should (eq 'left (claude-remote-swipe-direction -300 20 1000)))
  (should (eq 'right (claude-remote-swipe-direction 300 -20 1000)))
  (should-not (claude-remote-swipe-direction 100 0 1000))   ; a tap's wobble or a short drag
  (should-not (claude-remote-swipe-direction 300 200 1000)) ; a scroll
  (should-not (claude-remote-swipe-direction 300 0 0)))

(defun claude-phone-seen-test--ev (kind id x y &optional more)
  (let ((posn (list (selected-window) nil (cons x y) 0)))
    (pcase kind
      ('begin (list 'touchscreen-begin (cons id posn)))
      ('update (list 'touchscreen-update (list (cons id posn))))
      ('end (append (list 'touchscreen-end (cons id posn)) more)))))

(defmacro claude-phone-seen-test--swipes (&rest body)
  "Run BODY collecting the swipes in `got' (each (DIRECTION . WINDOW)); timers run at once."
  `(let* ((got nil) (claude-remote-swipe--start nil)
          (claude-remote-swipe-active-function nil)
          (claude-remote-swipe-function (lambda (d w) (push (cons d w) got))))
     (cl-letf (((symbol-function 'run-at-time) (lambda (_ _ f &rest a) (apply f a))))
       ,@body)
     (nreverse got)))

(ert-deftest claude-phone-swipe-events-fire-once-at-the-lift ()
  (let* ((w (window-pixel-width (selected-window))) (far (max 400 w))
         (got (claude-phone-seen-test--swipes
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'begin 1 far 50))
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'update 1 (/ far 2) 52))
               (should-not got)
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'end 1 0 55))
               ;; a lift without a start does nothing
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'end 1 0 55)))))
    (should (equal '(left) (mapcar #'car got)))))

(ert-deftest claude-phone-swipe-ignores-taps-pinches-cancels-and-other-events ()
  (should-not (claude-phone-seen-test--swipes
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'begin 1 100 50))
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'end 1 104 51))))
  (should-not (claude-phone-seen-test--swipes ; two fingers
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'begin 1 900 50))
               (claude-remote-swipe-feed (list 'touchscreen-update
                                               (list (cons 1 (list (selected-window) nil '(900 . 50) 0))
                                                     (cons 2 (list (selected-window) nil '(800 . 50) 0)))))
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'end 1 0 50))))
  (should-not (claude-phone-seen-test--swipes ; cancelled
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'begin 1 900 50))
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'end 1 0 50 '(t)))))
  (should-not (claude-phone-seen-test--swipes ; the other finger's lift, a mouse event, nothing
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'begin 1 900 50))
               (claude-remote-swipe-feed (claude-phone-seen-test--ev 'end 2 0 50))
               (claude-remote-swipe-feed '(mouse-1 nil))
               (claude-remote-swipe-feed nil))))

(ert-deftest claude-phone-swipe-moves-through-the-board-in-order ()
  (let ((a (claude-phone-seen-test--task "a" "running")) (b (claude-phone-seen-test--task "b" "running"))
        (c (claude-phone-seen-test--task "c" "running")))
    (claude-phone-seen-test--with (list a b c)
      (let ((claude-remote-home--view 'detail) (win (selected-window)) (msgs nil))
        (cl-letf (((symbol-function 'message) (lambda (f &rest a) (push (apply #'format f a) msgs))))
          (set-window-buffer win (get-buffer-create claude-remote-home-buffer))
          (claude-remote-home-task b)
          (claude-remote-home-swipe 'left win)
          (should (equal "c" (plist-get (plist-get claude-remote-home--detail :agent) :title)))
          (claude-remote-home-swipe 'left win)
          (should (equal "c" (plist-get (plist-get claude-remote-home--detail :agent) :title)))
          (should (equal "This is the last agent" (car msgs)))
          (claude-remote-home-swipe 'right win)
          (claude-remote-home-swipe 'right win)
          (should (equal "a" (plist-get (plist-get claude-remote-home--detail :agent) :title)))
          (claude-remote-home-swipe 'right win)
          (should (equal "This is the first agent" (car msgs)))
          ;; opening by swipe marks it seen
          (should-not (claude-phone-task-unseen-p a))
          ;; the agent left the Board
          (setq claude-phone-glance (list :tasks (vector b c)))
          (claude-remote-home-swipe 'left win)
          (should (equal "That agent is no longer on the Board" (car msgs))))))))

(ert-deftest claude-phone-swipe-does-nothing-outside-the-detail ()
  (let ((a (claude-phone-seen-test--task "a" "running")) (b (claude-phone-seen-test--task "b" "running")))
    (claude-phone-seen-test--with (list a b)
      (let ((win (selected-window)))
        (set-window-buffer win (get-buffer-create claude-remote-home-buffer))
        (claude-remote-home-task a)
        (setq claude-remote-home--view 'board)
        (claude-remote-home-swipe 'left win)
        (should (equal "a" (plist-get (plist-get claude-remote-home--detail :agent) :title)))
        (setq claude-remote-home--view 'detail)
        (with-temp-buffer (set-window-buffer win (current-buffer))
                          (claude-remote-home-swipe 'left win))
        (should (equal "a" (plist-get (plist-get claude-remote-home--detail :agent) :title)))))))

(provide 'claude-phone-seen-test)
