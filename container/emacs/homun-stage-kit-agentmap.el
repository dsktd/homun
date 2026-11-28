;;; homun-stage-kit-agentmap.el --- Stage kit part: agents at work on a map of repos -*- lexical-binding: t -*-

;; The part "agentmap" is a gource-like picture of the event stream the agentviz service
;; appends to ~/claude/.services/agentviz/events.jsonl, one JSON object per line:
;;
;;   {"t", "agent", "label", "model", "kind", "path", "repo", "ok"}
;;
;; kind is read edit write bash search build test start finish.  Repos are clusters, files
;; are dots that fade with the age of their last touch, an agent is a coloured circle with
;; its label near the file of its latest event and a short trail, a build or test flashes
;; green or red on `ok', start and finish make an agent appear or fade out.
;;
;; Fields besides "id", "width" (72) and "label": "file" (the stream), "rows" (16) text
;; rows tall.  Only the bytes past the last offset are read, on the kit's
;; poll; the picture is rebuilt only when events arrived, at most every
;; `homun-stage-kit-agentmap-min-interval' seconds, and the slices are kept otherwise.  Ages
;; are measured against the newest event, so a quiet stream keeps its picture.  A click on an
;; agent opens its run detail, a click on a file opens it.  A tty gets one line per agent.
;;
;; `M-x homun-stage-agentmap-show' shows the scene.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'json)
(require 'homun-stage)
(require 'homun-stage-kit)
(require 'homun-stage-kit-parts)

(defvar homun-stage-kit-agentmap-file (expand-file-name "~/claude/.services/agentviz/events.jsonl")
  "The event stream the map reads.")
(defvar homun-stage-kit-agentmap-min-interval 0.25 "Seconds between two rebuilds of the picture.")
(defvar homun-stage-kit-agentmap-fade 120.0 "Seconds after which a touched file is gone.")
(defvar homun-stage-kit-agentmap-flash 4.0 "Seconds a build or test flash lasts.")
(defvar homun-stage-kit-agentmap-linger 30.0 "Seconds a finished agent stays, fading.")
(defvar homun-stage-kit-agentmap-builds 0 "Rebuilds of the picture, for tests and the frame bench.")

(defconst homun-stage-kit-agentmap--agent-faces
  '(font-lock-keyword-face font-lock-string-face font-lock-function-name-face font-lock-type-face
    font-lock-constant-face font-lock-variable-name-face font-lock-builtin-face)
  "Faces whose foreground colours the agents, so the theme decides.")

;;; Model

(cl-defstruct (homun-stage-kit-agentmap--m (:constructor homun-stage-kit-agentmap--m-make) (:copier nil))
  (offset 0) (rev 0) (now 0.0) (bad 0) (files (make-hash-table :test #'equal))
  (repos nil) (agents (make-hash-table :test #'equal)) (flashes nil) (seen 0))

(defun homun-stage-kit-agentmap--num (x) (if (numberp x) (float x) 0.0))

(defun homun-stage-kit-agentmap--apply (m ev)
  "Fold the event alist EV into the model M."
  (let* ((t0 (homun-stage-kit-agentmap--num (alist-get 't ev))) (agent (alist-get 'agent ev))
         (kind (alist-get 'kind ev)) (path (alist-get 'path ev)) (repo (or (alist-get 'repo ev) ""))
         (ok (not (memq (alist-get 'ok ev) '(:false nil)))) (a (and agent (gethash agent (homun-stage-kit-agentmap--m-agents m)))))
    (setf (homun-stage-kit-agentmap--m-now m) (max t0 (homun-stage-kit-agentmap--m-now m)))
    (cl-incf (homun-stage-kit-agentmap--m-seen m))
    (unless (member repo (homun-stage-kit-agentmap--m-repos m))
      (setf (homun-stage-kit-agentmap--m-repos m) (append (homun-stage-kit-agentmap--m-repos m) (list repo))))
    (when (and (stringp path) (not (equal kind "finish")))
      (let ((f (gethash path (homun-stage-kit-agentmap--m-files m))))
        (puthash path (list repo t0 (or (nth 2 f) (hash-table-count (homun-stage-kit-agentmap--m-files m)))) (homun-stage-kit-agentmap--m-files m))))
    (when agent
      (unless a (setq a (list :id agent)))
      (setq a (plist-put a :label (or (alist-get 'label ev) (plist-get a :label) agent)))
      (setq a (plist-put a :model (or (alist-get 'model ev) (plist-get a :model))))
      (setq a (plist-put a :t t0))
      (setq a (plist-put a :kind kind))
      (setq a (plist-put a :ended (and (equal kind "finish") t0)))
      (when (stringp path)
        (setq a (plist-put a :trail (seq-take (cons (cons repo path) (seq-remove (lambda (p) (equal p (cons repo path))) (plist-get a :trail))) 4))))
      (puthash agent a (homun-stage-kit-agentmap--m-agents m)))
    (when (member kind '("build" "test"))
      (push (list t0 repo path ok) (homun-stage-kit-agentmap--m-flashes m))
      (setf (homun-stage-kit-agentmap--m-flashes m) (seq-take (homun-stage-kit-agentmap--m-flashes m) 12)))))

(defun homun-stage-kit-agentmap--read (m file)
  "Read the lines appended to FILE since the offset of M into M.
Non-nil when any came."
  (let* ((size (file-attribute-size (file-attributes file))) (got nil))
    (when (< size (homun-stage-kit-agentmap--m-offset m))
      (clrhash (homun-stage-kit-agentmap--m-files m)) (clrhash (homun-stage-kit-agentmap--m-agents m))
      (setf (homun-stage-kit-agentmap--m-repos m) nil (homun-stage-kit-agentmap--m-flashes m) nil
            (homun-stage-kit-agentmap--m-offset m) 0 got t))
    (when (> size (homun-stage-kit-agentmap--m-offset m))
      (let ((chunk (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally file nil (homun-stage-kit-agentmap--m-offset m) size)
                     (buffer-string))))
        ;; Only whole lines: the writer may be half way through one
        (when-let* ((nl (cl-position ?\n chunk :from-end t)))
          (cl-incf (homun-stage-kit-agentmap--m-offset m) (1+ nl))
          (dolist (l (split-string (decode-coding-string (substring chunk 0 nl) 'utf-8) "\n" t))
            (condition-case nil
                (homun-stage-kit-agentmap--apply m (json-parse-string l :object-type 'alist :null-object nil :false-object :false))
              (error (cl-incf (homun-stage-kit-agentmap--m-bad m))))
            (setq got t)))))
    got))

(defvar homun-stage-kit-agentmap--last-build (make-hash-table :test #'equal) "Source key to when its picture was last built.")

(defun homun-stage-kit-agentmap--source (node key)
  "Store the model of NODE's stream; a new revision when events arrived."
  (let* ((file (expand-file-name (or (alist-get 'file node) homun-stage-kit-agentmap-file)))
         (old (homun-stage-kit-get key)) (m (or (plist-get old :m) (homun-stage-kit-agentmap--m-make))))
    (cond ((not (file-readable-p file))
           (homun-stage-kit-put key (list :m m :rev (plist-get old :rev) :error "no event stream yet")))
          ((homun-stage-kit-agentmap--read m file)
           (homun-stage-kit-put key (list :m m :rev (1+ (or (plist-get old :rev) 0)))))
          ((plist-get old :error) (homun-stage-kit-put key (list :m m :rev (plist-get old :rev)))))))

;;; Picture

(defun homun-stage-kit-agentmap--pos (m repo path w h)
  "(X . Y) of PATH in REPO's cluster, or of the cluster's centre without a path."
  (let* ((repos (homun-stage-kit-agentmap--m-repos m)) (n (max 1 (length repos)))
         (i (or (cl-position repo repos :test #'equal) 0))
         (cols (ceiling (sqrt n))) (rws (ceiling n (float cols)))
         (cx (* w (/ (+ (mod i cols) 0.5) cols))) (cy (* h (/ (+ (/ i cols) 0.5) rws)))
         (f (and path (gethash path (homun-stage-kit-agentmap--m-files m)))))
    (if (null f) (cons cx cy)
      (let* ((k (nth 2 f)) (a (* k 2.399963)) (r (* 9.0 (sqrt (1+ (mod k 40)))))
             (r (min r (* 0.42 (min (/ w cols) (/ h rws))))))
        (cons (+ cx (* r (cos a))) (+ cy (* r (sin a))))))))

(defun homun-stage-kit-agentmap--agent-color (id)
  (let ((c (face-attribute (nth (mod (sxhash-equal id) (length homun-stage-kit-agentmap--agent-faces))
                                homun-stage-kit-agentmap--agent-faces)
                           :foreground nil t)))
    (if (stringp c) c (homun-stage-kit--svg-face 'default :foreground))))

(defun homun-stage-kit-agentmap--items (m w h)
  "The things of M in a W by H box: ((KIND ID X Y DATA) ...), agents last."
  (let ((now (homun-stage-kit-agentmap--m-now m)) out)
    (maphash (lambda (path f)
               (when (< (- now (nth 1 f)) homun-stage-kit-agentmap-fade)
                 (let ((p (homun-stage-kit-agentmap--pos m (car f) path w h))) (push (list 'file path (car p) (cdr p) (car f)) out))))
             (homun-stage-kit-agentmap--m-files m))
    (maphash (lambda (id a)
               (let ((end (plist-get a :ended)))
                 (unless (and end (> (- now end) homun-stage-kit-agentmap-linger))
                   (let* ((tr (car (plist-get a :trail))) (p (homun-stage-kit-agentmap--pos m (car tr) (cdr tr) w h)))
                     (push (list 'agent id (car p) (cdr p) a) out)))))
             (homun-stage-kit-agentmap--m-agents m))
    (nreverse out)))

(defun homun-stage-kit-agentmap--svg (m w h)
  "The picture of the model M, W by H pixels, in the theme's colours."
  (cl-incf homun-stage-kit-agentmap-builds)
  (let* ((svg (svg-create w h)) (now (homun-stage-kit-agentmap--m-now m))
         (fg (homun-stage-kit--svg-face 'default :foreground)) (shade (homun-stage-kit--svg-face 'shadow :foreground))
         (ok (homun-stage-kit--svg-face 'success :foreground)) (bad (homun-stage-kit--svg-face 'error :foreground))
         (repos (homun-stage-kit-agentmap--m-repos m)))
    (cl-loop for r in repos
             for p = (homun-stage-kit-agentmap--pos m r nil w h)
             do (svg-circle svg (car p) (cdr p) (* 0.2 (min w h)) :fill "none" :stroke-color shade :stroke-width 0.5 :stroke-opacity 0.4)
             (svg-text svg (if (equal r "") "?" (file-name-nondirectory (directory-file-name r)))
                       :x (car p) :y (- (cdr p) (* 0.2 (min w h)) 3) :text-anchor "middle" :fill shade :font-size 10))
    (dolist (it (homun-stage-kit-agentmap--items m w h))
      (when (eq (car it) 'file)
        (let ((age (- now (nth 1 (gethash (nth 1 it) (homun-stage-kit-agentmap--m-files m))))))
          (svg-circle svg (nth 2 it) (nth 3 it) 2.5 :fill fg :opacity (max 0.08 (- 1.0 (/ age homun-stage-kit-agentmap-fade)))))))
    (dolist (f (homun-stage-kit-agentmap--m-flashes m))
      (pcase-let ((`(,t0 ,repo ,path ,good) f))
        (when (< (- now t0) homun-stage-kit-agentmap-flash)
          (let ((p (homun-stage-kit-agentmap--pos m repo path w h)) (k (- 1.0 (/ (- now t0) homun-stage-kit-agentmap-flash))))
            (svg-circle svg (car p) (cdr p) (+ 6 (* 18 (- 1.0 k))) :fill "none" :stroke-color (if good ok bad)
                        :stroke-width 2.5 :stroke-opacity k)))))
    (dolist (it (homun-stage-kit-agentmap--items m w h))
      (when (eq (car it) 'agent)
        (let* ((a (nth 4 it)) (end (plist-get a :ended)) (col (homun-stage-kit-agentmap--agent-color (nth 1 it)))
               (op (if end (max 0.1 (- 1.0 (/ (- now end) homun-stage-kit-agentmap-linger))) 1.0))
               (prev (list (cons (nth 2 it) (nth 3 it)))))
          (dolist (tr (cdr (plist-get a :trail)))
            (push (homun-stage-kit-agentmap--pos m (car tr) (cdr tr) w h) prev))
          (cl-loop for (p q) on (nreverse prev) while q
                   do (svg-line svg (car p) (cdr p) (car q) (cdr q) :stroke-color col :stroke-width 1.5 :stroke-opacity (* 0.5 op)))
          (svg-circle svg (nth 2 it) (nth 3 it) 6 :fill col :opacity op :stroke-color fg :stroke-width 1)
          (svg-text svg (or (plist-get a :label) (nth 1 it)) :x (+ (nth 2 it) 9) :y (+ (nth 3 it) 4) :fill fg :font-size 11 :opacity op))))
    svg))

(defun homun-stage-kit-agentmap--targets (m w h rows)
  "A vector of ROWS click targets: per text row the agent, else the file."
  (let ((v (make-vector rows nil)) (ch (max 1 (frame-char-height))))
    (dolist (it (homun-stage-kit-agentmap--items m w h))
      (let ((r (min (1- rows) (max 0 (floor (nth 3 it) ch)))))
        (when (or (null (aref v r)) (eq (car it) 'agent))
          (aset v r (if (eq (car it) 'agent)
                        (list 'agent (nth 1 it))
                      (list 'file (let ((p (nth 1 it)) (repo (nth 4 it)))
                                    (if (or (file-name-absolute-p p) (equal repo "")) p (expand-file-name p repo)))))))))
    v))

(defun homun-stage-kit-agentmap--text (m)
  "One line per agent: the text a tty gets."
  (let (out)
    (maphash (lambda (id a)
               (push (format "● %s  %s %s" (or (plist-get a :label) id) (or (plist-get a :kind) "")
                             (or (cdr (car (plist-get a :trail))) ""))
                     out))
             (homun-stage-kit-agentmap--m-agents m))
    (or (nreverse out) (list "no agents yet"))))

(defun homun-stage-kit-agentmap--lines (inst d w rows)
  "The ROWS lines of INST for the data D, rebuilt when its revision moved."
  (let* ((m (plist-get d :m)) (graphic (and (fboundp 'widgetry-graphic-p) (widgetry-graphic-p)))
         (key (list graphic (plist-get d :rev) w rows)) (kept (homun-stage-kit--state inst :lines))
         (stamp (float-time)))
    (cond
     ((or (null m) (plist-get d :error)) (homun-stage-kit--pad (list (propertize (or (plist-get d :error) "waiting for the event stream") 'face 'shadow)) rows w))
     ((and kept (or (equal (homun-stage-kit--state inst :key) key)
                    (< (- stamp (or (homun-stage-kit--state inst :built) 0)) homun-stage-kit-agentmap-min-interval)))
      kept)
     (t
      (homun-stage-kit--set inst :key key)
      (homun-stage-kit--set inst :built stamp)
      (homun-stage-kit--set
       inst :lines
       (if (not graphic)
           (homun-stage-kit--pad (mapcar (lambda (l) (homun-stage-kit--fit l w)) (homun-stage-kit-agentmap--text m)) rows w)
         (let* ((pw (* w (frame-char-width))) (ph (* rows (frame-char-height)))
                (targets (homun-stage-kit-agentmap--targets m pw ph rows)))
           (cl-loop for l in (homun-stage-kit--svg-lines (homun-stage-kit-agentmap--svg m pw ph) rows)
                    for i from 0
                    collect (homun-stage-kit--target l (aref targets i) "RET: open the agent's run or the file")))))))))

(homun-stage-kit-define
 "agentmap" nil
 (lambda (node)
   (let ((f (expand-file-name (or (alist-get 'file node) homun-stage-kit-agentmap-file))))
     (list (list (list "agentmap" f) #'homun-stage-kit-agentmap--source 0.25))))
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (or (alist-get 'width node) 72)) (rows (or (alist-get 'rows node) 16))
          (f (expand-file-name (or (alist-get 'file node) homun-stage-kit-agentmap-file))))
     (cons (homun-stage-kit-agentmap--lines inst (homun-stage-kit-get (list "agentmap" f)) w rows) nil))))

;;;###autoload
(defun homun-stage-agentmap-show ()
  "Show the scene of the agents at work as a map of repos, files and agents."
  (interactive)
  (homun-stage-show "manager" "agentmap" "Agents map"
                    '((type . "agentmap") (id . "map")) "pinned")
  (unless noninteractive (homun-stage-display "agentmap")))

(provide 'homun-stage-kit-agentmap)
;;; homun-stage-kit-agentmap.el ends here
