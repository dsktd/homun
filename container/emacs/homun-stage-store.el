;;; homun-stage-store.el --- Stage scenes: the store, patches, ownership, the buffers -*- lexical-binding: t -*-

;; The scenes agents show on the Stage, one per id, kept in `homun-stage-scenes' and in
;; `homun-stage-dir'/<id>.json so they survive an Emacs restart.  Every change is refused
;; whole or applied whole: a refusal signals `homun-stage-refused' with (ERROR FIELD LIMIT),
;; which the API answers as {error, field, limit}; a tree the validator refuses signals
;; `homun-stage-invalid' (FIELD MESSAGE).  Nothing is drawn before a change is accepted.
;;
;; Patch paths are by id: /<node-id>, /<node-id>/<field>, /<node-id>/<list>/<item-id> and
;; /<node-id>/<list>/<item-id>/<field>; an item id of `-' appends.  Only the scene's owner
;; role patches or closes it; the role "cal" may close or pin any scene.

(require 'homun-layout)
(require 'cl-lib)
(require 'homun-proc)
(require 'json)
(require 'subr-x)
(require 'homun-stage)
(require 'homun-menu)
(require 'homun-button)
(defvar touch-screen-delay)

(define-error 'homun-stage-refused "Stage call refused")

(defvar homun-stage-dir (expand-file-name "~/claude/.homun/state/stage/")
  "Where every open scene is kept as <id>.json; closed ones go to closed/.")

(defconst homun-stage-lifetimes '("turn" "ephemeral" "pinned" "system"))
(defconst homun-stage-max-bytes (* 256 1024) "Largest scene, as JSON.")
(defconst homun-stage-max-nodes 2000)
(defconst homun-stage-max-ops 64 "Ops in one patch.")
(defconst homun-stage-max-rate 20 "Patches per second per scene.")
(defconst homun-stage-max-tabs 6 "Open scenes; the least recently used turn scene goes first.")
(defconst homun-stage-max-log 100 "Patches kept per scene.")

(cl-defstruct (homun-stage-scene (:constructor homun-stage-scene--make) (:copier nil))
  id owner session title lifetime stale-ms (version 0) root patches (used 0.0) recent render-ms)

(defvar homun-stage-scenes (make-hash-table :test #'equal) "Scene id to its `homun-stage-scene'.")

(defun homun-stage--refuse (error field &optional limit)
  (signal 'homun-stage-refused (list error field limit)))

(defun homun-stage-scene (id)
  "The open scene ID, else refuse."
  (or (gethash id homun-stage-scenes) (homun-stage--refuse "no such scene" "id")))

(defun homun-stage--may (caller scene)
  (unless (or (equal caller "cal") (equal caller (homun-stage-scene-owner scene)))
    (homun-stage--refuse "not owner" "id")))

;;; JSON

(defun homun-stage-parse (text)
  "TEXT as scene data: objects as alists, arrays as lists, false as :false."
  (json-parse-string text :object-type 'alist :array-type 'list :null-object nil :false-object :false))

(defun homun-stage--jsonable (x)
  (cond ((eq x :false) :json-false)
        ((and (consp x) (symbolp (car x)) (car x)) (cons (car x) (homun-stage--jsonable (cdr x))))
        ((consp x) (mapcar #'homun-stage--jsonable x))
        (t x)))

(defun homun-stage-encode (x) (json-encode (homun-stage--jsonable x)))

(defun homun-stage--count (node)
  "Nodes in the tree NODE."
  (1+ (cl-loop for (_ . v) in node
               when (and (consp v) (consp (car v)) (consp (caar v)))
               sum (cl-loop for c in v when (and (consp c) (assq 'type c)) sum (homun-stage--count c)))))

(defun homun-stage--check-tree (root)
  (when (> (string-bytes (homun-stage-encode root)) homun-stage-max-bytes)
    (homun-stage--refuse "scene too large" "root" "max_bytes"))
  (when (> (homun-stage--count root) homun-stage-max-nodes)
    (homun-stage--refuse "too many nodes" "root" "max_nodes"))
  (homun-stage-validate root))

;;; Paths and ops

(defun homun-stage--obj-p (x) (and (consp x) (consp (car x)) (symbolp (caar x))))

(defun homun-stage--find (node id)
  "The node with ID in the tree NODE, and its parent's list cell: (NODE . CELL)."
  (if (equal (alist-get 'id node) id) (cons node nil)
    (cl-loop for cell in node
             thereis (and (consp (cdr cell)) (homun-stage--obj-p (cadr cell))
                          (cl-loop for c in (cdr cell)
                                   thereis (if (and (homun-stage--obj-p c) (equal (alist-get 'id c) id))
                                               (cons c cell)
                                             (and (homun-stage--obj-p c) (assq 'type c)
                                                  (homun-stage--find c id))))))))

(defun homun-stage--put (obj key value)
  "Set KEY of the alist OBJ to VALUE in place."
  (if-let* ((cell (assq key obj))) (setcdr cell value) (nconc obj (list (cons key value)))))

(defun homun-stage--drop (obj key)
  "Remove KEY from the alist OBJ in place (OBJ keeps at least one key)."
  (when-let* ((cell (assq key obj)))
    (if (and (eq (car obj) cell) (cdr obj))
        (progn (setcar obj (cadr obj)) (setcdr obj (cddr obj)))
      (delq cell obj))))

(defun homun-stage--replace (obj new)
  (setcar obj (car new)) (setcdr obj (cdr new)))

(defun homun-stage--apply (root op i)
  "Apply the I'th OP to ROOT (a private copy) in place."
  (let* ((field (format "ops/%d" i))
         (path (alist-get 'path op))
         (verbs (cl-remove-if-not (lambda (k) (assq k op)) '(set insert remove animate)))
         (verb (car verbs))
         (value (pcase verb
                  ('animate (let ((a (alist-get 'animate op)))
                              (unless (and (homun-stage--obj-p a) (assq 'to a))
                                (homun-stage--refuse "animate needs to" (concat field "/animate")))
                              (alist-get 'to a)))
                  (_ (alist-get verb op))))
         (segs (and (stringp path) (string-prefix-p "/" path) (split-string (substring path 1) "/"))))
    (unless (= 1 (length verbs))
      (homun-stage--refuse "one of set, insert, remove, animate" field))
    (unless (and segs (<= (length segs) 4) (cl-notany #'string-empty-p segs))
      (homun-stage--refuse "bad path" (concat field "/path")))
    (let* ((at (lambda (n) (concat "/" (string-join (take n segs) "/"))))
           (hit (or (homun-stage--find root (nth 0 segs)) (homun-stage--refuse "no such node" (funcall at 1))))
           (node (car hit)) (key (and (nth 1 segs) (intern (nth 1 segs)))))
      (pcase (length segs)
        (1 (pcase verb
             ((or 'set 'animate)
              (unless (homun-stage--obj-p value) (homun-stage--refuse "not an object" field))
              (homun-stage--replace node (copy-tree value)))
             ('remove (let ((cell (or (cdr hit) (homun-stage--refuse "the root stays" (funcall at 1)))))
                        (setcdr cell (delq node (cdr cell)))))
             (_ (homun-stage--refuse "insert needs a list path" (funcall at 1)))))
        (2 (pcase verb
             ('remove (homun-stage--drop node key))
             ('insert (homun-stage--refuse "insert needs a list path" (funcall at 2)))
             (_ (homun-stage--put node key (copy-tree value)))))
        (_ (let* ((cell (assq key node))
                  (_ (unless (and cell (listp (cdr cell))) (homun-stage--refuse "no such list" (funcall at 2))))
                  (item-id (nth 2 segs))
                  (item (unless (equal item-id "-")
                          (or (cl-find-if (lambda (x) (and (homun-stage--obj-p x) (equal (alist-get 'id x) item-id)))
                                          (cdr cell))
                              (homun-stage--refuse "no such item" (funcall at 3))))))
             (if (= (length segs) 3)
                 (pcase verb
                   ('insert (let ((new (copy-tree value)))
                              (setcdr cell (if item
                                               (let ((pos (cl-position item (cdr cell))))
                                                 (append (take pos (cdr cell)) (list new) (nthcdr pos (cdr cell))))
                                             (append (cdr cell) (list new))))))
                   ('remove (unless item (homun-stage--refuse "nothing to remove" (funcall at 3)))
                            (setcdr cell (delq item (cdr cell))))
                   (_ (unless item (homun-stage--refuse "use insert to append" (funcall at 3)))
                      (unless (homun-stage--obj-p value) (homun-stage--refuse "not an object" field))
                      (homun-stage--replace item (copy-tree value))))
               (unless item (homun-stage--refuse "no such item" (funcall at 3)))
               (let ((k (intern (nth 3 segs))))
                 (pcase verb
                   ('remove (homun-stage--drop item k))
                   ('insert (homun-stage--refuse "insert needs a list path" (funcall at 4)))
                   (_ (homun-stage--put item k (copy-tree value))))))))))))

(defun homun-stage-apply-ops (root ops)
  "A new tree: ROOT with OPS applied, all or none; ROOT is not changed."
  (unless (and (listp ops) ops) (homun-stage--refuse "ops: a non-empty list" "ops"))
  (when (> (length ops) homun-stage-max-ops) (homun-stage--refuse "too many ops" "ops" "max_ops"))
  (let ((copy (copy-tree root)))
    (cl-loop for op in ops for i from 0
             do (unless (homun-stage--obj-p op) (homun-stage--refuse "not an object" (format "ops/%d" i)))
             (homun-stage--apply copy op i))
    (homun-stage--check-tree copy)))

;;; The homund backend

(defcustom homun-stage-backend 'local
  "Where the scenes are kept: `homund' (`homund stage', which this store subscribes
to) or `local' (this file's own store, the fallback kept for one release)."
  :type '(choice (const local) (const homund))
  :group 'homun-layout)

(defvar homun-stage--subscription nil "The `homund stage subscribe' process.")

(defun homun-stage--homund-p ()
  (and (eq homun-stage-backend 'homund) (executable-find "homund") t))

(defun homun-stage--homund (stdin &rest args)
  "Run `homund stage' ARGS with STDIN as JSON text; the reply as an alist.
A refusal ({error, field, limit}, exit 1) signals `homun-stage-refused'."
  (with-temp-buffer
    (let* ((coding-system-for-write 'utf-8) (coding-system-for-read 'utf-8)
           (process-environment (cons (concat "HOMUN_STAGE=" (directory-file-name homun-stage-dir))
                                      process-environment))
           (result (homun-proc-sync "homund" (cons "stage" args) stdin))
           (status (car result))
           (reply (homun-stage-parse (if (string-empty-p (cdr result)) "{}" (cdr result)))))
      (if (eql status 0) reply
        (homun-stage--refuse (or (alist-get 'error reply) "homund stage failed")
                             (alist-get 'field reply) (alist-get 'limit reply))))))

(defun homun-stage--sync (&optional id)
  "Make `homun-stage-scenes' match the files of `homun-stage-dir' (only ID when
given).
A scene that is gone loses its buffer; one that changed is drawn again."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (file (if id (list (homun-stage--file id))
                    (and (file-directory-p homun-stage-dir) (directory-files homun-stage-dir t "\\.json\\'"))))
      (when-let* ((s (homun-stage--read file)))
        (puthash (homun-stage-scene-id s) t seen)
        (let ((old (gethash (homun-stage-scene-id s) homun-stage-scenes)))
          (unless (and old (eql (homun-stage-scene-version old) (homun-stage-scene-version s)))
            (when old (setf (homun-stage-scene-recent s) (homun-stage-scene-recent old)))
            (puthash (homun-stage-scene-id s) s homun-stage-scenes)
            (when (get-buffer (homun-stage-buffer-name (homun-stage-scene-id s)))
              (homun-stage-render s))))))
    (dolist (gone (cl-remove-if (lambda (k) (or (gethash k seen) (and id (not (equal k id)))))
                                (hash-table-keys homun-stage-scenes)))
      (remhash gone homun-stage-scenes)
      (when-let* ((b (get-buffer (homun-stage-buffer-name gone)))) (homun-stage--forget b)))))

(defun homun-stage--event (_proc output)
  "Filter of the subscription: each envelope line of OUTPUT is a scene that
changed."
  (dolist (line (split-string output "\n" t))
    (when-let* ((e (ignore-errors (homun-stage-parse line)))
                (body (alist-get 'body e)))
      (with-demoted-errors "homun-stage: %S" (homun-stage--sync (alist-get 'id body))))))

(defun homun-stage-subscribe ()
  "Follow `homund stage subscribe': the store mirrors every change made anywhere."
  (interactive)
  (when (and (homun-stage--homund-p) (not (process-live-p homun-stage--subscription)))
    (let ((process-environment (cons (concat "HOMUN_STAGE=" (directory-file-name homun-stage-dir))
                                     process-environment)))
      (setq homun-stage--subscription
            (make-process :name "homun-stage" :command '("homund" "stage" "subscribe")
                          :connection-type 'pipe :noquery t :filter #'homun-stage--event
                          :stderr (get-buffer-create " *homun-stage-err*"))))))

;;; Persistence

(defun homun-stage--file (id &optional closed)
  (expand-file-name (concat id ".json") (if closed (expand-file-name "closed" homun-stage-dir) homun-stage-dir)))

(defun homun-stage--alist (s)
  `((id . ,(homun-stage-scene-id s)) (owner_role . ,(homun-stage-scene-owner s))
    (session . ,(homun-stage-scene-session s)) (title . ,(homun-stage-scene-title s))
    (lifetime . ,(homun-stage-scene-lifetime s)) (stale_ms . ,(homun-stage-scene-stale-ms s))
    (version . ,(homun-stage-scene-version s)) (used . ,(homun-stage-scene-used s))
    (root . ,(homun-stage-scene-root s)) (patches . ,(vconcat (homun-stage-scene-patches s)))))

(defun homun-stage--write (s &optional closed)
  (let ((file (homun-stage--file (homun-stage-scene-id s) closed)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'utf-8))
      (write-region (homun-stage-encode (homun-stage--alist s)) nil (concat file ".tmp") nil 'silent))
    (rename-file (concat file ".tmp") file t)))

(defun homun-stage--read (file)
  "The scene stored in FILE, or nil."
  (when-let* ((a (ignore-errors
                   (homun-stage-parse (with-temp-buffer (insert-file-contents file) (buffer-string))))))
    (homun-stage-scene--make
     :id (alist-get 'id a) :owner (alist-get 'owner_role a) :session (alist-get 'session a)
     :title (alist-get 'title a) :lifetime (alist-get 'lifetime a)
     :stale-ms (alist-get 'stale_ms a) :version (alist-get 'version a)
     :used (or (alist-get 'used a) 0.0) :root (alist-get 'root a)
     :patches (alist-get 'patches a))))

(defun homun-stage-load ()
  "Read every open scene of `homun-stage-dir' into `homun-stage-scenes'."
  (clrhash homun-stage-scenes)
  (dolist (file (and (file-directory-p homun-stage-dir)
                     (directory-files homun-stage-dir t "\\.json\\'")))
    (when-let* ((s (homun-stage--read file)))
      (puthash (homun-stage-scene-id s) s homun-stage-scenes)))
  (homun-stage-subscribe))

;;; The calls

(defun homun-stage--lru ()
  (sort (hash-table-values homun-stage-scenes)
        (lambda (a b) (< (homun-stage-scene-used a) (homun-stage-scene-used b)))))

(defun homun-stage--make-room (id)
  "Close the least recently used turn or ephemeral scene when a new ID would pass
the cap."
  (when (and (not (gethash id homun-stage-scenes))
             (>= (hash-table-count homun-stage-scenes) homun-stage-max-tabs))
    (let ((old (or (cl-find-if (lambda (s) (member (homun-stage-scene-lifetime s) '("turn" "ephemeral")))
                               (homun-stage--lru))
                   (homun-stage--refuse "too many pinned or system scenes" "id" "max_tabs"))))
      (homun-stage--close old))))

(defvar homun-stage-shown-hook nil "Run with the scene after `homun-stage-show' stored it.")

(defun homun-stage-show (caller id title root &optional lifetime stale-ms session)
  "Create or replace the scene ID for CALLER; return its version."
  (unless (and (stringp id) (string-match-p "\\`[a-z0-9][a-z0-9_-]\\{0,63\\}\\'" id))
    (homun-stage--refuse "id: [a-z0-9][a-z0-9_-]*, at most 64" "id"))
  (let ((lifetime (or lifetime "turn")) (old (gethash id homun-stage-scenes)))
    (unless (member lifetime homun-stage-lifetimes) (homun-stage--refuse "unknown lifetime" "lifetime"))
    (when old (homun-stage--may caller old))
    (condition-case e (homun-stage--check-tree root)
      (homun-stage-invalid (signal (car e) (cons (concat "root" (cadr e)) (cddr e)))))
    (if (homun-stage--homund-p)
        (let ((v (alist-get 'version (homun-stage--homund (homun-stage-encode root) "store" caller id
                                                          (or title "") lifetime))))
          (homun-stage--sync)
          (let ((s (homun-stage-scene id)))
            (setf (homun-stage-scene-session s) session (homun-stage-scene-stale-ms s) stale-ms)
            (homun-stage-render s)
            (run-hook-with-args 'homun-stage-shown-hook s))
          v)
    (homun-stage--make-room id)
    (let ((s (homun-stage-scene--make
              :id id :owner (if old (homun-stage-scene-owner old) caller) :session session :title title
              :lifetime lifetime :stale-ms stale-ms :root root :used (float-time)
              :version (1+ (if old (homun-stage-scene-version old) 0))
              :patches (and old (homun-stage-scene-patches old)))))
      (homun-stage--log s `((show . t) (root . ,root) (version . ,(homun-stage-scene-version s))))
      (puthash id s homun-stage-scenes)
      (homun-stage--write s)
      (homun-stage-render s)
      (run-hook-with-args 'homun-stage-shown-hook s)
      (homun-stage-scene-version s)))))

;; An entry with a `root' is the state after it; the oldest entry always has one, so the log
;; can be scrubbed: an entry dropped off the front is folded into its successor's root.
(defun homun-stage--log (s entry)
  (let ((log (append (homun-stage-scene-patches s)
                     (list (append entry `((version . ,(1+ (homun-stage-scene-version s))) (ts . ,(float-time))))))))
    (while (> (length log) homun-stage-max-log)
      (let ((old (pop log)) (next (car log)))
        (when (and (alist-get 'root old) (not (alist-get 'root next)) (alist-get 'ops next))
          (setcar log (append next `((root . ,(ignore-errors
                                                 (homun-stage-apply-ops (alist-get 'root old) (alist-get 'ops next))))))))))
    (setf (homun-stage-scene-patches s) log)))

(defun homun-stage-root-at (s version)
  "The root of the scene S as it was after VERSION, or nil when the log no longer
reaches it."
  (let ((log (homun-stage-scene-patches s)) root)
    (while (and log (<= (alist-get 'version (car log)) version))
      (let ((e (pop log)))
        (cond ((alist-get 'root e) (setq root (alist-get 'root e)))
              ((and root (alist-get 'ops e)) (setq root (homun-stage-apply-ops root (alist-get 'ops e)))))))
    root))

(defun homun-stage-log-versions (s)
  "The versions the log of the scene S can show, oldest first."
  (cl-loop for e in (homun-stage-scene-patches s)
           when (or (alist-get 'root e) (alist-get 'ops e)) collect (alist-get 'version e)))

(cl-defun homun-stage-patch (caller id ops &optional if-version)
  "Apply OPS to the scene ID for CALLER, all or none; return the new version."
  (let* ((s (homun-stage-scene id)) (now (float-time)))
    (homun-stage--may caller s)
    (when (and if-version (/= if-version (homun-stage-scene-version s)))
      (homun-stage--refuse (format "stale: version is %d" (homun-stage-scene-version s)) "if_version"))
    (let ((recent (cl-remove-if (lambda (t0) (> (- now t0) 1.0)) (homun-stage-scene-recent s))))
      (when (>= (length recent) homun-stage-max-rate)
        (homun-stage--refuse "too many patches" "ops" "patch_rate"))
      (let ((root (homun-stage-apply-ops (homun-stage-scene-root s) ops)))
        (when (homun-stage--homund-p)
          (let ((before (homun-stage-scene-root s)) (recent (cons now recent)))
            (homun-stage--homund (homun-stage-encode ops) "patch" caller id
                                 "if_version" (number-to-string (homun-stage-scene-version s)))
            (homun-stage--sync id)
            (setf (homun-stage-scene-recent (homun-stage-scene id)) recent)
            (homun-stage-anim-start id before ops)
            (homun-stage-render (homun-stage-scene id))
            (cl-return-from homun-stage-patch (homun-stage-scene-version (homun-stage-scene id)))))
        (homun-stage--log s `((ops . ,ops)))
        (homun-stage-anim-start id (homun-stage-scene-root s) ops)
        (setf (homun-stage-scene-root s) root
              (homun-stage-scene-recent s) (cons now recent)
              (homun-stage-scene-used s) now)
        (cl-incf (homun-stage-scene-version s))
        (homun-stage--write s)
        (homun-stage-render s)
        (homun-stage-scene-version s)))))

(defun homun-stage--close (s)
  (when (homun-stage--homund-p)
    (homun-stage--homund nil "close" "cal" (homun-stage-scene-id s)))
  (remhash (homun-stage-scene-id s) homun-stage-scenes)
  (homun-stage--write s t)
  (ignore-errors (delete-file (homun-stage--file (homun-stage-scene-id s))))
  (when-let* ((b (get-buffer (homun-stage-buffer-name (homun-stage-scene-id s)))))
    (homun-stage--forget b)))

(defun homun-stage-close (caller id)
  "Close the scene ID for CALLER: its last state goes to closed/<id>.json."
  (let ((s (homun-stage-scene id)))
    (homun-stage--may caller s)
    (homun-stage--close s)
    id))

(defun homun-stage-pin (caller id &optional off)
  "Pin the scene ID (unpin with OFF, back to a turn scene); the owner or Cal."
  (let ((s (homun-stage-scene id)))
    (homun-stage--may caller s)
    (setf (homun-stage-scene-lifetime s) (if off "turn" "pinned"))
    (if (homun-stage--homund-p)
        (apply #'homun-stage--homund nil "pin" "cal" id (and off '("off")))
      (homun-stage--write s))
    (homun-stage-scene-lifetime s)))

(defun homun-stage-list ()
  "The open scenes, most recently used first, as a list of alists."
  (mapcar (lambda (s)
            `((id . ,(homun-stage-scene-id s)) (title . ,(homun-stage-scene-title s))
              (owner_role . ,(homun-stage-scene-owner s)) (lifetime . ,(homun-stage-scene-lifetime s))
              (version . ,(homun-stage-scene-version s))
              (shown . ,(if (get-buffer-window (homun-stage-buffer-name (homun-stage-scene-id s)) t) t :false))))
          (reverse (homun-stage--lru))))

(defun homun-stage--topics (node)
  (cl-loop for (k . v) in node
           append (cond ((and (homun-stage--obj-p v) (eq (caar v) 'bind) (stringp (cdar v))) (list (cdar v)))
                        ((and (consp v) (homun-stage--obj-p (car v)))
                         (cl-loop for c in v when (homun-stage--obj-p c) append (homun-stage--topics c))))
           into out
           finally return (progn (ignore k) (delete-dups out))))

(defun homun-stage-get (id)
  "The scene ID as an alist: spec, bound values, its text render, size and last
render time."
  (let* ((s (homun-stage-scene id)) (text (homun-stage-text (homun-stage-scene-root s)))
         (buf (get-buffer (homun-stage-buffer-name id))) (win (and buf (get-buffer-window buf t))))
    `((id . ,id) (title . ,(homun-stage-scene-title s)) (owner_role . ,(homun-stage-scene-owner s))
      (lifetime . ,(homun-stage-scene-lifetime s)) (version . ,(homun-stage-scene-version s))
      (root . ,(homun-stage-scene-root s))
      (bound . ,(or (mapcar (lambda (topic) (cons (intern topic) (gethash topic homun-stage-bindings)))
                            (homun-stage--topics (homun-stage-scene-root s)))
                    :json-empty))
      (events . []) (patches . ,(length (homun-stage-scene-patches s)))
      (render_ms . ,(homun-stage-scene-render-ms s))
      (text . ,text)
      (size . ((lines . ,(length (split-string text "\n")))
               (pixels . ,(and win (vector (window-body-width win t) (window-body-height win t)))))))))

;;; The buffers

(defun homun-stage-buffer-name (id) (format "*stage %s*" id))

(defvar-local homun-stage--id nil "The scene this buffer shows.")
(defvar-local homun-stage--callout nil "The focus note shown in the header line.")
(defvar-local homun-stage--scrub nil "The version of the patch log this buffer shows, nil for the live scene.")

(define-derived-mode homun-stage-mode special-mode "Stage"
  "A Stage scene.  k closes it, p pins or unpins it (as Cal)."
  (setq-local cursor-type nil truncate-lines t)
  (when (fboundp 'claude-header) (claude-header "" "k close | p pin | [ ] scrub"))
  (setq header-line-format
        '(:eval (let ((s (gethash homun-stage--id homun-stage-scenes)))
                  (concat " " (propertize (or (and s (homun-stage-scene-title s)) "") 'face 'bold)
                          (if (and s (equal (homun-stage-scene-lifetime s) "pinned")) "  [pinned]" "")
                          (if homun-stage--scrub (format "  [v%d; ] for newer]" homun-stage--scrub) "")
                          (if homun-stage--callout (concat "  ▸ " homun-stage--callout) ""))))))

(define-key homun-stage-mode-map "k" #'homun-stage-close-this)
(define-key homun-stage-mode-map "p" #'homun-stage-pin-this)
(define-key homun-stage-mode-map "?" #'homun-menu-stage)
(define-key homun-stage-mode-map "[" #'homun-stage-scrub-back)
(define-key homun-stage-mode-map "]" #'homun-stage-scrub-forward)

(defun homun-stage-scrub (delta)
  "Show the scene of this buffer DELTA patches back (negative) or forward in its
log.
Going past the newest patch shows the live scene again."
  (let* ((s (homun-stage-scene homun-stage--id)) (vs (homun-stage-log-versions s))
         (cur (or homun-stage--scrub (homun-stage-scene-version s)))
         (i (or (cl-position cur vs :test #'>=  :from-end t) (1- (length vs))))
         (j (+ i delta)))
    (setq homun-stage--scrub (and (< j (1- (length vs))) (nth (max j 0) vs)))
    (homun-stage-render s)
    homun-stage--scrub))

(defun homun-stage-scrub-back () "Step back through the patch log." (interactive) (homun-stage-scrub -1))
(defun homun-stage-scrub-forward () "Step forward through the patch log." (interactive) (homun-stage-scrub 1))

(defun homun-stage-close-this ()
  "Close the scene of this buffer."
  (interactive)
  (homun-stage-close "cal" homun-stage--id))

(defun homun-stage-pin-this ()
  "Pin the scene of this buffer, or unpin a pinned one."
  (interactive)
  (let ((s (homun-stage-scene homun-stage--id)))
    (homun-stage-pin "cal" homun-stage--id (equal (homun-stage-scene-lifetime s) "pinned"))
    (force-mode-line-update)))

(defun homun-stage--line-col (pos)
  "POS as (LINE . COLUMN)."
  (save-excursion (goto-char pos) (cons (line-number-at-pos) (current-column))))

(defun homun-stage--pos (place)
  "The position of PLACE (LINE . COLUMN), clamped to the buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- (car place)))
    (move-to-column (cdr place))
    (point)))

(defmacro homun-stage--keeping-view (&rest body)
  "Run BODY, which redraws the buffer, then put point and each window's start and
point back on the same line and column (a scene redraws to the same layout, so
that is the same place); the first draw leaves point at the top."
  (declare (indent 0))
  `(let ((places (mapcar (lambda (w)
                           (list w (homun-stage--line-col (window-start w))
                                 (homun-stage--line-col (window-point w))
                                 (window-vscroll w t)))
                         (get-buffer-window-list nil nil t)))
         (here (and (> (buffer-size) 0) (homun-stage--line-col (point)))))
     ,@body
     (goto-char (if here (homun-stage--pos here) (point-min)))
     (pcase-dolist (`(,w ,start ,pt ,vscroll) places)
       (when (window-live-p w)
         (set-window-start w (homun-stage--pos start) t)
         (set-window-vscroll w vscroll t) ; a redraw must not drop the pixel scroll
         (set-window-point w (homun-stage--pos pt))))))

(defvar homun-stage-render-functions nil
  "Abnormal hook run in a scene's buffer after it is drawn, with the scene, at the
end of the text.")

(defun homun-stage-render (s)
  "Draw the scene S into its buffer again; record how long it took."
  (let ((started (float-time))
        (buf (get-buffer-create (homun-stage-buffer-name (homun-stage-scene-id s)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'homun-stage-mode) (homun-stage-mode))
      (setq homun-stage--id (homun-stage-scene-id s))
      (let ((inhibit-read-only t)
            (width (if-let* ((w (get-buffer-window buf t))) (- (window-body-width w t) 8) 600)))
        (homun-stage--keeping-view
          (erase-buffer)
          (homun-stage-insert (if-let* ((v homun-stage--scrub) (r (homun-stage-root-at s v))) r
                                (homun-stage-anim-view (homun-stage-scene-id s) (homun-stage-scene-root s)))
                              width (homun-stage-env))
          (run-hook-with-args 'homun-stage-render-functions s))))
    (setf (homun-stage-scene-render-ms s) (round (* 1000 (- (float-time) started))))
    buf))

(defun homun-stage-display (id)
  "Show the scene ID in the side window without selecting it; return the window."
  (let ((buf (or (get-buffer (homun-stage-buffer-name id)) (homun-stage-render (homun-stage-scene id)))))
    (or (get-buffer-window buf t)
        (and (not noninteractive) (homun-layout-place buf)))))

(defun homun-stage-focus (id &optional node note)
  "Bring the scene ID forward; point at NODE with the callout NOTE."
  (let ((s (homun-stage-scene id)))
    (when (and node (not (homun-stage--find (homun-stage-scene-root s) node)))
      (homun-stage--refuse "no such node" "node"))
    (setf (homun-stage-scene-used s) (float-time))
    (with-current-buffer (homun-stage-render s)
      (setq homun-stage--callout (and (or node note) (string-join (delq nil (list node note)) ": "))))
    (let ((w (homun-stage-display id)))
      (when w (force-mode-line-update t))
      (and w t))))

;;; The stage region's tabs

;; The tab line of the stage region lists the pinned tool tabs (`homun-stage-tools'), then
;; the open scenes, then the pages that set `homun-stage-tab' to their label (the pairing code, the agent view, the idle scene).  Drawn by the built-in tab line, so
;; clicks, hover, close buttons and scrolling are its own; a tool tab has no close button.

(require 'tab-line)

(defvar-local homun-stage-tab nil
  "In a page that is not a scene: the label under which it is a tab of the stage
region.")

(defcustom homun-stage-tools '(questions todos)
  "The tool tabs the stage region always shows, in this
order (`homun-stage-tool-specs').
The tabs before `todos' come ahead of the scenes and pages; `todos' and any tool
after it come last, so the Stage is what the region shows."
  :type '(set (const todos) (const questions))
  :group 'homun-layout)

(declare-function claude-todos "claude-todos")
(declare-function claude-questions--pending "claude-questions")
(defvar claude-todos-view-name)

(defconst homun-stage-tool-specs
  `((todos "todos"
           ,(lambda () (require 'claude-todos) (get-buffer claude-todos-view-name))
           ,(lambda () (require 'claude-todos)
              (save-window-excursion (claude-todos))
              (get-buffer claude-todos-view-name)))
    (questions "questions"
               ,(lambda () (require 'claude-questions) (car (claude-questions--pending)))
               ,(lambda () (require 'claude-questions)
                  (or (car (claude-questions--pending)) (user-error "No pending questions")))))
  "Tool tabs: (NAME LABEL PEEK OPEN).  PEEK returns the live buffer or nil; OPEN
makes it.")

(defun homun-stage-pinned-buffers ()
  "The live buffers of the tool tabs."
  (delq nil (mapcar (lambda (n) (when-let* ((spec (assq n homun-stage-tool-specs))) (funcall (nth 2 spec))))
                    homun-stage-tools)))

(defun homun-stage-label-of (buffer)
  "The tab label of BUFFER: a page's `homun-stage-tab', a scene's title or id."
  (or (buffer-local-value 'homun-stage-tab buffer)
      (when-let* ((id (buffer-local-value 'homun-stage--id buffer)))
        (or (and (gethash id homun-stage-scenes) (homun-stage-scene-title (gethash id homun-stage-scenes)))
            id))
      (buffer-name buffer)))

(defun homun-stage-tab-buffers ()
  "The tabs of the stage region after the tools: the open scenes, then the pages,
by label."
  (let ((pinned (homun-stage-pinned-buffers)))
    (append (delq nil (mapcar (lambda (s) (get-buffer (homun-stage-buffer-name (alist-get 'id s))))
                              (reverse (homun-stage-list))))
            (sort (seq-filter (lambda (b) (and (buffer-local-value 'homun-stage-tab b) (not (memq b pinned))))
                              (buffer-list))
                  (lambda (a b) (string< (homun-stage-label-of a) (homun-stage-label-of b)))))))

(defun homun-stage--resume ()
  "Draw and return the buffer of the scene shown last (its `used' is saved with
it).
A scene never shown comes after one that was: then the newest that is not
ephemeral."
  (when-let* ((scenes (reverse (homun-stage--lru)))
              (s (if (> (homun-stage-scene-used (car scenes)) 0)
                     (car scenes)
                   (or (cl-find-if-not (lambda (s) (equal (homun-stage-scene-lifetime s) "ephemeral"))
                                       scenes)
                       (car scenes)))))
    (homun-stage-render s)))

(defun homun-stage-default-buffer ()
  "The buffer the stage region shows when nothing else asks for it.
The Stage itself: the most recently used scene (drawn again after a restart),
else a read-only one-line placeholder when there is no scene at all."
  (or (car (homun-stage-tab-buffers))
      (homun-stage--resume)
      (homun-layout--placeholder)))

(defun homun-stage--forget (buffer)
  "Kill BUFFER, a tab of the stage region; its windows show another tab first."
  (let ((others (remq buffer (append (homun-stage-pinned-buffers) (homun-stage-tab-buffers)))))
    (dolist (w (get-buffer-window-list buffer nil t))
      (if others (homun-layout-show (car others) w) (homun-layout-close w)))
    (kill-buffer buffer)
    (force-mode-line-update t)))

(defun homun-stage--tab-show (buffer)
  (homun-layout-show buffer (selected-window))
  (force-mode-line-update t))

(defun homun-stage--tabs ()
  "The tabs of the stage region as tab-line alists."
  (let* ((current (window-buffer))
         (tools (seq-filter (lambda (n) (assq n homun-stage-tool-specs)) homun-stage-tools))
         (late (member 'todos tools))
         (tool-tab
          (lambda (n)
               (pcase-let ((`(,_ ,label ,peek ,open) (assq n homun-stage-tool-specs)))
                 `((name . ,(concat " " label " "))
                   (selected . ,(and current (eq (funcall peek) current)))
                   (select . ,(lambda () (when-let* ((b (funcall open))) (homun-stage--tab-show b))))))))
         (early (seq-take tools (- (length tools) (length late)))))
    (append
     (mapcar tool-tab early)
     (mapcar (lambda (b)
               `((name . ,(concat " " (homun-stage-label-of b)))
                 (selected . ,(eq b current))
                 (select . ,(lambda () (when (buffer-live-p b) (homun-stage--tab-show b))))
                 (close . ,(lambda ()
                             (when (buffer-live-p b)
                               (if-let* ((id (buffer-local-value 'homun-stage--id b)))
                                   (homun-stage-close "cal" id)
                                 (homun-stage--forget b)))))))
             (homun-stage-tab-buffers))
     (mapcar tool-tab late))))

(defun homun-stage--tab-name (tab tabs)
  "The tab-line name of TAB as a homun-button tab, the current one active.
The default format supplies the properties tab-line reads (the tab, its keymap
and the close mark)."
  (let* ((s (tab-line-tab-name-format-default tab tabs))
         (end (or (next-single-property-change 0 'keymap s) (length s)))
         (selected (get-text-property 0 'selected s))
         (button (homun-button (string-trim (substring-no-properties s 0 end))
                               (if selected 'tab-active 'tab))))
    (if-let* ((image (get-text-property 0 'display button)))
        (put-text-property 0 end 'display image s)
      (put-text-property 0 end 'face (get-text-property 0 'face button) s))
    s))

;; Emacs 31.1 `tab-line-track-tap' passes t as the repeat of its long-press timer,
;; which `run-at-time' rejects ("Invalid repetition interval: t"): tapping a tab
;; errors.  Same function with a one-shot timer (upstream bug, unreported).
(defun homun-stage--track-tap (event &optional function)
  "Fixed `tab-line-track-tap': track the tap of EVENT; long press calls FUNCTION."
  (if (not (eq (car-safe event) 'touchscreen-begin))
      t
    (let ((result (catch 'context-menu
                    (let ((timer (and function
                                      (run-at-time touch-screen-delay nil
                                                   #'throw 'context-menu 'context-menu))))
                      (unwind-protect (touch-screen-track-tap event)
                        (when timer (cancel-timer timer)))))))
      (cond ((eq result 'context-menu) (prog1 nil (funcall function event)))
            (result t)))))

(advice-add 'tab-line-track-tap :override #'homun-stage--track-tap)

(defun homun-stage-tab-line ()
  "The tab line of the stage region (see `homun-stage--tabs')."
  (let ((tab-line-tabs-function #'homun-stage--tabs)
        (tab-line-tab-name-format-function #'homun-stage--tab-name)
        (tab-line-close-button-show t)
        (tab-line-new-button-show nil)
        (tab-line-separator " "))
    (tab-line-format)))

(homun-stage-load)

(declare-function homun-stage-anim-start "homun-stage-anim")
(declare-function homun-stage-anim-view "homun-stage-anim")
(provide 'homun-stage-store)
(require 'homun-stage-anim)
;;; homun-stage-store.el ends here
