;;; claude-settings.el --- the user's settings page for the cockpit -*- coding: utf-8; lexical-binding: t -*-

;; One buffer of the options worth changing, grouped under headings, each a
;; control of the Stage scene `claude-settings-scene' with a one-line description and a reset.
;; A change applies at once (the variable is set and widgetry buffers and the
;; board are redrawn) and is saved to `claude-settings-file', which
;; `claude-settings-load' reads at startup (cockpit.el).  Never Doom's custom-file.

;;; Code:

(require 'homun-dir)
(require 'cl-lib)
(require 'subr-x)
(require 'homun-stage-store)
(autoload 'claude-pair-phone "claude-pair" nil t)

(defvar claude-settings-file (expand-file-name "~/claude/.services/emacs/settings.eld")
  "Where changed settings are kept: an alist of (VARIABLE . VALUE).")

(defconst claude-settings-scene "settings" "The id of the settings scene on the Stage.")

(defvar claude-settings-groups
  '(("Buttons"
     (widgetry-hover-time number "Seconds a widget takes to light up on hover."
                          :min 0.02 :max 1.0)
     (widgetry-button-motion-time number "Seconds of the slide hint of a drag button."
                                  :min 0.1 :max 4.0)
     (widgetry-button-press-time number "Seconds a button looks pressed." :min 0.0 :max 1.0)
     (widgetry-button-hold-time number "Seconds to hold a hold button to arm it." :min 0.1 :max 3.0)
     (widgetry-button-ease-time number "Seconds the fill of an armed confirm button takes."
                                :min 0.0 :max 1.0)
     (widgetry-button-hint-time number "Seconds a confirm button shows its hint." :min 0.2 :max 5.0)
     (widgetry-button-confirm-distance distance "Pixels to drag a confirm button; 0 is its own width."
                                       :min 0 :max 300 :step 1))
    ("Activation flash"
     (widgetry-flash-style set "How a widget shows it activated; several draw together."
                           :choices (border flash tick sweep))
     (widgetry-flash-time number "Seconds the activation flash lasts." :min 0.05 :max 2.0))
    ("Dragging"
     (widgetry-drag-threshold integer "Pixels per selector step or toggle flip." :min 5 :max 120 :step 1)
     (widgetry-slider-drag-step number "Slider change per pixel dragged." :min 0.001 :max 0.1)
     (widgetry-corner-radius integer "Pixels of the rounded widget corners." :min 0 :max 12 :step 0.1))
    ("Transcript"
     (claude-transcript-tail-turns integer "Turns rendered on open and refresh." :min 20 :max 1000 :step 5)
     (claude-transcript-result-lines integer "Lines of a tool result before it is cut." :min 5 :max 200 :step 1)
     (claude-transcript-poll-interval number "Seconds between checks without file notification."
                                      :min 0.5 :max 10.0 :step 0.05))
    ("Compose and follow"
     (claude-compose-auto-open boolean "Opening the main transcript also opens the compose split.")
     (claude-compose-height number "Compose window height as a fraction of the frame."
                            :min 0.1 :max 0.9)
     (claude-follow-display choice "What an agent's new edit shows while auto-follow is on."
                            :choices (file diff nil)))
    ("Layout"
     (homun-layout-orientation choice "Layout family: by the frame's shape, or always wide or portrait."
                                :choices (auto wide portrait))
     (homun-layout-narrow-columns integer "Columns where the cockpit turns single-column (with a margin either side)." :min 40 :max 200 :step 2)
     (homun-layout-settle-seconds number "Seconds a resized frame must hold still before the layout follows." :min 0.2 :max 5.0)
     (homun-layout-lock boolean "Slot windows keep their buffer, cannot be deleted, and have no clickable mode line."))
    ("Slate"
     (homun-stage-tools set "Tool tabs pinned first in the stage region."
                         :choices (todos questions)))
    ("Development"
     (claude-auto-reload boolean "Load a cockpit Elisp file again when it changes on disk."))
    ("Approvals"
     (claude-approve-quiet boolean "Quiet mode: the hook allows read-only requests itself, listed on the queue's ticker (off by default)."))
    ("Attention"
     (claude-attn-quiet boolean "Hold interrupt pushes to the phone during the quiet hours (off by default).")
     (claude-attn-quiet-start integer "Hour the quiet hours start (equal to the end: none)." :min 0 :max 23 :step 1)
     (claude-attn-quiet-end integer "Hour the quiet hours end." :min 0 :max 23 :step 1)
     (claude-attn-desk-idle integer "Seconds idle after which Cal no longer counts as at the desktop." :min 30 :max 3600 :step 30))
    ("Board"
     (claude-board-interval integer "Seconds between redraws of a visible board." :min 1 :max 60 :step 0.1)
     (claude-board-throttle integer "Seconds between redraws when files change." :min 1 :max 30 :step 0.1)
     (claude-board-visible-columns set "Optional columns the board shows (c on the board); Task stays."
                                   :choices (type model age context activity))
     (claude-board-activity-detail boolean "A row names its latest activity next to the strip (d on the board).")))
  "Headings and their rows: (VARIABLE KIND DESCRIPTION . PROPS).
KIND is boolean, choice, set, number, integer or distance (nil shown as 0).")

;;;; Storage

(defun claude-settings--saved ()
  "The saved alist, or nil."
  (when (file-readable-p claude-settings-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents claude-settings-file)
          (read (current-buffer)))
      (error (message "claude-settings: cannot read %s: %s"
                      claude-settings-file (error-message-string err))
             nil))))

(defun claude-settings--write (alist)
  "Write ALIST to `claude-settings-file', through a temp file."
  (make-directory (file-name-directory claude-settings-file) t)
  (let ((temp (concat claude-settings-file ".tmp")))
    (with-temp-file temp
      (insert ";; claude-settings: written by the settings page  -*- lisp-data -*-\n")
      (let ((print-length nil) (print-level nil))
        (pp alist (current-buffer))))
    (rename-file temp claude-settings-file t)))

(defun claude-settings-load ()
  "Set every saved setting; before a library loads, its defcustom keeps it."
  (pcase-dolist (`(,var . ,value) (claude-settings--saved))
    (when (symbolp var) (set-default var value))))

(defun claude-settings--default (var)
  "The default value of VAR: its defcustom's, else its value."
  (if-let* ((standard (get var 'standard-value)))
      (eval (car standard) t)
    (default-value var)))

(defvar claude-settings--defaults nil
  "Defaults of plain defvars, kept before the first change: (VARIABLE . VALUE).")

(defun claude-settings--default-of (var)
  (if (get var 'standard-value)
      (claude-settings--default var)
    (alist-get var claude-settings--defaults (default-value var))))

;;;; Applying

(defun claude-settings--redraw ()
  "Redraw every widgetry widget outside the settings scene, and the board."
  (let ((page (get-buffer (homun-stage-buffer-name claude-settings-scene))))
    (dolist (buffer (buffer-list))
      (unless (eq buffer page)
        (with-current-buffer buffer
          (dolist (overlay (overlays-in (point-min) (point-max)))
            (when-let* ((widget (overlay-get overlay 'widgetry)))
              (ignore-errors (widgetry-redraw widget))))))))
  (when (fboundp 'claude-board--refresh)
    (when-let* ((board (get-buffer "*claude-board*")))
      (claude-board--refresh board))))

(defvar claude-settings--save-timer nil)

(defvar claude-settings--pending nil
  "Variables changed since the last save.")

(defun claude-settings-set (var value)
  "Set VAR to VALUE now, redraw, and save it (a slider drag saves once, when idle)."
  (unless (or (get var 'standard-value) (assq var claude-settings--defaults))
    (push (cons var (default-value var)) claude-settings--defaults))
  (set-default var value)
  (claude-settings--redraw)
  (cl-pushnew var claude-settings--pending)
  (when (timerp claude-settings--save-timer) (cancel-timer claude-settings--save-timer))
  (setq claude-settings--save-timer
        (run-with-idle-timer 0.5 nil #'claude-settings--flush)))

(defun claude-settings--store (var alist)
  "ALIST with VAR saved, or dropped when it is back at its default."
  (let ((alist (assq-delete-all var (copy-alist alist))))
    (if (equal (default-value var) (claude-settings--default-of var))
        alist
      (append alist (list (cons var (default-value var)))))))

(defvar widgetry-active-gesture)

(defun claude-settings--flush ()
  "Save every pending variable in one write."
  (when (timerp claude-settings--save-timer) (cancel-timer claude-settings--save-timer))
  (setq claude-settings--save-timer nil)
  (when claude-settings--pending
    (let ((alist (claude-settings--saved)))
      (dolist (var (reverse claude-settings--pending))
        (setq alist (claude-settings--store var alist)))
      (setq claude-settings--pending nil)
      (claude-settings--write alist)))
  (unless (bound-and-true-p widgetry-active-gesture) (claude-settings-refresh)))

(add-hook 'kill-emacs-hook #'claude-settings--flush)

;;;; The scene

(defun claude-settings--label (choice) (if choice (symbol-name choice) "none"))

(defun claude-settings--shown (var kind props)
  "The value of VAR as its scene node holds it: strings for symbols, a number, a
boolean or a list."
  (let ((value (default-value var)))
    (pcase kind
      ('choice (claude-settings--label value))
      ('set (mapcar #'symbol-name (seq-filter (lambda (c) (memq c (ensure-list value)))
                                              (plist-get props :choices))))
      ('distance (or value 0))
      ('boolean (if value t :false))
      (_ value))))

(defun claude-settings--from-node (_var kind props value)
  "VALUE, as a scene control reports it, turned back into the Lisp value of VAR."
  (let ((choices (plist-get props :choices)))
    (pcase kind
      ('choice (seq-find (lambda (c) (equal (claude-settings--label c) value)) choices))
      ('set (seq-filter (lambda (c) (member (symbol-name c) (ensure-list value))) choices))
      ('boolean (and value (not (eq value :false))))
      ((or 'integer 'distance)
       (let ((n (round value))) (if (and (eq kind 'distance) (zerop n)) nil n)))
      (_ value))))

(defun claude-settings--control (var kind props)
  "The scene node of the control of VAR, and its action."
  (let ((id (format "set-%s" var)))
    (puthash id (lambda (value) (claude-settings-set var (claude-settings--from-node var kind props value)))
             homun-stage-actions)
    `((type . "widget") (id . ,id)
      (kind . ,(pcase kind ('boolean "toggle") ('choice "selector") ('set "chips") (_ "slider")))
      (label . ,(symbol-name var)) (value . ,(claude-settings--shown var kind props))
      ,@(when (memq kind '(choice set))
          `((choices . ,(mapcar (lambda (c) (if (eq kind 'choice) (claude-settings--label c) (symbol-name c)))
                                (plist-get props :choices)))))
      ,@(when (memq kind '(number integer distance))
          `((min . ,(plist-get props :min)) (max . ,(plist-get props :max))
            ,@(when (plist-get props :step) `((step . ,(plist-get props :step))))
            ,@(when (memq kind '(integer distance)) '((decimals . 0))))))))

(defun claude-settings--row (row)
  "The nodes of the settings ROW: its name, control and reset on one line, then its
description."
  (pcase-let* ((`(,var ,kind ,doc . ,props) row)
               (reset (format "reset-%s" var)))
    (puthash reset (lambda ()
                     (claude-settings-set var (claude-settings--default-of var))
                     (claude-settings-refresh))
             homun-stage-actions)
    `(((type . "row")
       (children . (((type . "text") (face . "accent") (text . ,(symbol-name var)))
                    ,(claude-settings--control var kind props)
                    ((type . "widget") (kind . "button") (id . ,reset) (label . "reset") (tag . " ↺ ")))))
      ((type . "text") (face . "dim") (text . ,(concat "  " doc))))))

(defun claude-settings-scene ()
  "The settings scene tree: a heading per group, its rows under it."
  `((type . "col")
    (children
     ((type . "text") (face . "title") (text . "Settings"))
     ((type . "text") (face . "dim")
      (text . ,(format "Every control applies at once; ↺ restores a row's default. Kept in %s."
                       (abbreviate-file-name claude-settings-file))))
     ,@(unless (bound-and-true-p claude-bus-transport) ; the desktop cockpit, not a remote one
         (puthash "pair-phone" #'claude-pair-phone homun-stage-actions)
         '(((type . "widget") (kind . "button") (id . "pair-phone") (label . "Pair phone"))))
     ,@(mapcan (pcase-lambda (`(,heading . ,rows))
                 (let ((rows (seq-filter (lambda (row) (boundp (car row))) rows)))
                   (when rows
                     `(((type . "text") (text . ""))
                       ((type . "text") (face . "title") (text . ,heading))
                       ,@(mapcan #'claude-settings--row rows)))))
               claude-settings-groups))))

(defun claude-settings-refresh ()
  "Draw the scene again from the current values, when it is open and changed."
  (when-let* ((open (gethash claude-settings-scene homun-stage-scenes)))
    (let ((root (claude-settings-scene)))
      (unless (equal root (homun-stage-scene-root open))
        (homun-stage-show "cal" claude-settings-scene "Settings" root "system")))))

;;;###autoload
(defun claude-settings ()
  "Show the settings scene on the Stage; return its buffer."
  (interactive)
  (homun-stage-show "cal" claude-settings-scene "Settings" (claude-settings-scene) "system")
  (homun-stage-display claude-settings-scene)
  (get-buffer (homun-stage-buffer-name claude-settings-scene)))

(provide 'claude-settings)
;;; claude-settings.el ends here
