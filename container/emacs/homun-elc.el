;;; homun-elc.el --- Compiled copies of the cockpit's Elisp, made at daemon start -*- lexical-binding: t -*-

;; The checkout is mounted read-only, so compiled files go to
;; ~/claude/.services/emacs/elc/<key>/, where <key> is a hash of the sources.  The directory is
;; made once per source state, by a child Emacs in batch mode, and `homun-elc-ensure' returns it
;; for the front of `load-path'.  A file that fails to compile gets no .elc there and so loads
;; from its source, further down `load-path'.  `load file' and live development keep loading
;; the sources.  Native code is not made: Emacs finds no .eln for a loaded .elc (tried), and the .eln of
;; the sources is only used when the .el loads.

;;; Code:

(require 'homun-dir)
(require 'bytecomp)

(defvar homun-elc-root (expand-file-name "~/claude/.services/emacs/elc/")
  "Where the compiled directories are kept, one per source state.")

(defun homun-elc--sources ()
  "The .el files of the cockpit that are compiled, as paths relative to the source
directory."
  (let ((default-directory homun-cockpit-dir))
    (seq-remove (lambda (f) (member f '("init.el" "cockpit.el" "homun-dir.el" "homun-elc.el")))
                (append (directory-files "." nil "\\`[^.].*\\.el\\'")
                        (mapcar (lambda (f) (concat "widgetry/" f))
                                (directory-files "widgetry" nil "\\`widgetry.*\\.el\\'"))))))

(defun homun-elc--key (files)
  "A hash of the names and contents of FILES, in the source directory."
  (let ((default-directory homun-cockpit-dir))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert "layout 2\0")
      (dolist (f files)
        (insert f "\0")
        (insert-file-contents-literally f))
      (secure-hash 'sha1 (current-buffer)))))

(defun homun-elc-batch (dest files load-path-list)
  "In a batch Emacs: byte-compile FILES of the source directory into DEST.
A failed file leaves no .elc and gets one line on stderr."
  (let ((load-path load-path-list)
        (default-directory homun-cockpit-dir)
        (byte-compile-dest-file-function
         (lambda (f) (expand-file-name (concat (file-relative-name f homun-cockpit-dir) "c") dest))))
    (dolist (f files)
      (make-directory (file-name-directory (expand-file-name f dest)) t)
      (unless (eq t (byte-compile-file f))
        (ignore-errors (delete-file (expand-file-name (concat f "c") dest)))
        (message "homun-elc: %s did not compile, it loads from source" f))
      ;; Emacs with native compilation looks for the source next to a .elc it finds by
      ;; searching `load-path' (it hashes it for the .eln name), and signals file-missing
      ;; for FOO.el.gz when there is none: link the source beside the .elc
      (when (file-exists-p (expand-file-name (concat f "c") dest))
        (make-symbolic-link (expand-file-name f homun-cockpit-dir) (expand-file-name f dest) t)))))

(defun homun-elc--build (dest files)
  "Compile FILES into the new directory DEST with a child Emacs.  Non-nil when it
ran."
  (let ((exe (expand-file-name invocation-name invocation-directory))
        (log (get-buffer-create " *homun-elc*")))
    (make-directory dest t)
    (with-current-buffer log (erase-buffer))
    (and (zerop (call-process
                 exe nil log nil "--batch" "--eval" (format "(setq load-path '%S)"
                         (append (list (directory-file-name homun-cockpit-dir)
                                       (expand-file-name "widgetry" homun-cockpit-dir))
                                 load-path))
                 "--load" (expand-file-name "homun-elc.el" homun-cockpit-dir)
                 "--eval" (format "(homun-elc-batch %S '%S load-path)" dest files)))
         (progn (with-current-buffer log
                  (dolist (l (split-string (buffer-string) "\n" t))
                    (when (string-prefix-p "homun-elc:" l) (message "%s" l)))) t))))

(defun homun-elc-enable ()
  "Put the compiled directory ahead of the sources on `load-path', if a test
require works.
A failure (or no directory) leaves `load-path' as it was and everything loads
from source."
  (when-let* ((elc (homun-elc-ensure)))
    (let ((saved load-path))
      (condition-case err
          (progn (add-to-list 'load-path (expand-file-name "widgetry" elc))
                 (add-to-list 'load-path (directory-file-name elc))
                 (require 'claude-gc)
                 (require 'widgetry))
        (error (setq load-path saved)
               (message "homun-elc: compiled copy unusable, loading sources (%s)"
                        (error-message-string err)))))))

(defun homun-elc-ensure ()
  "The directory of compiled sources, made first when missing; nil when it cannot
be made."
  (condition-case err
      (let* ((files (homun-elc--sources))
             (dir (expand-file-name (homun-elc--key files) homun-elc-root))
             (done (expand-file-name "done" dir)))
        (unless (file-exists-p done)
          (let ((tmp (concat (directory-file-name dir) ".tmp")))
            (delete-directory tmp t)
            (unless (homun-elc--build tmp files)
              (error "the child Emacs failed"))
            (delete-directory dir t)
            (rename-file tmp dir)
            (write-region "" nil done)
            (dolist (old (directory-files homun-elc-root t "\\`[^.]"))
              (unless (equal (file-name-as-directory old) (file-name-as-directory dir))
                (delete-directory old t)))))
        dir)
    (error (message "homun-elc: no compiled copy, loading sources (%s)" (error-message-string err))
           nil)))

(provide 'homun-elc)
;;; homun-elc.el ends here
