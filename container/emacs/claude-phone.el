;;; claude-phone.el --- The phone cockpit's strip, tabs and views -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;;; Commentary:

;; Three tabs (Talk, Board, Status) under a strip (link, 5h usage, waiting chip): the strip is
;; the header line and the tabs the mode line (at the bottom, above compose) of the phone's main window.  The
;; widget faces are set on ONE frame only (`claude-phone-frame') from the theme's own faces.  `claude-remote-home' feeds it the remote cockpit's data.

;;; Code:

(require 'cl-lib)
(require 'widgetry-button)
(require 'widgetry-toggle)
(require 'widgetry-meter)
(require 'homun-menu)
(require 'homun-button)
(declare-function claude-remote--outbox "claude-remote") ; called only once claude-remote is loaded

(defface claude-phone-strip '((t :inherit header-line :weight bold))
  "The thin strip on top." :group 'claude)
(defface claude-phone-title '((t :weight bold :height 1.25))
  "A waiting item's headline." :group 'claude)

(defface claude-phone-meter-ok '((t :inherit success)) "A usage bar below 60%." :group 'claude)
(defface claude-phone-meter-warn '((t :inherit warning)) "A usage bar from 60% to 85%." :group 'claude)
(defface claude-phone-meter-bad '((t :inherit error)) "A usage bar above 85%." :group 'claude)

(defvar claude-phone-frame nil "The frame the theme faces are set on.")

(defun claude-phone--meter (fraction width)
  "A usage bar in the ok, warn or bad face."
  (propertize (widgetry-meter-string fraction width) 'face
              (cond ((< fraction 0.6) 'claude-phone-meter-ok)
                    ((< fraction 0.85) 'claude-phone-meter-warn)
                    (t 'claude-phone-meter-bad))))

(defun claude-phone--colour (face attr frame)
  "ATTR of FACE on FRAME, resolved through inheritance, or the default's."
  (let ((c (face-attribute face attr frame t)))
    (if (stringp c) c (face-attribute 'default attr frame))))

(defun claude-phone--faces (frame)
  "The face specs on FRAME, read from the theme's own faces (`header-line', `link',
`success', `warning', `error'), so a light or dark theme carries over."
  (let* ((bg (claude-phone--colour 'default :background frame))
         (fg (claude-phone--colour 'default :foreground frame))
         (panel (claude-phone--colour 'header-line :background frame))
         (acc (claude-phone--colour 'link :foreground frame))
         (ok (claude-phone--colour 'success :foreground frame)))
    `((header-line :background ,panel :foreground ,fg :box nil :inherit nil)
      (widgetry-tag :background ,panel :foreground ,fg :box (:line-width 1 :color ,acc))
      (widgetry-value :background ,panel :foreground ,fg :height 1.6
                      :box (:line-width 3 :color ,panel))
      (widgetry-value-on :background ,ok :foreground ,bg :weight bold)
      (widgetry-button-pressed :background ,acc :foreground ,bg)
      (widgetry-meter-fill-ok :background ,ok)
      (widgetry-meter-fill-warn :background ,(claude-phone--colour 'warning :foreground frame))
      (widgetry-meter-fill-high :background ,(claude-phone--colour 'error :foreground frame)))))

(defun claude-phone-theme (frame &optional _mode)
  "Set the widget faces on FRAME only, from the theme's faces.
_MODE is ignored: the theme decides light or dark."
  (dolist (f (claude-phone--faces frame))
    (apply #'set-face-attribute (car f) frame (cdr f)))
  (setq claude-phone-frame frame))

;;; Content

(defun claude-phone--ago (secs)
  (if (< secs 90) (format "%ds" secs) (format "%dm" (/ secs 60))))

(defun claude-phone-order (items)
  "ITEMS, most urgent first, oldest first among equals."
  (sort (copy-sequence items)
        (lambda (a b) (if (= (plist-get a :urgency) (plist-get b :urgency))
                          (> (plist-get a :age) (plist-get b :age))
                        (> (plist-get a :urgency) (plist-get b :urgency))))))

(defun claude-phone--line (&rest parts)
  (insert (apply #'concat parts) "\n"))

;;; The strip and the tabs: the header line and the tab line of the phone's main window

(defvar claude-phone-view-function nil
  "Called with a view (`talk', `board', `status' or `approval') when a tab or the
strip asks for it.")
(defvar claude-phone-reconnect-function #'ignore "Called when the link word of the strip is tapped.")
(defvar claude-phone-view 'talk "The tab shown: `talk', `board' or `status'.")
(defconst claude-phone-tabs '((talk . "Talk") (board . "Board") (status . "Status")))

(defvar claude-phone-glance nil "The newest glance record of the host (a plist), or nil.")

(defun claude-phone--usage (glance)
  "The five-hour usage of GLANCE as a fraction, or nil."
  (when-let* ((five (plist-get (plist-get glance :usage) :five)))
    (/ five 100.0)))

(defun claude-phone--tap (label action)
  "LABEL as a plain tap target of a header or tab line that calls ACTION (no
arguments)."
  (let ((map (make-sparse-keymap)) (cmd (lambda () (interactive) (funcall action))))
    (dolist (line '(header-line tab-line mode-line))
      (define-key map (vector line 'mouse-1) cmd))
    (propertize label 'keymap map 'mouse-face 'highlight)))

(defun claude-phone--view (view)
  (when claude-phone-view-function (funcall claude-phone-view-function view)))

(defun claude-phone-talk () "Switch the phone to the Talk screen." (interactive) (claude-phone--view 'talk))
(defun claude-phone-board () "Switch the phone to the Board screen." (interactive) (claude-phone--view 'board))
(defun claude-phone-status () "Switch the phone to the Status screen." (interactive) (claude-phone--view 'status))

(defun claude-phone-link ()
  "The state of the link: (live), (retry . SECONDS) or (offline . QUEUED)."
  (let ((queued (length (and (fboundp 'claude-remote--outbox) (claude-remote--outbox))))
        (timer (bound-and-true-p claude-remote--timer)))
    (cond ((bound-and-true-p claude-remote-connected) '(live))
          ((> queued 0) (cons 'offline queued))
          ((timerp timer) (cons 'retry (max 0 (round (float-time (time-subtract (timer--time timer) nil))))))
          (t '(offline . 0)))))

(defun claude-phone-strip (link usage waiting)
  "The strip: LINK (see `claude-phone-link'), five-hour USAGE (a fraction or nil),
WAITING items.
Tap the link word to reconnect, 5h for Status, the chip for the first waiting
item."
  (let* ((face (pcase (car link) ('live 'success) ('retry 'warning) (_ 'error)))
         (word (pcase link
                 (`(live) "live")
                 (`(retry . ,s) (format "retry %ds" s))
                 (`(offline . 0) "offline")
                 (`(offline . ,n) (format "offline · %d" n))))
         (chip (and (> waiting 0) (format "▲ %d waiting" waiting))))
    (concat " " (propertize "●" 'face face) " "
            (homun-button word 'link (lambda () (funcall claude-phone-reconnect-function)) t)
            (when usage
              (concat "  " (claude-phone--tap
                            (concat (propertize "5h " 'face 'shadow) (claude-phone--meter usage 6)
                                    (format " %d%%" (round (* 100 usage))))
                            (lambda () (claude-phone--view 'status)))))
            (when chip
              (concat (propertize " " 'display `(space :align-to (- right ,(1+ (string-width chip)))))
                      (homun-button chip 'primary (lambda () (claude-phone--view 'approval)) t))))))

(defun claude-phone-tabs (current &optional trailing)
  "Talk, Board and Status as pills spread over the line; CURRENT is highlighted and
underlined.
TRAILING, a right-aligned string, ends the line: the pills spread over the room
left of it."
  (let* ((full (apply #'+ (mapcar (lambda (tab) (+ 2 (string-width (cdr tab)))) claude-phone-tabs)))
         ;; at large text sizes the labels shorten, never the pills
         (short (> (+ full (string-width (or trailing ""))) (window-width)))
         (n (length claude-phone-tabs)) (i 0)
         (share (if trailing (max 0.5 (- 1 (/ (float (string-width trailing)) (max 1 (window-width))))) 1.0)))
    (concat
     (mapconcat
     (lambda (tab)
       (prog1 (concat (propertize " " 'display `(space :align-to (,(* share (/ (float i) n)) . text)))
                      (homun-button (if short (substring (cdr tab) 0 1) (cdr tab)) (if (eq (car tab) current) 'tab-active 'tab)
                                    (lambda () (claude-phone--view (car tab))) t))
         (setq i (1+ i))))
     claude-phone-tabs "")
     trailing)))

;;; Questions without the minibuffer: pills in a bottom window, each with a visible Cancel

(defconst claude-phone-ask-buffer "*homun ask*")

(defun claude-phone--ask-close ()
  (when-let* ((window (get-buffer-window claude-phone-ask-buffer)))
    (quit-window t window)))

(defun claude-phone--ask-open (prompt pills text)
  "Show PROMPT with the header-line PILLS ((LABEL . FUNCTION)...); TEXT non-nil
makes the body editable."
  (let ((buffer (get-buffer-create claude-phone-ask-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (kill-all-local-variables)
        (erase-buffer)
        (if text (text-mode) (special-mode))
        (setq-local touch-screen-display-keyboard (and text t) cursor-type (and text t) mode-line-format nil
                    header-line-format
                    (concat (propertize (format " %s " prompt) 'face 'shadow) "\n"
                            (mapconcat (lambda (p) (homun-button (car p) 'secondary (cdr p) t))
                                       pills "  ")))))
    (let ((window (or (get-buffer-window buffer)
                      (display-buffer-in-side-window buffer '((side . bottom) (window-height . 8))))))
      (select-window window))
    (when (fboundp 'frame-toggle-on-screen-keyboard) (frame-toggle-on-screen-keyboard nil (not text)))
    buffer))

(defun claude-phone-ask (prompt callback)
  "Ask for a line of text in a small compose-like window: Send calls CALLBACK with
it, Cancel with nothing."
  (let ((buffer (claude-phone--ask-open
                 prompt
                 (list (cons "Send" (lambda () (let ((text (string-trim (with-current-buffer claude-phone-ask-buffer (buffer-string)))))
                                                 (claude-phone--ask-close) (funcall callback text))))
                       (cons "Cancel" #'claude-phone--ask-close))
                 t)))
    (with-current-buffer buffer (visual-line-mode 1))))

(defun claude-phone-confirm (prompt yes &optional no)
  "Ask PROMPT with Yes and No pills: YES or NO (functions, no arguments) runs after
the tap."
  (claude-phone--ask-open prompt
                          (list (cons "Yes" (lambda () (claude-phone--ask-close) (funcall yes)))
                                (cons "No" (lambda () (claude-phone--ask-close) (when no (funcall no)))))
                          nil))

(defun claude-phone--run (label action)
  "Run ACTION for the button LABEL with feedback: \"LABEL…\" at once, then its own
message or the result.
ACTION is a command or a function of no arguments, as the answers of an approval
card are."
  (message "%s…" label)
  (redisplay t)
  (condition-case err
      (let ((text (current-message)))
        (if (commandp action) (call-interactively action) (funcall action))
        (when (equal (current-message) text) (message "%s: done" label)))
    (error (message "%s failed: %s" label (error-message-string err)))))

(defun claude-phone--button (label &optional action role)
  "A button LABEL of ROLE (default secondary); ACTION (a command or a function of
no arguments) runs on a tap, with feedback."
  (homun-button-insert (format "%-26s" label) (or role 'secondary)
                       (lambda () (if action (claude-phone--run label action) (message "%s" label))))
  (insert "\n\n"))

(defun claude-phone--answer (a &optional role)
  "Answer A is a label or (LABEL . ACTION); ROLE is its button's."
  (if (consp a) (claude-phone--button (car a) (cdr a) role) (claude-phone--button a nil role)))

(defvar claude-phone-card 0 "The index of the waiting item the approval card shows.")

(defun claude-phone--waiting (items)
  "The approval card of item `claude-phone-card' of ITEMS: Back and paging on top,
what it asks in the code face, its answers at the bottom of the window (thumb
level), the last apart."
  (let* ((n (length items))
         (i (setq claude-phone-card (max 0 (min claude-phone-card (1- n)))))
         (it (nth i items)) (answers (plist-get it :answers))
         (ask (equal (plist-get it :kind) "question")))
    (insert (homun-button "‹ Back" 'secondary (lambda () (claude-phone--view 'board)) t))
    (when (> n 1)
      (let ((page (format "%d of %d ›" (1+ i) n)))
        (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width page))))))
        (insert (homun-button page 'secondary
                              (lambda () (setq claude-phone-card (% (1+ i) n))
                                (claude-phone--view 'approval))
                              t))))
    (insert "\n\n")
    (claude-phone--line (propertize (if ask "? QUESTION" "▲ APPROVAL") 'face (if ask '(link bold) '(warning bold))))
    (claude-phone--line (propertize (plist-get it :title) 'face 'claude-phone-title))
    (claude-phone--line (propertize (format "%s ago" (claude-phone--ago (plist-get it :age))) 'face 'shadow) "\n")
    (let ((start (point)))
      (insert (plist-get it :body) "\n")
      (add-face-text-property start (point) '(:inherit (fixed-pitch claude-phone-row) :extend t)))
    (let ((room (- (window-body-height (or (get-buffer-window (current-buffer) t) (selected-window)))
                   (count-lines (point-min) (point)) (* 3 (length answers)) 1)))
      (insert (make-string (max 1 room) ?\n)))
    (cl-loop for (a . more) on answers
             do (unless more (insert "\n")) ; the last (Deny…) stands apart
             (claude-phone--answer a (cond ((and (not more) (cdr answers)) 'danger) ((eq a (car answers)) 'primary))))))

(defface claude-phone-row '((t :inherit header-line :weight normal :extend t))
  "A Board row: a panel-coloured block." :group 'claude)

(defvar claude-phone-glance-time nil "When the glance arrived (`float-time'), or nil.")

(defun claude-phone--section (title &optional right)
  "A dim section TITLE, RIGHT at the right edge."
  (insert "\n" (propertize title 'face '(shadow bold)))
  (when right
    (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width right)))))
            (propertize right 'face 'shadow)))
  (insert "\n"))

(defun claude-phone--row (glyph glyph-face title sub &optional action unseen)
  "A two-line row: GLYPH in GLYPH-FACE and TITLE, SUB dim under it; ACTION (no
arguments) on a tap.  UNSEEN adds a dot after the title."
  (let ((start (point)))
    (insert " " (propertize glyph 'face glyph-face) "  " (propertize title 'face 'bold)
            (if unseen (propertize " ●" 'face 'link) "")
            (if action (concat (propertize " " 'display '(space :align-to (- right 3))) "›") "")
            "\n    " (propertize sub 'face 'shadow) "\n")
    (add-face-text-property start (point) 'claude-phone-row t)
    (when action
      (make-text-button start (1- (point)) 'action (lambda (_) (funcall action))
                        'follow-link t 'face nil 'mouse-face 'highlight))
    (insert (propertize "\n" 'face '(:height 0.4)))))

(defvar claude-phone-task-function nil
  "Called with a glance task (a plist) when its Board row is tapped: shows its
detail.")

;;; Unseen: what changed since its detail was last opened
;; The seen state is per device: one file, (KEY . SIGNATURE) pairs, so it outlives a reconnect and
;; a restart.  A task is unseen when its signature is not the one remembered for its key.

(defvar claude-phone-seen-file nil "Where the seen state is kept, or nil for memory only.")
(defvar claude-phone--seen nil "Alist (KEY . SIGNATURE), read from `claude-phone-seen-file' on first use.")
(defvar claude-phone--seen-loaded nil "Non-nil once `claude-phone--seen' was read from the file.")

(defun claude-phone-task-key (task)
  "The identity of the glance TASK: its kind and title."
  (format "%s|%s" (plist-get task :kind) (plist-get task :title)))

(defun claude-phone-task-signature (task)
  "What of the glance TASK a change shows: state, latest line and tracker item."
  (format "%s|%s|%s" (plist-get task :state) (plist-get task :last) (plist-get task :tracker)))

(defun claude-phone--seen ()
  "The seen alist, read once from the file; a missing or damaged file is empty."
  (unless claude-phone--seen-loaded
    (setq claude-phone--seen-loaded t
          claude-phone--seen
          (let ((data (and claude-phone-seen-file (file-readable-p claude-phone-seen-file)
                           (ignore-errors (with-temp-buffer (insert-file-contents claude-phone-seen-file)
                                            (read (current-buffer)))))))
            (and (listp data)
                 (seq-filter (lambda (e) (and (consp e) (stringp (car e)) (stringp (cdr e)))) data)))))
  claude-phone--seen)

(defun claude-phone-task-unseen-p (task)
  "Non-nil when the glance TASK changed since its detail was last opened, or never was."
  (not (equal (cdr (assoc (claude-phone-task-key task) (claude-phone--seen)))
              (claude-phone-task-signature task))))

(defun claude-phone-task-mark-seen (task)
  "Remember the glance TASK as seen as it is now; forget the tasks gone from the glance."
  (let* ((key (claude-phone-task-key task))
         (live (cons key (mapcar #'claude-phone-task-key (append (plist-get claude-phone-glance :tasks) nil)))))
    (setq claude-phone--seen
          (cons (cons key (claude-phone-task-signature task))
                (seq-filter (lambda (e) (and (not (equal (car e) key)) (member (car e) live)))
                            (claude-phone--seen))))
    (when claude-phone-seen-file
      (condition-case err
          (progn (make-directory (file-name-directory claude-phone-seen-file) t)
                 (with-temp-file claude-phone-seen-file (prin1 claude-phone--seen (current-buffer))))
        (file-error (message "phone: seen state not saved: %s" (error-message-string err)))))))

(defun claude-phone--board (glance items)
  "ATTENTION (the waiting ITEMS, messages and a doctor failure), then the TASKS of
GLANCE."
  (let* ((tasks (append (plist-get glance :tasks) nil))
         (doc (plist-get glance :doctor))
         (problem (and glance (not (eq (plist-get doc :ok) t)) (plist-get doc :problem)))
         (n (+ (length items) (if (stringp problem) 1 0))))
    (claude-phone--section "ATTENTION" (and (> n 0) (number-to-string n)))
    (dolist (it items)
      (let ((ask (plist-get it :answers)))
        (claude-phone--row (cond ((not ask) "·") ((equal (plist-get it :kind) "question") "?") (t "▲"))
                           (cond ((not ask) 'shadow) ((equal (plist-get it :kind) "question") 'link) (t 'warning))
                           (plist-get it :title)
                           (format "%s · %s%s" (plist-get it :kind) (claude-phone--ago (plist-get it :age))
                                   (if ask " · tap to answer" ""))
                           (and ask (lambda () (claude-phone--view 'approval))))))
    (when (stringp problem)
      (claude-phone--row "!" 'error (format "Doctor: %s" problem) "doctor"
                         (lambda () (claude-phone--view 'status))))
    (when (= n 0) (insert (propertize "Nothing waits on you.\n" 'face 'shadow)))
    (claude-phone--section "TASKS" (and tasks (format "%d running" (length tasks))))
    (dolist (tk tasks)
      (claude-phone--row "◌" 'link (plist-get tk :title)
                         (format "%s · %s · %s" (or (plist-get tk :state) "running")
                                 (plist-get tk :kind) (or (plist-get tk :age) ""))
                         (and claude-phone-task-function
                              (let ((tk tk)) (lambda () (funcall claude-phone-task-function tk))))
                         (claude-phone-task-unseen-p tk)))
    (unless tasks
      (insert (propertize (if glance "No tasks running.\n" "No board data from the host yet.\n") 'face 'shadow)))
    (when claude-phone-glance-time
      (insert "\n" (propertize (format "updated %s ago"
                                       (claude-phone--ago (round (- (float-time) claude-phone-glance-time))))
                               'face 'shadow) "\n"))))

(defun claude-phone--reset (epoch)
  "The time to EPOCH as \"↺ 2h10\", or its weekday when over a day away."
  (when (numberp epoch)
    (let ((secs (- epoch (float-time))))
      (cond ((<= secs 0) "↺ now")
            ((< secs 86400) (format "↺ %dh%02d" (/ secs 3600) (/ (mod (round secs) 3600) 60)))
            (t (format-time-string "↺ %a" epoch))))))

(defun claude-phone--usage-line (label used reset)
  "LABEL, a meter of USED percent, the percent and the RESET countdown."
  (when (numberp used)
    (claude-phone--line " " (propertize label 'face 'bold) "  "
                        (claude-phone--meter (/ used 100.0) 12)
                        (format "  %d%%  " (round used))
                        (propertize (or (claude-phone--reset reset) "") 'face 'shadow))))

(defun claude-phone--status-face (status)
  (pcase status ("ok" 'success) ((or "warn" "unknown") 'warning) ("fail" 'error) (_ 'shadow)))

(defun claude-phone--role-check (role checks)
  "The check of CHECKS that is ROLE's session, or nil."
  (seq-find (lambda (c) (string-match-p (format "\\_<%s\\_>" (regexp-quote role)) (plist-get c :id))) checks))

(defvar claude-phone-doctor nil "(TIME . CHECKS) of the last Run doctor from this phone, or nil.")
(defvar claude-phone-doctor-function nil "Runs the doctor on the host (Run doctor).")

;;; The doctor: a strip on Status, the details on the services view

(defconst claude-phone-doctor-areas
  '(("Containers" . "C") ("Host" . "H") ("Services" . "S") ("Cockpit" . "E") ("Roles" . "R") ("Data" . "D"))
  "The doctor's areas in order, each with the letter that names it in the strip.")

(defvar claude-phone-services-area nil "The area the services view puts point on, or nil.")
(defvar claude-phone-services-open nil "Ids of the checks whose detail the services view shows.")

(defun claude-phone--check-area (check)
  "The area of CHECK: its own, else the one whose id prefix the gateway uses, else Cockpit."
  (or (plist-get check :area)
      (let ((id (or (plist-get check :id) "")))
        (cond ((string-prefix-p "container" id) "Containers")
              ((string-match-p "\\`\\(disk\\|host\\|net\\)" id) "Host")
              ((string-match-p "\\`\\(scheduler\\|mechanic\\|broker\\)" id) "Roles")
              (t "Cockpit")))))

(defun claude-phone--worst (checks)
  "The worst status of CHECKS: \"fail\", \"warn\", \"unknown\", \"ok\", or nil for none."
  (seq-find (lambda (s) (seq-some (lambda (c) (equal (plist-get c :status) s)) checks))
            '("fail" "warn" "unknown" "ok")))

(defun claude-phone--open-services (&optional area)
  "Show the services view, point on AREA."
  (setq claude-phone-services-area area)
  (claude-phone--view 'services))

(defun claude-phone--doctor-strip (checks doc glance)
  "One line: a glyph per area in its worst status's face (a tap opens that area on the
services view), then the warn and fail counts (a tap opens the view).  Without data
every glyph is dim; a doctor problem counts as a fail."
  (let* ((problem (and (stringp (plist-get doc :problem)) 1))
         (warn (cl-count "warn" checks :key (lambda (c) (plist-get c :status)) :test #'equal))
         (fail (+ (or problem 0) (cl-count "fail" checks :key (lambda (c) (plist-get c :status)) :test #'equal)))
         (start (point)))
    (insert " ")
    (pcase-dolist (`(,area . ,letter) claude-phone-doctor-areas)
      (let* ((worst (and glance (claude-phone--worst
                                 (seq-filter (lambda (c) (equal (claude-phone--check-area c) area)) checks))))
             (text (concat (propertize (if (equal worst "fail") "✗" (if (equal worst "warn") "▲" "●"))
                                       'face (if worst (claude-phone--status-face worst) 'shadow))
                           (propertize letter 'face 'shadow)))
             (area area))
        (insert (claude-phone--tap-text text (lambda () (claude-phone--open-services area))
                                        (format "%s: %s" area (or worst "no data"))) "  ")))
    (insert (claude-phone--tap-text
             (concat (propertize (format "▲%d" warn) 'face (if (> warn 0) 'warning 'shadow)) " "
                     (propertize (format "✗%d" fail) 'face (if (> fail 0) 'error 'shadow)))
             (lambda () (claude-phone--open-services)) "Open the service status")
            "\n")
    (add-face-text-property start (point) 'claude-phone-row t)))

(defun claude-phone--tap-text (text action help)
  "TEXT as a button that calls ACTION; HELP is its tooltip."
  (with-temp-buffer
    (insert text)
    (make-text-button (point-min) (point-max) 'action (lambda (_) (funcall action))
                      'follow-link t 'mouse-face 'highlight 'help-echo help)
    (buffer-string)))

(defun claude-phone--toggle-check (id)
  "Show or hide the detail of the check ID on the services view."
  (setq claude-phone-services-open (if (member id claude-phone-services-open)
                                       (remove id claude-phone-services-open)
                                     (cons id claude-phone-services-open)))
  (claude-phone--view 'services))

(defun claude-phone--services (glance)
  "The service status: a section per area, a row per check (status and summary), and under
a row the tapped open its hint and the file behind it."
  (let ((checks (append (or (cdr claude-phone-doctor) (plist-get glance :checks)) nil))
        (area-pos nil))
    (insert (homun-button "‹ Back" 'secondary (lambda () (claude-phone--view 'status)) t) "\n")
    (claude-phone--section "SERVICE STATUS" (and claude-phone-doctor
                                                  (format "%s ago" (claude-phone--ago (round (- (float-time) (car claude-phone-doctor)))))))
    (claude-phone--button "Run doctor" claude-phone-doctor-function)
    (cond ((null glance) (insert (propertize "No data from the host yet.\n" 'face 'shadow)))
          ((null checks) (insert (propertize "No check answered: unknown.\n" 'face 'warning))))
    (pcase-dolist (`(,area . ,_) claude-phone-doctor-areas)
      (let ((rows (seq-filter (lambda (c) (equal (claude-phone--check-area c) area)) checks)))
        (when rows
          (when (equal area claude-phone-services-area) (setq area-pos (point)))
          (claude-phone--section area (format "%d" (length rows)))
          (dolist (c rows)
            (let* ((id (plist-get c :id)) (st (plist-get c :status)) (open (member id claude-phone-services-open)))
              (claude-phone--row (if (equal st "fail") "✗" (if (equal st "warn") "▲" "●"))
                                 (claude-phone--status-face st)
                                 (plist-get c :name)
                                 (format "%s · %s" st (plist-get c :summary))
                                 (lambda () (claude-phone--toggle-check id)))
              (when open
                (let ((hint (plist-get c :hint)) (file (plist-get c :open)))
                  (unless (or (member hint '(nil "")) ) (claude-phone--line "    " (propertize hint 'face 'shadow)))
                  (when (stringp file) (claude-phone--line "    " (propertize file 'face 'shadow)))
                  (when (and (member hint '(nil "")) (not (stringp file)))
                    (claude-phone--line "    " (propertize "nothing more to show" 'face 'shadow))))))))))
    (when area-pos (setq claude-phone-services-area nil) (goto-char area-pos))
    area-pos))

;;; The update line: the desktop update card, as one line

(defvar claude-phone-recreate-function nil "Asks the host to recreate on the staged image.")

(defun claude-phone-update-line (update now)
  "The one line for the glance's UPDATE plist at NOW, or nil when idle.
Phase, step, elapsed time with the ETA by the pace so far, and the launcher rev."
  (when (and (listp update) (stringp (plist-get update :phase)))
    (let* ((phase (plist-get update :phase)) (step (plist-get update :step))
           (total (plist-get update :total)) (rev (plist-get update :rev))
           (since (plist-get update :since))
           (elapsed (and (numberp since) (max 0 (floor (- now since)))))
           (eta (and (equal phase "building") (numberp step) (numberp total) (> step 0)
                     (> total step) elapsed (> elapsed 0)
                     (* (/ (float elapsed) step) (- total step)))))
      (mapconcat
       #'identity
       (delq nil (list (pcase phase
                         ("building" "building") ("staged" "staged, waiting")
                         ("recreating" "recreating") ("failed" "failed") (_ phase))
                       (and (equal phase "building") (numberp step) (numberp total)
                            (format "step %d/%d" step total))
                       (and elapsed (member phase '("building" "recreating"))
                            (format "%dm%02ds" (/ elapsed 60) (% elapsed 60)))
                       (and eta (format "~%dm left" (ceiling (/ eta 60))))
                       (and (stringp rev) (format "launcher %s" rev))))
       " · "))))

(defun claude-phone--update (glance)
  "The update line, with Recreate while an image waits; nothing when idle."
  (when-let* ((update (plist-get glance :update))
              (line (claude-phone-update-line update (float-time))))
    (claude-phone--section "UPDATE")
    (claude-phone--line " " line)
    (when (and (equal (plist-get update :phase) "staged") claude-phone-recreate-function)
      (insert "\n")
      (claude-phone--button
       "Recreate"
       (lambda ()
         (claude-phone-confirm "Recreate ends every session. Recreate now?"
                               claude-phone-recreate-function))
       'danger))))

(defun claude-phone--status (glance role pick unhandled)
  "USAGE meters, ROLES (state dot, tap: Compose writes to it), DOCTOR lines and Run
doctor, then the last attention decisions and the unhandled counts.  ROLE is the
role Compose writes to; PICK is called with a role name when its row is tapped."
  (let* ((u (plist-get glance :usage)) (doc (plist-get glance :doctor))
         (checks (append (or (cdr claude-phone-doctor) (plist-get glance :checks)) nil)))
    (claude-phone--update glance)
    (claude-phone--section "USAGE")
    (if u
        (progn (claude-phone--usage-line "5h" (plist-get u :five) (plist-get u :five_reset))
               (claude-phone--usage-line "7d" (plist-get u :seven) (plist-get u :seven_reset)))
      (insert (propertize "No usage from the host yet.\n" 'face 'shadow)))
    (claude-phone--section "ROLES" (format "compose → %s" role))
    (dolist (r (append (plist-get glance :roles) nil))
      (let* ((c (claude-phone--role-check r checks)) (st (and c (plist-get c :status))))
        (claude-phone--row "●" (claude-phone--status-face st)
                           (if (equal r role) (concat r "  ✎") r)
                           (if c (format "%s · %s" st (plist-get c :summary)) "no check")
                           (lambda () (funcall pick r)))))
    (claude-phone--section "DOCTOR" (and claude-phone-doctor
                                         (format "%s ago" (claude-phone--ago (round (- (float-time) (car claude-phone-doctor)))))))
    (claude-phone--doctor-strip checks doc glance)
    (insert "\n")
    (claude-phone--button "Run doctor" claude-phone-doctor-function)
    (when-let* ((attn (append (plist-get glance :attn) nil)))
      (claude-phone--section "ATTENTION LADDER")
      (dolist (a attn)
        (claude-phone--line " " (propertize (format "%-9s" (plist-get a :level)) 'face 'shadow)
                            (plist-get a :text))))
    (when unhandled
      (claude-phone--section "UNHANDLED")
      (dolist (c unhandled)
        (claude-phone--line " " (format "%-14s %d" (car c) (cdr c)))))))

(defvar claude-phone-role nil "The role Status shows as the compose target.")
(defvar claude-phone-role-function #'ignore "Called with a role name when Status picks one.")
(defvar claude-phone-unhandled nil "Alist (KIND . COUNT) shown on Status.")

(defun claude-phone-show (buffer view items)
  "Render VIEW (`board', `status' or `approval') into BUFFER from ITEMS and the
glance."
  (with-current-buffer (get-buffer-create buffer)
    (let* ((inhibit-read-only t) (items (claude-phone-order items))
           (waiting (seq-filter (lambda (i) (plist-get i :answers)) items))
           (old (point)))
      (kill-all-local-variables) (erase-buffer)
      (setq-local cursor-type nil mode-line-format nil)
      (pcase view
        ('status (claude-phone--status claude-phone-glance claude-phone-role
                                       claude-phone-role-function claude-phone-unhandled))
        ('approval (if waiting (claude-phone--waiting waiting)
                     (claude-phone--line (propertize "Nothing waits on you." 'face 'shadow))))
        ('services (let ((pos (claude-phone--services claude-phone-glance)))
                     (goto-char (or pos (min old (point-max))))))
        (_ (claude-phone--board claude-phone-glance items)))
      (unless (eq view 'services) (goto-char (point-min))))
    (current-buffer)))

(provide 'claude-phone)
;;; claude-phone.el ends here
