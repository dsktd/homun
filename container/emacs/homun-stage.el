;;; homun-stage.el --- Stage scenes: model, validator, text and SVG renderers -*- lexical-binding: t -*-

;; A scene is data: a tree of nodes as parsed JSON (alists, lists), each an alist with a `type'
;; of `homun-stage-types' and an optional string `id'.  `homun-stage-validate' refuses a bad
;; tree by signalling `homun-stage-invalid' with the path of the first bad field, so a caller
;; can answer {error, field}.  Values are a literal, {"bind": "topic.path"} (read from
;; `homun-stage-bindings') or {"expr": EXPR} (homun-expr, over the variables of ENV).
;;
;; Every node type has a text render (`homun-stage-text', the one tests compare and the
;; terminal and narrow phone use) and an SVG render (`homun-stage-svg').  `homun-stage-insert'
;; puts a scene in a buffer as blocks: text nodes as buffer text, every other maximal subtree
;; as one SVG image.
;;
;; A stepper may give each step its own state (`states': done now next failed you) and a note
;; (`notes'); with `layout' "line" it is one line of text, its steps joined by arrows.  A text
;; node may name a `face' (title dim ok warn err accent).  In a buffer, widget nodes are live
;; widgetry controls; a press calls the function `homun-stage-actions' holds for the node's id.
;;
;; Presets build the scenes the cockpit itself shows: `homun-stage-steps' (a titled list of
;; steps, the Manager's plan) and `homun-stage-build' (an image build with its buttons).

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'dom)
(require 'json)
(require 'homun-expr)
(require 'homun-clock)

(define-error 'homun-stage-invalid "Invalid scene")

(defconst homun-stage-types
  '(("col" children) ("row" children) ("text" text) ("md" text) ("table" rows)
    ("stepper" steps) ("meter" value) ("widget" kind) ("layer" children) ("graph" nodes)
    ("timeline" events) ("chart" data) ("shape" kind) ("diffview" diff))
  "Each node type with its required fields.")

(defconst homun-stage-text-types '("text" "md" "table" "widget" "meter" "diffview")
  "The node types drawn as buffer text, never as SVG.")

(defvar homun-stage-parts nil
  "Node types added by a library (homun-stage-kit): alist of TYPE to a plist with
:fields (required), :text (NODE ENV -> string) and :insert (NODE ENV, inserts at
point). They are text nodes.")

(defconst homun-stage-part-libraries
  '(homun-stage-kit homun-stage-kit-parts homun-stage-kit-agentmap)
  "The libraries that add node types to `homun-stage-parts'.  Every place that
needs the full set of types (the validator, the cockpit, the phone) loads
them through `homun-stage-load-parts'.")

(defun homun-stage-load-parts ()
  "Load every library of `homun-stage-part-libraries'."
  (dolist (lib homun-stage-part-libraries) (require lib)))

(defun homun-stage--part (type) (cdr (assoc type homun-stage-parts)))

(defconst homun-stage-widget-kinds '("meter" "slider" "toggle" "button" "selector" "chips" "check")
  "The widgetry controls a widget node may embed.")

(defvar homun-stage-bindings (make-hash-table :test #'equal)
  "Topic path to its latest value, for {\"bind\": ...} values.")

(defvar homun-stage-meter-width 20 "Cells of a meter's bar in the text render.")

(defvar homun-stage-actions (make-hash-table :test #'equal)
  "Node id to the function a press of that widget node calls, for the cockpit's own
scenes.")

(defconst homun-stage-step-marks
  '(("done" "✓" homun-stage-done) ("now" "▸" homun-stage-now) ("next" "·" homun-stage-next)
    ("failed" "✗" homun-stage-failed) ("you" "🔺" homun-stage-you))
  "Each step state with its mark and face.")

(defface homun-stage-done '((t :inherit shadow)) "A done step." :group 'homun-layout)
(defface homun-stage-now '((t :inherit (bold highlight))) "The step in progress." :group 'homun-layout)
(defface homun-stage-next '((t :inherit default)) "A step still to do." :group 'homun-layout)
(defface homun-stage-failed '((t :inherit error)) "A failed step." :group 'homun-layout)
(defface homun-stage-you '((t :inherit (bold warning))) "A step waiting for the user." :group 'homun-layout)
(defface homun-stage-title '((t :inherit bold :height 1.1)) "A text node with face title." :group 'homun-layout)

(defconst homun-stage-faces
  '(("title" . homun-stage-title) ("dim" . shadow) ("ok" . success) ("warn" . warning)
    ("err" . error) ("accent" . font-lock-keyword-face) ("now" . homun-stage-now))
  "The faces a text node may name.")

;;; Validation

(defconst homun-stage-chart-kinds '("line" "bar" "spark" "hist") "The kinds of a chart node.")
(defconst homun-stage-shape-kinds '("circle" "rect" "line" "polygon" "path" "text" "arrow")
  "The kinds of a shape node.")

(defun homun-stage--invalid (field fmt &rest args)
  (signal 'homun-stage-invalid (list field (apply #'format fmt args))))

(defun homun-stage--check-value (v field)
  (when (consp v)
    (cond ((and (consp (car v)) (eq (caar v) 'bind))
           (unless (stringp (cdar v)) (homun-stage--invalid field "bind is not a string")))
          ((and (consp (car v)) (eq (caar v) 'expr))
           (when-let* ((why (homun-expr-check (cdar v)))) (homun-stage--invalid field "expr: %s" why))))))

(defun homun-stage--check-vals (v field)
  "Refuse V unless it is a list of values, or one bind or expr that gives a list."
  (cond ((null v))
        ((and (consp v) (consp (car v)) (memq (caar v) '(bind expr)))
         (homun-stage--check-value v field))
        ((and (listp v) (not (consp (car v))))
         (cl-loop for x in v for i from 0 do (homun-stage--check-value x (format "%s/%d" field i))))
        ((and (listp v) (cl-every (lambda (x) (or (atom x) (memq (car-safe (car-safe x)) '(bind expr)))) v))
         (cl-loop for x in v for i from 0 do (homun-stage--check-value x (format "%s/%d" field i))))
        (t (homun-stage--invalid field "not a list of values"))))

(defun homun-stage--check-graph (node path)
  "Refuse the graph NODE at PATH unless its nodes have ids and its edges join them."
  (let ((ids (mapcar (lambda (n) (and (consp n) (alist-get 'id n))) (alist-get 'nodes node))))
    (unless (and ids (cl-every #'stringp ids))
      (homun-stage--invalid (concat path "/nodes") "a list of nodes with an id each"))
    (unless (member (or (alist-get 'layout node) "layered") '("layered"))
      (homun-stage--invalid (concat path "/layout") "layered"))
    (cl-loop for e in (alist-get 'edges node) for i from 0
             do (unless (and (consp e) (= (length e) 2) (member (car e) ids) (member (cadr e) ids))
                  (homun-stage--invalid (format "%s/edges/%d" path i) "not a pair of node ids")))))

(defun homun-stage-validate (node)
  "Return NODE when it is a valid scene tree, else signal
`homun-stage-invalid' (FIELD MESSAGE)."
  (homun-stage-load-parts)
  (let ((ids (make-hash-table :test #'equal)))
    (cl-labels
        ((walk (node path)
           (unless (and (consp node) (consp (car node)))
             (homun-stage--invalid path "not an object"))
           (let* ((type (alist-get 'type node)) (spec (or (assoc type homun-stage-types)
                                                                  (when-let* ((p (homun-stage--part type)))
                                                                    (cons type (plist-get p :fields))))))
             (unless spec (homun-stage--invalid (concat path "/type") "unknown type %S" type))
             (when-let* ((id (alist-get 'id node)))
               (unless (stringp id) (homun-stage--invalid (concat path "/id") "not a string"))
               (when (gethash id ids) (homun-stage--invalid (concat path "/id") "duplicate id %s" id))
               (puthash id t ids))
             (dolist (field (cdr spec))
               (unless (assq field node)
                 (homun-stage--invalid (format "%s/%s" path field) "missing")))
             (dolist (field '(value label current text))
               (homun-stage--check-value (alist-get field node) (format "%s/%s" path field)))
             (dolist (var (alist-get 'vars node))
               (homun-stage--check-value (cdr var) (format "%s/vars/%s" path (car var))))
             (pcase type
               ((or "col" "row")
                (unless (listp (alist-get 'children node))
                  (homun-stage--invalid (concat path "/children") "not a list"))
                (cl-loop for c in (alist-get 'children node) for i from 0
                         do (walk c (format "%s/children/%d" path i))))
               ("stepper"
                (unless (and (consp (alist-get 'steps node)) (cl-every #'stringp (alist-get 'steps node)))
                  (homun-stage--invalid (concat path "/steps") "not a list of strings"))
                (when-let* ((states (alist-get 'states node)))
                  (unless (and (= (length states) (length (alist-get 'steps node)))
                               (cl-every (lambda (x) (assoc x homun-stage-step-marks)) states))
                    (homun-stage--invalid (concat path "/states") "one of done now next failed you per step"))))
               ((or "text" "md")
                (when-let* ((face (alist-get 'face node)))
                  (unless (assoc face homun-stage-faces)
                    (homun-stage--invalid (concat path "/face") "unknown face %S" face))))
               ("diffview"
                (unless (stringp (alist-get 'diff node))
                  (homun-stage--invalid (concat path "/diff") "not a string")))
               ("table"
                (unless (cl-every #'listp (alist-get 'rows node))
                  (homun-stage--invalid (concat path "/rows") "not a list of rows")))
               ("layer"
                (unless (listp (alist-get 'children node))
                  (homun-stage--invalid (concat path "/children") "not a list"))
                (cl-loop for c in (alist-get 'children node) for i from 0
                         do (walk c (format "%s/children/%d" path i))))
               ("graph" (homun-stage--check-graph node path))
               ("timeline"
                (unless (cl-every (lambda (e) (and (consp e) (assq 'at e) (assq 'label e)))
                                  (alist-get 'events node))
                  (homun-stage--invalid (concat path "/events") "each event needs at and label")))
               ("chart"
                (unless (member (alist-get 'kind node) homun-stage-chart-kinds)
                  (homun-stage--invalid (concat path "/kind") "one of line bar spark hist"))
                (homun-stage--check-vals (alist-get 'data node) (concat path "/data")))
               ("shape"
                (unless (member (alist-get 'kind node) homun-stage-shape-kinds)
                  (homun-stage--invalid (concat path "/kind") "unknown shape %S" (alist-get 'kind node)))
                (dolist (f '(x y r w h x2 y2 size opacity))
                  (homun-stage--check-value (alist-get f node) (format "%s/%s" path f))))
               ("widget"
                (unless (member (alist-get 'kind node) homun-stage-widget-kinds)
                  (homun-stage--invalid (concat path "/kind") "unknown widget %S" (alist-get 'kind node)))))
             node)))
      (walk node ""))))

;;; Values

(defun homun-stage-value (v &optional env)
  "The value of V: a literal, a binding (nil while unpublished) or an expression
over ENV."
  (pcase v
    (`((bind . ,topic)) (gethash topic homun-stage-bindings))
    (`((expr . ,x)) (homun-expr-eval x env))
    (_ v)))

(defun homun-stage--str (v)
  (cond ((null v) "…") ((eq v t) "on") ((eq v :false) "off") ((stringp v) v) ((floatp v) (format "%g" v)) (t (format "%s" v))))

(defun homun-stage--fraction (node env)
  (let ((v (homun-stage-value (alist-get 'value node) env))
        (lo (or (alist-get 'min node) 0)) (hi (or (alist-get 'max node) 1)))
    (and (numberp v) (max 0.0 (min 1.0 (if (= hi lo) 0.0 (/ (- v lo) (float (- hi lo)))))))))

(defun homun-stage--states (node env)
  "The state of each step of the stepper NODE: its `states', else from `current'."
  (or (alist-get 'states node)
      (let ((cur (homun-stage--current node env)))
        (cl-loop for _ in (alist-get 'steps node) for i from 0
                 collect (cond ((< i cur) "done") ((= i cur) "now") (t "next"))))))

(defun homun-stage--stepper-text (node env)
  "The stepper NODE as text, each step with the mark and face of its state."
  (let* ((line (equal (alist-get 'layout node) "line"))
         (notes (alist-get 'notes node))
         (parts (cl-loop for s in (alist-get 'steps node)
                         for state in (homun-stage--states node env) for i from 0
                         collect (pcase-let ((`(,_ ,mark ,face) (or (assoc state homun-stage-step-marks)
                                                                    (assoc "next" homun-stage-step-marks))))
                                   (concat (propertize (concat mark " " s) 'face face)
                                           (when-let* ((n (and (not line) (nth i notes)))
                                                       ((stringp n)) ((not (string-empty-p n))))
                                             (propertize (concat "\n    " n) 'face 'shadow)))))))
    (string-join parts (if line (propertize "  →  " 'face 'shadow) "\n"))))

(defun homun-stage--current (node env)
  "The index of NODE's current step: the value of `current', a number or a step
name."
  (let ((c (homun-stage-value (alist-get 'current node) env)))
    (if (stringp c) (or (cl-position c (alist-get 'steps node) :test #'equal) 0) (or c 0))))

;;; Environment

(defvar homun-stage--t0 (float-time) "When the Stage started: `t' of an expression counts from it.")

(defun homun-stage-env (&optional extra w h)
  "The expression environment: EXTRA, then t dt i n w h unless EXTRA gives them."
  (let ((env (copy-sequence extra)))
    (dolist (d `(("t" . ,(- (funcall homun-clock-time-function) homun-stage--t0))
                 ("dt" . 0.0) ("i" . 0) ("n" . 1) ("w" . ,(or w 0)) ("h" . ,(or h 0))))
      (unless (assoc (car d) env) (setq env (append env (list d)))))
    env))

(defun homun-stage--scope (node env)
  "ENV extended with the variables the node NODE declares in `vars'."
  (if-let* ((vars (alist-get 'vars node)))
      (append (mapcar (lambda (v) (cons (symbol-name (car v)) (homun-stage-value (cdr v) env))) vars) env)
    env))

(defun homun-stage--num (node key env &optional default)
  "The number of field KEY of NODE (a literal, bind or expr), else DEFAULT."
  (let ((v (homun-stage-value (alist-get key node) (homun-stage-env env))))
    (if (numberp v) v (or default 0))))

(defun homun-stage--series (node env)
  "The data of the chart NODE as a list of numbers."
  (let* ((d (alist-get 'data node))
         (d (if (and (consp d) (consp (car d)) (memq (caar d) '(bind expr)))
                (homun-stage-value d (homun-stage-env env))
              d)))
    (cl-loop for x in (append d nil)
             for v = (homun-stage-value x (homun-stage-env env))
             when (numberp v) collect v)))

;;; Graph, timeline, chart, shape: text

(defun homun-stage--layers (node)
  "An alist (ID . LAYER) of the graph NODE: the longest path from a source, edges
that close a cycle ignored."
  (let ((edges (alist-get 'edges node)) (layer (make-hash-table :test #'equal)) (n (length (alist-get 'nodes node))))
    (dolist (nd (alist-get 'nodes node)) (puthash (alist-get 'id nd) 0 layer))
    (dotimes (_ n)
      (dolist (e edges)
        (when (< (gethash (cadr e) layer) (min (1- n) (1+ (gethash (car e) layer))))
          (puthash (cadr e) (min (1- n) (1+ (gethash (car e) layer))) layer))))
    (mapcar (lambda (nd) (cons (alist-get 'id nd) (gethash (alist-get 'id nd) layer))) (alist-get 'nodes node))))

(defun homun-stage--graph-text (node env)
  (let ((layers (homun-stage--layers node)) (edges (alist-get 'edges node)))
    (string-join
     (mapcar (lambda (nd)
               (let* ((id (alist-get 'id nd))
                      (mark (cadr (or (assoc (pcase (alist-get 'state nd) ("active" "now") ("pending" "next") (x x))
                                             homun-stage-step-marks)
                                      '(nil "○"))))
                      (to (cl-loop for e in edges when (equal (car e) id) collect (cadr e))))
                 (concat (make-string (* 2 (alist-get id layers nil nil #'equal)) ?\s) mark " "
                         (homun-stage--str (homun-stage-value (or (alist-get 'label nd) id) env))
                         (if to (concat " → " (string-join to ", ")) ""))))
             (alist-get 'nodes node))
     "\n")))

(defun homun-stage--timeline-text (node env)
  (let* ((evs (mapcar (lambda (e) (cons (let ((a (homun-stage-value (alist-get 'at e) env))) (if (numberp a) a 0))
                                        (homun-stage--str (homun-stage-value (alist-get 'label e) env))))
                      (alist-get 'events node)))
         (evs (sort evs (lambda (a b) (< (car a) (car b))))))
    (string-join (mapcar (lambda (e) (format "%s ● %s" (homun-stage--str (car e)) (cdr e))) evs) "\n")))

(defconst homun-stage--blocks "▁▂▃▄▅▆▇█")

(defun homun-stage--spark (vals lo hi)
  (mapconcat (lambda (v)
               (string (aref homun-stage--blocks
                             (if (= hi lo) 0 (min 7 (floor (* 8 (/ (- v lo) (float (- hi lo))))))))))
             vals ""))

(defun homun-stage--bins (vals n)
  (let* ((lo (apply #'min vals)) (hi (apply #'max vals)) (bins (make-list n 0)))
    (dolist (v vals)
      (cl-incf (nth (if (= hi lo) 0 (min (1- n) (floor (* n (/ (- v lo) (float (- hi lo))))))) bins)))
    bins))

(defun homun-stage--chart-text (node env)
  (let* ((vals (homun-stage--series node env)) (kind (alist-get 'kind node)))
    (if (null vals) "…"
      (let ((lo (apply #'min vals)) (hi (apply #'max vals)))
        (pcase kind
          ("bar" (let ((labels (alist-get 'labels node)))
                   (string-join
                    (cl-loop for v in vals for i from 0
                             collect (format "%s %s %s" (or (nth i labels) i)
                                             (make-string (max 0 (round (* 20 (/ v (float (max hi 1e-9)))))) ?█)
                                             (homun-stage--str v)))
                    "\n")))
          ("hist" (let ((b (homun-stage--bins vals (or (alist-get 'bins node) 8))))
                    (format "%s %s…%s" (homun-stage--spark b 0 (apply #'max b)) (homun-stage--str lo) (homun-stage--str hi))))
          ("line" (format "%s %s…%s" (homun-stage--spark vals lo hi) (homun-stage--str lo) (homun-stage--str hi)))
          (_ (homun-stage--spark vals lo hi)))))))

(defun homun-stage--shape-text (node env)
  (let ((kind (alist-get 'kind node)))
    (if (equal kind "text") (homun-stage--str (homun-stage-value (alist-get 'text node) env))
      (format "(%s)" kind))))


(defun homun-stage--pad (s w) (concat s (make-string (max 0 (- w (string-width s))) ?\s)))

(defun homun-stage--beside (blocks)
  "Join the multi-line strings BLOCKS side by side, two spaces apart."
  (let* ((cols (mapcar (lambda (b) (split-string b "\n")) blocks))
         (widths (mapcar (lambda (ls) (apply #'max 0 (mapcar #'string-width ls))) cols))
         (height (apply #'max 0 (mapcar #'length cols))))
    (string-join
     (cl-loop for i below height
              collect (string-trim-right
                       (string-join (cl-mapcar (lambda (ls w) (homun-stage--pad (or (nth i ls) "") w))
                                               cols widths)
                                    "  ")))
     "\n")))

(defun homun-stage--table-text (node env)
  (let* ((rows (mapcar (lambda (r) (mapcar (lambda (c) (homun-stage--str (homun-stage-value c env))) r))
                       (append (when-let* ((h (alist-get 'header node))) (list h)) (alist-get 'rows node))))
         (n (apply #'max 0 (mapcar #'length rows)))
         (widths (cl-loop for i below n
                          collect (apply #'max 0 (mapcar (lambda (r) (string-width (or (nth i r) ""))) rows))))
         (lines (mapcar (lambda (r)
                          (string-trim-right
                           (string-join (cl-loop for w in widths for i from 0
                                                 collect (homun-stage--pad (or (nth i r) "") w))
                                        " │ ")))
                        rows)))
    (when (alist-get 'header node)
      (setcdr lines (cons (string-join (mapcar (lambda (w) (make-string w ?─)) widths) "─┼─")
                          (cdr lines))))
    (string-join lines "\n")))

(defvar homun-stage-stale nil "Topics whose binding went silent; nodes bound to one are hatched.")

(defface homun-stage-stale '((t :inherit error :strike-through t :underline (:style wave)))
  "A node whose bound topic went silent." :group 'homun-layout)

(defun homun-stage--stale-node-p (node)
  "Non-nil when a field of NODE is bound to a topic in `homun-stage-stale'."
  (and homun-stage-stale
       (cl-some (lambda (f) (pcase (cdr f) (`((bind . ,topic)) (member topic homun-stage-stale))))
                node)))

(defun homun-stage-text (node &optional env)
  "The text render of NODE, with ENV for its expressions; a node bound to a silent
topic is hatched."
  (let ((text (homun-stage--text node env)))
    (if (and (stringp text) (homun-stage--stale-node-p node))
        (propertize (substring-no-properties text) 'face 'homun-stage-stale)
      text)))

(defun homun-stage--diff-text (diff)
  "DIFF with its added, removed and hunk lines in diff faces."
  (mapconcat (lambda (line)
               (let ((face (cond ((string-prefix-p "+" line) 'diff-added)
                                 ((string-prefix-p "-" line) 'diff-removed)
                                 ((string-prefix-p "@@" line) 'diff-hunk-header))))
                 (if face (propertize line 'face face) line)))
             (split-string diff "\n") "\n"))

(defun homun-stage--text (node &optional env)
  (pcase (alist-get 'type node)
    ("col" (string-join (mapcar (lambda (c) (homun-stage-text c env)) (alist-get 'children node)) "\n"))
    ("row" (homun-stage--beside (mapcar (lambda (c) (homun-stage-text c env)) (alist-get 'children node))))
    ((or "text" "md")
     (let ((text (homun-stage--str (homun-stage-value (alist-get 'text node) env)))
           (face (cdr (assoc (alist-get 'face node) homun-stage-faces))))
       (if face (propertize text 'face face) text)))
    ("table" (homun-stage--table-text node env))
    ("diffview" (homun-stage--diff-text (alist-get 'diff node)))
    ("stepper" (homun-stage--stepper-text node env))
    ("meter"
     (let ((f (homun-stage--fraction node env)) (label (alist-get 'label node)))
       (concat (if label (concat (homun-stage--str (homun-stage-value label env)) " ") "")
               (progn (require 'widgetry-meter) (widgetry-meter-string (or f 0.0) homun-stage-meter-width 'widgetry-meter-fill-ok))
               (if f (format " %d%%" (round (* 100 f))) " …"))))
    ("layer" (string-join (mapcar (lambda (c) (homun-stage-text c env)) (alist-get 'children node)) "\n"))
    ("graph" (homun-stage--graph-text node env))
    ("timeline" (homun-stage--timeline-text node env))
    ("chart" (homun-stage--chart-text node env))
    ("shape" (homun-stage--shape-text node env))
    ((and type (guard (homun-stage--part type)))
     (funcall (plist-get (homun-stage--part type) :text) node env))
    ("widget"
     (format "[%s: %s]" (homun-stage--str (homun-stage-value (alist-get 'label node) env))
             (homun-stage--str (homun-stage-value (alist-get 'value node) env))))))

;;; SVG render

(defconst homun-stage-line-px 20 "Pixel height of one text line in an SVG render.")

(defun homun-stage--colour (face attr fallback)
  (let ((c (face-attribute face attr nil t))) (if (stringp c) c fallback)))

(defun homun-stage-palette ()
  "The theme palette: fg bg accent ok warn err, from the active faces.
The hex values are fallbacks for a face the theme leaves unset (a bare -Q
frame)."
  `((fg . ,(homun-stage--colour 'default :foreground "#d0d0d0"))
    (bg . ,(homun-stage--colour 'default :background "#101418"))
    (accent . ,(homun-stage--colour 'font-lock-keyword-face :foreground "#7aa2f7"))
    (ok . ,(homun-stage--colour 'success :foreground "#9ece6a"))
    (warn . ,(homun-stage--colour 'warning :foreground "#e0af68"))
    (err . ,(homun-stage--colour 'error :foreground "#f7768e"))))

(defun homun-stage--draw (svg node x y w env pal)
  "Draw NODE on SVG at X Y, W pixels wide; return its height in pixels."
  (let ((lh homun-stage-line-px) (fg (alist-get 'fg pal)))
    (pcase (alist-get 'type node)
      ("col" (let ((h 0))
               (dolist (c (alist-get 'children node) h)
                 (cl-incf h (homun-stage--draw svg c x (+ y h) w env pal)))))
      ("row" (let* ((cs (alist-get 'children node)) (cw (/ w (max 1 (length cs)))))
               (cl-loop for c in cs for i from 0
                        maximize (homun-stage--draw svg c (+ x (* i cw)) y cw env pal))))
      ("stepper"
       (let ((states (homun-stage--states node env)) (steps (alist-get 'steps node)))
         (cl-loop for s in steps for state in states for i from 0
                  for cy = (+ y (* i lh) (/ lh 2))
                  do (svg-circle svg (+ x (/ lh 2)) cy (/ lh 4)
                                 :fill (pcase state
                                         ("done" (alist-get 'ok pal)) ("now" (alist-get 'accent pal))
                                         ("failed" (alist-get 'err pal)) ("you" (alist-get 'warn pal))
                                         (_ "none"))
                                 :stroke fg)
                  (svg-text svg s :x (+ x lh) :y (+ cy (/ lh 4)) :fill fg :font-size (* lh 0.7)))
         (* lh (length steps))))
      ("meter"
       (let ((f (or (homun-stage--fraction node env) 0)) (label (alist-get 'label node)) (bx x))
         (when label
           (svg-text svg (homun-stage--str (homun-stage-value label env))
                     :x x :y (+ y (* lh 0.75)) :fill fg :font-size (* lh 0.7))
           (setq bx (+ x (/ w 3))))
         (svg-rectangle svg bx (+ y 4) (- (+ x w) bx) (- lh 8) :fill "none" :stroke fg)
         (svg-rectangle svg bx (+ y 4) (* f (- (+ x w) bx)) (- lh 8) :fill (alist-get 'accent pal))
         lh))
      ("layer" (let* ((cs (alist-get 'children node)) (n (length cs)) (env (homun-stage--scope node env)))
                 (cl-loop for c in cs for i from 0
                          maximize (homun-stage--draw svg c x y w
                                                      (append `(("i" . ,i) ("n" . ,n)) env) pal))))
      ("shape" (homun-stage--draw-shape svg node x y w env pal))
      ("graph" (homun-stage--draw-graph svg node x y w env pal))
      ("timeline" (homun-stage--draw-timeline svg node x y w env pal))
      ("chart" (homun-stage--draw-chart svg node x y w env pal))
      (_ (let ((lines (split-string (homun-stage-text node env) "\n")))
           (cl-loop for l in lines for i from 0
                    do (svg-text svg l :x x :y (+ y (* (1+ i) lh) -5) :fill fg :font-size (* lh 0.7)))
           (* lh (length lines)))))))

(defun homun-stage--paint (name pal &optional default)
  "The colour of NAME: a palette name (fg bg accent a b c ok warn err), else NAME
itself."
  (cond ((null name) default)
        ((assq (intern name) pal) (alist-get (intern name) pal))
        ((member name '("a" "b" "c")) (alist-get 'accent pal))
        (t name)))

(defun homun-stage--draw-shape (svg node x y _w env pal)
  "Draw the shape NODE at X Y of the svg; return its lowest pixel below Y."
  (let* ((env (homun-stage-env (homun-stage--scope node env)))
         (num (lambda (k &optional d) (homun-stage--num node k env d)))
         (px (+ x (funcall num 'x))) (py (+ y (funcall num 'y)))
         (fill (homun-stage--paint (alist-get 'fill node) pal))
         (stroke (homun-stage--paint (alist-get 'stroke node) pal))
         (opacity (funcall num 'opacity 1))
         (opts (append (list :fill (or fill "none") :opacity opacity)
                       (when stroke (list :stroke stroke)))))
    (pcase (alist-get 'kind node)
      ("circle" (let ((r (funcall num 'r 5)))
                  (apply #'svg-circle svg px py r opts) (+ (funcall num 'y) r)))
      ("rect" (let ((h (funcall num 'h 10)))
                (apply #'svg-rectangle svg px py (funcall num 'w 10) h opts) (+ (funcall num 'y) h)))
      ((or "line" "arrow")
       (let* ((x2 (+ x (funcall num 'x2))) (y2 (+ y (funcall num 'y2)))
              (ang (atan (- y2 py) (- x2 px))))
         (svg-line svg px py x2 y2 :stroke (or stroke fill (alist-get 'fg pal)) :opacity opacity)
         (when (equal (alist-get 'kind node) "arrow")
           (svg-polygon svg (list (cons x2 y2)
                                  (cons (- x2 (* 8 (cos (- ang 0.4)))) (- y2 (* 8 (sin (- ang 0.4)))))
                                  (cons (- x2 (* 8 (cos (+ ang 0.4)))) (- y2 (* 8 (sin (+ ang 0.4))))))
                        :fill (or stroke fill (alist-get 'fg pal))))
         (max (funcall num 'y) (funcall num 'y2))))
      ("polygon"
       (let ((pts (mapcar (lambda (p) (cons (+ x (homun-stage-value (car p) env)) (+ y (homun-stage-value (cadr p) env))))
                          (alist-get 'points node))))
         (when (>= (length pts) 3) (apply #'svg-polygon svg pts opts))
         (apply #'max 0 (mapcar (lambda (p) (- (cdr p) y)) pts))))
      ("path" (apply #'svg-node svg 'path :d (alist-get 'd node) opts)
       (funcall num 'h 0))
      ("text" (let ((size (funcall num 'size 14)))
                (svg-text svg (homun-stage--str (homun-stage-value (alist-get 'text node) env))
                          :x px :y (+ py size) :fill (or fill (alist-get 'fg pal)) :font-size size)
                (+ (funcall num 'y) (* 1.3 size)))))))

(defun homun-stage--draw-graph (svg node x y w env pal)
  "Draw the graph NODE in layers left to right; return its height."
  (let* ((layers (homun-stage--layers node)) (nl (1+ (apply #'max 0 (mapcar #'cdr layers))))
         (bw (min 120 (/ (float w) (max 1 nl) 1.4))) (gap (if (> nl 1) (/ (- w bw) (1- nl)) 0))
         (rh 36) (seen (make-hash-table)) (pos (make-hash-table :test #'equal)) (rows 0)
         (fg (alist-get 'fg pal)))
    (dolist (nd (alist-get 'nodes node))
      (let* ((l (alist-get (alist-get 'id nd) layers nil nil #'equal)) (r (gethash l seen 0)))
        (puthash l (1+ r) seen) (setq rows (max rows (1+ r)))
        (puthash (alist-get 'id nd) (cons (+ x (* l gap)) (+ y (* r rh))) pos)))
    (dolist (e (alist-get 'edges node))
      (let ((a (gethash (car e) pos)) (b (gethash (cadr e) pos)))
        (svg-line svg (+ (car a) bw) (+ (cdr a) 12) (car b) (+ (cdr b) 12) :stroke fg)))
    (dolist (nd (alist-get 'nodes node))
      (let ((p (gethash (alist-get 'id nd) pos)))
        (svg-rectangle svg (car p) (cdr p) bw 24 :rx 4 :stroke fg
                       :fill (pcase (alist-get 'state nd)
                               ("active" (alist-get 'accent pal)) ("done" (alist-get 'ok pal))
                               ("failed" (alist-get 'err pal)) (_ "none")))
        (svg-text svg (homun-stage--str (homun-stage-value (or (alist-get 'label nd) (alist-get 'id nd)) env))
                  :x (+ (car p) 6) :y (+ (cdr p) 16) :fill fg :font-size 12)))
    (* rh (max 1 rows))))

(defun homun-stage--draw-timeline (svg node x y w env pal)
  "Draw the timeline NODE as an axis with a dot and label per event; return its
height."
  (let* ((evs (mapcar (lambda (e) (cons (let ((a (homun-stage-value (alist-get 'at e) env))) (if (numberp a) a 0))
                                        (homun-stage--str (homun-stage-value (alist-get 'label e) env))))
                      (alist-get 'events node)))
         (lo (apply #'min 0 (mapcar #'car evs))) (hi (apply #'max 1 (mapcar #'car evs)))
         (fg (alist-get 'fg pal)))
    (svg-line svg x (+ y 20) (+ x w) (+ y 20) :stroke fg)
    (cl-loop for e in (sort evs (lambda (a b) (< (car a) (car b)))) for i from 0
             for ex = (+ x 4 (* (- w 8) (/ (- (car e) lo) (float (max 1e-9 (- hi lo))))))
             do (svg-circle svg ex (+ y 20) 4 :fill (alist-get 'accent pal))
             (svg-text svg (cdr e) :x ex :y (+ y (if (cl-oddp i) 44 12)) :fill fg :font-size 11
                       :text-anchor (if (> (- ex x) (/ w 2)) "end" "start")))
    52))

(defun homun-stage--draw-chart (svg node x y w env pal)
  "Draw the chart NODE; return its height."
  (let* ((vals (homun-stage--series node env)) (h (homun-stage--num node 'height env 80))
         (kind (alist-get 'kind node)) (col (alist-get 'accent pal)))
    (when vals
      (let* ((vals (if (equal kind "hist") (homun-stage--bins vals (or (alist-get 'bins node) 8)) vals))
             (lo (if (member kind '("bar" "hist")) 0 (apply #'min vals))) (hi (apply #'max vals))
             (n (length vals)) (sy (lambda (v) (- (+ y h) (* h (/ (- v lo) (float (max 1e-9 (- hi lo))))))))
             (sx (lambda (i) (+ x (* w (/ (+ i 0.5) n))))))
        (if (member kind '("bar" "hist"))
            (cl-loop for v in vals for i from 0
                     do (svg-rectangle svg (- (funcall sx i) (/ w n 2.5)) (funcall sy v) (/ w n 1.25)
                                       (- (+ y h) (funcall sy v)) :fill col)
                     (when-let* ((l (and (equal kind "bar") (nth i (alist-get 'labels node)))))
                       (svg-text svg (homun-stage--str l) :x (funcall sx i) :y (+ y h 12)
                                 :text-anchor "middle" :fill (alist-get 'fg pal) :font-size 10)))
          (svg-polyline svg (cl-loop for v in vals for i from 0 collect (cons (funcall sx i) (funcall sy v)))
                        :stroke col :fill "none"))))
    (if (and vals (equal kind "bar") (alist-get 'labels node)) (+ h 16) h)))

(defun homun-stage-svg (node width &optional env)
  "The SVG render of NODE, WIDTH pixels wide."
  (let* ((pal (homun-stage-palette)) (env (homun-stage-env env width))
         (probe (svg-create width 1))
         (h (max 1 (homun-stage--draw probe node 0 0 width env pal)))
         (svg (svg-create width h)))
    (homun-stage--draw svg node 0 0 width env pal)
    svg))

;;; Into a buffer

(defun homun-stage--text-only-p (node)
  (or (member (alist-get 'type node) homun-stage-text-types)
      (homun-stage--part (alist-get 'type node))
      (and (equal (alist-get 'type node) "stepper") (equal (alist-get 'layout node) "line"))
      (and (member (alist-get 'type node) '("col" "row"))
           (cl-every #'homun-stage--text-only-p (alist-get 'children node)))))

(defvar homun-stage-event-program nil
  "The command that delivers a message on stdin; nil uses `claude-compose-program'.")

(defun homun-stage-event-command (scene node kind value)
  "The delivery command for a stage event, its attributes after `meta'."
  (append (or homun-stage-event-program
              (and (boundp 'claude-compose-program) (symbol-value 'claude-compose-program)))
          (list "meta" "origin=stage" (format "scene=%s" scene) (format "node=%s" node)
                (format "kind=%s" kind) (format "value=%s" value))))

(defun homun-stage-event (scene node kind value &optional text)
  "Send the channel event of a click or change on NODE of SCENE; TEXT is its
message body."
  (when-let* ((command (homun-stage-event-command scene node kind value))
              ((car command)))
    (let ((process (make-process :name "homun-stage-event" :connection-type 'pipe
                                 :command command :noquery t
                                 :buffer (generate-new-buffer " *homun-stage-event*")
                                 :sentinel (lambda (p _)
                                             (unless (process-live-p p)
                                               (kill-buffer (process-buffer p)))))))
      (process-send-string process (or text (format "[stage %s/%s %s %s]" scene node kind value)))
      (process-send-eof process))))

(defun homun-stage--press (id)
  "The `:notify' of the widget node ID: its action, when it has one, else the click
is an event."
  (lambda (&rest _)
    (if-let* ((f (and id (gethash id homun-stage-actions))))
        (funcall f)
      (when (and id (not (string-prefix-p "ask:" id)))
        (homun-stage-event (or (bound-and-true-p homun-stage-scene) "stage") id "click" "t")))))

(defun homun-stage--button (node env)
  "A `widgetry-buttons' spec of the button NODE."
  (append (list :label (homun-stage--str (homun-stage-value (alist-get 'label node) env))
                :notify (homun-stage--press (alist-get 'id node)))
          (when-let* ((tag (alist-get 'tag node))) (list :tag tag))
          (when-let* ((face (pcase (alist-get 'face node)
                              ("ok" 'homun-button-primary) ("err" 'homun-button-danger))))
            (list :label-face face))
          (when (equal (alist-get 'confirm node) "hold") (list :confirm 'hold))))

(defun homun-stage--insert-widget (node env)
  "Insert the widget NODE as a live widgetry control, else as its text."
  (let ((kind (or (alist-get 'kind node) (alist-get 'type node))))
    (cond ((not (require 'widgetry nil t)) (insert (homun-stage-text node env)))
          ((equal kind "meter")
           (let ((f (homun-stage--fraction node env)))
             (when-let* ((label (alist-get 'label node)))
               (insert (homun-stage--str (homun-stage-value label env)) " "))
             (widget-create 'widgetry-meter :read-only t :width (or (alist-get 'width node) 24) :tag ""
                            :value (or f 0.0) :fill-face 'widgetry-meter-fill-ok)))
          ((equal kind "button")
           (widget-create 'widgetry-buttons :stretch t :buttons (list (homun-stage--button node env))))
          ((member kind '("toggle" "slider" "selector" "chips" "check"))
           (homun-stage--insert-control node kind env))
          (t (insert (homun-stage-text node env))))))

(defun homun-stage--changed (id)
  "The `:notify' of the control node ID: its action gets the new value; with none,
the change is an event."
  (lambda (widget &rest _)
    (let ((value (widget-value widget)))
      (if-let* ((f (and id (gethash id homun-stage-actions))))
          (funcall f value)
        (when id (homun-stage-event (or (bound-and-true-p homun-stage-scene) "stage") id "set"
                                    (json-encode value)))))))

(defun homun-stage--insert-control (node kind env)
  "Insert the control NODE of KIND (toggle, slider, selector, chips or check) as a
live widget."
  (let ((value (homun-stage-value (alist-get 'value node) env))
        (choices (alist-get 'choices node))
        (notify (homun-stage--changed (alist-get 'id node))))
    (pcase kind
      ("toggle" (widget-create 'widgetry-toggle :value (and value (not (eq value :false))) :notify notify))
      ("slider" (widget-create 'widgetry-slider :value (or value 0) :notify notify
                               :min (or (alist-get 'min node) 0.0) :max (or (alist-get 'max node) 1.0)
                               :decimals (alist-get 'decimals node) :step (alist-get 'step node)))
      ("selector" (widget-create 'widgetry-selector :value value :choices choices :notify notify))
      ("chips" (widget-create 'widgetry-chips :tag " ◈ " :choices choices :value value :notify notify))
      ;; A check's value is t, :false or "some" (a master box over a partly chosen group)
      ("check" (widget-create 'widgetry-check :value (and (eq value t) '(on)) :partial (equal value "some")
                              :notify notify)))))

(defun homun-stage--insert-text (node env)
  "Insert the text-only NODE, tagged with its id."
  (let ((start (point)))
    (homun-stage--insert-text-1 node env)
    (when-let* ((id (alist-get 'id node))) (homun-stage--tag start id))))

(defun homun-stage--insert-text-1 (node env)
  "Insert the text-only NODE: a row on one line, widgets live."
  (pcase (alist-get 'type node)
    ("col" (cl-loop for (c . more) on (alist-get 'children node)
                    do (homun-stage--insert-text c env) (when more (insert "\n"))))
    ("row"
     (let ((cs (alist-get 'children node)))
       (if (and cs (cl-every (lambda (c) (and (equal (alist-get 'kind c) "button")
                                              (require 'widgetry nil t)))
                             cs))
           ;; A row of buttons is one segmented group
           (widget-create 'widgetry-buttons :stretch t :buttons (mapcar (lambda (c) (homun-stage--button c env)) cs))
         (cl-loop for (c . more) on cs
                  do (homun-stage--insert-text c env) (when more (insert " "))))))
    ((or "widget" "meter") (homun-stage--insert-widget node env))
    (type (if-let* ((f (plist-get (homun-stage--part type) :insert))) (funcall f node env)
            (insert (homun-stage-text node env))))))

(defun homun-stage--tag (start id)
  "Mark the text from START to point as node ID where no inner node has claimed it:
as `homun-stage-node', and as `homun-node' (SCENE/ID, read by the compose chips)
in a scene buffer."
  (let ((pos start) (scene (bound-and-true-p homun-stage--id)))
    (while (< pos (point))
      (let ((end (or (next-single-property-change pos 'homun-stage-node nil (point)) (point))))
        (unless (get-text-property pos 'homun-stage-node)
          (put-text-property pos end 'homun-stage-node id)
          (put-text-property pos end 'help-echo #'homun-stage-hover)
          (when scene (put-text-property pos end 'homun-node (concat scene "/" id))))
        (setq pos end)))))

(defun homun-stage-insert (node width &optional env)
  "Insert NODE at point as blocks: text nodes as text, other subtrees as SVG WIDTH
wide.
Text of a node with an id is tagged with it (see `homun-stage--tag'); the
innermost id wins."
  (let ((start (point)))
    (homun-stage--insert node width env)
    (when-let* ((id (alist-get 'id node))) (homun-stage--tag start id))))

;; Pixel scrolling (`pixel-scroll-precision-mode') only moves within one display line, so a tall
;; image in one line makes upward scrolling jump or stick.  Slices of about a line's height are
;; one line each; the node tag (`homun-stage--tag') covers all of them, so a click on any slice
;; still resolves to the node.
(defun homun-stage--insert-svg (svg)
  "Insert SVG at point as slices of one line's height each."
  (let* ((h (ceiling (string-to-number (format "%s" (or (dom-attr svg 'height) 0)))))
         (rows (max 1 (ceiling h (max 1 (frame-char-height))))))
    (insert-sliced-image (svg-image svg) " " nil rows 1)))

(defun homun-stage--insert (node width env)
  (cond ((and (equal (alist-get 'type node) "col") (not (homun-stage--text-only-p node)))
         (dolist (c (alist-get 'children node)) (homun-stage-insert c width env)))
        ((homun-stage--text-only-p node) (homun-stage--insert-text node env) (insert "\n"))
        ((and (fboundp 'widgetry-graphic-p) (widgetry-graphic-p)) (homun-stage--insert-svg (homun-stage-svg node width env)) (insert "\n"))
        (t (insert (homun-stage-text node env) "\n"))))

;;; Presets

(defun homun-stage-age (seconds)
  "SECONDS as a short age: 12s, 3m, 2h."
  (let ((s (max 0 (round seconds))))
    (cond ((< s 60) (format "%ds" s)) ((< s 3600) (format "%dm" (/ s 60)))
          (t (format "%dh" (/ s 3600))))))

(defun homun-stage-steps (title steps &optional line)
  "A scene of TITLE over STEPS, each (TEXT STATE NOTE); with LINE, the steps on one
line."
  `((type . "col")
    (children . (,@(when title `(((type . "text") (id . "title") (face . "title") (text . ,title))))
                 ((type . "stepper") (id . "steps")
                  (steps . ,(mapcar #'car steps))
                  (states . ,(mapcar (lambda (s) (or (nth 1 s) "next")) steps))
                  ,@(when (cl-some (lambda (s) (nth 2 s)) steps)
                      `((notes . ,(mapcar (lambda (s) (or (nth 2 s) "")) steps))))
                  ,@(when line '((layout . "line"))))))))

(defun homun-stage-build (title steps &rest more)
  "A scene of an image build: the TITLE line (a list of text nodes), STEPS (see
`homun-stage-steps') on one line, then MORE: :meter FRACTION, :info TEXT, :note
TEXT
\(an error) and :buttons, a list of (ID LABEL TAG FACE CONFIRM)."
  (let ((meter (plist-get more :meter)) (info (plist-get more :info))
        (note (plist-get more :note)) (buttons (plist-get more :buttons)))
    `((type . "col")
      (children
       ((type . "row") (id . "head") (children . ,title))
       ((type . "text") (text . ""))
       ,(cadr (assq 'children (homun-stage-steps nil steps t)))
       ((type . "text") (text . ""))
       ((type . "row") (id . "progress")
        (children . (,@(when meter `(((type . "widget") (id . "meter") (kind . "meter") (label . "build")
                                      (value . ,meter))))
                     ((type . "text") (id . "info") (face . "dim") (text . ,(or info ""))))))
       ,@(when note `(((type . "text") (id . "note") (face . "err") (text . ,note))))
       ((type . "text") (text . ""))
       ((type . "row") (id . "buttons")
        (children . ,(mapcar (pcase-lambda (`(,id ,label ,tag ,face ,confirm))
                               `((type . "widget") (kind . "button") (id . ,id) (label . ,label)
                                 ,@(when tag `((tag . ,tag))) ,@(when face `((face . ,face)))
                                 ,@(when confirm `((confirm . ,confirm)))))
                             buttons)))))))

;;; The ask preset

(defun homun-ask-answer (id question choices text status &rest more)
  "The answer object of question ID, shared by the ask scene and the Org renderer.
CHOICES is the list of ticked texts, TEXT the free answer, STATUS \"answered\" or
\"na\"; MORE are extra (KEY . VALUE) pairs."
  `((id . ,id) (question . ,question) (choices . ,(vconcat choices)) (text . ,text)
    (status . ,status) ,@more))

(defun homun-ask--send (id question choices text)
  "Deliver the answer to question ID as a stage event at once."
  (homun-stage-event (or (bound-and-true-p homun-stage-scene) "ask") id "answer" "t"
                     (json-serialize (homun-ask-answer id question choices text "answered"))))

(defun homun-ask--mark (key label on)
  "Redraw the option button KEY of the open scene, LABEL ticked when ON."
  (when-let* ((scene (bound-and-true-p homun-stage-scene))
              (s (and (boundp 'homun-stage-scenes) (gethash scene homun-stage-scenes))))
    (homun-stage-patch (homun-stage-scene-owner s) scene
                       `(((path . ,(format "/%s/label" key)) (set . ,(if on (concat "☑ " label) label)))))))

(defun homun-stage-ask (questions)
  "A scene of QUESTIONS, each (ID TEXT KIND OPTIONS), KIND choice, many or text.
Every question is answered on its own: a choice sends when picked, many sends on
its Send button after the options are ticked, text on its Answer button (a
prompt)."
  (let (children)
    (pcase-dolist (`(,id ,text ,kind ,options) questions)
      (let ((picked (list nil)) (n 0) (buttons nil))
        (push `((type . "text") (id . ,(format "%s-q" id)) (face . "title") (text . ,text)) children)
        (pcase kind
          ("text"
           (puthash (format "ask:%s" id)
                    (lambda ()
                      (if (and (bound-and-true-p homun-layout-phone) (fboundp 'claude-phone-ask))
                          (claude-phone-ask text (lambda (answer) (homun-ask--send id text nil answer)))
                        (homun-ask--send id text nil (read-string (concat text " ")))))
                    homun-stage-actions)
           (push `((type . "widget") (kind . "button") (id . ,(format "ask:%s" id))
                   (label . "Answer")) buttons))
          (_
           (dolist (opt options)
             (let ((key (format "ask:%s:%d" id (cl-incf n))) (opt opt))
               (puthash key (if (equal kind "many")
                                (lambda () (setcar picked (if (member opt (car picked))
                                                              (remove opt (car picked))
                                                            (append (car picked) (list opt))))
                                  (homun-ask--mark key opt (member opt (car picked))))
                              (lambda () (homun-ask--send id text (list opt) "")))
                        homun-stage-actions)
               (push `((type . "widget") (kind . "button") (id . ,key) (label . ,opt)) buttons)))
           (when (equal kind "many")
             (puthash (format "ask:%s" id)
                      (lambda () (homun-ask--send id text (car picked) ""))
                      homun-stage-actions)
             (push `((type . "widget") (kind . "button") (id . ,(format "ask:%s" id))
                     (label . "Send") (face . "ok")) buttons))))
        (push `((type . "row") (id . ,(format "%s-a" id)) (children . ,(nreverse buttons))) children)))
    `((type . "col") (children . ,(nreverse children)))))

(provide 'homun-stage)
;;; homun-stage.el ends here
