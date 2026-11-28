;;; homun-stage-kit.el --- Stage scene kit: animated parts bound to live data -*- lexical-binding: t -*-

;; Six node types for Stage scenes, each bound to live data so a scene is a few lines of spec:
;;
;;   ring     a progress ring: "topic" (a published 0..1, or 0..max), or "start" and "span"
;;            (elapsed of span seconds); "agent" adds a spinner while it runs and opens its run.
;;   log      the tail of a build log: "buffer" (a name) or "compile" (a directory: the newest
;;            compilation buffer there, bin/homun-compile's), or a log "file", or "latest" (a
;;            buildlog project directory: the log its latest.json names); "skip" (a regexp of
;;            lines to leave out); "lines" (4).  It scrolls in.
;;   tests    pass and fail counters parsed from that compile output (ERT, cargo, pytest); they
;;            tick.  With "latest" the newest log of that directory holding a test result.
;;   files    a grid of the files git status names in "dir", lit when touched and fading out.
;;   commits  the commits of "dir" since "base" (main) as a graph that grows a node per commit.
;;   budget   the 5h plan budget gauge from usage-db; "low" (80) is where it turns warning.
;;
;; All take "id", "width" (48) and "label".  Every element is clickable (RET or a click): it
;; opens what it shows (the compile buffer, the file, the commit, the agent's run detail).
;;
;; A part is drawn as fixed lines of buffer text.  Its data comes from sources polled by one
;; timer while a Stage buffer with parts is visible (git asynchronously); a change wakes the
;; `homun-clock' client, which redraws each line whose text changed, in place.  A tick never
;; renders the scene and never inserts a line: unchanged lines are not touched.
;;
;; Events (`homun-stage-kit-event-functions'): agent-start, agent-finish, build-pass,
;; build-fail, merge, budget-low.  The scene "agents" (`homun-stage-kit-agents-show') is
;; composed from the parts per running agent and shown again only on an event.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'homun-clock)
(require 'homun-stage)
(require 'homun-stage-store)
(require 'homun-proc)
(require 'widgetry-core)

(declare-function claude-agent--select "claude-agent")
(declare-function claude-links-row "claude-links")
(declare-function claude-links-rows "claude-links")
(declare-function claude-run-detail-open "claude-run-detail")
(declare-function magit-show-commit "magit-diff")
(defvar homun-compile--time)

(defvar homun-stage-kit-poll 0.5 "Seconds between looks at the data sources.")
(defvar homun-stage-kit-width 48 "Default columns of a part.")
(defvar homun-stage-kit-usage-url "http://127.0.0.1:8080/usage-db/" "What the budget gauge opens.")
(defvar homun-stage-kit-event-functions nil
  "Abnormal hook run with (EVENT PLIST): agent-start agent-finish build-pass
build-fail merge budget-low.")
(defvar homun-stage-kit-visible-function
  (lambda (buf) (when-let* ((w (get-buffer-window buf t))) (frame-visible-p (window-frame w))))
  "Non-nil for a buffer a visible window shows.")

(defface homun-stage-kit-hot '((t (:inherit success :weight bold :inverse-video t))) "A file just touched." :group 'homun-layout)
(defface homun-stage-kit-warm '((t (:inherit success :weight bold))) "A file touched lately." :group 'homun-layout)

(defvar homun-stage-kit--data (make-hash-table :test #'equal) "Source key to its latest data.")
(defvar homun-stage-kit--polled (make-hash-table :test #'equal) "Source key to when it was last polled.")
(defvar homun-stage-kit--buffers nil "Buffers holding parts.")
(defvar homun-stage-kit--timer nil)
(defvar homun-stage-kit--writes 0 "Lines replaced by ticks, for tests and the frame bench.")

(cl-defstruct (homun-stage-kit--inst (:constructor homun-stage-kit--inst-make) (:copier nil))
  type node (state nil) (lines nil))

(defvar-local homun-stage-kit--insts nil "The parts drawn in this buffer: insts whose LINES are (MARKER . SHOWN).")
(defvar-local homun-stage-kit--pending nil "Parts inserted by the render under way.")

;;; Registry

(defvar homun-stage-kit--parts nil "Alist of type to (SOURCES-FN . DRAW-FN).")

(defun homun-stage-kit-define (type fields sources draw)
  "Make TYPE a Stage node type with required FIELDS.
SOURCES is called with the node and returns its (KEY FUNCTION PERIOD) sources;
FUNCTION gets the node and KEY and stores data with `homun-stage-kit-put'.  DRAW
is called with the inst, the time and SNAP and returns (LINES . MOVING):
propertized strings, a fixed number."
  (setf (alist-get type homun-stage-kit--parts nil nil #'equal) (cons sources draw))
  (setf (alist-get type homun-stage-parts nil nil #'equal)
        (list :fields fields :text #'homun-stage-kit--text :insert #'homun-stage-kit--insert)))

(defun homun-stage-kit--draw (inst now snap)
  "(LINES . MOVING) of INST, each line tagged with the node id (a tick keeps the
tag)."
  (let* ((r (funcall (cdr (alist-get (homun-stage-kit--inst-type inst) homun-stage-kit--parts nil nil #'equal))
                     inst now snap))
         (id (alist-get 'id (homun-stage-kit--inst-node inst)))
         (scene (bound-and-true-p homun-stage--id)))
    (when id
      (setcar r (mapcar (lambda (l)
                          (let ((l (copy-sequence l)))
                            (put-text-property 0 (length l) 'homun-stage-node id l)
                            (when scene (put-text-property 0 (length l) 'homun-node (concat scene "/" id) l))
                            l))
                        (car r))))
    r))

(defun homun-stage-kit--sources (node)
  (funcall (car (alist-get (alist-get 'type node) homun-stage-kit--parts nil nil #'equal)) node))

;;; Data

(defun homun-stage-kit-get (key) (gethash key homun-stage-kit--data))

(defun homun-stage-kit-put (key value)
  "Store VALUE for the source KEY; a change wakes the clock."
  (unless (equal value (gethash key homun-stage-kit--data))
    (puthash key value homun-stage-kit--data)
    (homun-stage-kit--wake)))

(defun homun-stage-kit-event (event &rest plist)
  "Run `homun-stage-kit-event-functions' with EVENT and PLIST."
  (run-hook-with-args 'homun-stage-kit-event-functions event plist))

(defun homun-stage-kit--poll ()
  "Poll the due sources of the parts in visible buffers; stop when no buffer holds
parts."
  (setq homun-stage-kit--buffers (cl-delete-if-not #'buffer-live-p homun-stage-kit--buffers))
  (if (null homun-stage-kit--buffers)
      (progn (cancel-timer homun-stage-kit--timer) (setq homun-stage-kit--timer nil))
    (let ((now (float-time)) (seen nil))
      (dolist (buf homun-stage-kit--buffers)
        (when (funcall homun-stage-kit-visible-function buf)
          (dolist (inst (buffer-local-value 'homun-stage-kit--insts buf))
            (pcase-dolist (`(,key ,fn ,period) (homun-stage-kit--sources (homun-stage-kit--inst-node inst)))
              (unless (or (member key seen) (< (- now (gethash key homun-stage-kit--polled 0)) period))
                (push key seen)
                (puthash key now homun-stage-kit--polled)
                (condition-case err (funcall fn (homun-stage-kit--inst-node inst) key)
                  (error (homun-stage-kit-put key (list :error (error-message-string err)))))))))))))

(defun homun-stage-kit--arm ()
  (unless homun-stage-kit--timer
    (setq homun-stage-kit--timer (run-with-timer 0 homun-stage-kit-poll #'homun-stage-kit--poll))))

;;; Lines in the buffer

(defun homun-stage-kit--fit (s w)
  "S cut or padded to W columns, its properties kept."
  (truncate-string-to-width s w nil ?\s))

(defvar-keymap homun-stage-kit-map
  :doc "Keys on a part's element."
  "RET" #'homun-stage-kit-open
  "<mouse-1>" #'homun-stage-kit-open
  "<mouse-2>" #'homun-stage-kit-open)

(defun homun-stage-kit--target (s target &optional help)
  "S, opening TARGET when clicked: (buffer NAME [POS]) (file PATH [LINE]) (agent
ID) (commit DIR SHA) (url URL) (refresh KEY: fetch that source again)
(touch FILE KEY: touch FILE, a request to another process, and read KEY again)."
  (if (null target) s
    (propertize s 'homun-kit-open target 'mouse-face 'highlight 'keymap homun-stage-kit-map
                'help-echo (or help (format "RET: open %s" (cadr target))))))

(defun homun-stage-kit--text (node &optional _env)
  "The text of the part NODE at its end state (no tween), with the data known now."
  (let ((inst (homun-stage-kit--inst-make :type (alist-get 'type node) :node node)))
    (string-join (car (homun-stage-kit--draw inst (funcall homun-clock-time-function) t)) "\n")))

(defun homun-stage-kit--insert (node _env)
  "Insert the part NODE at point, one span per line, and note it for the clock."
  (let* ((inst (homun-stage-kit--inst-make :type (alist-get 'type node) :node node))
         (lines (car (homun-stage-kit--draw inst (funcall homun-clock-time-function) t))))
    (cl-loop for (line . more) on lines
             do (push (cons (copy-marker (point)) line) (homun-stage-kit--inst-lines inst))
             (insert line) (when more (insert "\n")))
    (setf (homun-stage-kit--inst-lines inst) (nreverse (homun-stage-kit--inst-lines inst)))
    (push inst homun-stage-kit--pending)))

(defun homun-stage-kit-adopt (&rest _)
  "Make the parts inserted since the last adopt the live ones of this buffer (a
render drew them).
Hook of `homun-stage-render-functions'."
  (dolist (inst homun-stage-kit--insts)
    (dolist (l (homun-stage-kit--inst-lines inst)) (set-marker (car l) nil)))
  (setq homun-stage-kit--insts (nreverse homun-stage-kit--pending) homun-stage-kit--pending nil)
  (when homun-stage-kit--insts
    (cl-pushnew (current-buffer) homun-stage-kit--buffers)
    (homun-stage-kit--arm)
    (homun-stage-kit--wake)))

(add-hook 'homun-stage-render-functions #'homun-stage-kit-adopt)

(defun homun-stage-kit--put-line (cell new)
  "Replace the line of CELL (MARKER . SHOWN) with NEW in place."
  (let ((inhibit-read-only t) (m (car cell)))
    (with-silent-modifications
      (save-excursion
        (goto-char m) (insert new) (delete-region (point) (+ (point) (length (cdr cell))))
        (set-marker m (- (point) (length new)))))
    (setcdr cell new)
    (cl-incf homun-stage-kit--writes)))

(defun homun-stage-kit--step (inst now snap)
  "Redraw the lines of INST that changed.  Non-nil while it moves."
  (pcase-let ((`(,lines . ,moving) (homun-stage-kit--draw inst now snap)))
    (cl-loop for cell in (homun-stage-kit--inst-lines inst) for line in lines
             unless (or (not (marker-position (car cell))) (equal-including-properties line (cdr cell)))
             do (homun-stage-kit--put-line cell line))
    moving))

(defun homun-stage-kit-tick (snap)
  "The clock client: step every part of the visible buffers.  Non-nil while one
moves."
  (let ((now (funcall homun-clock-time-function)) (any nil))
    (dolist (buf homun-stage-kit--buffers)
      (when (and (buffer-live-p buf) (funcall homun-stage-kit-visible-function buf))
        (with-current-buffer buf
          (dolist (inst homun-stage-kit--insts)
            (when (homun-stage-kit--step inst now snap) (setq any t))))))
    any))

(defun homun-stage-kit--wake ()
  (homun-clock-register 'stage-kit #'homun-stage-kit-tick)
  (homun-clock-dirty 'stage-kit))

(defun homun-stage-kit-open (&optional event)
  "Open what the element at point (or of EVENT) shows."
  (interactive (list last-nonmenu-event))
  (let* ((pos (if (mouse-event-p event) (posn-point (event-start event)) (point)))
         (target (and pos (get-text-property pos 'homun-kit-open
                                             (if (mouse-event-p event) (window-buffer (posn-window (event-start event))))))))
    (pcase target
      ('nil (user-error "Nothing to open here"))
      (`(buffer ,name . ,at)
       (if-let* ((b (get-buffer name)))
           (progn (pop-to-buffer b) (when (car at) (goto-char (car at))))
         (user-error "Buffer %s is gone" name)))
      (`(file ,path . ,at) (find-file-other-window path) (when (car at) (goto-char (point-min)) (forward-line (1- (car at)))))
      (`(refresh ,key) (puthash key 0 homun-stage-kit--polled) (homun-stage-kit--poll) (message "Refreshing"))
      (`(touch ,file ,key) (make-directory (file-name-directory file) t) (write-region "" nil file nil 'silent) (puthash key 0 homun-stage-kit--polled) (message "Asked for a fresh fetch"))
      (`(agent ,id) (require 'claude-run-detail) (claude-run-detail-open id))
      (`(commit ,dir ,sha) (homun-stage-kit--show-commit dir sha))
      (`(url ,url) (browse-url url)))))

(defun homun-stage-kit--show-commit (dir sha)
  (let ((default-directory (file-name-as-directory dir)))
    (if (require 'magit nil t)
        (magit-show-commit sha)
      (let ((buf (get-buffer-create (format "*commit %s*" sha))))
        (with-current-buffer buf
          (let ((inhibit-read-only t)) (erase-buffer) (call-process "git" nil t nil "show" sha))
          (goto-char (point-min)) (diff-mode) (view-mode 1))
        (pop-to-buffer buf)))))

;;; Helpers of parts

(defun homun-stage-kit--w (node) (or (alist-get 'width node) homun-stage-kit-width))

(defun homun-stage-kit--chase (cur target snap)
  "CUR a step nearer TARGET: (VALUE . MOVING)."
  (if (or snap (null cur) (< (abs (- target cur)) 0.004)) (cons target nil)
    (cons (+ cur (* 0.3 (- target cur))) t)))

(defun homun-stage-kit--count (cur target snap)
  "The integer CUR ticked toward TARGET: (VALUE . MOVING)."
  (if (or snap (null cur) (= cur target)) (cons target nil)
    (let ((step (max 1 (/ (abs (- target cur)) 6))))
      (cons (if (< cur target) (min target (+ cur step)) (max target (- cur step))) t))))

(defun homun-stage-kit--state (inst key &optional default)
  (or (plist-get (homun-stage-kit--inst-state inst) key) default))

(defun homun-stage-kit--set (inst key value)
  (setf (homun-stage-kit--inst-state inst) (plist-put (homun-stage-kit--inst-state inst) key value))
  value)

(defun homun-stage-kit--bar (f cells)
  (let ((n (round (* cells (max 0.0 (min 1.0 f))))))
    (concat (make-string n ?█) (make-string (- cells n) ?░))))

(defun homun-stage-kit--compile-buffer (node)
  "The buffer NODE reads: its \"buffer\", else the newest compilation buffer under
\"compile\"."
  (if-let* ((name (alist-get 'buffer node))) (get-buffer name)
    (when-let* ((dir (alist-get 'compile node)))
      (let ((dir (file-name-as-directory (expand-file-name dir))))
        (car (sort (cl-remove-if-not
                    (lambda (b) (with-current-buffer b
                                  (and (derived-mode-p 'compilation-mode)
                                       (string-prefix-p dir (expand-file-name default-directory)))))
                    (buffer-list))
                   (lambda (a b) (> (or (buffer-local-value 'homun-compile--time a) 0)
                                    (or (buffer-local-value 'homun-compile--time b) 0)))))))))

(defun homun-stage-kit--build-key (node)
  (append (list "build" (alist-get 'buffer node) (alist-get 'compile node))
          (when (or (alist-get 'file node) (alist-get 'latest node))
            (list (alist-get 'file node) (alist-get 'latest node) (alist-get 'skip node)
                  (and (alist-get 'latest node) (alist-get 'type node))))))

(defvar homun-stage-kit--scans (make-hash-table :test #'eq :weakness 'key)
  "Compile buffer to its scan: (TICK POS PASS FAIL FIRST-FAIL).")

(defconst homun-stage-kit--pass-re
  "^\\(?: +passed +[0-9]+/[0-9]+ \\|test .+ \\.\\.\\. ok$\\|.+::.+ PASSED\\)")
(defconst homun-stage-kit--fail-re
  "^\\(?: +FAILED +[0-9]+/[0-9]+ \\|test .+ \\.\\.\\. FAILED$\\|.+::.+ FAILED\\)")

(defun homun-stage-kit--scan (buf)
  "Bring the scan of BUF up to date, reading only what was added since."
  (with-current-buffer buf
    (let ((sc (or (gethash buf homun-stage-kit--scans) (list -1 (point-min) 0 0 nil))))
      (when (< (point-max) (nth 1 sc)) (setq sc (list -1 (point-min) 0 0 nil)))
      (unless (= (nth 0 sc) (buffer-modified-tick))
        (save-excursion
          (goto-char (nth 1 sc))
          (while (re-search-forward (concat "\\(" homun-stage-kit--pass-re "\\)\\|\\(" homun-stage-kit--fail-re "\\)")
                                    (save-excursion (goto-char (point-max)) (line-beginning-position)) t)
            (if (match-beginning 1) (cl-incf (nth 2 sc))
              (cl-incf (nth 3 sc)) (unless (nth 4 sc) (setf (nth 4 sc) (match-beginning 0))))
            (forward-line 1))
          (setf (nth 1 sc) (save-excursion (goto-char (point-max)) (line-beginning-position))
                (nth 0 sc) (buffer-modified-tick)))
        (puthash buf sc homun-stage-kit--scans))
      sc)))

(defconst homun-stage-kit--tail-bytes 16384 "How much of a log file's end a part reads.")

(defun homun-stage-kit--latest (dir type)
  "The log file of the buildlog project DIR (the one latest.json names).
For the part TYPE \"tests\" it is the newest log holding a test result."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (if (equal type "tests")
        (cl-loop for f in (sort (directory-files dir t "\\.log\\'") #'file-newer-than-file-p)
                 for n below 6
                 when (with-temp-buffer
                        (insert-file-contents f nil (max 0 (- (file-attribute-size (file-attributes f)) homun-stage-kit--tail-bytes)))
                        (re-search-forward "^test result: " nil t))
                 return f)
      (when-let* ((json (expand-file-name "latest.json" dir))
                  (_ (file-readable-p json)))
        (ignore-errors
          (alist-get 'log (with-temp-buffer (insert-file-contents json) (json-parse-buffer :object-type 'alist))))))))

(defun homun-stage-kit--file-data (path stamp skip old)
  "The build data of the log file PATH, read from its tail.
OLD is returned when STAMP is the one of OLD."
  (if (and old (equal (plist-get old :stamp) stamp)) old
    (let ((size (file-attribute-size (file-attributes path))) pass (fail 0) lines)
      (with-temp-buffer
        (insert-file-contents path nil (max 0 (- size homun-stage-kit--tail-bytes)))
        (goto-char (point-min))
        (while (re-search-forward "\e\\[[0-9;]*[A-Za-z]" nil t) (replace-match ""))
        (goto-char (point-min))
        (while (re-search-forward "^test result: .*? \\([0-9]+\\) passed; \\([0-9]+\\) failed" nil t)
          (setq pass (+ (or pass 0) (string-to-number (match-string 1))))
          (cl-incf fail (string-to-number (match-string 2))))
        (setq lines (split-string (buffer-string) "\n" t))
        (when (> size homun-stage-kit--tail-bytes) (pop lines)))
      (unless pass
        (setq pass (cl-count-if (lambda (l) (string-match-p homun-stage-kit--pass-re l)) lines)
              fail (cl-count-if (lambda (l) (string-match-p homun-stage-kit--fail-re l)) lines)))
      (when skip (setq lines (cl-remove-if (lambda (l) (string-match-p skip l)) lines)))
      (list :name path :file t :stamp stamp :live nil :total (length lines) :lines (last lines 12)
            :pass pass :fail fail))))

(defun homun-stage-kit--file-source (node key)
  "Data of a log file (\"file\", or the log of the dir \"latest\"), as for a buffer."
  (let* ((path (or (alist-get 'file node)
                   (when-let* ((d (alist-get 'latest node)))
                     (homun-stage-kit--latest d (alist-get 'type node)))))
         (attrs (and path (file-attributes (expand-file-name path)))))
    (homun-stage-kit-put
     key (when attrs
           (homun-stage-kit--file-data (expand-file-name path)
                                       (list (file-attribute-size attrs) (file-attribute-modification-time attrs))
                                       (alist-get 'skip node) (homun-stage-kit-get key))))))

(defun homun-stage-kit--build-source (node key)
  "Data of a compile buffer: (:name :live :total :lines :pass :fail :first)."
  (if (or (alist-get 'file node) (alist-get 'latest node))
      (homun-stage-kit--file-source node key)
   (homun-stage-kit-put
   key
   (when-let* ((buf (homun-stage-kit--compile-buffer node)))
     (let ((sc (homun-stage-kit--scan buf)))
       (with-current-buffer buf
         (save-excursion
           (goto-char (point-max))
           (when (bolp) (forward-line -1))
           (let ((end (line-end-position)) (total (line-number-at-pos)))
             (forward-line -11)
             (list :name (buffer-name) :live (and (get-buffer-process buf) t) :total total
                   :lines (split-string (buffer-substring-no-properties (point) end) "\n")
                   :pass (nth 2 sc) :fail (nth 3 sc) :first (nth 4 sc))))))))))

(defun homun-stage-kit--build-target (d)
  "The open target of build data D: its file, or its buffer."
  (when d (if (plist-get d :file) (list 'file (plist-get d :name)) (list 'buffer (plist-get d :name) (plist-get d :first)))))

;;; ring

(defun homun-stage-kit--ring-target (node now)
  (let ((topic (alist-get 'topic node)) (start (alist-get 'start node)))
    (cond (topic (let ((v (homun-stage-kit-get (list "topic" topic))))
                   (if (numberp v) (/ v (float (or (alist-get 'max node) 1))) 0.0)))
          ((numberp start) (/ (- now start) (float (or (alist-get 'span node) 1800))))
          (t 0.0))))

(homun-stage-kit-define
 "ring" nil
 (lambda (node)
   (delq nil (list (when-let* ((topic (alist-get 'topic node)))
                     (list (list "topic" topic)
                           (lambda (_ key) (homun-stage-kit-put key (gethash (cadr key) homun-stage-bindings))) 0.25))
                   (when-let* ((agent (alist-get 'agent node)))
                     (list (list "agent" agent)
                           (lambda (_ key) (homun-stage-kit-put
                                            key (and (require 'claude-links nil t)
                                                     (alist-get 'status (claude-links-row (cadr key))))))
                           2)))))
 (lambda (inst now snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (f (min 1.0 (max 0.0 (/ (round (* 100 (homun-stage-kit--ring-target node now))) 100.0))))
          (c (homun-stage-kit--chase (homun-stage-kit--state inst :f) f snap))
          (shown (homun-stage-kit--set inst :f (car c)))
          (agent (alist-get 'agent node))
          (running (and agent (equal (homun-stage-kit-get (list "agent" agent)) "running")))
          (spin (if running (aref widgetry-spinner-frames
                                  (mod (floor now widgetry-spinner-interval) (length widgetry-spinner-frames)))
                  " "))
          (ring (string (aref "○◔◑◕●" (round (* 4 shown)))))
          (pct (format " %3d%%" (round (* 100 shown))))
          (label (homun-stage--str (homun-stage-value (or (alist-get 'label node) "") nil))))
     (cons (list (homun-stage-kit--target
                  (concat (propertize spin 'face 'font-lock-keyword-face) " "
                          (propertize ring 'face (if (>= shown 1) 'success 'font-lock-keyword-face)) " "
                          (homun-stage-kit--fit label (- w 9)) (propertize pct 'face 'shadow))
                  (and agent (list 'agent agent)) (and agent "RET: the agent's run")))
           (or (cdr c) running)))))

;;; log

(homun-stage-kit-define
 "log" nil
 (lambda (node) (list (list (homun-stage-kit--build-key node) #'homun-stage-kit--build-source 0.5)))
 (lambda (inst _now snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (n (or (alist-get 'lines node) 4))
          (d (homun-stage-kit-get (homun-stage-kit--build-key node)))
          (total (or (plist-get d :total) 0))
          (c (homun-stage-kit--count (homun-stage-kit--state inst :at) total snap))
          (at (homun-stage-kit--set inst :at (car c)))
          (lines (plist-get d :lines))
          ;; the window of N lines ending at line AT; LINES ends at line TOTAL
          (end (max 0 (- (length lines) (- total at))))
          (shown (last (seq-take lines end) n))
          (target (homun-stage-kit--build-target d)))
     (cons (cl-loop for i below n
                    for l = (nth (- i (- n (length shown))) shown)
                    collect (homun-stage-kit--target
                             (propertize
                              (homun-stage-kit--fit (concat "│ " (cond (l (string-trim-right l))
                                                                       ((and (= i 0) (null d)) "no build yet")
                                                                       (t ""))) w)
                              'face (if (and l (string-match-p "error\\|FAILED\\|failed" l)) 'error 'shadow))
                             target))
           (cdr c)))))

;;; tests

(homun-stage-kit-define
 "tests" nil
 (lambda (node) (list (list (homun-stage-kit--build-key node) #'homun-stage-kit--build-source 0.5)))
 (lambda (inst _now snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (d (homun-stage-kit-get (homun-stage-kit--build-key node)))
          (p (homun-stage-kit--count (homun-stage-kit--state inst :pass) (or (plist-get d :pass) 0) snap))
          (f (homun-stage-kit--count (homun-stage-kit--state inst :fail) (or (plist-get d :fail) 0) snap))
          (pass (homun-stage-kit--set inst :pass (car p))) (fail (homun-stage-kit--set inst :fail (car f))))
     (cons (list (homun-stage-kit--target
                  (homun-stage-kit--fit
                   (concat (propertize "tests " 'face 'shadow)
                           (propertize (format "✓ %-4d" pass) 'face 'success) " "
                           (propertize (format "✗ %-4d" fail) 'face (if (> fail 0) 'error 'shadow))
                           (propertize (cond ((null d) " no build") ((plist-get d :live) " running")
                                             (t " done"))
                                       'face 'shadow))
                   w)
                  (homun-stage-kit--build-target d)
                  (and d (if (plist-get d :first) "RET: the first failure" "RET: the build"))))
           (or (cdr p) (cdr f))))))

;;; files

(defun homun-stage-kit--status-source (node key)
  "Run git status in the node's dir; store ((PATH CODE MTIME) ...)."
  (let ((dir (file-name-as-directory (expand-file-name (alist-get 'dir node)))))
    (when (file-directory-p dir)
      (homun-proc-async
       (format "stage-kit status %s" dir) "git" (list "-C" dir "status" "--porcelain=v1" "-uall")
       (lambda (status out)
         (when (eq status 0)
           (homun-stage-kit-put
            key
            (cl-loop for line in (split-string out "\n" t)
                     for raw = (substring line 3)
                     for path = (if (string-match " -> \\(.*\\)" raw) (match-string 1 raw) raw)
                     for attrs = (file-attributes (expand-file-name path dir))
                     collect (list path (string-trim (substring line 0 2))
                                   (if attrs (float-time (file-attribute-modification-time attrs)) 0))))))))))

(defun homun-stage-kit--heat (age)
  (cond ((< age 1.5) 'homun-stage-kit-hot) ((< age 5) 'homun-stage-kit-warm) ((< age 20) 'success) (t 'default)))

(homun-stage-kit-define
 "files" '(dir)
 (lambda (node) (list (list (list "status" (alist-get 'dir node)) #'homun-stage-kit--status-source 3)))
 (lambda (inst now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (dir (file-name-as-directory (expand-file-name (alist-get 'dir node))))
          (cols (or (alist-get 'cols node) 3)) (max (or (alist-get 'max node) 9))
          (cw (/ (- w 1) cols))
          (all (homun-stage-kit-get (list "status" (alist-get 'dir node))))
          (files (sort (seq-take (sort (copy-sequence all) (lambda (a b) (> (nth 2 a) (nth 2 b)))) max)
                       (lambda (a b) (string< (car a) (car b)))))
          (moving nil)
          (cells (cl-loop for (path code mtime) in files
                          for age = (- now mtime)
                          do (when (< age 20) (setq moving t))
                          collect (homun-stage-kit--target
                                   (propertize (homun-stage-kit--fit
                                                (format "%s %s" (pcase code ("D" "-") ((or "A" "??") "+") (_ "•"))
                                                        (file-name-nondirectory path))
                                                (1- cw))
                                               'face (homun-stage-kit--heat age))
                                   (list 'file (expand-file-name path dir))))))
     (cons (cons (homun-stage-kit--fit
                  (propertize (format "files  %d changed in %s" (length all)
                                      (file-name-nondirectory (directory-file-name dir)))
                              'face 'shadow)
                  w)
                 (cl-loop for r below (ceiling max cols)
                          collect (homun-stage-kit--fit
                                   (concat " " (mapconcat (lambda (c) (concat (or c (make-string (1- cw) ?\s)) " "))
                                                          (cl-loop for i below cols collect (nth (+ (* r cols) i) cells))
                                                          ""))
                                   w)))
           moving))))

;;; commits

(defun homun-stage-kit--commits-source (node key)
  "Store (:base HEAD-OF-BASE :commits ((SHA SUBJECT) ...) oldest first); a moved
base is a merge."
  (let ((dir (expand-file-name (alist-get 'dir node))) (base (or (alist-get 'base node) "main"))
        (max (or (alist-get 'max node) 16)))
    (when (file-directory-p dir)
      (homun-proc-async
       (format "stage-kit commits %s" dir) "git"
       (list "-C" dir "log" "--format=%h%x09%s" "-n" (number-to-string max) (concat base "..HEAD"))
       (lambda (status out)
         (when (eq status 0)
           (homun-proc-async
            (format "stage-kit base %s" dir) "git" (list "-C" dir "rev-parse" "--short" base)
            (lambda (_ head)
              (let* ((head (string-trim head)) (old (homun-stage-kit-get key)))
                (when (and old (plist-get old :base) (not (equal head (plist-get old :base))))
                  (homun-stage-kit-event 'merge :dir dir :base base :head head))
                (homun-stage-kit-put
                 key (list :base head
                           :commits (nreverse (mapcar (lambda (l) (split-string l "\t"))
                                                      (split-string out "\n" t))))))))))))))

(homun-stage-kit-define
 "commits" '(dir)
 (lambda (node) (list (list (list "commits" (alist-get 'dir node) (alist-get 'base node))
                            #'homun-stage-kit--commits-source 5)))
 (lambda (inst now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (dir (expand-file-name (alist-get 'dir node))) (base (or (alist-get 'base node) "main"))
          (d (homun-stage-kit-get (list "commits" (alist-get 'dir node) (alist-get 'base node))))
          (commits (plist-get d :commits))
          (born (or (homun-stage-kit--state inst :born) (homun-stage-kit--set inst :born (make-hash-table :test #'equal))))
          (first (not (homun-stage-kit--state inst :seen)))
          (fit (max 1 (/ (- w (length base) 12) 2)))
          (shown (last commits fit)) (moving nil))
     (when d (homun-stage-kit--set inst :seen t))
     (cons (list (homun-stage-kit--fit
                  (concat (propertize (concat base " ") 'face 'shadow)
                          (mapconcat
                           (lambda (c)
                             (let* ((at (or (gethash (car c) born) (puthash (car c) (if first 0 now) born)))
                                    (age (- now at)) (head (eq c (car (last commits)))))
                               (when (< age 0.4) (setq moving t))
                               (concat (propertize "─" 'face 'shadow)
                                       (homun-stage-kit--target
                                        (propertize (cond ((< age 0.1) "·") ((< age 0.2) "∘") ((< age 0.3) "○")
                                                          (head "◉") (t "●"))
                                                    'face (if head 'font-lock-keyword-face 'success))
                                        (list 'commit dir (car c)) (concat (car c) " " (cadr c))))))
                           shown "")
                          (propertize (format "  %d" (length commits)) 'face 'shadow))
                  w)
                 (let ((c (car (last commits))))
                   (homun-stage-kit--target
                    (propertize (homun-stage-kit--fit (if c (concat "  " (car c) " " (cadr c)) "  no commits yet") w)
                                'face 'shadow)
                    (and c (list 'commit dir (car c))))))
           moving))))

;;; budget

(defun homun-stage-kit--budget-source (node key)
  (let* ((row (and (require 'claude-agent nil t)
                   (ignore-errors (claude-agent--select "select five_hour_used from samples where five_hour_used is not null order by ts desc limit 1"))))
         (v (caar row)) (low (or (alist-get 'low node) 80)) (old (homun-stage-kit-get key)))
    (when (and (numberp v) (>= v low) (or (not (numberp old)) (< old low)))
      (homun-stage-kit-event 'budget-low :used v))
    (homun-stage-kit-put key v)))

(homun-stage-kit-define
 "budget" nil
 (lambda (_node) (list (list (list "budget") #'homun-stage-kit--budget-source 30)))
 (lambda (inst _now snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (v (homun-stage-kit-get (list "budget"))) (low (or (alist-get 'low node) 80))
          (c (homun-stage-kit--chase (homun-stage-kit--state inst :v) (/ (if (numberp v) v 0) 100.0) snap))
          (f (homun-stage-kit--set inst :v (car c)))
          (label (or (alist-get 'label node) "5h budget"))
          (cells (max 4 (- w (length label) 8))))
     (cons (list (homun-stage-kit--target
                  (homun-stage-kit--fit
                   (concat (propertize (concat label " ") 'face 'shadow)
                           (propertize (homun-stage-kit--bar f cells)
                                       'face (cond ((>= (* 100 f) (+ low 10)) 'error) ((>= (* 100 f) low) 'warning) (t 'success)))
                           (if (numberp v) (format " %3d%%" (round (* 100 f))) "    …"))
                   w)
                  (list 'url homun-stage-kit-usage-url) "RET: the usage charts"))
           (cdr c)))))

;;; Build events

(defun homun-stage-kit--build-finished (buf msg)
  "Hook of `compilation-finish-functions': a build-pass or build-fail event."
  (homun-stage-kit-event (if (string-prefix-p "finished" msg) 'build-pass 'build-fail)
                         :buffer (buffer-name buf)
                         :dir (expand-file-name (buffer-local-value 'default-directory buf))))

(add-hook 'compilation-finish-functions #'homun-stage-kit--build-finished)

;;; The scene "agents at work"

(defvar homun-stage-kit-agents-id "agents" "The scene id of agents at work.")
(defvar homun-stage-kit--agents-timer nil)
(defvar homun-stage-kit--agents nil "The running agents last seen: (ID DESC START DIR).")
(defvar homun-stage-kit--builds nil "Alist of dir to the last build event (EVENT TIME).")
(defvar homun-stage-kit--banner nil "(TEXT FACE) of the newest merge or budget event.")
(defvar homun-stage-kit--dirs (make-hash-table :test #'equal) "Transcript to (SIZE . DIR).")

(defun homun-stage-kit-agent-dir (transcript)
  "The worktree the agent of TRANSCRIPT works in: the git directory under ~/claude
its tail names most."
  (when-let* ((attrs (and transcript (file-attributes transcript))))
    (let ((size (file-attribute-size attrs)) (hit (gethash transcript homun-stage-kit--dirs)))
      (if (eql (car hit) size) (cdr hit)
        (let ((root (expand-file-name "~/claude/")) (counts nil))
          (with-temp-buffer
            (insert-file-contents transcript nil (max 0 (- size 65536)))
            (while (re-search-forward (concat (regexp-quote root) "\\([a-z0-9_][a-z0-9_-]*/[A-Za-z0-9_.-]+\\)") nil t)
              (cl-incf (alist-get (match-string 1) counts 0 nil #'equal))))
          (let ((dir (cl-loop for (d . _) in (sort counts (lambda (a b) (> (cdr a) (cdr b))))
                              for full = (concat root d)
                              when (file-exists-p (expand-file-name ".git" full)) return full)))
            (puthash transcript (cons size dir) homun-stage-kit--dirs)
            dir))))))

(defun homun-stage-kit--running ()
  "(ID DESC START DIR) of each running agent of the links store."
  (when (require 'claude-links nil t)
    (let (out)
      (maphash (lambda (id row)
                 (when (equal (alist-get 'status row) "running")
                   (push (list id (or (alist-get 'desc row) id) (alist-get 'start row)
                               (homun-stage-kit-agent-dir (alist-get 'transcript row)))
                         out)))
               (claude-links-rows))
      (sort out (lambda (a b) (< (or (nth 2 a) 0) (or (nth 2 b) 0)))))))

(defun homun-stage-kit-agent-parts (id desc start dir)
  "The parts of one agent: its ring, then, with a worktree DIR, tests, log, files
and commits."
  (let ((p (lambda (type &rest fields) `((type . ,type) (id . ,(format "%s-%s" id type)) ,@fields)))
        (build (assoc dir homun-stage-kit--builds)))
    (append
     (list (funcall p "ring" `(label . ,(concat desc (pcase (cadr build) ('build-fail "  ✗ build failed")
                                                                          ('build-pass "  ✓ build passed") (_ ""))))
                    `(agent . ,id) `(start . ,start) '(span . 1800)))
     (if (null dir) (list `((type . "text") (text . "  worktree not known yet") (face . "dim")))
       (list (funcall p "tests" `(compile . ,dir))
             (funcall p "log" `(compile . ,dir) '(lines . 3))
             (funcall p "files" `(dir . ,dir))
             (funcall p "commits" `(dir . ,dir)))))))

(defun homun-stage-kit-agents-spec (agents)
  "The scene of AGENTS, each (ID DESC START DIR)."
  `((type . "col")
    (children
     ((type . "text") (text . ,(format "Agents at work · %d" (length agents))) (face . "title"))
     ((type . "budget") (id . "budget"))
     ,@(when homun-stage-kit--banner
         (list `((type . "text") (text . ,(car homun-stage-kit--banner)) (face . ,(cadr homun-stage-kit--banner)))))
     ,@(if agents (cl-loop for a in agents append (apply #'homun-stage-kit-agent-parts a))
         (list '((type . "text") (text . "No agent is running.") (face . "dim")))))))

(defun homun-stage-kit--agents-on-event (event plist)
  "Scene change on EVENT: note it and show the scene again (never from a tick)."
  (pcase event
    ((or 'build-pass 'build-fail)
     (setf (alist-get (directory-file-name (plist-get plist :dir)) homun-stage-kit--builds nil nil #'equal)
           (list event (float-time))))
    ('merge (setq homun-stage-kit--banner (list (format "⇢ merged into %s: %s" (plist-get plist :base)
                                                        (plist-get plist :head))
                                                "ok")))
    ('budget-low (setq homun-stage-kit--banner (list (format "▲ budget low: %d%% of 5h used" (plist-get plist :used))
                                                     "warn"))))
  (when (gethash homun-stage-kit-agents-id homun-stage-scenes)
    (homun-stage-kit--agents-show-now)))

(add-hook 'homun-stage-kit-event-functions #'homun-stage-kit--agents-on-event)

(defun homun-stage-kit--agents-show-now ()
  (homun-stage-show "manager" homun-stage-kit-agents-id "Agents at work"
                    (homun-stage-kit-agents-spec homun-stage-kit--agents) "pinned"))

(defun homun-stage-kit--agents-poll ()
  "Agent start and finish events from the links store; stop with the scene."
  (if (not (gethash homun-stage-kit-agents-id homun-stage-scenes))
      (progn (cancel-timer homun-stage-kit--agents-timer) (setq homun-stage-kit--agents-timer nil))
    (let* ((new (homun-stage-kit--running)) (old homun-stage-kit--agents))
      (unless (equal new old)
        (setq homun-stage-kit--agents new)
        (dolist (a new) (unless (assoc (car a) old) (homun-stage-kit-event 'agent-start :agent (car a))))
        (dolist (a old) (unless (assoc (car a) new) (homun-stage-kit-event 'agent-finish :agent (car a))))
        ;; A worktree found later changes the scene without an event of its own
        (homun-stage-kit--agents-show-now)))))

(defun homun-stage-kit-agents-show ()
  "Show the scene \"agents at work\" and keep it in line with the running agents."
  (interactive)
  (setq homun-stage-kit--agents (homun-stage-kit--running))
  (homun-stage-kit--agents-show-now)
  (unless homun-stage-kit--agents-timer
    (setq homun-stage-kit--agents-timer (run-with-timer 2 2 #'homun-stage-kit--agents-poll)))
  (unless noninteractive (homun-stage-display homun-stage-kit-agents-id)))

(provide 'homun-stage-kit)
;;; homun-stage-kit.el ends here
