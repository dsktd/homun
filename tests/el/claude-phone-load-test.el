;;; claude-phone-load-test.el --- ERT: the phone's files load alone and bind only defined commands -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/claude-phone-load-test.el -f ert-run-tests-batch-and-exit
;; The phone gets exactly the gateway's client set (container/cockpit-gateway/client.go): the
;; cockpit's Elisp minus clientSkip, widgetry flat beside it and the ELPA clientDeps.  Each entry
;; file is loaded in its own `emacs -Q' with only that set on `load-path'.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst claude-phone-load-test--src
  (expand-file-name "container/emacs" (locate-dominating-file (or load-file-name buffer-file-name default-directory) "container")))

(defconst claude-phone-load-test--entries
  '("claude-remote" "claude-remote-home" "claude-remote-live" "claude-remote-report" "claude-remote-swipe"
    "claude-phone" "claude-task-detail")
  "The files the phone loads itself or through its UI.")

(defun claude-phone-load-test--go-list (name)
  "The strings of the Go variable NAME in client.go."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "../cockpit-gateway/client.go" claude-phone-load-test--src))
    (goto-char (point-min))
    (re-search-forward (concat name " = "))
    (let ((end (save-excursion (re-search-forward "[}\n]\\(?:$\\|\n\\)") (point))) names)
      (while (re-search-forward "\"\\([^\"]+\\.el\\|[a-z-]+\\)\"" end t) (push (match-string 1) names))
      (nreverse names))))

(defvar claude-phone-load-test--dir nil)

(defun claude-phone-load-test--fetch-set ()
  "A directory holding the files the gateway serves the phone."
  (or claude-phone-load-test--dir
      (let ((dir (make-temp-file "phone-fetch" t))
            (skip (claude-phone-load-test--go-list "clientSkip")))
        (dolist (f (append (directory-files claude-phone-load-test--src t "\\`[^.].*\\.el\\'")
                           (directory-files (expand-file-name "widgetry" claude-phone-load-test--src) t "\\`widgetry.*\\.el\\'")))
          (unless (member (file-name-nondirectory f) skip)
            (make-symbolic-link f (expand-file-name (file-name-nondirectory f) dir))))
        (dolist (dep (claude-phone-load-test--go-list "clientDeps"))
          (when-let* ((lib (locate-library dep)))
            (dolist (f (directory-files (file-name-directory lib) t "\\.el\\'"))
              (unless (string-match-p "-\\(autoloads\\|pkg\\)\\.el\\'" f)
                (ignore-errors (make-symbolic-link f (expand-file-name (file-name-nondirectory f) dir)))))))
        (setq claude-phone-load-test--dir dir))))

(defun claude-phone-load-test--emacs (dir form)
  "Run FORM in a clean batch Emacs with DIR and Emacs's own Lisp on `load-path'; (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((code (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                              "-Q" "--batch" "--eval" (format "(let ((lisp (file-name-directory (locate-library \"simple\"))))
                                      (setq load-path (cons %S (seq-filter (lambda (d) (string-prefix-p lisp (file-name-as-directory d))) load-path))))" dir)
                              "--eval" (prin1-to-string form))))
      (cons code (buffer-string)))))

(ert-deftest claude-phone-fetch-set-has-the-entry-files ()
  (let ((dir (claude-phone-load-test--fetch-set)))
    (dolist (e claude-phone-load-test--entries)
      (should (file-exists-p (expand-file-name (concat e ".el") dir))))
    (should (file-exists-p (expand-file-name "consult.el" dir)))))

(ert-deftest claude-phone-entry-files-load-alone ()
  (let ((dir (claude-phone-load-test--fetch-set)))
    (dolist (e claude-phone-load-test--entries)
      (let ((res (claude-phone-load-test--emacs dir `(progn (require ',(intern e)) (message "loaded")))))
        (should (equal (list e 0) (list e (car res))))
        (unless (zerop (car res)) (message "%s: %s" e (cdr res)))
        (should-not (string-match-p "void-function\\|Symbol.s function definition is void" (cdr res)))))))

;; Reading a file's forms gives two lists: the symbols its code binds or calls.  A call counts only
;; when some file of the fetch set defines the function, so Emacs's own and optional ones are left out.

(defun claude-phone-load-test--forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun claude-phone-load-test--defined (dir)
  "The functions and macros the .el files of DIR define at top level."
  (let (out)
    (dolist (f (directory-files dir t "\\.el\\'"))
      (dolist (form (claude-phone-load-test--forms f))
        (when (and (memq (car-safe form) '(defun defmacro cl-defun cl-defmacro defsubst define-minor-mode define-derived-mode))
                   (symbolp (cadr form)))
          (push (cadr form) out))))
    out))

(defun claude-phone-load-test--uses (file defined)
  "The symbols FILE binds (#'SYM, a quoted key target) or calls that are in DEFINED.
Those it declares with `declare-function' are left out: it says they come from a file it loads late."
  (let (out declared)
    (cl-labels ((walk (x)
                  (when (consp x)
                    (cond ((and (eq (car x) 'function) (symbolp (cadr x))) (push (cadr x) out))
                          ((eq (car x) 'declare-function) (push (cadr x) declared))
                          ((and (memq (car x) '(define-key keymap-set)) (eq (car-safe (nth 3 x)) 'quote)
                                (symbolp (cadr (nth 3 x))))
                           (push (cadr (nth 3 x)) out))
                          ((and (symbolp (car x)) (memq (car x) defined)) (push (car x) out)))
                    (while (consp x) (walk (car x)) (setq x (cdr x))))))
      (mapc #'walk (claude-phone-load-test--forms file)))
    (seq-difference (delete-dups out) declared)))

(ert-deftest claude-phone-bound-and-called-functions-are-defined ()
  "Loading one entry file, everything it binds or calls that the fetch set defines is fboundp.
Each file is tried alone, so a `require' it forgot is not made up for by another file."
  (let* ((dir (claude-phone-load-test--fetch-set))
         (defined (claude-phone-load-test--defined dir)))
    (dolist (e claude-phone-load-test--entries)
      (let* ((syms (claude-phone-load-test--uses (expand-file-name (concat e ".el") dir) defined))
             (res (claude-phone-load-test--emacs
                   dir `(progn (require ',(intern e))
                               (dolist (s ',syms) (unless (fboundp s) (message "UNDEFINED %s" s)))))))
        (should (equal (list e 0) (list e (car res))))
        (should (equal (list e nil)
                       (list e (seq-filter (lambda (l) (string-prefix-p "UNDEFINED" l))
                                           (split-string (cdr res) "\n")))))))))

(provide 'claude-phone-load-test)
