;;; homun-compile.el --- compilation buffers for agents' builds (bin/homun-compile) -*- lexical-binding: t -*-

;; `compile start' runs COMMAND in DIR with `compilation-start' (so cargo, gradle and nix
;; errors are clickable), in the buffer "*compile: <dir>: <command>*", without showing it or
;; taking focus.  When it ends, its output and then its exit status are written to
;; <homun-compile-dir>/<ID>.out and <ID>.status; bin/homun-compile polls for the status file.

(require 'compile)
(require 'homun-api)

(defvar homun-compile-dir (expand-file-name "~/claude/.services/emacs/compile/")
  "Where the results of finished runs are written.")

(defvar homun-compile-keep 20 "How many compile buffers made here stay.")

(defvar-local homun-compile--id nil "The run id of this buffer, nil for any other.")
(defvar-local homun-compile--time nil "When this buffer's run started.")
(defvar-local homun-compile--code nil "The exit status of the run, once known.")

(defun homun-compile--name (dir command)
  "A new buffer name for COMMAND run in DIR."
  (let ((short (replace-regexp-in-string "[ \t\n]+" " " command)))
    (generate-new-buffer-name
     (format "*compile: %s: %s*" (file-name-nondirectory (directory-file-name dir))
             (truncate-string-to-width short 40 nil nil "…")))))

(defun homun-compile--exit (status code msg)
  "Remember CODE for the finish hook; leave the message as it is."
  (setq homun-compile--code code)
  (cons msg status))

(defun homun-compile--finish (buffer _msg)
  "Write BUFFER's output, then its status, when it is one of ours."
  (when-let* ((id (buffer-local-value 'homun-compile--id buffer)))
    (let ((base (expand-file-name id homun-compile-dir))
          (code (or (buffer-local-value 'homun-compile--code buffer) 1)))
      (make-directory homun-compile-dir t)
      (with-current-buffer buffer
        (write-region (point-min) (point-max) (concat base ".out") nil 'silent))
      (write-region (format "%d\n" code) nil (concat base ".status") nil 'silent)
      (run-at-time 0 nil #'homun-compile--trim))))

(defun homun-compile--trim ()
  "Kill the oldest finished compile buffers of ours beyond `homun-compile-keep'."
  (let ((ours (seq-filter (lambda (b) (and (buffer-local-value 'homun-compile--id b)
                                           (null (get-buffer-process b))))
                          (buffer-list))))
    (dolist (b (nthcdr homun-compile-keep
                       (sort ours (lambda (a b) (> (buffer-local-value 'homun-compile--time a)
                                                   (buffer-local-value 'homun-compile--time b))))))
      (kill-buffer b))))

;; A finished run's process is gone only after the sentinel returns: trim from a timer.
(add-hook 'compilation-finish-functions #'homun-compile--finish)

(defun homun-compile-start (dir command id)
  "Run COMMAND in DIR as run ID, in a buffer that is not shown.  Return its name."
  (unless (file-directory-p dir) (homun-api--fail 'invalid "no directory %s" dir))
  (unless (string-match-p "\\`[A-Za-z0-9_.-]+\\'" id) (homun-api--fail 'invalid "bad id %s" id))
  (let* ((default-directory (file-name-as-directory (expand-file-name dir)))
         (name (homun-compile--name dir command))
         (compilation-buffer-name-function (lambda (_mode) name))
         (compilation-ask-about-save nil)
         (display-buffer-overriding-action '(display-buffer-no-window (allow-no-window . t)))
         (buffer (compilation-start command nil)))
    (with-current-buffer buffer
      (setq homun-compile--id id
            homun-compile--code nil
            homun-compile--time (float-time)
            compilation-exit-message-function #'homun-compile--exit))
    name))

(homun-api-define "compile start" "Run COMMAND in DIR with compilation-start in a buffer \"*compile: <dir>: <command>*\" that is not shown; when it ends its output is in compile/ID.out and its exit status in compile/ID.status under ~/claude/.services/emacs (bin/homun-compile does all this)."
    ((dir string :required t) (command string :required t) (id string :required t))
  (homun-compile-start dir command id))

;;; Batch checks: ERT and byte-compile in a fresh batch Emacs, then their summary

(defun homun-compile--elisp-file (file)
  "FILE expanded when it is an existing .el file in a git checkout under ~/claude."
  (let ((full (homun-api--existing 'file file)))
    (unless (and (string-suffix-p ".el" full)
                 (string-prefix-p (expand-file-name "~/claude/") full)
                 (not (string-prefix-p (expand-file-name "~/claude/.services/") full))
                 (locate-dominating-file full ".git"))
      (homun-api--fail 'invalid "file: a .el file in a checkout under ~/claude, not %s" full))
    full))

(defun homun-compile--batch (files &rest tail)
  "The batch Emacs command line for FILES (all of one checkout) followed by TAIL."
  (let* ((root (or (locate-dominating-file (car files) "container/emacs")
                   (file-name-directory (car files))))
         (lisp (expand-file-name "container/emacs" root))
         (dirs (delete-dups (append (list lisp (expand-file-name "widgetry" lisp))
                                    (mapcar #'file-name-directory files)))))
    (mapconcat #'shell-quote-argument
               (append (list (expand-file-name invocation-name invocation-directory) "-Q" "--batch")
                       (mapcan (lambda (d) (list "-L" (directory-file-name d))) dirs)
                       tail)
               " ")))

(defun homun-compile--sh (dir command kind)
  "Start COMMAND (POSIX-quoted) in DIR under sh, whatever the user's shell.
Return the run id."
  (let ((id (format "%s-%s-%d" kind (format-time-string "%s") (random 100000)))
        (shell-file-name (or (executable-find "sh") "/bin/sh"))
        (shell-command-switch "-c"))
    (homun-compile-start dir command id)
    id))

(defun homun-compile-ert (file selector)
  "Start the ERT tests of FILE that SELECTOR (a regexp of test names) picks.
Return the run id."
  (unless (string-match-p "\\`[][A-Za-z0-9_.*+?^$|\\\\-]+\\'" selector)
    (homun-api--fail 'invalid "selector: a regexp of test names, not %s" selector))
  (let ((full (homun-compile--elisp-file file)))
    (homun-compile--sh (file-name-directory full)
                       (homun-compile--batch
                        (list full) "-l" full "--eval"
                        (format "(ert-run-tests-batch-and-exit %S)" selector))
                       "ert")))

(defun homun-compile-check (files)
  "Start byte-compiling FILES (space separated) into a scratch directory.
Return the run id."
  (let ((full (mapcar #'homun-compile--elisp-file (split-string files nil t)))
        (out (make-temp-file "homun-bytecomp" t)))
    (unless full (homun-api--fail 'invalid "files: none given"))
    (homun-compile--sh (file-name-directory (car full))
                       (apply #'homun-compile--batch full "--eval"
                              (format "(setq byte-compile-dest-file-function (lambda (f) (expand-file-name (concat (file-name-nondirectory f) \"c\") %S)))" out)
                              "-f" "batch-byte-compile" full)
                       "bytecomp")))

(defconst homun-compile--summary
  "^\\(Ran [0-9]+ tests?\\|[0-9]+ unexpected\\|   FAILED\\|.*: \\(Warning\\|Error\\):\\|Error: \\|Compilation \\(finished\\|exited\\)\\)"
  "Lines of a run's output that make its summary.")

(defun homun-compile-result (id)
  "The state of run ID as a plist: done, status, summary lines and the last lines."
  (unless (string-match-p "\\`[A-Za-z0-9_.-]+\\'" id) (homun-api--fail 'invalid "bad id %s" id))
  (let ((status (expand-file-name (concat id ".status") homun-compile-dir))
        (out (expand-file-name (concat id ".out") homun-compile-dir)))
    (if (not (file-exists-p status))
        (list :id id :done :json-false)
      (with-temp-buffer
        (insert-file-contents out)
        (let ((lines (split-string (buffer-string) "\n" t)))
          (list :id id :done t
                :status (with-temp-buffer (insert-file-contents status) (string-to-number (buffer-string)))
                :summary (vconcat (seq-take (seq-filter (lambda (l) (string-match-p homun-compile--summary l)) lines) 60))
                :tail (vconcat (last lines 8))))))))

(homun-api-define "ert run" "Run the ERT tests of FILE (a .el file in a checkout under ~/claude) that SELECTOR picks (a regexp of test names, default all) in a fresh batch Emacs with the checkout's container/emacs on the load path; answers {id}: read the result with compile_result."
    ((file string :required t) (selector string :default "."))
  (json-encode (list :id (homun-compile-ert file selector))))

(homun-api-define "compile check" "Byte-compile FILES (space separated .el files of one checkout under ~/claude) in a fresh batch Emacs into a scratch directory, so no .elc lands in the tree; answers {id}: read the warnings with compile_result."
    ((files string :required t))
  (json-encode (list :id (homun-compile-check files))))

(homun-api-define "compile result" "The run ID of compile_start, ert_run or compile_check: done false while it runs, else its exit status, summary (test counts, failures, warnings, errors) and last lines.  Read-only."
    ((id string :required t))
  (json-encode (homun-compile-result id)))

(provide 'homun-compile)
;;; homun-compile.el ends here
