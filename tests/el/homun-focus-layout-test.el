;;; homun-focus-layout-test.el --- ERT for the focus shape of homun-layout.el -*- lexical-binding: t; -*-
;; emacs --batch -L container/emacs -L <evil> -l tests/el/homun-focus-layout-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'claude)
(require 'claude-transcript)
(require 'claude-transcript-focus)
(require 'homun-layout)
(require 'homun-iface)
(require 'evil nil t)

(defconst homun-focus-layout-test--fixture
  (expand-file-name "claude-transcript-fixture.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun homun-focus-layout-test--state ()
  "Windows of the selected frame as (REGION BUFFER START), left to right."
  (mapcar (lambda (w) (list (window-parameter w 'homun-region) (window-buffer w) (window-start w)))
          (window-list nil 'no-minibuf)))

(defmacro homun-focus-layout-test--with (&rest body)
  "Run BODY in the four-region layout with a transcript of the fixture shown."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "homun-focus" t))
          (file (expand-file-name "session.jsonl" dir))
          (claude-transcript-projects-directory dir)
          (homun-layout-lock t) (homun-layout-narrow-columns 1)
          (homun-layout-orientation 'wide) (homun-layout-compose-lines 4)
          (config (current-window-configuration))
          (compose (generate-new-buffer " compose-test"))
          (transcript (generate-new-buffer " transcript-test")))
     (copy-file homun-focus-layout-test--fixture file)
     (unwind-protect
         (progn
           (set-frame-size nil 120 50)
           (homun-layout--build)
           (with-current-buffer transcript
             (claude-transcript-mode)
             (setq claude-transcript--file file)
             (claude-transcript--render claude-transcript-tail-turns))
           (homun-layout-show transcript (homun-layout-window 'transcript))
           (homun-layout-show compose (homun-layout-window 'compose))
           (select-window (homun-layout-window 'compose))
           ,@body)
       (let ((ignore-window-parameters t) (homun-layout-lock nil))
         (when-let* ((b (get-buffer (format "*focus: %s*" (file-name-base file))))) (kill-buffer b))
         (set-frame-parameter nil (quote homun-layout-focus) nil)
         (homun-layout-lock-apply)
         (set-window-configuration config)
         (kill-buffer compose) (kill-buffer transcript)
         (delete-directory dir t)))))

(ert-deftest homun-focus-layout-enter-shows-two-windows ()
  (homun-focus-layout-test--with
    (homun-layout-focus-toggle)
    (should (= 2 (length (window-list nil 'no-minibuf (frame-first-window)))))
    (should (eq 'focus (homun-layout--shape)))
    (let ((view (homun-layout-window 'transcript))
          (compose (homun-layout-window 'compose)))
      (should (provided-mode-derived-p (buffer-local-value 'major-mode (window-buffer view))
                                       'claude-transcript-focus-mode))
      (should (eq (window-buffer compose) (get-buffer " compose-test")))
      (should (< (window-top-line view) (window-top-line compose)))
      (should (= (window-total-height compose) 4)))))

(ert-deftest homun-focus-layout-exit-restores-windows ()
  (homun-focus-layout-test--with
    (set-window-start (homun-layout-window 'transcript) 5)
    (let ((before (homun-focus-layout-test--state)))
      (homun-layout-focus-toggle)
      (homun-layout-focus-toggle)
      (should (equal before (homun-focus-layout-test--state)))
      (should-not (frame-parameter nil 'homun-layout-focus))
      (should (eq 'wide (homun-layout--shape))))))

(ert-deftest homun-focus-layout-q-restores-windows ()
  (homun-focus-layout-test--with
    (let ((before (sort (mapcar #'car (homun-focus-layout-test--state)) #'string<)))
      (select-window (homun-layout-window 'transcript))
      (claude-transcript-focus)
      (should (= 2 (length (window-list nil 'no-minibuf (frame-first-window)))))
      (with-current-buffer (window-buffer (homun-layout-window 'transcript))
        (claude-transcript-focus-quit))
      (should (equal before (sort (mapcar #'car (homun-focus-layout-test--state)) #'string<)))
      (should (derived-mode-p 'claude-transcript-mode)))))

(ert-deftest homun-focus-layout-starts-in-interface-state ()
  (skip-unless (featurep 'evil))
  (should (eq (evil-initial-state 'claude-transcript-focus-mode) 'homun-interface)))

;; In the focus view j, k and ]] move, i selects the box in insert state and typing lands there
(ert-deftest homun-focus-layout-keys-navigate-and-compose ()
  (skip-unless (featurep 'evil))
  (let ((was evil-mode))
    (evil-mode 1)
    (unwind-protect
        (homun-focus-layout-test--with
          (homun-layout-focus-toggle)
          (let ((view (selected-window)))
            (should (eq evil-state 'homun-interface))
            (execute-kbd-macro (kbd "M-j"))
            (should (eq last-command 'homun-iface-next))
            (execute-kbd-macro (kbd "]]"))
            (should (eq last-command 'homun-iface-next-turn))
            (execute-kbd-macro (kbd "i"))
            (should (eq (selected-window) (homun-layout-window 'compose)))
            (should (eq evil-state 'insert))
            (should (eq (buffer-local-value 'evil-state (window-buffer view)) 'homun-interface))
            (execute-kbd-macro (kbd "test"))
            (should (equal (with-current-buffer " compose-test" (buffer-string)) "test"))))
      (unless was (evil-mode -1)))))

;; The live cockpit: the files loaded again in today's order, the real compose
;; box, a view left over from before in normal state
(ert-deftest homun-focus-layout-live-loaded-typing ()
  (skip-unless (featurep 'evil))
  (require 'claude-compose)
  (let ((was evil-mode)
        (dir (file-name-directory (locate-library "claude-transcript-focus"))))
    (evil-mode 1)
    (dolist (file '("claude-compose" "homun-iface" "claude-transcript-focus"))
      (load (expand-file-name (concat file ".el") dir) nil t))
    (unwind-protect
        (homun-focus-layout-test--with
          (let ((box (claude-compose--buffer)))
            (homun-layout-show box (homun-layout-window 'compose))
            (select-window (homun-layout-window 'compose))
            (evil-normal-state)
            (execute-kbd-macro (kbd "TAB"))
            (should (derived-mode-p 'claude-transcript-focus-mode))
            (dolist (state '(homun-interface normal))
              (select-window (homun-layout-window 'transcript))
              (evil-change-state state)
              (execute-kbd-macro (kbd "i"))
              (should (eq (window-buffer (selected-window)) box))
              (should (eq evil-state 'insert))
              (execute-kbd-macro (kbd "cat")))
            (should (equal (with-current-buffer box (buffer-string)) "catcat"))
            (with-current-buffer box (erase-buffer))))
      (unless was (evil-mode -1)))))

;; The buffer-local size hook gets a window, not a frame
(ert-deftest homun-focus-layout-size-hook-takes-a-window ()
  (homun-focus-layout-test--with
    (homun-layout-focus-toggle)
    (let ((view (homun-layout-window 'transcript)))
      (claude-transcript-focus--size-changed view)
      (claude-transcript-focus--size-changed (selected-frame)))))

;;; homun-focus-layout-test.el ends here
