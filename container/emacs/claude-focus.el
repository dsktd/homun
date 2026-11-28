;;; claude-focus.el --- What Emacs shows next, set by the Manager -*- lexical-binding: t -*-

;; The Manager picks what Emacs should show for the work at hand with
;; `claude-focus-set' (bin/claude-emacs show). It lives in the daemon for two
;; hours. A new frame starts on it (`claude-frame-start'); a frame that is
;; already open gets it in another window, without being raised, focused or
;; having its selected window or point touched.

(require 'homun-layout)
(require 'subr-x)
(require 'claude-identity)

(defvar claude-focus-ttl 7200
  "Seconds a focus stays valid after `claude-focus-set'.")

(defvar claude-focus--state nil
  "The focus as (KIND ARG TITLE TIME), or nil.")

(declare-function claude-dashboard-buffer "claude-dashboard" ())
(declare-function claude--report-buffer "claude" (file &optional title))
(declare-function claude-open-dir "claude" (dir))

(defun claude-focus--current ()
  "The focus as (KIND ARG TITLE), or nil when none is set or it expired."
  (pcase claude-focus--state
    (`(,kind ,arg ,title ,time)
     (when (< (- (float-time) time) claude-focus-ttl)
       (list kind arg title)))))

(defun claude-focus--buffer (kind arg)
  "A buffer showing ARG of the focus KIND, without displaying it."
  (pcase kind
    ('file (let* ((path (if (consp arg) (car arg) arg))
                  (buffer (let ((revert-without-query '(".*"))) (find-file-noselect path))))
             ;; Only place point in a buffer nobody is looking at
             (when (and (consp arg) (not (get-buffer-window buffer t)))
               (with-current-buffer buffer
                 (goto-char (point-min))
                 (forward-line (1- (cdr arg)))))
             buffer))
    ('dir (dired-noselect arg))
    ('diff (diff-no-select (car arg) (cdr arg) nil t))
    ('report (claude--report-buffer arg (nth 2 claude-focus--state)))
    ('dashboard (claude-dashboard-buffer))
    (_ (user-error "Unknown focus %s" kind))))

(defun claude-focus--show-live (frame buffer title)
  "Show BUFFER beside the work in FRAME and say so, leaving the user's focus alone."
  (homun-layout-beside buffer frame)
  (message "%s: showing %s" claude-agent-name title))

(defun claude-focus-set (kind arg &optional title)
  "Make KIND the focus with target ARG; show it in a GUI frame if one exists.
KIND is `file' (ARG a path or (PATH . LINE)), `dir' (a path), `diff' (the
cons (A . B) of two paths), `report' (a path) or `dashboard' (ARG ignored).
TITLE names it in the echo area, and is the buffer name of a report."
  (let ((title (or title (pcase arg
                           ((pred stringp) (file-name-nondirectory (directory-file-name arg)))
                           (`(,(and (pred stringp) path) . ,_) (file-name-nondirectory path))
                           (_ (symbol-name kind))))))
    (setq claude-focus--state (list kind arg title (float-time)))
    (when-let* ((frame (and (not noninteractive)
                            (seq-find (lambda (f) (frame-parameter f 'window-system))
                                      (frame-list)))))
      (claude-focus--show-live frame (claude-focus--buffer kind arg) title))
    title))

(defun claude-focus-clear ()
  "Drop the focus."
  (setq claude-focus--state nil)
  t)

(defun claude-focus-show-here ()
  "Show the focus, or the dashboard when there is none, in the selected window."
  (interactive)
  (if-let* ((focus (claude-focus--current)))
      (pcase-let ((`(,kind ,arg ,_title) focus))
        (if (eq kind 'dir)
            (claude-open-dir arg)
          (switch-to-buffer (claude-focus--buffer kind arg))))
    (switch-to-buffer (claude-dashboard-buffer))))

(provide 'claude-focus)

;;; claude-focus.el ends here
