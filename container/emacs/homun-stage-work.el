;;; homun-stage-work.el --- The `work-map' scene, live from the todo org and the agent store -*- lexical-binding: t -*-

;; The main session's todo org (one item per STRT/WAIT/TODO heading, plus the agents that
;; ended lately) and the agent store (`claude-links') give each item its state; the meter is
;; done/total.  A file-notify watch on both (debounced) calls `homun-stage-work-sync': the same
;; planets only patch (moved, recoloured); changed planets show the scene again.  Nothing polls.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'claude-todos)
(require 'claude-links)
(require 'homun-stage-store)
(require 'homun-stage-anim)
(require 'homun-stage-live)

(defconst homun-stage-work-id "work-map")
(defvar homun-stage-work-recent 3600 "Seconds a finished agent stays on the map.")
(defvar homun-stage-work-max 16 "Most nodes on the map; the newest listed stay.")
(defvar homun-stage-work-delay 1.0 "Seconds a change waits for more before the map syncs.")
(defvar homun-stage-work--timer nil)
(defvar homun-stage-work--watches nil)

(defun homun-stage-work--state (keyword agent)
  "Node state of the todo KEYWORD, overridden by the store row AGENT while it runs
or failed."
  (let ((st (and agent (alist-get 'status agent))))
    (cond ((equal st "running") "running") ((equal st "failed") "failed")
          ((equal keyword "STRT") "running") ((equal keyword "WAIT") "wait")
          ((equal keyword "FAILED") "failed")
          ((equal keyword "DONE") "done")
          (t "todo"))))

(defun homun-stage-work-running ()
  "The agents running now, as the board lists them: task plists (:id :desc).
The one source of what runs; the todo org and the links store only label it."
  (require 'claude-agent)
  (seq-filter (lambda (task) (eq (plist-get task :kind) 'agent))
              (claude-agent-tasks--list)))

(defun homun-stage-work--todo-items (file now)
  "The (ID LABEL STATE SECTION AGENT) of the todo FILE: open headings and the
lately ended agents."
  (let (section out)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (while (not (eobp))
          (cond ((looking-at "\\* \\(.+\\)") (setq section (match-string 1)))
                ((looking-at "\\*\\* \\(TODO\\|STRT\\|WAIT\\|DONE\\|FAILED\\) \\(.+\\)")
                 (let* ((kw (match-string 1)) (label (match-string 2))
                        (id nil)
                        (agent (save-excursion
                                 (forward-line 1)
                                 (when (re-search-forward "^:AGENT: \\[\\[homun-agent:\\([^]]+\\)\\]\\]"
                                                          (save-excursion (or (re-search-forward "^\\*" nil t) (point-max)))
                                                          t)
                                   (claude-links-row (setq id (match-string 1))))))
                        (end (alist-get 'end agent)))
                   (when (or (member kw '("TODO" "STRT" "WAIT"))
                             (and end (< (- now end) homun-stage-work-recent)))
                     (push (list (format "n%d" (length out)) label (homun-stage-work--state kw agent) section
                                 id)
                           out)))))
          (forward-line 1))))
    (nreverse out)))

(defun homun-stage-work--items (file now)
  "The (ID LABEL STATE SECTION AGENT) of the map.  Every running agent is there,
in state running, whether or not a todo heading or a link names it; the todo
FILE adds labels, open headings and the lately ended agents.  Over
`homun-stage-work-max' the oldest rows that do not run go."
  (let* ((live (homun-stage-work-running))
         (running (mapcar (lambda (task) (plist-get task :id)) live))
         (items (mapcar (lambda (it)
                          (if (member (nth 4 it) running)
                              (append (seq-take it 2) (list "running") (nthcdr 3 it))
                            it))
                        (homun-stage-work--todo-items file now)))
         (known (delq nil (mapcar (lambda (it) (nth 4 it)) items))))
    (dolist (task live)
      (unless (member (plist-get task :id) known)
        (setq items (append items (list (list "" (or (plist-get task :desc) (plist-get task :id))
                                              "running" "Agents" (plist-get task :id)))))))
    (let ((excess (- (length items) homun-stage-work-max)))
      (setq items (seq-remove (lambda (it) (and (> excess 0) (not (equal (nth 2 it) "running"))
                                                (cl-decf excess)))
                              items)))
    (cl-loop for it in items for i from 0 collect (cons (format "n%d" i) (cdr it)))))

;; Scene: an orrery.  The manager is the sun; each item is a planet on an orbit by urgency (running or
;; failed inner, waiting on Cal middle, todo outer, done small on the outer), its angle from a hash
;; of its id.  A change of state or orbit only patches: positions tween once, nothing runs while idle.

(defconst homun-stage-work--cx 200)
(defconst homun-stage-work--cy 170)

(defun homun-stage-work--short (label)
  "LABEL cut to its first three words."
  (string-join (seq-take (split-string label) 3) " "))

(defun homun-stage-work--look (state)
  "(ORBIT RADIUS FILL OPACITY) of a planet in STATE."
  (pcase state
    ("running" '(60 9 "accent" 1.0))
    ("failed" '(60 11 "err" 1.0))
    ("wait" '(110 9 "warn" 1.0))
    ("done" '(155 5 "ok" 1.0))
    (_ '(155 7 "fg" 0.4))))

(defun homun-stage-work--ids (items)
  "ITEMS as ((ID LABEL STATE) ...), the id a short hash of the label, made unique."
  (let (seen)
    (cl-loop for it in items
             for base = (substring (md5 (cadr it)) 0 6)
             for n = (cl-count base seen :test #'equal)
             do (push base seen)
             collect (list (if (> n 0) (format "%s%d" base n) base) (cadr it) (caddr it)))))

(defun homun-stage-work--planet (id label state)
  "The shape nodes of one planet: its circle, and its LABEL outside it unless done."
  (pcase-let* ((`(,orbit ,r ,fill ,opacity) (homun-stage-work--look state))
               (a (* 2 float-pi (/ (string-to-number (substring id 0 5) 16) (float #xfffff))))
               (x (+ homun-stage-work--cx (* orbit (cos a))))
               (y (+ homun-stage-work--cy (* orbit (sin a)))))
    `(((type . "shape") (kind . "circle") (id . ,(concat "p" id)) (x . ,(round x)) (y . ,(round y))
       (r . ,r) (fill . ,fill) (opacity . ,opacity))
      ,@(unless (equal state "done")
          (let* ((text (homun-stage-work--short label)) (d (+ r 5))
                 (lx (+ x (* d (cos a)))) (ly (+ y (* d (sin a)))))
            `(((type . "shape") (kind . "text") (id . ,(concat "l" id)) (text . ,text) (size . 12)
               (x . ,(round (if (< (cos a) 0) (- lx (* 6.5 (length text))) lx)))
               (y . ,(round (- ly 6)))
               (fill . ,(pcase state ("failed" "err") ("wait" "warn") (_ "fg"))))))))))

(declare-function claude-board--usage "claude-board" ())

(defun homun-stage-work--budget ()
  "(FIVE SEVEN) plan usage percents of the newest sample, the board's source, or
nil."
  (when (fboundp 'claude-board--usage)
    (when-let* ((u (claude-board--usage))) (list (nth 0 u) (nth 2 u)))))

(defun homun-stage-work--text (id x y text &optional size opacity)
  `((type . "shape") (kind . "text") (id . ,id) (x . ,x) (y . ,y) (text . ,text) (size . ,(or size 11))
    (opacity . ,(or opacity 0.6))))

(defun homun-stage-work--root (items)
  "The scene root for ITEMS."
  (let* ((items (homun-stage-work--ids items))
         (done (cl-count "done" items :key #'caddr :test #'equal))
         (cx homun-stage-work--cx) (cy homun-stage-work--cy) (budget (homun-stage-work--budget)))
    `((type . "col")
      (children
       ((type . "layer")
        (children
         ,@(cl-loop for (r o) in '((60 0.25) (110 0.2) (155 0.15)) collect
                    `((type . "shape") (kind . "circle") (x . ,cx) (y . ,cy) (r . ,r) (stroke . "fg")
                      (opacity . ,o)))
         ((type . "shape") (kind . "circle") (x . ,cx) (y . ,cy) (r . 22) (fill . "warn"))
         ((type . "shape") (kind . "text") (x . 183) (y . 161) (text . "manager") (size . 11) (fill . "bg"))
         ,@(cl-loop for (id label state) in items append (homun-stage-work--planet id label state))
         ,(homun-stage-work--text "g1" 385 20 "inner orbit = urgent")
         ,(homun-stage-work--text "g2" 385 38 "red blocking · blue building")
         ,(homun-stage-work--text "g3" 385 56 "amber waits on you · green done")
         ,@(cl-loop for (id pct name y) in `(("b5" ,(car budget) "5h" 290) ("b7" ,(cadr budget) "7d" 308))
                    collect (homun-stage-work--text id 385 y (format "%s budget %s" name (if pct (format "%2d%%" (round pct)) "?")) 12 1.0))))
       ((type . "meter") (id . "m") (value . ,(if items (/ (float done) (length items)) 0.0))
        (label . ,(format "today %d of %d" done (length items))))))))

(defun homun-stage-work--nodes (root)
  "The alist of id to node of every node of ROOT that has an id."
  (let (out)
    (cl-labels ((walk (n) (when-let* ((id (alist-get 'id n))) (push (cons id n) out))
                  (dolist (c (alist-get 'children n)) (walk c))))
      (walk root))
    out))

(defun homun-stage-work--ops (old new)
  "Patch ops from the scene root OLD to NEW (same ids): x and y tween, the meter
value tweens, the rest set."
  (let ((o (homun-stage-work--nodes old)) ops)
    (pcase-dolist (`(,id . ,n) (homun-stage-work--nodes new))
      (pcase-dolist (`(,k . ,v) n)
        (let ((was (alist-get k (alist-get id o nil nil #'equal))))
          (unless (or (memq k '(id type kind)) (equal was v))
            (push `((path . ,(format "/%s/%s" id k))
                    ,(if (memq k '(x y value)) `(animate (to . ,v) (ms . 800) (ease . "out")) `(set . ,v)))
                  ops)))))
    (nreverse ops)))

(defun homun-stage-work--ids-of (root)
  "The ids of ROOT's nodes, sorted: a different list means planets came or went."
  (sort (mapcar #'car (homun-stage-work--nodes root)) #'string<))

(defun homun-stage-work-sync ()
  "Bring the scene `work-map' in line with the todo org and the store."
  (setq homun-stage-work--timer nil)
  (let* ((items (homun-stage-work--items (claude-todos-file) (float-time)))
         (new (homun-stage-work--root items))
         (s (gethash homun-stage-work-id homun-stage-scenes))
         (old (and s (homun-stage-scene-root s))))
    (cond ((or (null old) (null (homun-stage--find old "m"))
               (not (equal (homun-stage-work--ids-of old) (homun-stage-work--ids-of new))))
           (homun-stage-show "manager" homun-stage-work-id "What's in flight" new "pinned"))
          ((setq items (homun-stage-work--ops old new))
           (homun-stage-patch "manager" homun-stage-work-id items)))))

(defun homun-stage-work--later (&rest _)
  (unless homun-stage-work--timer
    (setq homun-stage-work--timer (run-at-time homun-stage-work-delay nil #'homun-stage-work-sync))))

(defun homun-stage-work-start ()
  "Watch the todo directory and the store; sync now."
  (unless (cl-some #'file-notify-valid-p homun-stage-work--watches)
    (setq homun-stage-work--watches
          (cl-loop for dir in (list claude-todos-dir (file-name-directory claude-links-file))
                   when (file-directory-p dir)
                   collect (file-notify-add-watch dir '(change) #'homun-stage-work--later))))
  (homun-stage-work--later))

(provide 'homun-stage-work)
;;; homun-stage-work.el ends here
