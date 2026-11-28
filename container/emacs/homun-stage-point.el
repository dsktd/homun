;;; homun-stage-point.el --- Pointing: file pulses, transcript anchors, snapshot chips -*- lexical-binding: t -*-

;; Three ways the Stage and the rest of the cockpit point at each other:
;; - `homun-stage-pulse-file' flashes a line range of a file buffer, by overlay, without
;;   moving point or any window (`stage focus target=file:PATH:FROM[-TO]').
;; - A transcript link [text](homun:stage/SCENE/NODE) is an anchor: hovering it highlights the
;;   node in the scene buffer, hovering the node highlights the prose.
;; - [text](homun:stage/SCENE) is a chip: while the scene is open it hovers like an anchor,
;;   once closed a click opens its last state read-only.

(require 'cl-lib)
(require 'homun-stage-store)
(require 'homun-button)

(defface homun-stage-pulse '((t :inherit highlight :extend t)) "A pulsed region of a buffer." :group 'homun-layout)
(defface homun-stage-anchor '((t :inherit link :underline (:style dots))) "A transcript anchor." :group 'homun-layout)
(defcustom homun-stage-pulse-seconds 2.0 "How long a pulse or a hover highlight stays." :type 'number :group 'homun-layout)

(defvar homun-stage--marks nil "The overlays of the current pulse or hover highlight.")
(defvar homun-stage--mark-timer nil)

(defun homun-stage--unmark ()
  (mapc #'delete-overlay homun-stage--marks)
  (setq homun-stage--marks nil)
  (when (timerp homun-stage--mark-timer) (cancel-timer homun-stage--mark-timer))
  (setq homun-stage--mark-timer nil))

(defun homun-stage--mark (buffer from to)
  (let ((o (make-overlay from to buffer)))
    (overlay-put o 'face 'homun-stage-pulse)
    (overlay-put o 'priority 1000)
    (push o homun-stage--marks)))

(defun homun-stage--mark-later ()
  (setq homun-stage--mark-timer (run-at-time homun-stage-pulse-seconds nil #'homun-stage--unmark)))

;;; Files

(defun homun-stage-pulse-file (target)
  "Pulse the lines of TARGET, \"PATH:FROM[-TO]\", in the buffer visiting PATH; t when
shown.
Point, windows and the selected buffer stay as they are."
  (when (string-match "\\`\\(.+\\):\\([0-9]+\\)\\(?:-\\([0-9]+\\)\\)?\\'" target)
    (let* ((file (expand-file-name (match-string 1 target)))
           (from (string-to-number (match-string 2 target)))
           (to (if (match-string 3 target) (string-to-number (match-string 3 target)) from))
           (buf (find-buffer-visiting file)))
      (when (and buf (<= from to))
        (homun-stage--unmark)
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (forward-line (1- from))
              (let ((a (point)))
                (forward-line (1+ (- to from)))
                (homun-stage--mark buf a (point))))))
        (homun-stage--mark-later)
        t))))

;;; Anchors and chips

(defun homun-stage-anchor-text (label scene &optional node)
  "LABEL as the anchor of NODE (the chip of the scene, without NODE) of SCENE."
  (propertize (if (gethash scene homun-stage-scenes)
                  (propertize label 'face 'homun-stage-anchor)
                (homun-button label 'chip))
              'homun-stage-anchor (cons scene node)
              'help-echo #'homun-stage-hover
              'mouse-face 'highlight 'keymap homun-stage-anchor-map))

(defun homun-stage--regions (buffer prop pred)
  "The (FROM . TO) runs in BUFFER whose PROP value satisfies PRED."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let ((pos (point-min)) runs)
        (while (< pos (point-max))
          (let ((end (or (next-single-property-change pos prop nil (point-max)) (point-max))))
            (when (funcall pred (get-text-property pos prop)) (push (cons pos end) runs))
            (setq pos end)))
        runs))))

(defun homun-stage-highlight (scene node)
  "Highlight NODE of SCENE in its buffer and its anchors in every buffer that has
them."
  (homun-stage--unmark)
  (when-let* ((b (get-buffer (homun-stage-buffer-name scene))))
    (dolist (r (homun-stage--regions b 'homun-stage-node (lambda (v) (and v (or (null node) (equal v node))))))
      (homun-stage--mark b (car r) (cdr r))))
  (dolist (b (buffer-list))
    (unless (string-prefix-p "*stage " (buffer-name b))
      (dolist (r (homun-stage--regions b 'homun-stage-anchor
                                       (lambda (v) (and v (equal (car v) scene) (or (null node) (equal (cdr v) node))))))
        (homun-stage--mark b (car r) (cdr r)))))
  (homun-stage--mark-later)
  (length homun-stage--marks))

(defun homun-stage-hover (_window object pos)
  "A `help-echo' function: highlight the counterpart of the anchor or node at POS
of OBJECT."
  (when (bufferp object)
    (with-current-buffer object
      (if-let* ((a (get-text-property pos 'homun-stage-anchor)))
          (homun-stage-highlight (car a) (cdr a))
        (when-let* ((n (get-text-property pos 'homun-stage-node))
                    (id homun-stage--id))
          (homun-stage-highlight id n)))))
  nil)

(defun homun-stage--node-help (_w object pos) (homun-stage-hover nil object pos))

(defun homun-stage-snapshot-open (scene)
  "Show the last state of the closed SCENE in a read-only buffer; return the
buffer."
  (let* ((file (homun-stage--file scene t))
         (a (and (file-readable-p file)
                 (homun-stage-parse (with-temp-buffer (insert-file-contents file) (buffer-string)))))
         (buf (get-buffer-create (format "*stage snapshot %s*" scene))))
    (unless a (user-error "No closed scene %s" scene))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode) (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s (closed)\n" (or (alist-get 'title a) scene)) 'face 'bold))
        (homun-stage-insert (alist-get 'root a) 600 (homun-stage-env))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

(defun homun-stage-anchor-activate ()
  "Open the closed scene of the chip at point, or focus the open one."
  (interactive)
  (when-let* ((a (get-text-property (point) 'homun-stage-anchor)))
    (if (gethash (car a) homun-stage-scenes)
        (homun-stage-focus (car a) (cdr a))
      (homun-stage-snapshot-open (car a)))))

(defvar homun-stage-anchor-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'homun-stage-anchor-activate)
    (define-key m [mouse-1] #'homun-stage-anchor-activate)
    m))

(defun homun-stage-anchors-in (text)
  "TEXT with each [label](homun:stage/SCENE[/NODE]) link made an anchor or chip."
  (replace-regexp-in-string
   "\\[\\([^]\n]+\\)\\](homun:stage/\\([a-z0-9][a-z0-9_-]*\\)\\(?:/\\([A-Za-z0-9_.-]+\\)\\)?)"
   (lambda (m)
     (string-match "\\[\\([^]\n]+\\)\\](homun:stage/\\([^/)]+\\)\\(?:/\\([^)]+\\)\\)?)" m)
     (homun-stage-anchor-text (match-string 1 m) (match-string 2 m) (match-string 3 m)))
   text t t))

(provide 'homun-stage-point)
;;; homun-stage-point.el ends here
