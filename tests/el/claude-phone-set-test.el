;;; claude-phone-set-test.el --- ERT: the phone's own file set, as the gateway ships it -*- lexical-binding: t -*-
;; The phone loads a flat directory of the files cockpit-gateway's client.go serves (no init.el,
;; cockpit.el, Doom or other desktop files) into a plain Emacs.  These tests build that directory
;; and drive every phone view in a child `emacs -Q --batch' against an older gateway that knows
;; none of the newer API words, so a missing function or an endpoint the gateway lacks shows.

(require 'ert)
(require 'cl-lib)
(require 'claude)

(defconst claude-phone-set-test--here (file-name-directory (or load-file-name buffer-file-name))
  "This directory, where the transcript fixture is.")

(defconst claude-phone-set-test--skip '("init.el" "cockpit.el" "homun-elc.el" "claude-pair.el" "homun-init.el")
  "client.go's clientSkip.")

(defconst claude-phone-set-test--deps '(magit-section markdown-mode consult timeout compat cond-let llama)
  "client.go's clientDeps, found on this Emacs's `load-path'.")

(defun claude-phone-set-test--dir ()
  "A temporary flat directory holding the phone's files."
  (let* ((src (file-name-directory (locate-library "claude-remote.el")))
         (dir (make-temp-file "phone-set" t)))
    (dolist (f (append (directory-files src t "\\.el\\'")
                       (directory-files (expand-file-name "widgetry" src) t "\\`widgetry.*\\.el\\'")))
      (unless (member (file-name-nondirectory f) claude-phone-set-test--skip)
        (copy-file f (expand-file-name (file-name-nondirectory f) dir) t)))
    (dolist (dep claude-phone-set-test--deps)
      (when-let* ((lib (locate-library (format "%s.el" dep))))
        (dolist (f (directory-files (file-name-directory lib) t "\\.el\\'"))
          (unless (string-match-p "-\\(autoloads\\|pkg\\)\\.el\\'" f)
            (copy-file f (expand-file-name (file-name-nondirectory f) dir) t)))))
    dir))

(defconst claude-phone-set-test--script
  '(progn
     (require 'claude-remote)
     (require 'claude-remote-home)
     (require 'claude-transcript)
     (require 'homun-menu)
     (setq claude-transcript--widget-message t)
     (defun claude-phone-set-test--tap (line label)
       "Call the mouse-1 binding of LABEL in the header or tab LINE (the tabs sit in the mode line)."
       (let* ((i (or (string-search label line) (error "No %s in %S" label line)))
              (map (get-text-property i 'keymap line)))
         (funcall (lookup-key map [mode-line mouse-1]))))
     (advice-add 'claude-remote-transcript-file :override
                 (lambda () (getenv "PHONE_TRANSCRIPT")))
     (let (errs)
       ;; No minibuffer on the phone: any reader a phone path calls is an error
       (dolist (fn '(read-string read-from-minibuffer completing-read y-or-n-p yes-or-no-p read-number
                     read-file-name read-passwd read-multiple-choice read-answer))
         (let ((fn fn))
           (advice-add fn :override (lambda (&rest _) (push (list 'minibuffer fn) errs) ""))))
       ;; An older gateway: every API word is unknown
       (advice-add 'claude-remote-act :override
                   (lambda (_kind _args &optional _argv callback _local)
                     (when callback (funcall callback (list :ok nil :error "unknown api")))))
       (advice-add 'claude-remote-flush :override #'ignore)
       (dolist (step `((board . ,(lambda () (setq claude-remote-home--view 'board) (claude-remote-home-draw)))
                       (status . ,(lambda () (setq claude-remote-home--view 'status) (claude-remote-home-draw)))
                       (approval . ,(lambda () (setq claude-remote-home--view 'approval) (claude-remote-home-draw)))
                       (doctor . claude-remote-home-doctor)
                       (strip . claude-remote-home-strip)
                       (tabs . claude-remote-home-tabs)
                       (pills . ,(lambda ()
                                   (when (string-match-p "\\?" (claude-remote-home-tabs)) (error "Phone has a ? pill"))
                                   (setq claude-remote-home--view 'status) (claude-remote-home-draw)
                                   (with-current-buffer claude-remote-home-buffer
                                     (when (string-search "Update" (buffer-string)) (error "Update pill is back"))
                                     (unless (string-search "homun " (buffer-string)) (error "No version line")))
                                   (unless (transient-get-suffix 'homun-menu-transcript "U") (error "No Update in menu"))))
                       (compose . claude-remote-home-compose)
                       (home . claude-remote-home)
                       (home-tabs . ,(lambda () (claude-remote-home) (unless (string-match-p "Talk.*Board.*Status" (claude-remote-home-tabs)) (error "No tabs"))))
                       ;; Taps run after drawing, so the hooks they call must be set globally
                       (tap-board . ,(lambda ()
                                       (claude-phone-set-test--tap (claude-remote-home-tabs) "Board")
                                       (unless (eq claude-remote-home--view 'board) (error "Board tap did nothing"))))
                       (deny . ,(lambda ()
                                  (setq claude-phone-card 0)
                                  (claude-remote-home--deny "x")
                                  (unless (get-buffer-window claude-phone-ask-buffer) (error "Deny opened no ask window"))
                                  (claude-phone--ask-close)))
                       ;; Allow on the card is a widget whose press runs a plain function
                       (approve . ,(lambda ()
                                     (let ((claude-approve-answer-function #'claude-remote--approve-answer) sent)
                                       (cl-letf (((symbol-function 'claude-remote-act)
                                                  (lambda (kind args &rest _) (push (cons kind args) sent))))
                                         (claude-remote--handle
                                          (list :kind "scene" :source "approve.json"
                                                :data (list :id "approve" :title "Permissions (1)"
                                                            :root (json-parse-string
                                                                   (homun-stage-encode
                                                                    (claude-approve-scene
                                                                     `(((id . "9-9") (tool . "Bash") (summary . "ls")
                                                                        (since . ,(floor (float-time))) (risk . "read-only")))
                                                                     0))
                                                                   :object-type 'plist))))
                                         (puthash "9-9" 0 claude-approve--shown) ; past its guard
                                         (setq claude-phone-card 0 claude-remote-home--view 'approval)
                                         (claude-remote-home-draw)
                                         (with-current-buffer claude-remote-home-buffer
                                           (goto-char (point-min))
                                           (search-forward "Allow")
                                           (widget-apply (widget-at (1- (point))) :notify nil)))
                                       (unless (equal sent '(("approve" :id "9-9" :answer "allow")))
                                         (error "Approve sent %S" sent)))))
                       (stale . ,(lambda ()
                                   (claude-remote-flush)
                                   (claude-phone-confirm "Send?" #'ignore)
                                   (unless (string-match-p "Yes.*No" (buffer-local-value 'header-line-format (get-buffer claude-phone-ask-buffer)))
                                     (error "No Yes/No pills"))
                                   (claude-phone--ask-close)))
                       (tap-status . ,(lambda ()
                                        (claude-phone-set-test--tap (claude-remote-home-tabs) "Status")
                                        (unless (eq claude-remote-home--view 'status) (error "Status tap did nothing"))))
                       (tap-talk . ,(lambda ()
                                      (claude-phone-set-test--tap (claude-remote-home-tabs) "Talk")
                                      (unless (seq-some (lambda (b) (with-current-buffer b (derived-mode-p 'claude-transcript-mode)))
                                                (buffer-list))
                                        (error "Talk tap opened no transcript"))))
                       (choice . ,(lambda ()
                                    (or (claude-transcript--fmt-widgetry
                                         "s" "(choice t1 \"T\" (a \"A\") (b \"B\"))\n(choice t2 \"U\" (x \"X\"))")
                                        (error "No choice rows"))))))
         (get-buffer-create claude-remote-home-buffer)
         (condition-case err (funcall (cdr step)) (error (push (list (car step) err) errs))))
       (dolist (b (buffer-list))
         (with-current-buffer b
           (dolist (fmt (list header-line-format tab-line-format mode-line-format))
             (condition-case err (format-mode-line fmt) (error (push (list (buffer-name b) err) errs))))))
       (princ (format "ERRS %S\n" errs))
       (princ (format "MSGS %S\n" (with-current-buffer "*Messages*" (buffer-string))))))
  "What the child Emacs runs on the phone's file set.")

(defun claude-phone-set-test--run ()
  "The output of the script in a plain Emacs that sees only the phone's files."
  (let ((dir (claude-phone-set-test--dir))
        (default-directory temporary-file-directory) ; "~/..." would follow the child's HOME
        (process-environment
         (append (list (concat "HOME=" (make-temp-file "phone-home" t))
                       (concat "PHONE_TRANSCRIPT="
                               (expand-file-name "claude-transcript-fixture.jsonl" claude-phone-set-test--here)))
                 process-environment)))
    (unwind-protect
        (with-temp-buffer
          (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                        "-Q" "--batch" "-L" dir
                        "--eval" (prin1-to-string claude-phone-set-test--script))
          (buffer-string))
      (delete-directory dir t))))

(ert-deftest claude-phone-set-views-draw-on-an-old-gateway ()
  "Every phone view draws from the phone's files alone, with a gateway that predates it."
  (let ((out (claude-phone-set-test--run)))
    (should (string-match-p "^ERRS nil$" out))
    (should-not (string-match-p "unknown widgetry element" out))
    (should-not (string-match-p "void-function\\|void-variable" out))))

(ert-deftest claude-header-hint-in-a-window-without-mode-line ()
  "The header's hint element is one :eval whose form draws the hint where the mode line
is hidden (a nested (:eval ...) form signalled void-function in redisplay)."
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (let ((homun-key-hints t)           ; hints are off by default
          (element (car (last (claude-header "T" "RET open · ? help")))))
      (should (eq (car element) :eval))
      (setq-local mode-line-format nil)
      (should (string-match-p "RET open" (eval (cadr element) t)))
      (setq-local mode-line-format '("x"))
      (should-not (eval (cadr element) t)))))

;; Batch `format-mode-line' draws nothing, so the window's format is evaluated by hand
(defun claude-phone-set-test--mode-line (window)
  "The text of WINDOW's mode line as the phone's redisplay would draw it, or nil for none."
  (let ((fmt (window-parameter window 'mode-line-format)))
    (unless (eq fmt 'none)
      (with-selected-window window
        (let ((fmt (or fmt mode-line-format)))
          (and fmt (if (eq (car-safe fmt) :eval) (eval (cadr fmt) t) (format "%s" fmt))))))))

(ert-deftest claude-phone-set-tabs-survive-the-transcript ()
  "The phone's main window keeps the Talk, Board and Status pills in its mode line while it
shows the transcript, following or not, and the jump pill after them while scrolled up."
  (require 'claude-remote-home)
  (require 'claude-transcript)
  (save-window-excursion
    (let ((homun-layout-phone t) (claude-transcript-phone t)
          (homun-layout-tabs-function #'claude-remote-home-tabs)
          (window (selected-window)))
      (with-temp-buffer
        (claude-transcript-mode)
        (set-window-buffer window (current-buffer))
        (setq-local mode-line-format nil claude-transcript--unseen 2)
        (set-window-parameter window 'homun-region 'transcript)
        (set-window-parameter window 'mode-line-format '(:eval (homun-layout-narrow-tabs)))
        (unwind-protect
            (dolist (follow '(nil t))
              (set-window-parameter window 'claude-transcript-follow (cons follow 1))
              (claude-transcript--phone-jump window)
              (let ((line (claude-phone-set-test--mode-line window)))
                (dolist (pill '("Talk" "Board" "Status"))
                  (should (string-search pill (or line ""))))
                ;; the jump pill only while scrolled up, after the tabs
                (if follow
                    (should-not (string-search "↓" line))
                  (should (string-match-p "Status.*↓ 2 new · end" line)))))
          (set-window-parameter window 'homun-region nil)
          (set-window-parameter window 'mode-line-format nil))))))

;;; claude-phone-set-test.el ends here
