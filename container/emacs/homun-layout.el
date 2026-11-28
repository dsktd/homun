;;; homun-layout.el --- The cockpit's four regions, the only code that arranges windows -*- lexical-binding: t -*-

;; Four regions in one frame, placed by the frame's shape:
;;
;;   landscape                     portrait              narrow
;;   +------------+-----------+    +-----------------+   +----------------+
;;   | transcript | stage     |    | transcript      |   | stage (marquee)|
;;   |            |  (2/3)    |    +-----------------+   +----------------+
;;   |            +-----------+    | compose         |   | transcript     |
;;   +------------+ board     |    +-----------------+   +----------------+
;;   | compose    |  (1/3)    |    | stage           |   | compose        |
;;   +------------+-----------+    +-----------------+   +----------------+
;;                                 | board (1/4)     |
;;                                 +-----------------+
;;
;; The portrait board takes a quarter of the frame (`homun-layout-board-toggle' folds it to one line); the narrow
;; stage is one line (the marquee) until `homun-layout-marquee-toggle' opens it.
;;
;; `homun-layout-apply' builds it.  Each window carries a `homun-region' parameter and is
;; dedicated to it: a `display-buffer-alist' rule sends a buffer to the window of its region
;; (`homun-layout-regions') and never anywhere else.  Other code shows a buffer in a region
;; with `homun-layout-show' and finds a region's window with `homun-layout-window'; it
;; never splits, deletes or sizes windows itself.
;;
;; With `homun-layout-lock' (the default) the regions are locked against slips of the hand:
;; the transcript, the board and the compose box are strongly dedicated, so C-x b and a
;; click on a mode line cannot put another buffer there; no region window can be deleted;
;; and the mode lines have no mouse bindings.
;;
;; The frame's shape is picked again once a resize has held still for
;; `homun-layout-settle-seconds', with a margin around each threshold (hysteresis); a
;; resize that keeps the shape only scales the regions to their remembered proportions.
;; `homun-layout-focus-toggle' hides all but the transcript and the compose box.
;;
;; The names of claude-layout.el (slots main, compose, board, slate) still work: see there.

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup homun-layout nil "The cockpit window layout." :group 'tools)

(defcustom homun-layout-right-width 0.4
  "Fraction of the frame width taken by the right column (stage and board),
landscape."
  :type 'float)

(defcustom homun-layout-compose-lines 8
  "Height of the compose window in lines."
  :type 'integer)

(defcustom homun-layout-stage-height 0.67
  "Fraction of the right column's height taken by the stage, landscape."
  :type 'float)

(defcustom homun-layout-rest-height 0.45
  "Fraction of the frame height taken by everything below the compose box (stage,
board), portrait."
  :type 'float)

(defconst homun-layout-regions
  '((transcript . "\\`\\*transcript: ")
    (compose . "\\`\\*claude-compose")
    (board . "\\`\\*claude-board\\*\\'")
    (stage . "\\`\\*\\(?:homun-stage\\|stage \\|claude\\(?: run\\*\\|-events\\*\\|-update\\*\\| agent\\*\\| todos\\*\\| ask \\| report: \\| review \\)\\)"))
  "Which buffers (by name regexp) belong in which region.
A defconst, so loading the file again replaces a stale value in a running
daemon.")

(defconst homun-layout-old-names '((main . transcript) (slate . stage))
  "Slot names of claude-layout.el and the region each now names.")

(defcustom homun-layout-narrow-columns 100
  "Frames with fewer columns than this get the narrow layout (stage as a marquee)."
  :type 'integer)

(defcustom homun-layout-narrow-margin 8
  "Columns past `homun-layout-narrow-columns' a resize must go before the layout
changes.
A wide layout turns narrow below columns - margin, a narrow one wide above
columns + margin."
  :type 'integer)

(defcustom homun-layout-orientation 'auto
  "Which layout family the cockpit takes: `wide', `portrait', or `auto' by the
frame's pixel shape."
  :type '(choice (const auto) (const wide) (const portrait)))

(defcustom homun-layout-portrait-enter 1.15
  "Height / width (pixels) above which a wide layout turns portrait (`auto'
orientation)."
  :type 'float)

(defcustom homun-layout-portrait-leave 0.95
  "Height / width (pixels) below which a portrait layout turns wide (`auto'
orientation)."
  :type 'float)

(defcustom homun-layout-settle-seconds 1.0
  "Seconds a frame's size must stay put before the layout is picked or scaled
again."
  :type 'number)

(defcustom homun-layout-board-open-height 0.25
  "Fraction of the frame height of the portrait board, as built and when opened."
  :type 'float)

(defcustom homun-layout-marquee-open-height 0.5
  "Fraction of the frame height of the narrow stage when the marquee is opened."
  :type 'float)

(defvar homun-layout--state nil "The `window-state-get' of the saved layout.")
(defvar homun-layout--busy nil "Non-nil while the layout is being built or restored.")

(dolist (p '(homun-region homun-shape no-delete-other-windows))
  (add-to-list 'window-persistent-parameters (cons p 'writable)))

(defcustom homun-layout-other-region 'transcript
  "Region for any other buffer displayed in a frame with the layout; nil keeps
Emacs's own rules for those."
  :type '(choice (const nil) symbol))

(defcustom homun-layout-other-ignore
  "\\`\\(?: \\|\\*\\(?:Completions\\|which-key\\|Messages\\|Help\\|transient\\|Backtrace\\|Warnings\\|Minibuf\\|Echo\\)\\)"
  "Buffers never moved to `homun-layout-other-region' (internal and popup ones)."
  :type 'regexp)

(defun homun-layout--name (region)
  "REGION, an old slot name translated."
  (alist-get region homun-layout-old-names region))

(defun homun-layout-region (buffer)
  "The region of BUFFER (a buffer or its name), or nil.
In a frame with the layout, a buffer without a region of its own goes to
`homun-layout-other-region', unless it matches `homun-layout-other-ignore'."
  (let ((name (if (bufferp buffer) (buffer-name buffer) buffer)))
    (or (car (seq-find (lambda (r) (string-match-p (cdr r) name)) homun-layout-regions))
        (and homun-layout-other-region
             (not (string-match-p homun-layout-other-ignore name))
             (homun-layout--windows)
             homun-layout-other-region))))

;; What a region shows before it is filled: nothing to type into
(define-derived-mode homun-layout-placeholder-mode special-mode "Empty"
  "The buffer of a region that has nothing to show yet: read-only.")

(defun homun-layout--placeholder ()
  "The read-only `*claude-layout*' buffer with its one-line hint."
  (with-current-buffer (get-buffer-create "*claude-layout*")
    (unless (derived-mode-p 'homun-layout-placeholder-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (homun-layout-placeholder-mode)
        (insert (propertize "Nothing here yet: it fills when its view opens.\n" 'face 'shadow))))
    (current-buffer)))

(defun homun-layout--windows (&optional frame)
  "The region windows of FRAME as an alist (REGION . WINDOW)."
  (delq nil (mapcar (lambda (window)
                      (when-let* ((region (window-parameter window 'homun-region)))
                        (cons region window)))
                    (window-list frame 'no-minibuf))))

(defun homun-layout-window (region &optional frame)
  "The window of REGION in FRAME, or nil.  Old slot names (main, slate) work too."
  (cdr (assq (homun-layout--name region) (homun-layout--windows frame))))

(defun homun-layout-window-region (window)
  "The region WINDOW shows, or nil when it is not a region window."
  (window-parameter window 'homun-region))

(defun homun-layout--match (buffer _action)
  "Rule predicate: BUFFER has a region."
  (homun-layout-region buffer))

;;;; The lock

(defcustom homun-layout-lock t
  "Non-nil locks the region windows: see the top of this file.  Setting it applies
at once."
  :type 'boolean)

(defconst homun-layout-lock-mode-line
  '(" " (:propertize "%b" face mode-line-buffer-id) "  %l:%c  " mode-line-process
    mode-line-misc-info)
  "The mode line of a locked region: the buffer's name and hints, nothing to click.")

(defconst homun-layout-lock-regions
  '((transcript :dedicated t :mode-line none)
    (board :dedicated t :mode-line buffer)
    (compose :dedicated t :mode-line none)
    (stage :dedicated side))
  "What the lock does to each region: (REGION . PLIST) of :dedicated (the stage
keeps the soft dedication: any stage buffer may go there, through its tab line,
and nothing else), and :mode-line (default `homun-layout-lock-mode-line';
`buffer' leaves it to the buffer).")

(defun homun-layout--keep (_window)
  "The `delete-window' parameter of a locked region: the window stays."
  (message "The layout is locked: this window stays (the Layout setting unlocks it)"))

(defun homun-layout--dedicate (window)
  "Dedicate WINDOW to its region.
Locked: as `homun-layout-lock-regions' says.  Unlocked: softly, except the
transcript, which takes any buffer."
  (let ((region (window-parameter window 'homun-region)))
    (set-window-dedicated-p
     window (if homun-layout-lock
                (plist-get (alist-get region homun-layout-lock-regions) :dedicated)
              (and (not (eq region 'transcript)) 'side)))))

(defvar homun-layout-phone)

(defvar homun-layout-phone-header nil
  "On the phone: the header line of the main window (the strip), or nil.")

(defun homun-layout--lock-window (window)
  "Give region WINDOW what `homun-layout-lock' asks for now, or take it away."
  (let* ((region (window-parameter window 'homun-region))
         (spec (and homun-layout-lock (alist-get region homun-layout-lock-regions))))
    (homun-layout--dedicate window)
    (set-window-parameter window 'tab-line-format
                          (cond ((eq region 'stage)
                                 '(:eval (progn (require 'homun-stage-store) (homun-stage-tab-line))))
                                ((and (eq (window-parameter window 'homun-shape) 'narrow)
                                      (not homun-layout-phone) ; the phone's tabs are its mode line
                                      (not (eq region 'compose)))
                                 '(:eval (homun-layout-narrow-tabs)))))
    (set-window-parameter window 'delete-window (and homun-layout-lock #'homun-layout--keep))
    (set-window-parameter window 'no-other-window nil)
    (set-window-parameter window 'mode-line-format
                          (and homun-layout-lock
                               (let ((line (or (plist-get spec :mode-line) homun-layout-lock-mode-line)))
                                 (unless (eq line 'buffer) line))))
    (when homun-layout-phone
      (set-window-parameter window 'mode-line-format
                            (if (eq region 'transcript) '(:eval (homun-layout-narrow-tabs)) 'none))
      (when (eq region 'transcript)
        (set-window-parameter window 'header-line-format homun-layout-phone-header)))))

(defun homun-layout-lock-apply (&optional lock)
  "Lock or unlock every region window of every frame as `homun-layout-lock' says.
With LOCK (`on' or `off') as that says instead."
  (let ((homun-layout-lock (pcase lock ('on t) ('off nil) (_ homun-layout-lock))))
    (dolist (frame (frame-list))
      (dolist (r (homun-layout--windows frame))
        (homun-layout--lock-window (cdr r))))
    (force-mode-line-update t)))

(add-variable-watcher
 'homun-layout-lock
 (lambda (_symbol value operation where)
   (when (and (eq operation 'set) (null where))
     (homun-layout-lock-apply (if value 'on 'off)))))

(defun homun-layout-show (buffer window)
  "Show BUFFER in WINDOW whatever its dedication, which it keeps; return WINDOW.
For the cockpit's own code: a locked region refuses a plain `set-window-buffer'."
  (let ((dedicated (window-dedicated-p window)))
    (set-window-dedicated-p window nil)
    (set-window-buffer window buffer)
    (if (window-parameter window 'homun-region)
        (homun-layout--dedicate window)
      (set-window-dedicated-p window dedicated))
    window))

(defun homun-layout-pop (buffer)
  "Show BUFFER in the window of its region, select it and return BUFFER.
Nil when the frame has no window for that region."
  (when-let* ((window (homun-layout-window (homun-layout-region buffer))))
    (homun-layout-show buffer window)
    (select-window window)
    buffer))

(defun homun-layout-clear (window)
  "Blank region WINDOW (it shows the placeholder buffer)."
  (homun-layout-show (homun-layout--placeholder) window))

;;;; For the rest of the cockpit: every window change goes through here

(defconst homun-layout-fallback
  '((stage (side . right) (slot . 0) (window-width . 0.35))
    (compose (side . bottom) (slot . 0) (window-height . 8))
    (board (side . bottom) (slot . 1) (window-height . 8)))
  "Where a region's buffer goes in a frame without the layout: side window
parameters.")

(defun homun-layout-place (buffer &optional select)
  "Show BUFFER in the window of its region; in a frame without the layout, in the
side window `homun-layout-fallback' gives that region.  Select it with SELECT;
return the window."
  (let* ((display-buffer-overriding-action nil)
         (region (homun-layout-region buffer))
         (window (if (homun-layout--windows)
                     (homun-layout--display buffer nil)
                   (display-buffer
                    buffer (if-let* ((side (alist-get region homun-layout-fallback)))
                               `((display-buffer-reuse-window display-buffer-in-side-window)
                                 ,@side (window-parameters (no-delete-other-windows . t)))
                             '(display-buffer-reuse-window))))))
    (when (and select window) (select-window window))
    window))

(defun homun-layout-side (buffer &optional select)
  "Show BUFFER in the stage region (a right side window without the layout); see
`homun-layout-place'."
  (let ((homun-layout-regions (cons (cons 'stage (regexp-quote (buffer-name (get-buffer buffer))))
                                    homun-layout-regions)))
    (homun-layout-place buffer select)))

(defun homun-layout-beside (buffer &optional frame)
  "Show BUFFER in FRAME (default: the selected one) beside the selected window,
without selecting it: a window already showing it, another window, else a new
split."
  (with-selected-frame (or frame (selected-frame))
    (display-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window
                              display-buffer-pop-up-window)
                             (inhibit-same-window . t) (reusable-frames . nil)))))

(defun homun-layout-other-window (&optional here)
  "A window of the frame other than HERE (default: the selected one), split off
when none."
  (let ((here (or here (selected-window))))
    (or (seq-find (lambda (w) (not (eq w here))) (window-list nil 'never here))
        (split-window-sensibly here)
        (split-window here nil 'right))))

(defun homun-layout-alone (buffer &optional beside)
  "Show BUFFER alone in the selected window, every other window of the frame
closed; with BESIDE, that buffer in a split to its right."
  (pop-to-buffer-same-window buffer)
  (delete-other-windows)
  (when beside (set-window-buffer (split-window-right) beside)))

(defun homun-layout-close (window)
  "Take WINDOW away: a region window goes blank, any other window closes."
  (if (window-parameter window 'homun-region)
      (homun-layout-clear window)
    (ignore-errors (delete-window window))))

(defun homun-layout-point (window pos &optional start noforce)
  "Put WINDOW's point at POS (nil leaves it); with START, its first visible
position
\(NOFORCE as for `set-window-start')."
  (when start (set-window-start window start noforce))
  (when pos (set-window-point window pos)))

(defun homun-layout-tail (window)
  "Put WINDOW at the end of its buffer, the last line at the bottom.
An end that is already (even partly) visible leaves the window exactly as it is:
no recenter, no new start, vscroll kept."
  (let ((end (with-current-buffer (window-buffer window) (point-max))))
    (unless (pos-visible-in-window-p end window t)
      (set-window-point window end)
      (with-selected-window window (recenter -1)))))

(defun homun-layout-mark-window (window key value)
  "Set WINDOW's parameter KEY to VALUE, for code that tags its own windows."
  (set-window-parameter window key value))

(defun homun-layout--display (buffer _alist)
  "`display-buffer' action: BUFFER into the window of its region, else nothing
moves.
Returns nil when the frame has no layout at all, so other rules apply."
  (let* ((region (homun-layout-region buffer))
         (windows (homun-layout--windows)))
    (when windows
      (if-let* ((window (or (cdr (assq region windows))
                            ;; narrow: the board shares the transcript window
                            (and (eq region 'board)
                                 (when-let* ((main (cdr (assq 'transcript windows)))
                                             ((eq (window-parameter main 'homun-shape) 'narrow)))
                                   main)))))
          (if (eq (window-buffer window) buffer)
              window
            (homun-layout-show buffer window))
        (user-error "Layout: no %s window for %s%s"
                    region (if (bufferp buffer) (buffer-name buffer) buffer)
                    (homun-key-hint " (SPC o c l restores it)"))))))

(declare-function homun-key-hint "claude")

(defun homun-layout--install ()
  "Put the routing rule first in `display-buffer-alist', also in Doom's popup copy."
  (let ((rule '(homun-layout--match homun-layout--display)))
    (setq display-buffer-alist
          (cons rule (seq-remove (lambda (r) (memq (car-safe r) '(homun-layout--match claude-layout--match)))
                                 display-buffer-alist)))
    (when (boundp '+popup--display-buffer-alist)
      (setq +popup--display-buffer-alist
            (cons rule (remove rule +popup--display-buffer-alist))))))

(homun-layout--install)
(with-eval-after-load 'popup (homun-layout--install))
(add-hook 'after-init-hook #'homun-layout--install 90)
(add-hook 'doom-after-init-hook #'homun-layout--install 90)

(defun homun-layout--mark (window region shape)
  "Give WINDOW its REGION in a layout of SHAPE: parameters, dedication and lock."
  (set-window-parameter window 'homun-region region)
  (set-window-parameter window 'homun-shape shape)
  (set-window-parameter window 'no-delete-other-windows t)
  (homun-layout--lock-window window)
  (window-preserve-size window nil t)
  (window-preserve-size window t t))

;; Windows a daemon built with claude-layout.el before this file: their slots become regions
(defun homun-layout-adopt-slots ()
  "Turn the slot windows of the old layout into region windows in place."
  (dolist (window (window-list-1 nil 'no-minibuf t))
    (when-let* ((slot (window-parameter window 'claude-slot)))
      (set-window-parameter window 'homun-region (alist-get slot homun-layout-old-names slot))
      (set-window-parameter window 'homun-shape
                            (cond ((window-parameter window 'claude-narrow) 'narrow)
                                  ((window-parameter window 'claude-portrait) 'portrait)
                                  (t 'wide)))
      (set-window-parameter window 'claude-slot nil)
      (homun-layout--lock-window window))))

;;;; Narrow: the board and the todos as tabs of the transcript window

(defvar homun-layout-transcript-function
  (lambda () (require 'claude-compose) (claude-transcript-open (claude-compose--main-file)))
  "Shows the main session's transcript in its region; a remote cockpit has it
elsewhere.")

(defconst homun-layout-narrow-views
  '(("Transcript" . (lambda () (funcall homun-layout-transcript-function)))
    ("Board" . (lambda () (require 'claude-board) (claude-board)))
    ("Stage" . homun-layout-marquee-toggle)
    ("Todos" . (lambda () (require 'claude-todos) (claude-todos))))
  "The tabs of the narrow layout: (NAME . FUNCTION) showing that view.")

(defun homun-layout-narrow-view (name)
  "Show the view NAME of `homun-layout-narrow-views'."
  (interactive (list (completing-read "View: " (mapcar #'car homun-layout-narrow-views) nil t)))
  (let ((display-buffer-overriding-action nil))
    (funcall (cdr (assoc name homun-layout-narrow-views))))
  (when-let* ((main (homun-layout-window 'transcript)))
    (select-window main))
  (homun-layout--save))

(defun homun-layout--tab-click (event)
  "Show the view whose tab was clicked (EVENT)."
  (interactive "e")
  (let ((posn (event-start event)))
    (homun-layout-narrow-view
     (get-text-property (cdr (posn-string posn)) 'homun-view (car (posn-string posn))))))

(defvar homun-layout-tab-extra ""
  "Text after the tabs of the narrow tab line: a status that must stay on screen.")

(defvar homun-layout-tabs-function nil
  "When non-nil, draws the narrow tab line in place of
`homun-layout-narrow-views' (the phone's tabs).")

(defun homun-layout-narrow-tabs ()
  "The tab line of the narrow transcript window: one tap target per view."
  (if homun-layout-tabs-function (funcall homun-layout-tabs-function)
  (concat (mapconcat
   (lambda (view)
     (let ((map (make-sparse-keymap)))
       (define-key map [tab-line mouse-1] #'homun-layout--tab-click)
       (propertize (format " %s " (car view)) 'homun-view (car view) 'keymap map
                   'mouse-face 'highlight 'face 'tab-line-tab-inactive)))
   homun-layout-narrow-views " ")
   " " homun-layout-tab-extra)))

;;;; Picking the shape

(defun homun-layout--pick (&optional frame current)
  "The layout shape for FRAME now: `narrow', `portrait' or `wide'.
CURRENT is the shape built there, if any: each threshold then holds it until the
frame is past it by a margin, so a resize around a threshold does not flip it."
  (let* ((frame (or frame (selected-frame)))
         (columns (frame-width frame))
         (ratio (/ (float (frame-pixel-height frame)) (max 1 (frame-pixel-width frame)))))
    (cond ((if (eq current 'narrow)
               (<= columns (+ homun-layout-narrow-columns homun-layout-narrow-margin))
             (< columns (if current
                            (- homun-layout-narrow-columns homun-layout-narrow-margin)
                          homun-layout-narrow-columns)))
           'narrow)
          ((eq homun-layout-orientation 'portrait) 'portrait)
          ((and (eq homun-layout-orientation 'auto)
                (if (eq current 'portrait)
                    (>= ratio homun-layout-portrait-leave)
                  (> ratio (if current homun-layout-portrait-enter 1.0))))
           'portrait)
          (t 'wide))))

(defun homun-layout--shape (&optional frame)
  "The shape of the layout built in FRAME, or nil when there is none."
  (when-let* ((main (homun-layout-window 'transcript frame)))
    (or (window-parameter main 'homun-shape) 'wide)))

(defun homun-layout--split (window size side)
  "Split WINDOW, the new window SIZE lines or columns on SIDE; return the new
window."
  (split-window window (- (max 1 size)) side))

;; Portrait stacks top to bottom: transcript, compose, then the rest (stage and board).  The rest is cut off the root first, so compose sits right under the transcript.
(defun homun-layout--rest (root)
  "Split the rest off the bottom of ROOT, `homun-layout-rest-height' of it; return
its window."
  (homun-layout--split root (round (* homun-layout-rest-height (window-total-height root))) 'below))

(defun homun-layout--build-wide (root)
  "Transcript and compose on the left, stage over board on the right."
  (let* ((right (homun-layout--split root (round (* homun-layout-right-width (window-total-width root))) 'right))
         (compose (homun-layout--split root homun-layout-compose-lines 'below))
         (board (homun-layout--split right (round (* (- 1 homun-layout-stage-height)
                                                     (window-total-height right)))
                                     'below)))
    `((transcript . ,root) (compose . ,compose) (stage . ,right) (board . ,board))))

(defun homun-layout--build-portrait (root)
  "Transcript, compose, stage, then the board (`homun-layout-board-open-height' of
the frame), top to bottom."
  (let* ((height (window-total-height root))
         (rest (homun-layout--rest root))
         (compose (homun-layout--split root homun-layout-compose-lines 'below))
         (board (homun-layout--split rest (round (* homun-layout-board-open-height height))
                                     'below)))
    `((transcript . ,root) (compose . ,compose) (stage . ,rest) (board . ,board))))

(defvar homun-layout-phone nil
  "Non-nil on the phone cockpit: no stage window, no mode lines.")

(defun homun-layout--build-narrow (root)
  "The stage as a one-line marquee over the transcript and the compose box.
On the phone there is no stage window: what waits on the user is the Now screen."
  (if homun-layout-phone
      (let ((compose (homun-layout--split root homun-layout-compose-lines 'below)))
        `((transcript . ,root) (compose . ,compose)))
    (let* ((main (split-window root 2 'below))
           (compose (homun-layout--split main homun-layout-compose-lines 'below)))
      `((stage . ,root) (transcript . ,main) (compose . ,compose)))))

(defun homun-layout--build ()
  "Split the selected frame into the regions of its shape, each showing a scratch
buffer."
  (let ((ignore-window-parameters t)
        (placeholder (homun-layout--placeholder))
        (shape (homun-layout--pick)))
    (dolist (window (window-list nil 'no-minibuf))
      (set-window-dedicated-p window nil)
      (dolist (p '(homun-region homun-shape claude-slot claude-narrow claude-portrait window-side
                   no-delete-other-windows delete-window no-other-window mode-line-format))
        (set-window-parameter window p nil)))
    ;; On a live window: the root of a split frame is an internal window, and
    ;; deleting the others of that keeps the whole old layout inside it
    (delete-other-windows (frame-first-window))
    (pcase-dolist (`(,region . ,window)
                   (funcall (pcase shape
                              ('portrait #'homun-layout--build-portrait)
                              ('narrow #'homun-layout--build-narrow)
                              (_ #'homun-layout--build-wide))
                            (frame-root-window)))
      (set-window-buffer window placeholder)
      (homun-layout--mark window region shape))))

(defun homun-layout-map (&optional frame)
  "The regions of FRAME's layout as text: shape, then REGION@COLUMN,LINE
WIDTHxHEIGHT for each, top to bottom and left to right.  Tests and `window_get'
read it."
  (when-let* ((shape (homun-layout--shape frame)))
    (concat (symbol-name shape) " "
            (mapconcat (lambda (r)
                         (pcase-let ((`(,l ,top ,_ ,_) (window-edges (cdr r))))
                           (format "%s@%d,%d %dx%d" (car r) l top
                                   (window-total-width (cdr r)) (window-total-height (cdr r)))))
                       (sort (homun-layout--windows frame)
                             (lambda (a b)
                               (let ((ea (window-edges (cdr a))) (eb (window-edges (cdr b))))
                                 (or (< (nth 1 ea) (nth 1 eb))
                                     (and (= (nth 1 ea) (nth 1 eb)) (< (car ea) (car eb)))))))
                       " "))))

;;;; Collapsed regions: the portrait board, the narrow marquee

(defun homun-layout--toggle-height (region open-fraction)
  "Open REGION's window to OPEN-FRACTION of the frame, or close it to one line."
  (let* ((window (or (homun-layout-window region) (user-error "No %s region here" region)))
         (open (> (window-body-height window) 1))
         (want (if open 1 (round (* open-fraction (window-total-height (frame-root-window))))))
         (window-size-fixed nil)
         (homun-layout--busy t))
    (window-preserve-size window nil nil)
    (window-resize window (window-resizable window (- want (window-body-height window)) nil t) nil t)
    (window-preserve-size window nil t)
    (unless open (select-window window))
    (homun-layout--remember (selected-frame))))

(defun homun-layout-board-toggle ()
  "Open the one-line board of the portrait layout, or close it again."
  (interactive)
  (unless (eq (homun-layout--shape) 'portrait)
    (user-error "The board is one line only in the portrait layout"))
  (homun-layout--toggle-height 'board homun-layout-board-open-height))

(defun homun-layout-marquee-toggle ()
  "Open the stage marquee of the narrow layout, or close it to one line."
  (interactive)
  (unless (eq (homun-layout--shape) 'narrow)
    (user-error "The stage is a marquee only in the narrow layout"))
  (homun-layout--toggle-height 'stage homun-layout-marquee-open-height))

;;;###autoload
(defun homun-layout-expand ()
  "Open or close the collapsed region of this shape: the portrait board, the narrow
marquee."
  (interactive)
  (pcase (homun-layout--shape)
    ('portrait (homun-layout-board-toggle))
    ('narrow (homun-layout-marquee-toggle))
    (_ (message "Nothing is collapsed in this layout"))))

;;;; Filling

(defvar homun-layout-compose-function #'claude-compose--show
  "Shows the compose box in its region; a remote cockpit has its own.")

(defun homun-layout--fill ()
  "Show the regions' buffers; a region that cannot be filled says so and stays
empty."
  (let ((steps
         `((transcript . ,(lambda () (funcall homun-layout-transcript-function)))
           ,@(when (homun-layout-window 'board)
               `((board . ,(lambda () (require 'claude-board) (claude-board)))))
           ;; The phone has no stage window: what waits on Cal is its Now screen
           ,@(when (homun-layout-window 'stage)
               `((stage . ,(lambda () (require 'homun-stage-store)
                             (homun-layout-side (homun-stage-default-buffer))))))
           (compose . ,(lambda () (funcall homun-layout-compose-function))))))
    (dolist (step steps)
      (condition-case err
          (funcall (cdr step))
        (error (message "Layout: %s region not filled: %s"
                        (car step) (error-message-string err)))))))

;;;###autoload
(defun homun-layout-apply (&optional default)
  "Build the cockpit layout in the selected frame and save its sizes.
The layout Cal arranged for this frame's shape (`homun-layout-saved-file') takes
the place of the shipped default unless DEFAULT; one that does not restore
leaves the default."
  (interactive)
  (let ((homun-layout--busy t)
        (display-buffer-overriding-action nil))
    (homun-layout--install)
    (homun-layout--build)
    (homun-layout--fill)
    (unless default (homun-layout--use-saved)))
  (homun-layout--save)
  (when-let* ((window (homun-layout-window 'compose)))
    (select-window window)))

(defun homun-layout--plain-p (&optional frame)
  "Non-nil when every window of FRAME is a cockpit region (no *Messages*, popup or
Debugger)."
  (cl-every (lambda (w) (memq (window-parameter w 'homun-region)
                              (mapcar #'car homun-layout-regions)))
            (window-list frame 'no-minibuf)))

(defun homun-layout--save ()
  "Remember the sizes and buffers of the layout of the selected frame."
  (when (and (not homun-layout--busy) (homun-layout--windows) (homun-layout--plain-p))
    (setq homun-layout--state (window-state-get (frame-root-window) t))
    (homun-layout--remember (selected-frame))))

;;;###autoload
(defun homun-layout-restore ()
  "Put the saved layout back in the selected frame; build it when none is saved."
  (interactive)
  (if (not homun-layout--state)
      (homun-layout-apply)
    (let ((homun-layout--busy t)
          (ignore-window-parameters t))
      (window-state-put homun-layout--state (frame-root-window) 'safe)
      (dolist (r (homun-layout--windows))
        (homun-layout--lock-window (cdr r))))
    (if (homun-layout--plain-p)
        (homun-layout--install)
      ;; A saved state with a window that is no region: forget it, build the layout
      (setq homun-layout--state nil)
      (homun-layout-apply))))

;;;; Resizes

(defvar homun-layout--fractions nil
  "Per frame, the region windows' sizes as fractions of the frame: (FRAME
. ((REGION W . H) ...)).")

(defun homun-layout--measure (frame)
  "The sizes of FRAME's region windows as fractions of its root window."
  (let ((root (frame-root-window frame)))
    (mapcar (lambda (r)
              (list (car r)
                    (/ (float (window-total-width (cdr r))) (window-total-width root))
                    (/ (float (window-total-height (cdr r))) (window-total-height root))))
            (homun-layout--windows frame))))

(defun homun-layout--remember (frame)
  "Keep the current proportions of FRAME's regions for the next resize."
  (setf (alist-get frame homun-layout--fractions) (homun-layout--measure frame))
  (setq homun-layout--fractions (seq-filter (lambda (e) (frame-live-p (car e)))
                                            homun-layout--fractions)))

(defun homun-layout--fixed-lines-p (window)
  "Non-nil when WINDOW keeps its lines on a resize: the compose box and a one-line
region."
  (or (eq (window-parameter window 'homun-region) 'compose)
      (<= (window-body-height window) 1)))

(defun homun-layout--rescale (frame)
  "Give FRAME's region windows their remembered proportions again; the compose box
and collapsed regions keep their lines.  Only sizes change: buffers, point and
the selected window stay."
  (let ((root (frame-root-window frame))
        (homun-layout--busy t)
        (window-size-fixed nil))
    (dolist (entry (alist-get frame homun-layout--fractions))
      (when-let* ((window (homun-layout-window (car entry) frame)))
        (dolist (horizontal '(t nil))
          (unless (and (not horizontal) (homun-layout--fixed-lines-p window))
            (let* ((now (window-total-size window horizontal))
                   (want (round (* (if horizontal (nth 1 entry) (nth 2 entry))
                                   (window-total-size root horizontal))))
                   (delta (window-resizable window (- want now) horizontal t)))
              (unless (zerop delta)
                (ignore-errors (window-resize window delta horizontal t))))))))
    (homun-layout-fit-compose frame)))

(defun homun-layout-fit-compose (&optional frame)
  "Give FRAME's compose window room for `homun-layout-compose-lines' lines of its
text, measured in pixels: its header line, tab line and text scale take their
real height."
  (when-let* ((window (homun-layout-window 'compose frame)))
    (let* ((window-size-fixed nil)
           (homun-layout--busy t)
           (chrome (- (window-pixel-height window) (window-body-height window t)))
           (line (with-selected-window window (default-line-height)))
           (delta (window-resizable window (- (+ chrome (* homun-layout-compose-lines line))
                                             (window-pixel-height window))
                                    nil t t)))
      (unless (zerop delta)
        (ignore-errors (window-resize window delta nil t t))))))

(defvar homun-layout--repick-timers nil "Per frame, the pending settle timer.")

(defun homun-layout--settled (frame)
  "FRAME's size has stayed put: rebuild when its shape changed, else scale the
regions.
Focus mode (`homun-layout-focus-toggle') is left as it is."
  (setf (alist-get frame homun-layout--repick-timers nil 'remove) nil)
  (when (and (frame-live-p frame) (not homun-layout--busy)
             (not (frame-parameter frame 'homun-layout-focus)))
    (when-let* ((shape (homun-layout--shape frame)))
      (if (eq shape (homun-layout--pick frame shape))
          (homun-layout--rescale frame)
        (with-selected-frame frame
          ;; Focus stays in the region it was in
          (let ((region (window-parameter (frame-selected-window frame) 'homun-region)))
            (homun-layout-apply)
            (when-let* ((window (homun-layout-window region frame)))
              (select-window window)))))
      (homun-layout--remember frame))))

(defvar homun-layout--frame-sizes nil "Per frame, its pixel size when last seen.")

(defun homun-layout--size-change (frame)
  "After FRAME changed size: act once it has kept one size for
`homun-layout-settle-seconds'.
A window resized inside an unchanged frame (a dragged divider) is left alone."
  (when (and (not homun-layout--busy) (homun-layout--shape frame)
             (let ((size (cons (frame-pixel-width frame) (frame-pixel-height frame))))
               (unless (equal size (alist-get frame homun-layout--frame-sizes))
                 (setf (alist-get frame homun-layout--frame-sizes) size))))
    (when-let* ((timer (alist-get frame homun-layout--repick-timers)))
      (cancel-timer timer))
    (setf (alist-get frame homun-layout--repick-timers)
          (run-with-timer homun-layout-settle-seconds nil #'homun-layout--settled frame))))

(remove-hook 'window-size-change-functions 'claude-layout--size-change)
(add-hook 'window-size-change-functions #'homun-layout--size-change)

;;;; Focus: the transcript and the compose box alone

(declare-function claude-transcript-focus--open "claude-transcript-focus")
(declare-function homun-stage-default-buffer "homun-stage-store")
(declare-function claude-board "claude-board")
(declare-function claude-compose--main-file "claude-compose")
(declare-function claude-transcript-open "claude-transcript")
(declare-function claude-compose--show "claude-compose")

(defun homun-layout--build-focus ()
  "The focus shape: the transcript over the compose box, at its normal height.
The transcript window stays; the compose box shows what it showed."
  (let* ((compose-buffer (window-buffer (homun-layout-window 'compose)))
         (transcript (let ((window (homun-layout-window 'transcript)))
                       (delete-other-windows window)
                       window))
         (compose (homun-layout--split transcript homun-layout-compose-lines 'below)))
    (set-window-buffer compose compose-buffer)
    `((transcript . ,transcript) (compose . ,compose))))

(defun homun-layout--focus-enter (frame)
  "Replace the layout of FRAME by the focus shape and show the reading view."
  (let ((homun-layout--busy t)
        (ignore-window-parameters t))
    (set-frame-parameter frame 'homun-layout-focus
                         (window-state-get (frame-root-window frame) t))
    (select-window (homun-layout-window 'transcript frame))
    (pcase-dolist (`(,region . ,window) (homun-layout--build-focus))
      (homun-layout--mark window region 'focus))
    (claude-transcript-focus--open)))

(defun homun-layout--focus-leave (frame saved)
  "Put the SAVED window state back in FRAME, locks and all."
  (let ((homun-layout--busy t)
        (ignore-window-parameters t))
    (window-state-put saved (frame-root-window frame) 'safe)
    (set-frame-parameter frame 'homun-layout-focus nil)
    (dolist (r (homun-layout--windows frame))
      (homun-layout--lock-window (cdr r)))
    (run-at-time 0 nil #'homun-layout--settled frame)))

(defun homun-layout-focus-toggle ()
  "Show the transcript's reading view over the compose box alone (the `focus'
shape), or bring the layout back exactly as it was.
The frame keeps the layout it had in its `homun-layout-focus' parameter
meanwhile, and a resize does not pick the layout again until focus ends."
  (interactive)
  (let* ((frame (selected-frame))
         (saved (frame-parameter frame 'homun-layout-focus)))
    (cond
     (saved (homun-layout--focus-leave frame saved)
            (message "Layout back"))
     ((not (homun-layout--shape frame)) (user-error "No layout in this frame"))
     (t (homun-layout--focus-enter frame)
        (message "Focus: transcript and compose (the same key brings the rest back)")))))

(defun homun-layout--after-resize (&rest _)
  "Save the layout after the user resized a window of it."
  (homun-layout--save))

(dolist (f '(adjust-window-trailing-edge window-resize))
  (advice-remove f 'claude-layout--after-resize)
  (advice-add f :after #'homun-layout--after-resize))

(defcustom homun-layout-divider-width 8
  "Pixels of the draggable dividers between windows, right and bottom."
  :type 'integer)

(setq window-divider-default-places t
      window-divider-default-right-width homun-layout-divider-width
      window-divider-default-bottom-width homun-layout-divider-width)
(window-divider-mode 1)

;;;; Across an Emacs restart

(defvar homun-layout-state-file (expand-file-name "~/claude/.services/emacs/homun-layout-state.eld")
  "Where `homun-layout-save-to-file' keeps the layout for the next start.")

(defun homun-layout-save-to-file ()
  "Write the layout of the selected frame to `homun-layout-state-file'."
  (homun-layout--save)
  (when-let* ((state (or homun-layout--state
                         (and (homun-layout--plain-p) (window-state-get (frame-root-window) t)))))
    (with-temp-file homun-layout-state-file
      (let ((print-length nil) (print-level nil)) (prin1 state (current-buffer))))))

(defun homun-layout--restore-from-file ()
  "After a restart: the first graphical frame gets the layout saved before it,
once."
  (when (and (file-readable-p homun-layout-state-file) (display-graphic-p))
    (let ((state (ignore-errors (with-temp-buffer (insert-file-contents homun-layout-state-file)
                                                   (read (current-buffer))))))
      (delete-file homun-layout-state-file)
      (when state
        (setq homun-layout--state state)
        (run-with-timer 1 nil (lambda () (ignore-errors (homun-layout-restore))))))))

(remove-hook 'server-after-make-frame-hook 'claude-layout--restore-from-file)
(add-hook 'server-after-make-frame-hook #'homun-layout--restore-from-file)

;;;; Arrangements that stay

(defvar homun-layout-saved-file (expand-file-name "~/claude/.services/emacs/homun-layout-saved.eld")
  "Per shape, the window state of the layout Cal arranged: ((SHAPE . STATE) ...).
Window shapes and buffer names only, never contents.")

(defvar homun-layout--persist-timer nil)

(defun homun-layout--saved ()
  "The contents of `homun-layout-saved-file', nil when missing or unreadable."
  (ignore-errors
    (with-temp-buffer (insert-file-contents homun-layout-saved-file) (read (current-buffer)))))

(defun homun-layout--regions-of-frame ()
  "The sorted region names of the selected frame's layout."
  (sort (mapcar #'car (homun-layout--windows)) #'string<))

(defun homun-layout--use-saved ()
  "Put the saved layout of the selected frame's shape over the built one.
A state that errors or comes out with other regions puts the built layout back,
with a message."
  (when-let* ((shape (homun-layout--shape))
              (saved (alist-get shape (homun-layout--saved))))
    (let ((default (window-state-get (frame-root-window) t))
          (regions (homun-layout--regions-of-frame))
          (ignore-window-parameters t))
      (condition-case err
          (progn (window-state-put saved (frame-root-window) 'safe)
                 (unless (and (equal regions (homun-layout--regions-of-frame))
                              (eq shape (homun-layout--shape))
                              (homun-layout--plain-p))
                   (error "regions differ"))
                 (dolist (r (homun-layout--windows))
                   (homun-layout--lock-window (cdr r))))
        (error (window-state-put default (frame-root-window) 'safe)
               (message "Saved layout not used (%s): the default is back"
                        (error-message-string err)))))))

(defun homun-layout--persist ()
  "Write the selected frame's layout under its shape, unless it is not a plain
cockpit one.
Skipped while a layout is applied, a minibuffer is open, focus mode is on, or a
window that is no region (a popup, the Debugger) is showing.  The lock keeps
buffers and windows as they are, so what a locked cockpit saves is what Cal
resized."
  (setq homun-layout--persist-timer nil)
  (when-let* (((not homun-layout--busy))
              ((not (active-minibuffer-window)))
              ((not (frame-parameter nil 'homun-layout-focus)))
              (shape (homun-layout--shape))
              ((homun-layout--plain-p)))
    (let ((all (homun-layout--saved)))
      (setf (alist-get shape all) (window-state-get (frame-root-window) t))
      (make-directory (file-name-directory homun-layout-saved-file) t)
      (with-temp-file homun-layout-saved-file
        (let ((print-length nil) (print-level nil)) (prin1 all (current-buffer)))))))

(defun homun-layout--changed ()
  "Window configuration changed: save the layout once it has held still for 2 s."
  (unless (or homun-layout--busy homun-layout--persist-timer)
    (setq homun-layout--persist-timer (run-with-idle-timer 2 nil #'homun-layout--persist))))

(add-hook 'window-configuration-change-hook #'homun-layout--changed)

;;;###autoload
(defun homun-layout-reset ()
  "Build the shipped default layout and forget the arranged one of this frame's
shape."
  (interactive)
  (let* ((shape (homun-layout--pick))
         (all (homun-layout--saved)))
    (when (assq shape all)
      (with-temp-file homun-layout-saved-file
        (prin1 (assq-delete-all shape all) (current-buffer))))
    (homun-layout-apply t)))

(provide 'homun-layout)
;;; homun-layout.el ends here
