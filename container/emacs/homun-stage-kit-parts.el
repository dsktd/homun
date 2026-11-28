;;; homun-stage-kit-parts.el --- More parts of the stage scene kit -*- lexical-binding: t -*-

;; Parts added to `homun-stage-kit' for project scenes, same rules: each is fixed lines of
;; buffer text, bound to a source, redrawn in place only when its text changed, and opens what
;; it shows on RET or a click.  Fields besides "id", "width" (48) and "label":
;;
;;   prs        "repo" (OWNER/NAME), "numbers" (the PRs to show; all open ones when absent), "max" (6):
;;              title, CI state and +/- lines, read from the cache file of the manager's `stage`
;;              service (it runs gh; this side never does), by mtime.  Clicking the "fetched"
;;              span touches the service's request file.
;;   buildstat  "latest" (a buildlog project directory): pass or fail, duration and the first
;;              error of the run its latest.json names.
;;   players    "file" (a server log): the sessions and matches of its last summary line.
;;   checklist  "items", each {text, state done|now|next, open (a file), line}; or "file", a
;;              markdown list of `- [x] done`, `- [~] now` and `- [ ] next` lines.
;;   section    "file" and "heading" (regexp): the list items under that heading, each opening
;;              the file at its line; "max" (8).
;;   layout     "ron" (a saved layout of the panels project, as text) or "file": the box diagram
;;              of its areas, an SVG; "rows" (8) text lines tall.
;;   cycle      "steps", each {label, sub, open (a file), line}: a loop diagram, an SVG; "rows" (9).
;;
;; An SVG part is sliced into one line per text row by `homun-stage--insert-svg'; a tty gets
;; text lines of the same count.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'json)
(require 'homun-stage)
(require 'homun-stage-kit)
(require 'homun-proc)

(defvar homun-stage-kit-prs-period 20 "Seconds between reads of a PR cache file.")
(defvar homun-stage-kit-prs-cache-dir (expand-file-name "~/claude/.services/stage/") "Where the stage service caches PR lists.")
(defvar homun-stage-kit-stale-after 150 "Seconds without a write after which a log is stale.")

(defun homun-stage-kit--blank (n w)
  (cl-loop repeat n collect (make-string w ?\s)))

(defun homun-stage-kit--pad (lines n w)
  "LINES cut or padded with blank lines to N."
  (append (seq-take lines n) (homun-stage-kit--blank (max 0 (- n (length lines))) w)))

(defun homun-stage-kit--file-stamp (path)
  (when-let* ((a (and path (file-attributes path)))) (list (file-attribute-size a) (file-attribute-modification-time a))))

;;; prs

(defun homun-stage-kit--ci (checks)
  "The state of a statusCheckRollup list: fail, pending, pass or none."
  (let ((checks (append checks nil)))
    (cond ((null checks) 'none)
          ((cl-some (lambda (c) (member (alist-get 'conclusion c) '("FAILURE" "TIMED_OUT" "CANCELLED" "STARTUP_FAILURE")))
                    checks)
           'fail)
          ((cl-some (lambda (c) (or (member (alist-get 'status c) '("IN_PROGRESS" "QUEUED" "PENDING" "WAITING"))
                                    (member (alist-get 'state c) '("PENDING" "EXPECTED"))))
                    checks)
           'pending)
          (t 'pass))))

(defun homun-stage-kit--prs-parse (json numbers)
  "The PRs of the gh JSON text, only NUMBERS when given.
Each is (NUMBER TITLE URL CI ADD DEL STATE)."
  (let ((all (append (json-parse-string json :object-type 'alist :array-type 'list) nil)))
    (cl-loop for p in (sort all (lambda (a b) (< (alist-get 'number a) (alist-get 'number b))))
             when (or (null numbers) (memq (alist-get 'number p) numbers))
             collect (list (alist-get 'number p) (alist-get 'title p) (alist-get 'url p)
                           (homun-stage-kit--ci (alist-get 'statusCheckRollup p))
                           (alist-get 'additions p) (alist-get 'deletions p) (alist-get 'state p)))))

(defun homun-stage-kit--prs-key (node) (list "prs" (alist-get 'repo node)))

(defun homun-stage-kit--prs-cache (repo) (expand-file-name (concat "prs-" (replace-regexp-in-string "/" "-" repo) ".json") homun-stage-kit-prs-cache-dir))

(defun homun-stage-kit--prs-request () (expand-file-name "request" homun-stage-kit-prs-cache-dir))

(defun homun-stage-kit--prs-source (node key)
  "Read the PR list the manager's stage service cached, when its file changed.\nThis side never runs gh."
  (let* ((repo (alist-get 'repo node)) (numbers (alist-get 'numbers node)) (cache (homun-stage-kit--prs-cache repo))
         (stamp (homun-stage-kit--file-stamp cache)) (old (homun-stage-kit-get key)))
    (cond ((null stamp) (homun-stage-kit-put key (list :error "waiting for the manager's stage service")))
          ((not (equal stamp (plist-get old :stamp)))
           (condition-case err
               (homun-stage-kit-put
                key (list :prs (homun-stage-kit--prs-parse (with-temp-buffer (insert-file-contents cache) (buffer-string)) numbers)
                          :at (float-time (cadr stamp)) :stamp stamp))
             (error (homun-stage-kit-put key (append (list :error (error-message-string err)) old))))))))

(defun homun-stage-kit--prs-lines (node d w)
  (let* ((repo (alist-get 'repo node)) (n (or (alist-get 'max node) 6))
         (url (format "https://github.com/%s/pulls" repo))
         (at (plist-get d :at)) (err (plist-get d :error))
         (head (concat (homun-stage-kit--target (propertize (format "PRs %s" repo) 'face 'shadow) (list 'url url))
                       (propertize "  " 'face 'shadow)
                       (homun-stage-kit--target
                        (propertize (cond (err (format "failed: %s" err))
                                          (at (format-time-string "fetched %H:%M" at))
                                          (t "fetching…"))
                                    'face (if err 'error 'shadow))
                        (list 'touch (homun-stage-kit--prs-request) (homun-stage-kit--prs-key node)) "RET: ask the manager to fetch again")))
         (rows (cl-loop for (num title purl ci add del state) in (plist-get d :prs)
                        for stat = (format " +%d −%d" (or add 0) (or del 0))
                        collect (homun-stage-kit--target
                                 (concat (propertize (format "#%-4d" num) 'face 'shadow)
                                         (pcase ci
                                           ('pass (propertize "✓ " 'face 'success)) ('fail (propertize "✗ " 'face 'error))
                                           ('pending (propertize "◌ " 'face 'warning)) (_ (propertize "· " 'face 'shadow)))
                                         (propertize (homun-stage-kit--fit
                                                      (concat title (if (equal state "OPEN") "" (format " [%s]" (downcase state))))
                                                      (max 4 (- w 8 (length stat))))
                                                     'face (if (equal state "OPEN") 'default 'shadow))
                                         (propertize stat 'face 'shadow))
                                 (list 'url purl) (format "RET: #%d on GitHub" num)))))
    (cons head (append (seq-take rows n) (homun-stage-kit--blank (max 0 (- n (length rows))) w)))))

(homun-stage-kit-define
 "prs" '(repo)
 (lambda (node) (list (list (homun-stage-kit--prs-key node) #'homun-stage-kit--prs-source homun-stage-kit-prs-period)))
 (lambda (inst _now _snap)
   (let ((node (homun-stage-kit--inst-node inst)))
     (cons (homun-stage-kit--prs-lines node (homun-stage-kit-get (homun-stage-kit--prs-key node)) (homun-stage-kit--w node)) nil))))

;;; buildstat

(defun homun-stage-kit--buildstat-source (node key)
  "Store (:ok :command :seconds :log :error :stamp) of the node's latest.json."
  (let* ((json (expand-file-name "latest.json" (alist-get 'latest node)))
         (stamp (homun-stage-kit--file-stamp json)) (old (homun-stage-kit-get key)))
    (unless (and stamp old (equal (plist-get old :stamp) stamp))
      (homun-stage-kit-put
       key (when stamp
             (let* ((j (ignore-errors (with-temp-buffer (insert-file-contents json) (json-parse-buffer :object-type 'alist))))
                    (log (alist-get 'log j)))
               (list :stamp stamp :ok (eq (alist-get 'exit j) 0) :exit (alist-get 'exit j)
                     :command (alist-get 'command j) :seconds (alist-get 'seconds j) :log log
                     :error (and (not (eq (alist-get 'exit j) 0)) log (file-readable-p log)
                                 (homun-stage-kit--first-error log)))))))))

(defun homun-stage-kit--first-error (log)
  "The first error line of the log file LOG, colours removed."
  (with-temp-buffer
    (insert-file-contents log nil 0 (* 256 1024))
    (goto-char (point-min))
    (while (re-search-forward "\e\\[[0-9;]*[A-Za-z]" nil t) (replace-match ""))
    (goto-char (point-min))
    (when (re-search-forward "^\\(error\\(\\[[A-Z0-9]+\\]\\)?:.*\\)$" nil t) (match-string 1))))

(homun-stage-kit-define
 "buildstat" '(latest)
 (lambda (node) (list (list (list "buildstat" (alist-get 'latest node)) #'homun-stage-kit--buildstat-source 1)))
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (d (homun-stage-kit-get (list "buildstat" (alist-get 'latest node))))
          (target (and d (plist-get d :log) (list 'file (plist-get d :log)))))
     (cons (list (homun-stage-kit--target
                  (homun-stage-kit--fit
                   (if (null d) (propertize "build  none yet" 'face 'shadow)
                     (concat (propertize "build " 'face 'shadow)
                             (if (plist-get d :ok) (propertize "✓ pass" 'face 'success)
                               (propertize (format "✗ fail %s" (plist-get d :exit)) 'face 'error))
                             (propertize (format "  %s  %.1fs" (or (plist-get d :command) "") (or (plist-get d :seconds) 0)) 'face 'shadow)))
                   w)
                  target "RET: the build log")
                 (homun-stage-kit--target
                  (homun-stage-kit--fit
                   (cond ((null d) "") ((plist-get d :error) (concat "  " (plist-get d :error)))
                         ((plist-get d :ok) "  no errors") (t "  no error line in the log"))
                   w)
                  target "RET: the build log"))
           nil))))

;;; players

(defun homun-stage-kit--players-source (node key)
  "Store (:sessions :matches :stamp :stale) of the last summary line of the log."
  (let* ((file (expand-file-name (alist-get 'file node))) (a (file-attributes file))
         (stale (and a (> (- (float-time) (float-time (file-attribute-modification-time a))) homun-stage-kit-stale-after)))
         (stamp (homun-stage-kit--file-stamp file)) (old (homun-stage-kit-get key)))
    (cond ((null a) (homun-stage-kit-put key nil))
          ((and old (equal (plist-get old :stamp) stamp)) (homun-stage-kit-put key (plist-put (copy-sequence old) :stale stale)))
          (t (with-temp-buffer
               (insert-file-contents file nil (max 0 (- (file-attribute-size a) 65536)))
               (goto-char (point-max))
               (homun-stage-kit-put
                key (if (re-search-backward "sessions\\S-*?=\\S-*?\\([0-9]+\\).*?matches\\S-*?=\\S-*?\\([0-9]+\\)" nil t)
                        (list :stamp stamp :stale stale :sessions (string-to-number (match-string 1))
                              :matches (string-to-number (match-string 2)))
                      (list :stamp stamp :stale stale))))))))

(homun-stage-kit-define
 "players" '(file)
 (lambda (node) (list (list (list "players" (alist-get 'file node)) #'homun-stage-kit--players-source 1)))
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node))
          (d (homun-stage-kit-get (list "players" (alist-get 'file node))))
          (target (list 'file (expand-file-name (alist-get 'file node)))))
     (cons (list (homun-stage-kit--target
                  (homun-stage-kit--fit
                   (cond ((null d) (propertize "players  no log yet" 'face 'shadow))
                         ((plist-get d :sessions)
                          (concat (propertize "players " 'face 'shadow)
                                  (propertize (format "%d connected" (plist-get d :sessions)) 'face (if (> (plist-get d :sessions) 0) 'success 'default))
                                  (propertize (format "  %d matches%s" (plist-get d :matches) (if (plist-get d :stale) "  stale" ""))
                                              'face (if (plist-get d :stale) 'warning 'shadow))))
                         (t (propertize "players  no summary line yet" 'face 'shadow)))
                   w)
                  target "RET: the server log")
                 (homun-stage-kit--target
                  (propertize (homun-stage-kit--fit "  the log counts sessions; it names no players" w) 'face 'shadow)
                  target))
           nil))))

;;; checklist

(defun homun-stage-kit--checklist-parse (text)
  "The items (TEXT STATE LINE) of the markdown checklist TEXT."
  (let ((n 0) items)
    (dolist (l (split-string text "\n"))
      (cl-incf n)
      (when (string-match "\\`- \\[\\([x~ ]\\)\\] +\\(.+?\\) *\\'" l)
        (push (list (match-string 2 l) (pcase (match-string 1 l) ("x" "done") ("~" "now") (_ "next")) n) items)))
    (nreverse items)))

(defun homun-stage-kit--checklist-source (node key)
  "Store (:items :stamp) of the node's markdown file when it changed."
  (let* ((file (expand-file-name (alist-get 'file node))) (stamp (homun-stage-kit--file-stamp file)) (old (homun-stage-kit-get key)))
    (unless (and old stamp (equal (plist-get old :stamp) stamp))
      (homun-stage-kit-put
       key (if stamp
               (list :stamp stamp :items (homun-stage-kit--checklist-parse (with-temp-buffer (insert-file-contents file) (buffer-string))))
             (list :error "no checklist file"))))))

(homun-stage-kit-define
 "checklist" '()
 (lambda (node)
   (when (alist-get 'file node)
     (list (list (list "checklist" (alist-get 'file node)) #'homun-stage-kit--checklist-source 2))))
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node)) (file (alist-get 'file node))
          (d (and file (homun-stage-kit-get (list "checklist" file))))
          (items (if file
                     (mapcar (lambda (i) `((text . ,(nth 0 i)) (state . ,(nth 1 i)) (open . ,file) (line . ,(nth 2 i)))) (plist-get d :items))
                   (alist-get 'items node))))
     (cons (cons (homun-stage-kit--fit (propertize (or (alist-get 'label node) "") 'face 'shadow) w)
                 (append
                  (when (plist-get d :error) (list (homun-stage-kit--fit (propertize (plist-get d :error) 'face 'error) w)))
                  (cl-loop for it in items
                           for state = (alist-get 'state it) for open = (alist-get 'open it)
                           collect (homun-stage-kit--target
                                    (homun-stage-kit--fit
                                     (propertize (format "%s %s" (pcase state ("done" "✓") ("now" "▸") (_ "·")) (alist-get 'text it))
                                                 'face (pcase state ("done" 'success) ("now" 'warning) (_ 'shadow)))
                                     w)
                                    (and open (list 'file open (alist-get 'line it)))))))
           nil))))

;;; section

(defun homun-stage-kit--section-source (node key)
  "Store (:stamp :head :items) of the list under the node's heading.\nHEAD and each item are (LINE . TEXT)."
  (let* ((file (expand-file-name (alist-get 'file node))) (stamp (homun-stage-kit--file-stamp file)) (old (homun-stage-kit-get key)))
    (unless (and old stamp (equal (plist-get old :stamp) stamp))
      (homun-stage-kit-put
       key (when stamp
             (with-temp-buffer
               (insert-file-contents file)
               (goto-char (point-min))
               (when (re-search-forward (alist-get 'heading node) nil t)
                 (let ((head (cons (line-number-at-pos) (string-trim (replace-regexp-in-string "\\`#+ *" "" (buffer-substring (line-beginning-position) (line-end-position))))))
                       (end (save-excursion (if (re-search-forward "^#+ " nil t) (line-beginning-position) (point-max))))
                       items)
                   (while (re-search-forward "^\\(?:[0-9]+\\.\\|[-*]\\) +\\(.*\\)$" end t)
                     (push (cons (line-number-at-pos) (replace-regexp-in-string "\\*\\*" "" (match-string 1))) items))
                   (list :stamp stamp :head head :items (nreverse items))))))))))

(homun-stage-kit-define
 "section" '(file heading)
 (lambda (node) (list (list (list "section" (alist-get 'file node) (alist-get 'heading node)) #'homun-stage-kit--section-source 2)))
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node)) (n (or (alist-get 'max node) 8))
          (file (expand-file-name (alist-get 'file node)))
          (d (homun-stage-kit-get (list "section" (alist-get 'file node) (alist-get 'heading node))))
          (head (plist-get d :head)))
     (cons (cons (homun-stage-kit--target
                  (propertize (homun-stage-kit--fit (if d (cdr head) "section not found") w) 'face 'shadow)
                  (and head (list 'file file (car head))))
                 (cl-loop for i below n
                          for it = (nth i (plist-get d :items))
                          collect (if it (homun-stage-kit--target
                                          (homun-stage-kit--fit (format " %s" (cdr it)) w)
                                          (list 'file file (car it)) "RET: open at this line")
                                    (make-string w ?\s))))
           nil))))

;;; SVG parts

(defun homun-stage-kit--svg-face (face attr)
  "ATTR of FACE as a colour string, from the theme."
  (let ((c (face-attribute face attr nil t))) (if (stringp c) c (if (eq attr :background) "white" "black"))))

(defun homun-stage-kit--svg-lines (svg rows)
  "The slices of SVG as ROWS strings, from `homun-stage--insert-svg'."
  (with-temp-buffer
    (homun-stage--insert-svg svg)
    (homun-stage-kit--pad (split-string (buffer-string) "\n" t) rows 1)))

(defun homun-stage-kit--svg-part (inst key rows w build text target caption)
  "Lines of an SVG part, ROWS tall, then CAPTION lines.
BUILD makes the image from its width and height in pixels; a frame
that is not graphic gets the TEXT lines.  The slices are kept while
KEY is the same.  The click target is TARGET."
  (let ((graphic (and (fboundp 'widgetry-graphic-p) (widgetry-graphic-p))))
    (if (and (equal (homun-stage-kit--state inst :key) (cons graphic key)) (homun-stage-kit--state inst :lines))
        (homun-stage-kit--state inst :lines)
      (homun-stage-kit--set inst :key (cons graphic key))
      (homun-stage-kit--set
       inst :lines
       (append (mapcar (lambda (l) (homun-stage-kit--target l target))
                       (if graphic
                           (homun-stage-kit--svg-lines (funcall build (* w (frame-char-width)) (* rows (frame-char-height))) rows)
                         (homun-stage-kit--pad (mapcar (lambda (l) (homun-stage-kit--fit l w)) text) rows w)))
               caption)))))

;;; layout

(defun homun-stage-kit--ron-parse (text)
  "Parse the RON TEXT into (NAME . FIELDS).
FIELDS is an alist of (FIELD . VALUE) for named fields, else a list
of values; numbers and strings are themselves."
  (let ((pos 0))
    (cl-labels
        ((ws () (while (and (< pos (length text)) (memq (aref text pos) '(?\s ?\n ?\t ?\r))) (cl-incf pos)))
         (peek () (ws) (and (< pos (length text)) (aref text pos)))
         (at (re) (and (string-match re text pos) (= (match-beginning 0) pos)))
         (ident () (ws) (when (at "[A-Za-z_][A-Za-z0-9_]*") (prog1 (match-string 0 text) (setq pos (match-end 0)))))
         (value ()
           (let ((c (peek)))
             (cond ((null c) (error "RON ends early"))
                   ((and (eq c ?\") (at "\"\\(\\(?:[^\"\\]\\|\\\\.\\)*\\)\""))
                    (prog1 (match-string 1 text) (setq pos (match-end 0))))
                   ((at "-?[0-9][0-9.eE+-]*")
                    (prog1 (string-to-number (match-string 0 text)) (setq pos (match-end 0))))
                   (t (let ((name (or (ident) "")))
                        (if (eq (peek) ?\() (cons name (fields)) (list name)))))))
         (fields ()
           (cl-incf pos)
           (let (out named)
             (while (not (eq (peek) ?\)))
               (let ((save pos) (id (ident)))
                 (if (and id (eq (peek) ?:))
                     (progn (cl-incf pos) (setq named t) (push (cons id (value)) out))
                   (setq pos save) (push (value) out)))
               (when (eq (peek) ?,) (cl-incf pos)))
             (cl-incf pos)
             (ignore named)
             (nreverse out))))
      (let ((v (value))) v))))

(defun homun-stage-kit--layout-tree (ron)
  "The saved layout RON as (area LABEL) or (split AXIS RATIO FIRST SECOND)."
  (let ((v (homun-stage-kit--ron-parse ron)))
    (cl-labels ((conv (n)
                  (pcase (car n)
                    ("Area" (list 'area (let ((k (cadr n))) (cond ((numberp k) (format "%g" k)) ((stringp k) k) (t (car k))))))
                    ("Split" (let ((f (cdr n)))
                               (list 'split (car (alist-get "axis" f nil nil #'equal)) (float (alist-get "ratio" f 0.5 nil #'equal))
                                     (conv (alist-get "first" f nil nil #'equal)) (conv (alist-get "second" f nil nil #'equal)))))
                    (_ (error "Not a saved layout: %s" (car n))))))
      (conv v))))

(defun homun-stage-kit--layout-rects (tree x y w h)
  "The areas of TREE in the box X Y W H: ((LABEL X Y W H) ...)."
  (pcase tree
    (`(area ,label) (list (list label x y w h)))
    (`(split ,axis ,ratio ,a ,b)
     (if (equal axis "Horizontal")
         (append (homun-stage-kit--layout-rects a x y (* w ratio) h)
                 (homun-stage-kit--layout-rects b (+ x (* w ratio)) y (* w (- 1 ratio)) h))
       (append (homun-stage-kit--layout-rects a x y w (* h ratio))
               (homun-stage-kit--layout-rects b x (+ y (* h ratio)) w (* h (- 1 ratio))))))))

(defun homun-stage-kit--layout-svg (tree width height)
  "The SVG of TREE, WIDTH by HEIGHT pixels, in the theme's colours."
  (let ((svg (svg-create width height)) (gap 3)
        (fg (homun-stage-kit--svg-face 'default :foreground)) (shade (homun-stage-kit--svg-face 'shadow :foreground))
        (fill (homun-stage-kit--svg-face 'highlight :background)))
    (pcase-dolist (`(,label ,x ,y ,w ,h) (homun-stage-kit--layout-rects tree 0 0 width height))
      (svg-rectangle svg (+ x gap) (+ y gap) (max 1 (- w gap gap)) (max 1 (- h gap gap)) :rx 4
                     :fill fill :stroke-color shade :stroke-width 1.5)
      (svg-text svg label :x (+ x (/ w 2)) :y (+ y (/ h 2) 4) :text-anchor "middle" :fill fg :font-size 14))
    svg))

(defun homun-stage-kit--layout-text (tree)
  "TREE as an indented outline, one string per node."
  (cl-labels ((walk (n d) (pcase n
                            (`(area ,l) (list (concat (make-string d ?\s) "▢ " l)))
                            (`(split ,axis ,r ,a ,b)
                             (cons (format "%s%s %.0f%%" (make-string d ?\s) (if (equal axis "Horizontal") "│ side by side" "─ stacked") (* 100 r))
                                   (append (walk a (+ d 2)) (walk b (+ d 2))))))))
    (walk tree 0)))

(defun homun-stage-kit--layout-source (node key)
  "Store the text of the node's layout file, read again when it changed."
  (let* ((file (expand-file-name (alist-get 'file node))) (stamp (homun-stage-kit--file-stamp file)) (old (homun-stage-kit-get key)))
    (unless (and old stamp (equal (plist-get old :stamp) stamp))
      (homun-stage-kit-put key (when stamp (list :stamp stamp :ron (with-temp-buffer (insert-file-contents file) (buffer-string))))))))

(homun-stage-kit-define
 "layout" nil
 (lambda (node) (when-let* ((f (alist-get 'file node)))
                  (list (list (list "layout" f) #'homun-stage-kit--layout-source 2))))
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node)) (rows (or (alist-get 'rows node) 8))
          (ron (or (alist-get 'ron node) (plist-get (homun-stage-kit-get (list "layout" (alist-get 'file node))) :ron)))
          (tree (and ron (condition-case nil (homun-stage-kit--layout-tree ron) (error nil))))
          (src (alist-get 'open node)))
     (cons (if (null tree)
               (cons (homun-stage-kit--fit (propertize (if ron "layout unreadable" "no layout file") 'face (if ron 'error 'shadow)) w)
                     (homun-stage-kit--blank (1- rows) w))
             (homun-stage-kit--svg-part inst ron rows w
                                        (lambda (pw ph) (homun-stage-kit--layout-svg tree pw ph))
                                        (homun-stage-kit--layout-text tree)
                                        (and src (list 'file src (alist-get 'line node))) nil))
           nil))))

;;; cycle

(defun homun-stage-kit--cycle-svg (steps width height)
  "The loop diagram of STEPS, each (LABEL SUB): boxes on an ellipse with arrows."
  (let* ((svg (svg-create width height)) (n (length steps))
         (cx (/ width 2.0)) (cy (/ height 2.0)) (rx (* width 0.36)) (ry (* height 0.34))
         (bw (min 170 (* width 0.30))) (bh 46)
         (fg (homun-stage-kit--svg-face 'default :foreground)) (shade (homun-stage-kit--svg-face 'shadow :foreground))
         (fill (homun-stage-kit--svg-face 'highlight :background))
         (pts (cl-loop for i below n for a = (+ (/ float-pi -2) (* 2 float-pi (/ i (float n))))
                       collect (cons (+ cx (* rx (cos a))) (+ cy (* ry (sin a)))))))
    (cl-loop for i below n for (x1 . y1) = (nth i pts) for (x2 . y2) = (nth (% (1+ i) n) pts)
             for dx = (- x2 x1) for dy = (- y2 y1) for len = (max 1.0 (sqrt (+ (* dx dx) (* dy dy))))
             for ux = (/ dx len) for uy = (/ dy len)
             for k = (min (/ (* 0.5 bw) (max 0.01 (abs ux))) (/ (* 0.5 bh) (max 0.01 (abs uy))))
             for sx = (+ x1 (* ux (+ k 4))) for sy = (+ y1 (* uy (+ k 4)))
             for ex = (- x2 (* ux (+ k 6))) for ey = (- y2 (* uy (+ k 6)))
             do (svg-line svg sx sy ex ey :stroke-color shade :stroke-width 2)
             (svg-polygon svg (list (cons ex ey)
                                    (cons (- ex (* 9 ux) (* -4 uy)) (- ey (* 9 uy) (* 4 ux)))
                                    (cons (- ex (* 9 ux) (* 4 uy)) (- ey (* 9 uy) (* -4 ux))))
                          :fill-color shade))
    (cl-loop for (x . y) in pts for (label sub) in steps
             do (svg-rectangle svg (- x (/ bw 2)) (- y (/ bh 2)) bw bh :rx 8 :fill fill :stroke-color shade :stroke-width 1.5)
             (svg-text svg label :x x :y (+ y -4) :text-anchor "middle" :fill fg :font-size 14 :font-weight "bold")
             (when sub (svg-text svg sub :x x :y (+ y 13) :text-anchor "middle" :fill shade :font-size 10)))
    svg))

(homun-stage-kit-define
 "cycle" '(steps)
 (lambda (_node) nil)
 (lambda (inst _now _snap)
   (let* ((node (homun-stage-kit--inst-node inst)) (w (homun-stage-kit--w node)) (rows (or (alist-get 'rows node) 9))
          (items (alist-get 'steps node))
          (steps (mapcar (lambda (s) (list (alist-get 'label s) (alist-get 'sub s))) items))
          (first (car items)))
     (cons (homun-stage-kit--svg-part
            inst steps rows w
            (lambda (pw ph) (homun-stage-kit--cycle-svg steps pw ph))
            (list (mapconcat (lambda (s) (concat (car s) (if (cadr s) (format " (%s)" (cadr s)) ""))) steps " → ")
                  (format "  ↺ back to %s" (car (car steps))))
            (and first (alist-get 'open first) (list 'file (alist-get 'open first) (alist-get 'line first)))
            (list (homun-stage-kit--fit
                   (apply #'concat
                          (cl-loop for s in items
                                   collect (homun-stage-kit--target
                                            (propertize (format " %s " (alist-get 'label s)) 'face 'shadow)
                                            (and (alist-get 'open s) (list 'file (alist-get 'open s) (alist-get 'line s))))
                                   collect " → "))
                   w)))
           nil))))

(provide 'homun-stage-kit-parts)
;;; homun-stage-kit-parts.el ends here
