;;; homun-api.el --- The one door into the manager's Emacs for agents -*- coding: utf-8; lexical-binding: t -*-

;; Agents and the CLI never splice Lisp text into `emacsclient --eval'.  They send
;; the constant form (homun-rpc) and put the call in the argument list, which the
;; server hands over in `server-eval-args-left':
;;
;;   emacsclient -s SOCKET --eval '(homun-rpc)' stage list
;;   emacsclient -s SOCKET --eval '(homun-rpc)' buffer peek name '*scratch*' chars 200
;;
;; The first two words name an entry (object verb), the rest are `key value' pairs,
;; checked against the registry before a handler runs.  Every entry is declared with
;; `homun-api-define', which is also what `homun-emacs help' lists.  A call runs
;; under a time limit, its answer is capped, and it is logged on one line.
;;
;; The reply is one string: "ok\nBODY", or "err CODE\nMESSAGE" with CODE one of
;; unknown, invalid, timeout, failed.

(declare-function homun-layout-window "homun-layout")
(declare-function homun-layout-show "homun-layout")
(require 'homun-layout)
(require 'homun-dir)
(require 'cl-lib)
(require 'json)
(require 'server)
(require 'subr-x)
(declare-function claude-click "claude-click")
(declare-function claude-doctor-probe "claude-doctor")
(declare-function claude-doctor-run "claude-doctor")
(declare-function homun-stage-publish "homun-stage-bind")
(declare-function homun-stage-render "homun-stage-store")
(declare-function homun-stage-scene "homun-stage-store")
(declare-function claude-transcript-refresh "claude-transcript")
(defvar homun-stage--id)
(declare-function claude--with-frame "None")
(declare-function claude-ask "claude")
(declare-function claude-ask-timeout "claude")
(declare-function claude-board "claude-board")
(declare-function claude-board--draw "claude-board")
(declare-function claude-board--mains "claude-board")
(declare-function claude-board--row "claude-board")
(declare-function claude-board--tasks "claude-board")
(declare-function claude-board--tree "claude-board")
(declare-function claude-compose--status "claude-compose")
(declare-function claude-diff "claude")
(declare-function claude-doctor "claude-doctor")
(declare-function claude-errwatch-list "claude-errwatch")
(declare-function claude-focus-clear "claude-focus")
(declare-function claude-focus-set "claude-focus")
(declare-function claude-homun--roles "claude-homun")
(declare-function claude-open "claude")
(declare-function claude-pair-phone "claude-pair")
(declare-function claude-pick "claude-pick")
(declare-function claude-questions "claude-questions")
(declare-function claude-questions-reply "claude-questions")
(declare-function claude-questions-show "claude-questions")
(declare-function claude-report "claude")
(declare-function claude-review "claude-review")
(declare-function claude-say "claude")
(declare-function claude-settings "claude-settings")
(declare-function claude-settings--default-of "claude-settings")
(declare-function claude-settings--flush "claude-settings")
(declare-function claude-settings-set "claude-settings")
(declare-function claude-task-detail-set-state "claude-task-detail")
(declare-function claude-task-detail-show-json "claude-task-detail")
(declare-function claude-todos "claude-todos")
(declare-function claude-todos-file "claude-todos")
(declare-function file-notify--watch-absolute-filename "filenotify")
(declare-function file-notify--watch-callback "filenotify")
(declare-function file-notify-valid-p "filenotify")
(declare-function homun-freeze-watch-profiler-lend "homun-freeze-watch")
(declare-function homun-freeze-watch-profiler-reclaim "homun-freeze-watch")
(declare-function homun-stage--refuse "homun-stage-store")
(declare-function homun-stage-close "homun-stage-store")
(declare-function homun-stage-display "homun-stage-store")
(declare-function homun-stage-encode "homun-stage-store")
(declare-function homun-stage-focus "homun-stage-store")
(declare-function homun-stage-get "homun-stage-store")
(declare-function homun-stage-list "homun-stage-store")
(declare-function homun-stage-patch "homun-stage-store")
(declare-function homun-stage-pulse-file "homun-stage-point")
(declare-function homun-stage-show "homun-stage-store")
(declare-function profiler-calltree-build "profiler")
(declare-function profiler-calltree-children "profiler")
(declare-function profiler-calltree-count "profiler")
(declare-function profiler-calltree-entry "profiler")
(defvar claude-compose--outbox)
(defvar claude-settings-groups)
(defvar claude-transcript--turns)
(defvar file-notify-descriptors)
(declare-function x-export-frames "xfns.c")

(defvar homun-api-log-file (expand-file-name "~/claude/.services/emacs/api.log")
  "One line per call.")
(defvar homun-api-log-max 262144 "Bytes after which the log is moved to .1.")
(defvar homun-api-timeout 5 "Seconds a handler may run before the call is cut off.")
(defvar homun-api-result-max 4000 "Characters of an answer that are returned.")

(defvar profiler-sampling-interval)

(defvar homun-api--entries nil "Alist of (NAME . plist), the registry.")
;; never reset: other files register into it, and `homun-api-register' replaces by name

(defvar homun-api-load-roots
  (list (or (getenv "CLAUDE_EMACS_CONF")
            homun-cockpit-dir))
  "Directories `load file' may take a file from: the cockpit's own Elisp (widgetry
is under it).  A host's configuration may add its own.")

(defconst homun-api--own-names "\\`\\(?:claude\\|homun\\|widgetry\\)-"
  "Variables whose whole value an agent may read.")

(defconst homun-api--secret-names "secret\\|token\\|passw\\|credential\\|auth\\|kill-ring"
  "Variables never read.")


;;; Registry

(defun homun-api-register (name doc args handler &rest props)
  "Register NAME (\"object verb\") with DOC, ARGS and HANDLER.
ARGS is a list of (KEY TYPE . PROPS): KEY a symbol, TYPE one of string int bool
symbol enum data json, PROPS among :required, :default, :choices (for enum),
:max
(for int), :hidden (left out of `api schema': the caller argument, which the MCP
server fills in).  PROPS of the entry: :internal t keeps it out of `api
schema' (a CLI verb of claude-emacs, not an MCP tool); :approve a function of
the handler's arguments that returns why Cal must approve this call, or nil to
run it at once."
  (setf (alist-get name homun-api--entries nil nil #'equal)
        (append (list :doc doc :args args :handler handler) props)))

(defmacro homun-api-define (name doc args &rest body)
  "Define the entry NAME with DOC; BODY runs with each of ARGS bound to its value.
BODY may start with entry properties (:internal, :approve) as keyword value
pairs."
  (declare (indent 3))
  (let (props)
    (while (keywordp (car body)) (push (pop body) props) (push (pop body) props))
    `(homun-api-register ,name ,doc ',args
                         (lambda ,(mapcar #'car args) ,@body)
                         ,@(nreverse props))))

(defun homun-api-alias (old new &rest props)
  "Make the old entry name OLD call NEW, for one release: never in `api schema'.
PROPS: :fixed, words put after NEW's name; :rename, an alist (OLD-KEY .
NEW-KEY)."
  (setf (alist-get old homun-api--entries nil nil #'equal)
        (list :doc (format "Old name of `%s'." new) :alias new
              :fixed (plist-get props :fixed) :rename (plist-get props :rename))))

(defun homun-api--unalias (hit)
  "HIT (NAME ENTRY REST) with an alias resolved to its new entry."
  (let ((entry (nth 1 hit)))
    (if-let* ((new (plist-get entry :alias)))
        (let ((rename (plist-get entry :rename)) (rest (nth 2 hit)) words)
          (while rest
            (push (or (cdr (assq (intern (car rest)) rename)) (car rest)) words)
            (when (cdr rest) (push (cadr rest) words))
            (setq rest (cddr rest)))
          (list new (cdr (assoc new homun-api--entries))
                (append (plist-get entry :fixed) (mapcar (lambda (w) (format "%s" w)) (nreverse words)))))
      hit)))

;;; Reading arguments

(define-error 'homun-api-error "Homun API error")

(defun homun-api--fail (code fmt &rest args)
  (signal 'homun-api-error (list code (apply #'format fmt args))))

(defun homun-api--plain-p (x)
  "Non-nil when X is data: strings, numbers, symbols, and lists or vectors of
those."
  (cond ((or (stringp x) (numberp x) (symbolp x)) t)
        ((vectorp x) (seq-every-p #'homun-api--plain-p x))
        ((proper-list-p x) (seq-every-p #'homun-api--plain-p x))
        ((consp x) (and (homun-api--plain-p (car x)) (homun-api--plain-p (cdr x))))))

(defun homun-api--coerce (key type props text)
  "TEXT as a value of TYPE for the argument KEY."
  (pcase type
    ('string text)
    ('int (unless (string-match-p "\\`-?[0-9]+\\'" text)
            (homun-api--fail 'invalid "%s: not an integer: %s" key text))
          (let ((n (string-to-number text)) (max (plist-get props :max)))
            (when (and max (> n max))
              (homun-api--fail 'invalid "%s: at most %d" key max))
            n))
    ('bool (cond ((member text '("yes" "true" "t" "1" "on")) t)
                 ((member text '("no" "false" "nil" "0" "off")) nil)
                 (t (homun-api--fail 'invalid "%s: yes or no, not %s" key text))))
    ('symbol (unless (string-match-p "\\`[a-z][a-z0-9-]*\\'" text)
               (homun-api--fail 'invalid "%s: not a plain symbol: %s" key text))
             (intern text))
    ('enum (let ((choices (plist-get props :choices)))
             (unless (member text choices)
               (homun-api--fail 'invalid "%s: one of %s, not %s" key
                                (string-join choices " ") text))
             text))
    ('data (let ((form (condition-case nil (let ((read-circle nil)) (car (read-from-string text)))
                         (error (homun-api--fail 'invalid "%s: not readable data" key)))))
             (unless (homun-api--plain-p form)
               (homun-api--fail 'invalid "%s: data only" key))
             form))
    ('json (condition-case nil
               (json-parse-string text :object-type 'alist :array-type 'list
                                  :null-object nil :false-object :false)
             (error (homun-api--fail 'invalid "%s: not JSON" key))))
    (_ (error "Bad argument type %S" type))))

(defun homun-api--bind (entry words)
  "The handler arguments for ENTRY from the `key value' list WORDS."
  (let ((spec (plist-get entry :args)) (given nil))
    (when (cl-oddp (length words))
      (homun-api--fail 'invalid "arguments come as key value pairs, last is %s" (car (last words))))
    (while words
      (let ((arg (assoc (intern (car words)) spec)))
        (unless arg (homun-api--fail 'invalid "unknown key %s" (car words)))
        (when (assq (car arg) given) (homun-api--fail 'invalid "key %s twice" (car words)))
        (push (cons (car arg) (homun-api--coerce (car arg) (cadr arg) (cddr arg) (cadr words)))
              given)
        (setq words (cddr words))))
    (mapcar (lambda (arg)
              (let ((hit (assq (car arg) given)))
                (cond (hit (cdr hit))
                      ((plist-get (cddr arg) :required)
                       (homun-api--fail 'invalid "missing %s" (car arg)))
                      (t (plist-get (cddr arg) :default)))))
            spec)))

(defun homun-api--lookup (argv)
  "The (NAME ENTRY REST) matching the head of ARGV, three words before two before
one."
  (seq-some (lambda (n)
              (when (>= (length argv) n)
                (let* ((name (string-join (mapcar (lambda (w) (format "%s" w)) (take n argv)) " "))
                       (entry (assoc name homun-api--entries)))
                  (and entry (list name (cdr entry) (nthcdr n argv))))))
            '(3 2 1)))

;;; Answers, log

(defun homun-api--cap (value)
  "VALUE as a string of at most `homun-api-result-max' characters."
  (let* ((text (if (stringp value) (substring-no-properties value)
                 (let ((print-length 60) (print-level 5) (print-circle nil))
                   (prin1-to-string value))))
         (n (length text)))
    (if (> n homun-api-result-max)
        (format "%s\n[cut: %d more characters]" (substring text 0 homun-api-result-max)
                (- n homun-api-result-max))
      text)))

(defun homun-api--log (argv status started)
  (ignore-errors
    (let ((dir (file-name-directory homun-api-log-file)))
      (when (file-directory-p dir)
        (when (> (or (file-attribute-size (file-attributes homun-api-log-file)) 0)
                 homun-api-log-max)
          (rename-file homun-api-log-file (concat homun-api-log-file ".1") t))
        (let ((line (format "%s %s %s %dms\n" (format-time-string "%FT%T%z") status
                            (truncate-string-to-width
                             (replace-regexp-in-string "[\n\r]" " " (string-join argv " ")) 200
                             nil nil "…")
                            (round (* 1000 (float-time (time-since started)))))))
          (let ((coding-system-for-write 'utf-8))
            (write-region line nil homun-api-log-file t 'silent)))))))

;;; Cal's approval

(defvar claude-approve-dir (expand-file-name "~/claude/.services/approve/")
  "Directory of the hook's requests/ and Emacs's answers/ (claude-approve.el).")
(defvar homun-api-approve-window 300 "Seconds an approval request of a call stays good.")

(defun homun-api--approval-files ()
  "The pending cockpit requests as (FILE . JSON), stale ones deleted."
  (let ((dir (expand-file-name "requests/" claude-approve-dir)) found)
    (dolist (file (and (file-directory-p dir)
                       (directory-files dir t "\\`[0-9]+-[0-9]+\\.json\\'")))
      (when-let* ((json (ignore-errors (json-read-file file)))
                  (argv (alist-get 'cockpit json)))
        (if (> (- (float-time) (or (alist-get 'since json) 0)) homun-api-approve-window)
            (ignore-errors (delete-file file))
          (push (cons file (cons (append argv nil) json)) found))))
    found))

(defun homun-api--approved (argv reason)
  "Return when Cal has approved the call ARGV; else ask him and fail with
`approval'.
The first call writes an approve card (REASON says why); the same call again
runs once Cal pressed Approve, fails once he pressed Deny, and waits otherwise.
An answer is used once and only for exactly the same words."
  (let* ((hit (seq-find (lambda (f) (equal (cadr f) argv)) (homun-api--approval-files)))
         (id (and hit (alist-get 'id (cddr hit))))
         (answer (and id (expand-file-name id (expand-file-name "answers/" claude-approve-dir))))
         (verdict (and answer (file-readable-p answer)
                       (with-temp-buffer (insert-file-contents answer nil 0 16) (buffer-string)))))
    (cond ((null hit)
           (let* ((id (format "%d-%d" (floor (* 1000000 (float-time))) (emacs-pid)))
                  (dir (expand-file-name "requests/" claude-approve-dir))
                  (file (expand-file-name (concat id ".json") dir)))
             (make-directory dir t)
             (with-temp-file (concat file ".tmp")
               (insert (json-encode `((id . ,id) (tool . ,(format "Cockpit %s" (string-join (seq-take argv 2) " ")))
                                      (summary . ,(format "%s (%s)" (string-join argv " ") reason))
                                      (since . ,(floor (float-time))) (timeout . ,homun-api-approve-window)
                                      (cockpit . ,(vconcat argv))))))
             (rename-file (concat file ".tmp") file t)
             (homun-api--fail 'approval "asked Cal (%s): call again with the same arguments once he approved; request %s" reason id)))
          ((null verdict) (homun-api--fail 'approval "still waiting for Cal's answer to %s" id))
          (t (ignore-errors (delete-file (car hit)))
             (ignore-errors (delete-file answer))
             (unless (equal verdict "allow")
               (homun-api--fail 'approval "Cal denied this call"))))))

(homun-api-define "approve demo" "Draw a demo approve card at the end of the main transcript for SECONDS (default 30), for screenshots: no hook waits on it, so its buttons decide nothing."
    ((seconds int :default 30 :max 300))
  (let* ((id (format "%d-%d" (floor (* 1000000 (float-time))) (emacs-pid)))
         (dir (expand-file-name "requests/" claude-approve-dir))
         (file (expand-file-name (concat id ".json") dir)))
    (make-directory dir t)
    (with-temp-file (concat file ".tmp")
      (insert (json-encode `((id . ,id) (tool . "Bash") (summary . "echo demo card")
                             (input . ((command . "echo 'demo card: nothing runs'")))
                             (since . ,(floor (float-time))) (timeout . ,seconds) (demo . t)))))
    (rename-file (concat file ".tmp") file t)
    (run-at-time seconds nil (lambda () (ignore-errors (delete-file file))))
    (format "demo card %s for %d s" id seconds)))

;;; The entry point

(defun homun-api-call (argv)
  "Run the call ARGV (a list of strings); return the reply string."
  (let ((started (current-time)) (status "ok")
        (homun-api-result-max homun-api-result-max)) ; an entry may raise it for its own answer
    (unwind-protect
        (condition-case err
            (let* ((hit (homun-api--unalias
                         (or (homun-api--lookup argv)
                             (homun-api--fail 'unknown "no entry %s (homun-emacs help)"
                                              (string-join (seq-take argv 2) " ")))))
                   (args (homun-api--bind (nth 1 hit) (nth 2 hit)))
                   (approve (plist-get (nth 1 hit) :approve))
                   (reason (and approve (apply approve args)))
                   (_ (when reason (homun-api--approved argv reason)))
                   (timed-out (list 'timeout))
                   (value (with-timeout (homun-api-timeout timed-out)
                            (apply (plist-get (nth 1 hit) :handler) args))))
              (when (eq value timed-out)
                (homun-api--fail 'timeout "%s took more than %d s" (car hit) homun-api-timeout))
              (concat "ok\n" (homun-api--cap value)))
          (homun-api-error
           (setq status (format "err %s" (cadr err)))
           (format "err %s\n%s" (cadr err) (nth 2 err)))
          (error (setq status "err failed")
                 (format "err failed\n%s" (error-message-string err))))
      (homun-api--log argv status started))))

(defun homun-rpc ()
  "The only form the CLI evaluates: the call is in `server-eval-args-left'."
  (let ((argv (prog1 server-eval-args-left (setq server-eval-args-left nil))))
    (homun-api-call (if (and argv (seq-every-p #'stringp argv)) argv '("api" "list")))))

;;; The registry describes itself

(defun homun-api--describe (name entry)
  (format "%s%s%s\n    %s" name
          (cond ((plist-get entry :internal) " [cli]")
                ((plist-get entry :approve) " [may ask Cal]")
                (t ""))
          (mapconcat (lambda (arg)
                       (format " %s%s<%s>" (car arg)
                               (if (plist-get (cddr arg) :required) " " "? ")
                               (if (eq (cadr arg) 'enum)
                                   (string-join (plist-get (cddr arg) :choices) "|")
                                 (cadr arg))))
                     (plist-get entry :args) "")
          (plist-get entry :doc)))

(defconst homun-api--whole 400000 "Answer cap for the entries that describe the registry.")

(defun homun-api--sorted (object)
  "The entries by name, only those of OBJECT when it is non-nil."
  (seq-filter (lambda (e) (or (null object) (string-prefix-p (concat object " ") (car e))))
              (sort (copy-sequence homun-api--entries) (lambda (a b) (string< (car a) (car b))))))

(homun-api-define "api list" "List the entries, or only those of the object named by OBJECT."
    ((object string))
  (setq homun-api-result-max homun-api--whole)
  (mapconcat (lambda (e) (homun-api--describe (car e) (cdr e))) (homun-api--sorted object) "\n"))

(defun homun-api--arg-schema (arg)
  (pcase-let ((`(,key ,type . ,props) arg))
    (append (list :key key :type type)
            (and (plist-get props :required) (list :required t))
            (and (plist-get props :default) (list :default (plist-get props :default)))
            (and (plist-get props :max) (list :max (plist-get props :max)))
            (and (plist-get props :choices) (list :choices (vconcat (plist-get props :choices)))))))

(homun-api-define "api schema" "The entries as JSON, for generated clients: name, doc and args (key, type, required, default, max, choices); approve when a call may ask Cal first. Old names and the CLI-only entries are left out."
    ((object string))
  (setq homun-api-result-max homun-api--whole)
  (json-encode (vconcat (mapcar (lambda (e)
                                  (append (list :name (car e) :doc (plist-get (cdr e) :doc)
                                                :args (vconcat (mapcar #'homun-api--arg-schema
                                                                       (seq-remove (lambda (a) (plist-get (cddr a) :hidden))
                                                                                   (plist-get (cdr e) :args)))))
                                          (and (plist-get (cdr e) :approve) (list :approve t))
                                          (and (assq 'caller (plist-get (cdr e) :args)) (list :caller t))))
                                (seq-remove (lambda (e) (or (plist-get (cdr e) :alias)
                                                            (plist-get (cdr e) :internal)))
                                            (homun-api--sorted object))))))

(defun homun-api--ping ()
  (format "pong emacs %s pid %d frames %d buffers %d" emacs-version (emacs-pid)
          (length (frame-list)) (length (buffer-list))))

;;; load file

(defconst homun-api-load-max 1048576 "Bytes a file `load file' takes at most.")

(defconst homun-api--worktree-regexp
  (concat "\\`" (regexp-quote (expand-file-name "~/claude/homun-wt/"))
          "[^/]+/container/emacs/\\(?:[^/]+/\\)*[^/]+\\.el\\'")
  "The agent worktrees' cockpit Elisp, which `load file' takes besides the roots.")

(defun homun-api--allowed-file (file)
  (let ((path (file-truename (expand-file-name file))))
    (unless (and (string-suffix-p ".el" path) (file-regular-p path)
                 (< (or (file-attribute-size (file-attributes path)) 0) homun-api-load-max)
                 (or (string-match-p homun-api--worktree-regexp path)
                     (seq-some (lambda (root)
                                 (and (file-directory-p root) (file-in-directory-p path root)))
                               homun-api-load-roots)))
      (homun-api--fail 'invalid "not a .el file under 1 MiB in the allowed directories: %s" file))
    path))

(defun homun-api--refresh-deffaces (file &optional only)
  "Apply the spec of every top-level defface in FILE (or just face ONLY), changed
or not.
A reloaded defface keeps its old spec, so `load' alone never shows the edit."
  (with-temp-buffer
    (insert-file-contents file)
    (condition-case nil
        (while t
          (let ((form (read (current-buffer))))
            (when (and (eq (car-safe form) 'defface) (memq only (list nil (nth 1 form))))
              ;; a re-declared defface drops out of `load-history': keep its file here
              (put (nth 1 form) 'homun-api--defface-file file)
              (face-spec-set (nth 1 form) (eval (nth 2 form) t) 'face-defface-spec))))
      (end-of-file nil))))

(homun-api-define "load file" "Load a .el file from the cockpit's Elisp directory (widgetry included)."
    ((path string :required t))
  (let ((file (homun-api--allowed-file path)))
    (load file nil t t)
    (homun-api--refresh-deffaces file)
    (format "loaded %s" file)))

;;; transcript

(defun homun-api--transcript-buffer (name)
  (or (if name (get-buffer name)
        (seq-find (lambda (b) (provided-mode-derived-p (buffer-local-value 'major-mode b)
                                                       'claude-transcript-mode))
                  (buffer-list)))
      (homun-api--fail 'invalid "no transcript buffer%s" (if name (concat " " name) ""))))

(defun homun-api--transcript-refresh (name turns)
  (with-current-buffer (homun-api--transcript-buffer name)
    (let ((inhibit-read-only t))
      (claude-transcript-refresh turns))
    (format "%s refreshed, %d chars" (buffer-name) (buffer-size))))

(homun-api-define "transcript refresh" "Render a transcript buffer again (the first one, or BUFFER)."
    ((buffer string) (turns int :max 500))
  (homun-api--transcript-refresh buffer turns))

;;; board

(homun-api-define "board get" "The board's rows (task, type, model, age, context, last line, activity cells); REDRAW draws the open board again first."
    ((max int :default 20 :max 60) (redraw bool))
  (require 'claude-board)
  (when-let* ((buffer (and redraw (get-buffer "*claude-board*"))))
    (with-current-buffer buffer (claude-board--draw)))
  (mapconcat (lambda (task) (mapconcat #'identity (claude-board--row task) " | "))
             (seq-take (claude-board--tree (append (claude-board--mains) (claude-board--tasks)))
                       max)
             "\n"))

;;; state

(defun homun-api--age (file)
  "Seconds since FILE was last written, or nil without it."
  (when-let* ((time (file-attribute-modification-time (file-attributes file))))
    (round (float-time (time-since time)))))

;; Mirrors session_mode in container/start.sh: the live session-mode file, else the host role
;; file (/run/homun-roles/<role>.json) over the manifest's `session.mode', else the default.
(defun homun-api--session-mode (key role services)
  "The session mode of KEY (a symbol), ROLE its registry entry, with where it came
from."
  (let* ((name (symbol-name key))
         (file (format "%s%s/session-mode" services name))
         (local (format "%s/%s.json" (or (getenv "HOMUN_ROLES_DIR") "/run/homun-roles") name))
         (asked (ignore-errors
                  (with-temp-buffer
                    (insert-file-contents file nil 0 64)
                    (string-trim (car (split-string (buffer-string) "\n"))))))
         (host (and (file-readable-p local)
                    (ignore-errors
                      (alist-get 'mode (alist-get 'session
                                                  (with-temp-buffer
                                                    (insert-file-contents local)
                                                    (json-parse-buffer :object-type 'alist))))))))
    (cond ((and asked (not (string-empty-p asked))) (format "%s (session-mode)" asked))
          (host (format "%s (host role file)" host))
          (t (format "%s (manifest%s)"
                     (or (alist-get 'mode (alist-get 'session role)) "terminal")
                     (if (file-readable-p local) "" ", host role file not visible"))))))

(defun homun-api--state-roles ()
  "One object per role of the registry: seat kind, session mode, alive, heartbeat
age."
  (let ((services (expand-file-name "~/claude/.services/")))
    (mapcar (lambda (role)
              (let ((age (homun-api--age (format "%s%s/heartbeat" services (car role)))))
                `((role . ,(symbol-name (car role)))
                  (seat . ,(alist-get 'kind (alist-get 'seat (cdr role))))
                  (session . ,(unless (equal (alist-get 'kind (alist-get 'seat (cdr role))) "none")
                                (homun-api--session-mode (car role) (cdr role) services)))
                  (alive . ,(if (and age (< age 600)) t :json-false))
                  (heartbeat_age . ,age))))
            (claude-homun--roles))))

(defun homun-api--state-lease ()
  "The repair lease as holder and age, or nil when nobody holds it."
  (let ((file (expand-file-name "~/claude/.services/mechanic/lease")))
    (when (file-readable-p file)
      (let ((lease (json-read-file file)))
        `((holder . ,(alist-get 'holder lease))
          (age . ,(- (floor (float-time)) (or (alist-get 'since lease) 0))))))))

(defun homun-api--state-services ()
  "Running services from `claude-services list', as name and pid."
  (delq nil
        (mapcar (lambda (line)
                  (let ((words (split-string line)))
                    (when (equal (nth 2 words) "running")
                      `((name . ,(car words)) (pid . ,(string-to-number (or (nth 3 words) "0")))))))
                (ignore-errors (process-lines "claude-services" "list")))))

(homun-api-define "state get" "The operation at a glance as compact JSON: roles (seat, session, alive, heartbeat age), repair lease, host pin and pin_state, running services, and the board's open agent/task rows."
    ()
  (require 'claude-board)
  (let* ((status (ignore-errors
                   (json-read-file (expand-file-name "~/claude/.services/host/status.json"))))
         (host (alist-get 'host status)))
    (json-encode
     `((roles . ,(vconcat (homun-api--state-roles)))
       (lease . ,(homun-api--state-lease))
       (pin . ,(alist-get 'pin host))
       (pin_state . ,(alist-get 'pin_state host))
       (services . ,(vconcat (homun-api--state-services)))
       (board_rows . ,(length (claude-board--tasks)))))))

;;; compose, queue

(homun-api-define "compose get" "The compose box: what the manager is doing now (status), who it talks to (who), or the user's messages not yet seen arriving, oldest first (queue)."
    ((what enum :required t :choices ("status" "who" "queue")))
  (require 'claude-compose)
  (pcase what
    ("status" (if-let* ((text (claude-compose--status))) (substring-no-properties text) "idle"))
    ("who" (let ((buffer (get-buffer "*claude-compose*")))
             (if buffer (buffer-local-value 'claude-compose--who buffer) "no compose buffer")))
    (_ (if claude-compose--outbox
           (mapconcat (lambda (m) (format "%s %s" (plist-get m :state)
                                          (truncate-string-to-width
                                           (replace-regexp-in-string "\n" " " (plist-get m :text))
                                           100 nil nil "…")))
                      claude-compose--outbox "\n")
         "empty"))))

;;; stage

(defvar homun-stage-dir)
(defvar homun-api-shot-dir)

(defmacro homun-api--stage (&rest body)
  "Run BODY with the Stage loaded; a refusal fails with the JSON {error, field,
limit}."
  `(progn
     (require 'homun-stage-store)
     (condition-case e (progn ,@body)
       (homun-stage-refused
        (homun-api--fail 'invalid "%s" (json-encode `((error . ,(nth 1 e)) (field . ,(nth 2 e))
                                                      ,@(and (nth 3 e) `((limit . ,(nth 3 e))))))))
       (homun-stage-invalid
        (homun-api--fail 'invalid "%s" (json-encode `((error . ,(nth 2 e)) (field . ,(nth 1 e)))))))))

(defun homun-api--stage-ok (version)
  (json-encode `((ok . t) (version . ,version))))

(homun-api-define "stage show" "Create or replace the Stage scene ID titled TITLE: ROOT is the node tree (JSON), LIFETIME turn (default), ephemeral, pinned or system, STALE_MS the time a binding may go unpublished. Shown in the side window without selecting it. Answers {ok, version}; a refusal is {error, field, limit?}."
    ((id string :required t) (title string :required t) (root json :required t)
     (lifetime enum :choices ("turn" "ephemeral" "pinned" "system")) (stale_ms int)
     (session string) (caller string :default "manager" :hidden t))
  (homun-api--stage
   (let ((v (homun-stage-show caller id title root lifetime stale_ms session)))
     (homun-stage-display id)
     (homun-api--stage-ok v))))

(homun-api-define "stage patch" "Change the scene ID by OPS (JSON list, at most 64), all or none: each {path, set|insert|remove|animate:{to,ms,ease}}, paths by id (/node/field, /node/list/item-id/field, /node/list/- appends). IF_VERSION refuses a stale edit. Only the scene's owner. Answers {ok, version}."
    ((id string :required t) (ops json :required t) (if_version int)
     (caller string :default "manager" :hidden t))
  (homun-api--stage (homun-api--stage-ok (homun-stage-patch caller id ops if_version))))

(homun-api-define "stage publish" "Feed the {bind} values of the Stage: set TOPIC (stage.<name>.* or state.<owner>.*) to VALUE (JSON); scenes bound to it redraw within a frame. Scripts publish with `homun-msg send stage <topic> <json>`."
    ((topic string :required t) (value json :required t))
  (homun-api--stage (progn (require (quote homun-stage-bind)) (homun-stage-publish topic value) (json-encode '((ok . t))))))

(homun-api-define "stage focus" "Bring the scene ID forward in the side window, without selecting it; NODE with NOTE puts a callout on that node in the header line. TARGET file:PATH:FROM[-TO] instead pulses those lines of the buffer visiting PATH (no ID), moving neither point nor windows; shown is false when no buffer visits it."
    ((id string) (node string) (note string) (target string))
  (homun-api--stage
   (json-encode
    `((ok . t) (shown . ,(if (cond ((and target (string-prefix-p "file:" target))
                                    (require 'homun-stage-point)
                                    (homun-stage-pulse-file (substring target 5)))
                                   (target (homun-stage--refuse "target: file:PATH:FROM[-TO]" "target"))
                                   (id (homun-stage-focus id node note))
                                   (t (homun-stage--refuse "id or target" "id")))
                               t :json-false))))))

(homun-api-define "stage get" "The scene ID as JSON: spec, bound values, events, patch count, last render time, its text render and size."
    ((id string :required t))
  (setq homun-api-result-max homun-api--whole)
  (homun-api--stage (homun-stage-encode (homun-stage-get id))))

(homun-api-define "stage snapshot" "A PNG of the scene ID exactly as the cockpit shows it (its window cropped out of the frame), under ~/claude/.services/emacs/shots/; answers {path, frame, crop}."
    ((id string :required t))
  (homun-api--stage
   (let ((win (homun-stage-display id)))
     (unless win (homun-stage--refuse "not shown: no graphic frame" "id"))
     (unless (fboundp 'x-export-frames) (homun-stage--refuse "no graphic frame export" "id"))
     (redisplay t)
     (let* ((stamp (format-time-string "%H%M%S"))
            (frame-file (expand-file-name (format "stage-%s-%s-frame.png" id stamp) homun-api-shot-dir))
            (file (expand-file-name (format "stage-%s-%s.png" id stamp) homun-api-shot-dir))
            (e (window-pixel-edges win))
            (crop (list (nth 0 e) (nth 1 e) (- (nth 2 e) (nth 0 e)) (- (nth 3 e) (nth 1 e))))
            (magick (executable-find "magick")))
       (make-directory homun-api-shot-dir t)
       (let ((data (x-export-frames (window-frame win) 'png)))
         (with-temp-file frame-file (set-buffer-multibyte nil) (insert data)))
       (unless (and magick
                    (eq 0 (call-process magick nil nil nil frame-file "-crop"
                                        (apply #'format "%dx%d+%d+%d" (nth 2 crop) (nth 3 crop) (take 2 crop))
                                        "+repage" file)))
         (setq file nil))
       (json-encode `((path . ,(or file frame-file)) (frame . ,frame-file)
                      (cropped . ,(if file t :json-false)) (crop . ,(vconcat crop))))))))

(homun-api-define "stage close" "Close the scene ID: its last state is kept in closed/. Only its owner (or Cal)."
    ((id string :required t) (caller string :default "manager" :hidden t))
  (homun-api--stage (homun-stage-close caller id) (json-encode '((ok . t)))))

(homun-api-define "stage list" "The open scenes, most recently used first: id, title, owner_role, lifetime, version, shown."
    ()
  (homun-api--stage (homun-stage-encode (vconcat (homun-stage-list)))))

;;; doctor

(homun-api-define "doctor get" "The health checks of homun-doctor as JSON: every container, service and component with area, id, name, status (ok, warn, fail, unknown), summary, hint, the file behind it and the service a restart would act on. PROBLEMS leaves out the checks that are ok."
    ((problems bool))
  (require 'claude-doctor)
  (setq homun-api-result-max 60000)
  (let ((data (claude-doctor-run)))
    (when problems
      (setf (alist-get 'checks data)
            (seq-remove (lambda (c) (equal (alist-get 'status c) "ok")) (alist-get 'checks data))))
    (setf (alist-get 'checks data) (vconcat (alist-get 'checks data)))
    (json-encode data)))

;;; tracker

(homun-api-define "tracker show" "Tracker entry ID as JSON (title, state, priority, tags, body, notes, workspace) with the branches of its workspace."
    ((id int :required t))
  :internal t
  (require 'claude-task-detail) (claude-task-detail-show-json id))

(homun-api-define "tracker state" "Set tracker entry ID to STATE: next, done or drop."
    ((id int :required t) (state string :required t))
  :internal t
  (require 'claude-task-detail) (claude-task-detail-set-state id state) "set")

;;; ui click, errors

(homun-api-define "ui click" "Press what mouse-1 would at LABEL or POSITION of BUFFER, a tab of the stage region; refuses approval cards, prompts and hold or drag buttons."
    ((buffer string :required t) (label string) (position int))
  (require 'claude-click)
  (condition-case err (claude-click buffer label position)
    (user-error (homun-api--fail 'refused "%s" (cadr err)))))

(homun-api-define "errors list" "The error watch's recent signatures (kind, source, message, count, first, last, sent, file), last seen first, as JSON."
    ((limit int :default 20 :max 200))
  (require 'claude-errwatch)
  (json-serialize (claude-errwatch-list limit)))

;;; pages

(homun-api-define "page open" "Show a cockpit page without selecting it: doctor and settings (scenes of the stage region), todos (the main session's todos window), board (in a frame) or questions (the oldest pending question buffer, in a fresh frame)."
    ((name enum :required t :choices ("doctor" "settings" "todos" "board" "questions")))
  (pcase name
    ("doctor" (require 'claude-doctor) (claude-doctor) "opened")
    ("settings" (require 'claude-settings) (buffer-name (claude-settings)))
    ("todos" (require 'claude-todos) (claude-todos) (claude-todos-file))
    ("board" (require 'claude) (require 'claude-board) (claude--with-frame (claude-board)) "board")
    ("questions" (require 'claude-questions) (format "%s" (claude-questions-show)))))

;;; pairing

(homun-api-define "remote pair" "Make a one-time pairing code (10 min) for the remote cockpit device NAME (default phone; a name that has a key gets a new one when the code is used), show its QR code and init.el line, and return the line. The user's action: it asks Cal first."
    ((name string :default "phone"))
  :approve (lambda (name) (format "pair the device %s with the cockpit gateway" name))
  (require 'claude-pair)
  (claude-pair-phone name))

;;; remote management: the gateway's per-device files, typed, never eval on the device

(defvar homun-api-remote-devices (expand-file-name "~/claude/.services/cockpit-gateway/devices/")
  "The cockpit-gateway's devices directory.")

(defun homun-api--remote-dir (name)
  (unless (and (string-match-p "\\`[a-z0-9][a-z0-9-]\\{0,31\\}\\'" name)
               (file-exists-p (expand-file-name (concat name ".json") homun-api-remote-devices)))
    (homun-api--fail 'invalid "no paired device %s" name))
  (file-name-as-directory (expand-file-name name homun-api-remote-devices)))

(defun homun-api--remote-read (file)
  (when (file-readable-p file)
    (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string)))))

(defun homun-api--remote-push (name cmd)
  "Queue the command CMD for the device NAME: its stream sends it within a second."
  (let* ((dir (expand-file-name "push/" (homun-api--remote-dir name)))
         (id (format-time-string "%s%N")) (file (expand-file-name (concat id ".json") dir)))
    (make-directory dir t)
    (with-temp-file (concat file ".tmp") (insert (json-serialize (list :cmd cmd :id id))))
    (rename-file (concat file ".tmp") file t)
    (let ((conn (ignore-errors (json-parse-string (homun-api--remote-read (expand-file-name "conn.json" (homun-api--remote-dir name)))))))
      (format "%s queued for %s (%s); its answer shows in remote_status / remote_logs"
              cmd name (if (and conn (> (gethash "streams" conn 0) 0)) "connected: sent within a second"
                         "offline: sent when it connects")))))

(homun-api-define "remote restart" "Restart the cockpit-gateway service, which runs in the cockpit's container (it rebuilds itself from a changed source); paired devices reconnect by themselves."
    ()
  (if (eql 0 (call-process "claude-services" nil nil nil "restart" "cockpit-gateway"))
      "restarted" (homun-api--fail 'failed "claude-services restart cockpit-gateway failed")))

(homun-api-define "remote logs" "The stored telemetry of the paired device NAME: its newest MAX entries of log.jsonl (errors with backtraces, warnings, *Messages* batches, startup logs, upgrade results), oldest first, as JSON lines."
    ((name string :required t) (max int :default 20 :max 200))
  (let ((text (homun-api--remote-read (expand-file-name "log.jsonl" (homun-api--remote-dir name)))))
    (if (not text) "no entries yet"
      (string-join (last (split-string text "\n" t) max) "\n"))))

(homun-api-define "remote status" "The paired device NAME: last seen, open streams, and its last status snapshot (Emacs, Android build, homun-remote version, packages, connection, queues), with the archive's version."
    ((name string :required t))
  (let* ((dir (homun-api--remote-dir name))
         (seen (file-attribute-modification-time (file-attributes (expand-file-name "seen" dir)))))
    (json-encode
     `((device . ,name)
       (last_seen . ,(and seen (format-time-string "%FT%TZ" seen t)))
       (last_seen_ago . ,(and seen (floor (- (float-time) (float-time seen)))))
       (conn . ,(ignore-errors (json-read-from-string (homun-api--remote-read (expand-file-name "conn.json" dir)))))
       (status . ,(ignore-errors (json-read-from-string (homun-api--remote-read (expand-file-name "status.json" dir)))))))))

(homun-api-define "remote check" "Ask the paired device NAME for a fresh status snapshot over its stream; it answers from a fixed allow-list. Read it with remote_status a few seconds later."
    ((name string :required t))
  (homun-api--remote-push name "check"))

(homun-api-define "remote upgrade" "Tell the paired device NAME to refetch the cockpit's files from the gateway and load them (homun-update), then report the result (remote_logs) and a fresh status."
    ((name string :required t))
  (homun-api--remote-push name "upgrade"))

;;; faces

(defun homun-api--face (name)
  (let ((face (intern-soft name)))
    (unless (and face (facep face) (string-match-p "\\`\\(claude\\|widgetry\\)-" name))
      (homun-api--fail 'invalid "only faces named claude-* or widgetry-*: %s" name))
    face))

(homun-api-define "face get" "The attributes a face sets."
    ((face string :required t))
  (let ((f (homun-api--face face)))
    (cl-loop for (a . _) in face-attribute-name-alist
             for v = (face-attribute f a nil)
             unless (eq v 'unspecified) append (list a v))))

(homun-api-define "face set" "Set one attribute of a claude-* or widgetry-* face, e.g. attribute foreground value #aabbcc; RESET puts the face back to its defface spec as its file has it now."
    ((face string :required t)
     (attribute enum :choices ("foreground" "background" "weight" "slant" "underline"
                          "inherit" "height" "box"))
     (value string) (reset bool))
  (let ((f (homun-api--face face)))
    (cond (reset
           (let ((file (or (get f 'homun-api--defface-file) (symbol-file f 'defface))))
             ;; re-read the defface from its file: the stored spec is stale after an edit
             (if (and file (file-readable-p (setq file (concat (file-name-sans-extension file) ".el"))))
                 (homun-api--refresh-deffaces (homun-api--allowed-file file) f)
               (face-spec-set f (get f 'face-defface-spec) 'face-defface-spec))
             (format "%s reset" face)))
          ((not (and attribute value)) (homun-api--fail 'invalid "give attribute and value, or reset"))
          (t (when (> (length value) 200) (homun-api--fail 'invalid "value: at most 200 characters"))
             (set-face-attribute f nil (intern (concat ":" attribute))
                                 (cond ((equal attribute "height")
                                        (or (and (string-match-p "\\`[0-9.]+\\'" value)
                                                 (string-to-number value))
                                            (homun-api--fail 'invalid "height: a number")))
                                       ((member attribute '("weight" "slant" "inherit"))
                                        (let ((sym (intern value)))
                                          (when (and (equal attribute "inherit") (not (facep sym)))
                                            (homun-api--fail 'invalid "inherit: not a face: %s" value))
                                          sym))
                                       (t value)))
             (format "%s %s %s" face attribute value)))))

;;; buffers, frames, windows

(defconst homun-api-shot-dir (expand-file-name "~/claude/.services/emacs/shots/")
  "Where `frame screenshot' writes its PNGs.")

(homun-api-define "frame screenshot" "A PNG of the frame showing buffer NAME (else the selected frame), written under ~/claude/.services/emacs/shots/ (PATH, a plain name ending in .png, names the file there); prints its path."
    ((name string) (path string))
  (let* ((buffer (and name (or (get-buffer name) (homun-api--fail 'invalid "no buffer %s" name))))
         (frame (or (and buffer (when-let* ((w (get-buffer-window buffer t))) (window-frame w)))
                    (selected-frame)))
         (base (or path (format-time-string "shot-%H%M%S.png")))
         (file (progn (unless (string-match-p "\\`[A-Za-z0-9_-][A-Za-z0-9._-]\\{0,80\\}\\.png\\'" base)
                        (homun-api--fail 'invalid "path: a plain file name ending in .png"))
                      (expand-file-name base homun-api-shot-dir))))
    (unless (fboundp 'x-export-frames) (homun-api--fail 'invalid "no graphic frame export"))
    (make-directory homun-api-shot-dir t)
    (let ((data (x-export-frames frame 'png)))
      (unless data (homun-api--fail 'invalid "frame export gave nothing"))
      (with-temp-file file (set-buffer-multibyte nil) (insert data)))
    file))

(defun homun-api--tree (node)
  (if (windowp node)
      (format "%s(%dx%d)" (buffer-name (window-buffer node)) (window-total-width node)
              (window-total-height node))
    (format "%s[%s]" (if (car node) "vsplit" "hsplit")
            (mapconcat #'homun-api--tree (cddr node) " "))))

;;; widgetry

;;; claude-emacs: the verbs of bin/claude-emacs, so it sends no Lisp text either

(defconst homun-api--private-paths
  (mapcar #'expand-file-name
          '("~/.claude.json" "~/.claude/.credentials.json" "~/.config/gh/" "~/.ssh/" "~/.gnupg/"
            "~/claude/.services/approve/" "~/claude/.services/proxy/users"))
  "Paths no entry opens, shows or visits: credentials and Cal's approvals.")

(defun homun-api--existing (key file)
  "FILE expanded (symbolic links resolved), or an invalid-argument error naming KEY
when it does not exist, is a credential (`homun-api--private-paths', a
secret-looking name) or is over 50 MB."
  (let ((full (file-truename (expand-file-name file))))
    (unless (file-exists-p full) (homun-api--fail 'invalid "%s: no such path: %s" key full))
    (when (or (seq-some (lambda (p) (or (string-prefix-p p full) (equal (directory-file-name p) full)))
                        homun-api--private-paths)
              (string-match-p homun-api--secret-names (file-name-nondirectory full)))
      (homun-api--fail 'invalid "%s: not shown here: %s" key full))
    (when (> (or (file-attribute-size (file-attributes full)) 0) 52428800)
      (homun-api--fail 'invalid "%s: over 50 MB: %s" key full))
    full))

(homun-api-define "frame open" "Raise a frame on FILE: visit it at LINE (kind file), compare it with OTHER in ediff (diff), or show it read-only titled TITLE (report)."
    ((kind enum :default "file" :choices ("file" "diff" "report"))
     (file string :required t) (other string) (line int) (title string))
  :internal t
  (require 'claude)
  (pcase kind
    ("file" (claude-open (homun-api--existing 'file file) line) "opened")
    ("diff" (claude-diff (homun-api--existing 'file file)
                         (homun-api--existing 'other (or other (homun-api--fail 'invalid "missing other"))))
            "diffing")
    (_ (claude-report (homun-api--existing 'file file) title) "shown")))

(homun-api-define "focus set" "Set what Emacs shows next, without raising a frame: KIND with PATH (and OTHER for diff, LINE for file, TITLE for report); clear drops it, so a new frame opens the dashboard."
    ((kind enum :required t :choices ("file" "dir" "diff" "report" "dashboard" "clear"))
     (path string) (other string) (line int) (title string))
  :internal t
  (require 'claude-focus)
  (let ((need (lambda (key value) (homun-api--existing key (or value (homun-api--fail 'invalid "missing %s" key))))))
    (pcase kind
      ("file" (claude-focus-set 'file (if line (cons (funcall need 'path path) line)
                                        (funcall need 'path path))))
      ("dir" (claude-focus-set 'dir (funcall need 'path path)))
      ("diff" (claude-focus-set 'diff (cons (funcall need 'path path) (funcall need 'other other))))
      ("report" (claude-focus-set 'report (funcall need 'path path) title))
      ("dashboard" (claude-focus-set 'dashboard nil))
      ("clear" (claude-focus-clear))))
  (if (equal kind "clear") "cleared" "focus set"))

(homun-api-define "ask open" "Ask the user in a frame; the answer lands in answers/ID.  KIND text: the question TEXT; pick: one quick choice among CHOICES (comma-separated) with the prompt TEXT, for TIMEOUT seconds; org: the Org question FILE (no display without a frame); review: the branch diff of DIRECTORY against BASE beside an Org notes buffer."
    ((kind enum :default "text" :choices ("text" "pick" "org" "review"))
     (id string :required t) (text string) (choices string) (timeout int :default 120 :max 86400)
     (file string) (directory string) (base string :default "main"))
  :internal t
  (let ((need (lambda (key value) (or value (homun-api--fail 'invalid "%s needs %s" kind key)))))
    (pcase kind
      ("text" (require 'claude) (claude-ask (funcall need 'text text) id) id)
      ("pick" (require 'claude-pick)
              (claude-pick id (funcall need 'text text)
                           (split-string (funcall need 'choices choices) "," t "[ \t]+") timeout))
      ("org" (require 'claude-questions)
             (claude-questions (homun-api--existing 'file (funcall need 'file file)) id))
      (_ (require 'claude-review)
         (claude-review id (homun-api--existing 'directory (funcall need 'directory directory)) base) id))))

(homun-api-define "ask close" "Mark the question ID as timed out." ((id string :required t))
  :internal t
  (require 'claude) (claude-ask-timeout id) "timed out")

(homun-api-define "ask reply" "The manager's reply TEXT to the ask on question QUESTION in buffer BUFFER."
    ((buffer string :required t) (question string :required t) (text string :required t))
  :internal t
  (require 'claude-questions) (claude-questions-reply buffer question text) "replied")

(homun-api-define "echo say" "Show TEXT in the echo area." ((text string :required t))
  :internal t
  (require 'claude) (claude-say text) "said")

;;; fonts check

(defun homun-api--char-font (ch frame)
  "Family of the font that draws CH on FRAME's default face, or nil."
  (with-selected-frame frame
    (let ((font (ignore-errors (internal-char-font nil ch))))
      (when (consp font) (setq font (car font)))
      (when (fontp font) (format "%s" (font-get font :family))))))

(homun-api-define "fonts check"
    "Per char of STRING (non-ASCII only): displayable, drawing font family, status ok/fallback/missing."
    ((string string :required t))
  (let ((frame (seq-find (lambda (f) (display-graphic-p f)) (frame-list))))
    (unless frame (homun-api--fail 'invalid "no graphic frame"))
    (let* ((default (with-selected-frame frame (face-attribute 'default :family)))
           (chars (seq-uniq (seq-filter (lambda (c) (> c 127)) (string-to-list string)))))
      (when (null chars) (homun-api--fail 'invalid "STRING has no non-ASCII char"))
      (json-encode
       (list :default default
             :chars
             (vconcat
              (mapcar
               (lambda (c)
                 (let* ((ok (and (char-displayable-p c) t))
                        (fam (homun-api--char-font c frame))
                        (status (cond ((or (not ok) (not fam)) "missing")
                                      ((string-equal-ignore-case fam default) "ok")
                                      (t "fallback"))))
                   (list :char (string c) :code (format "U+%04X" c)
                         :displayable (if ok t :json-false)
                         :font (or fam "") :status status)))
               chars)))))))

;;; JSON answers: the entries below reply in JSON, each bounded by the answer cap

(defun homun-api--flag (value) (if value t :json-false))

(defun homun-api--short (text max)
  (truncate-string-to-width (substring-no-properties text) max nil nil "…"))

(defun homun-api--printed (value max)
  "VALUE as Lisp text of at most MAX characters."
  (let ((print-length 40) (print-level 4) (print-circle nil))
    (homun-api--short (prin1-to-string value) max)))

(defun homun-api--json-rows (rows &rest head)
  "A JSON object of the plist HEAD, of ROWS and of cut.
Rows are dropped from the end until the text fits the answer cap; cut counts
them."
  (let ((rows (vconcat rows)) (cut 0) text)
    (while (progn (setq text (json-encode (append head (list :rows rows :cut cut))))
                  (and (> (length text) homun-api-result-max) (> (length rows) 0)))
      (let ((keep (/ (length rows) 2)))
        (setq cut (+ cut (- (length rows) keep)) rows (seq-take rows keep))))
    text))

(defun homun-api--view-messages (lines match)
  "The last LINES lines of *Messages*, newest first; with MATCH only the lines
matching that regexp."
  (with-current-buffer (messages-buffer)
    (let* ((all (split-string (buffer-substring-no-properties
                               (max (point-min) (- (point-max) 60000)) (point-max))
                              "\n" t))
           (hits (if match (seq-filter (lambda (line) (string-match-p match line)) all) all)))
      (homun-api--json-rows (mapcar (lambda (line) (homun-api--short line 300))
                                    (seq-take (reverse hits) lines))))))

;;; windows, buffers

(defun homun-api--window-id (window)
  "The number Emacs prints for WINDOW."
  (string-to-number (substring (format "%s" window) 9)))

(defun homun-api--windows ()
  "Every window but the minibuffers, visible graphic top-level frames first."
  (let ((front (lambda (frame) (and (display-graphic-p frame) (frame-visible-p frame)
                                    (not (frame-parameter frame 'parent-frame))))))
    (mapcan (lambda (frame) (window-list frame 'no-minibuf))
            (append (seq-filter front (frame-list)) (seq-remove front (frame-list))))))

(homun-api-define "window get" "Every window of every frame (id, frame, buffer, file, edges left top right bottom in columns and lines, layout slot, selected) and the frames; VIEW tree: the selected frame's windows as a tree of buffer(WxH)."
    ((view enum :default "list" :choices ("list" "tree")))
  (if (equal view "tree") (homun-api--tree (car (window-tree)))
  (homun-api--json-rows
   (mapcar (lambda (w)
             (list :window (homun-api--window-id w) :frame (frame-id (window-frame w))
                   :buffer (buffer-name (window-buffer w))
                   :file (buffer-file-name (window-buffer w))
                   :edges (vconcat (window-edges w))
                   :slot (window-parameter w 'homun-region)
                   :selected (homun-api--flag (eq w (frame-selected-window (window-frame w))))))
           (homun-api--windows))
   :frames (vconcat (mapcar (lambda (f)
                              (list :frame (frame-id f) :name (frame-parameter f 'name)
                                    :type (format "%s" (framep f)) :width (frame-width f) :height (frame-height f)
                                    :visible (homun-api--flag (frame-visible-p f))
                                    :child (homun-api--flag (frame-parameter f 'parent-frame))
                                    :selected (homun-api--flag (eq f (selected-frame)))))
                            (frame-list))))))

(defun homun-api--buffer (name)
  "The buffer NAME, refused when its name looks like it holds a secret."
  (when (string-match-p homun-api--secret-names name)
    (homun-api--fail 'invalid "%s is not readable here" name))
  (or (get-buffer name) (homun-api--fail 'invalid "no buffer %s" name)))

(homun-api-define "buffer get" "With NAME: its size, mode and CHARS characters from FROM.  Without: the buffers, most recent first (name, mode, size, file, shown, modified), MATCH a regexp on the name (else internal buffers are left out), at most MAX."
    ((name string) (chars int :default 300 :max 2000) (from int :default 1)
     (match string) (max int :default 40 :max 200))
  (if name
      (with-current-buffer (homun-api--buffer name)
        (let ((start (max (point-min) (min from (point-max)))))
          (format "%s size %d mode %s\n%s" name (buffer-size) major-mode
                  (buffer-substring-no-properties start (min (point-max) (+ start chars))))))
    (homun-api--json-rows
     (mapcar (lambda (b)
               (list :name (buffer-name b) :mode (buffer-local-value 'major-mode b)
                     :size (buffer-size b) :file (buffer-file-name b)
                     :shown (homun-api--flag (get-buffer-window b t))
                     :modified (homun-api--flag (and (buffer-file-name b) (buffer-modified-p b)))))
             (seq-take (seq-filter (lambda (b)
                                     (if match (string-match-p match (buffer-name b))
                                       (not (string-prefix-p " " (buffer-name b)))))
                                   (buffer-list))
                       max)))))

(defun homun-api--prop-start (name pos match)
  "The position of BUFFER NAME that POS or the first hit of the regexp MATCH names."
  (unless (= 1 (length (delq nil (list pos match))))
    (homun-api--fail 'invalid "give one of pos, match"))
  (if pos
      (if (<= (point-min) pos (point-max)) pos
        (homun-api--fail 'invalid "pos: outside %d..%d of %s" (point-min) (point-max) name))
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward match nil t) (match-beginning 0)
        (homun-api--fail 'invalid "match: no %s in %s" match name)))))

(homun-api-define "buffer props" "The text properties of buffer NAME from POS (or the first hit of the regexp MATCH) on for CHARS characters, as runs {from, to, text, props}, and the overlays at the start {from, to, props}; values printed and capped.  Read-only."
    ((name string :required t) (pos int) (match string) (chars int :default 40 :max 400))
  (with-current-buffer (homun-api--buffer name)
    (let* ((start (homun-api--prop-start name pos match))
           (end (min (point-max) (+ start chars)))
           runs)
      (save-restriction
        (widen)
        (let ((at start))
          (while (< at end)
            (let ((next (min end (next-property-change at nil end))))
              (push (list :from at :to next
                          :text (homun-api--short (buffer-substring-no-properties at next) 80)
                          :props (homun-api--printed (text-properties-at at) 400))
                    runs)
              (setq at next)))))
      (json-encode
       (list :name name :start start
             :runs (vconcat (nreverse runs))
             :overlays (vconcat (mapcar (lambda (o)
                                          (list :from (overlay-start o) :to (overlay-end o)
                                                :props (homun-api--printed (overlay-properties o) 400)))
                                        (overlays-at start))))))))

(defun homun-api--view-p (buffer)
  "Non-nil when BUFFER is a cockpit view `view refresh' can draw again."
  (let ((mode (symbol-name (buffer-local-value 'major-mode buffer))))
    (and (string-match-p homun-api--own-names mode)
         (or (provided-mode-derived-p (intern mode) 'claude-transcript-mode)
             (and (local-variable-p 'homun-stage--id buffer) (buffer-local-value 'homun-stage--id buffer))
             (local-variable-p 'revert-buffer-function buffer)))))

(defun homun-api--refresh-view (buffer)
  "Draw the cockpit view BUFFER again."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (cond ((derived-mode-p 'claude-transcript-mode) (claude-transcript-refresh nil))
            ((and (local-variable-p 'homun-stage--id) homun-stage--id)
             (homun-stage-render (homun-stage-scene homun-stage--id)))
            (t (revert-buffer t t))))))

(homun-api-define "view refresh" "Draw the cockpit view BUFFER again (a transcript, a Stage scene, the board or any claude-*/homun-* view with its own redraw), or without BUFFER every such view shown in a window.  Answers {refreshed, failed}."
    ((buffer string))
  (let ((views (if buffer
                   (let ((b (homun-api--buffer buffer)))
                     (unless (homun-api--view-p b) (homun-api--fail 'invalid "%s is not a cockpit view" buffer))
                     (list b))
                 (seq-filter (lambda (b) (and (get-buffer-window b t) (homun-api--view-p b)))
                             (buffer-list))))
        done failed)
    (dolist (b views)
      (condition-case e
          (progn (homun-api--refresh-view b) (push (buffer-name b) done))
        (error (push (list :buffer (buffer-name b) :error (error-message-string e)) failed))))
    (json-encode (list :refreshed (vconcat (nreverse done)) :failed (vconcat (nreverse failed))))))

(defun homun-api--one-window (slot window showing)
  "The window named by one of SLOT, WINDOW (an id) and SHOWING (a buffer name)."
  (unless (= 1 (length (delq nil (list slot window showing))))
    (homun-api--fail 'invalid "name the window by one of slot, window, showing"))
  (or (seq-find (lambda (w)
                  (cond (slot (eq (window-parameter w 'homun-region)
                                (alist-get (intern slot) '((main . transcript) (slate . stage)) (intern slot))))
                        (window (= window (homun-api--window-id w)))
                        (t (equal showing (buffer-name (window-buffer w))))))
                (homun-api--windows))
      (homun-api--fail 'invalid "no such window (window get)")))

(homun-api-define "window set" "Show BUFFER (or visit FILE) in one window, without selecting it or raising a frame. Name the window by SLOT (slate is the stage region), by WINDOW (an id from window get) or by SHOWING (the buffer it shows now). TOP shows the buffer from its start."
    ((buffer string) (file string) (slot enum :choices ("main" "board" "slate"))
     (window int) (showing string) (top bool))
  (unless (= 1 (length (delq nil (list buffer file))))
    (homun-api--fail 'invalid "give one of buffer, file"))
  (let* ((target (homun-api--one-window slot window showing))
         (was (buffer-name (window-buffer target)))
         (_ (when (string-prefix-p "*claude-compose" was)
              (homun-api--fail 'invalid "the compose window keeps its buffer")))
         (new (if buffer (homun-api--buffer buffer)
                (let ((enable-local-variables :safe) (large-file-warning-threshold nil))
                  (find-file-noselect (homun-api--existing 'file file) t)))))
    ;; a buffer of another region goes to its own window, never into the transcript's
    (when-let* (((and slot (not (eq (homun-layout--shape) 'narrow))))
                (region (homun-layout-region new))
                ((not (eq region (window-parameter target 'homun-region))))
                (own (homun-layout-window region)))
      (setq target own))
    (homun-layout-show new target)
    (when top (let ((start (with-current-buffer new (point-min))))
                (homun-layout-point target start start)))
    (json-encode (list :window (homun-api--window-id target) :buffer (buffer-name new) :was was))))

;;; variables, settings, libraries, modes, clipboard

(defconst homun-api--display-vars
  '(header-line-format mode-line-format tab-line-format face-remapping-alist
    line-spacing left-margin-width right-margin-width buffer-invisibility-spec)
  "Display variables `variable get' reads whole, as for the cockpit's own.")

(homun-api-define "variable get" "The value of the variable NAME (in BUFFER when given), printed and capped. Whole values only of claude-*, homun-* and widgetry-* variables and of the display variables header-line-format, mode-line-format, tab-line-format, face-remapping-alist, line-spacing, left-margin-width, right-margin-width and buffer-invisibility-spec; of any other, only a number or a symbol."
    ((name string :required t) (buffer string))
  (let ((var (intern-soft name))
        (where (if buffer (homun-api--buffer buffer)
                 (current-buffer))))
    (when (string-match-p homun-api--secret-names name)
      (homun-api--fail 'invalid "%s is not readable here" name))
    (if (not (and var (boundp var)))
        (json-encode (list :name name :bound :json-false))
      (let ((value (buffer-local-value var where)))
        (unless (or (string-match-p homun-api--own-names name) (memq var homun-api--display-vars)
                    (numberp value) (symbolp value))
          (homun-api--fail 'invalid "%s: only numbers and symbols outside claude-*, homun-*, widgetry-*"
                           name))
        (json-encode (list :name name :bound t :value (homun-api--printed value 2000)
                           :local (homun-api--flag (local-variable-p var where))))))))

;; A reloaded defvar keeps its old value, as a reloaded defface keeps its spec.
(defun homun-api--defvar-form (var file)
  "The top-level defvar, defvar-local, defconst or defcustom of VAR in FILE, or
nil."
  (with-temp-buffer
    (insert-file-contents file)
    (let (found)
      (condition-case nil
          (while (not found)
            (let ((form (read (current-buffer))))
              (when (and (memq (car-safe form) '(defvar defvar-local defconst defcustom))
                         (eq (nth 1 form) var) (cddr form))
                (setq found form))))
        (end-of-file nil))
      found)))

(defconst homun-api--settable-names
  "\\`\\(?:tooltip\\|x-gtk\\|gcmh\\|claude\\|homun\\|widgetry\\)-"
  "Variables an agent may set: display tuning and the cockpit's own.")

(defconst homun-api--risky-names
  (concat "\\`homun-api-\\|-\\(?:functions?\\|hooks?\\|command\\|program\\|args\\|dir\\|directory"
          "\\|file\\|path\\|roots?\\|regexp\\|form\\|predicate\\|handler\\|mode\\)\\'")
  "Variables whose value is code, a file or a matcher, or the API's own: Cal
approves setting them.")

(defun homun-api--scalar-p (value)
  "Non-nil when VALUE is plain data that names no function: a number, a short
string, t, nil, a keyword, a symbol without a function, or a short list of
those."
  (cond ((or (numberp value) (booleanp value) (keywordp value)) t)
        ((stringp value) (<= (length value) 500))
        ((symbolp value) (not (fboundp value)))
        ((proper-list-p value) (and (<= (length value) 50) (seq-every-p #'homun-api--scalar-p value)))))

(defun homun-api--var-settable (name)
  "The variable NAME if an agent may set it at all, else fail."
  (let ((var (intern-soft name)))
    (unless (and var (string-match-p homun-api--settable-names name)
                 (not (string-match-p homun-api--secret-names name)))
      (homun-api--fail 'invalid "%s: only tooltip-*, x-gtk-*, gcmh-*, claude-*, homun-*, widgetry-*, never a secret" name))
    (unless (boundp var) (homun-api--fail 'invalid "%s is not bound" name))
    (when (or (special-form-p var) (keywordp var) (memq var '(nil t)))
      (homun-api--fail 'invalid "%s cannot be set" name))
    var))

(defun homun-api--var-set-risk (name value _buffer reset)
  "Why setting NAME to VALUE needs Cal, or nil: risky names, values that are not
plain."
  (let ((var (homun-api--var-settable name)))
    (cond (reset nil)
          ((or (string-match-p homun-api--risky-names name) (get var 'risky-local-variable))
           "the variable holds code, a path or a matcher")
          ((not (homun-api--scalar-p value)) "the value is not plain data")
          ((not (homun-api--scalar-p (default-value var))) "the variable holds more than plain data"))))

(homun-api-define "variable set" "Set the variable NAME (in BUFFER only when given, else its default value) to VALUE, plain Lisp data: a number, string, t, nil, a keyword or a list of those.  RESET gives a claude-*, homun-* or widgetry-* variable the value its definition in the cockpit's Elisp has now (a reloaded file keeps the old one).  Only tooltip-*, x-gtk-*, gcmh-*, claude-*, homun-* and widgetry-* variables, never a secret; one that holds code, a path or more than plain data asks Cal first."
    ((name string :required t) (value data) (buffer string) (reset bool))
  :approve #'homun-api--var-set-risk
  (let ((var (homun-api--var-settable name)))
    (if reset
        (let* ((file (symbol-file var 'defvar))
               (source (and file (concat (file-name-sans-extension file) ".el")))
               (form (or (and source (string-match-p homun-api--own-names name)
                              (homun-api--defvar-form var (homun-api--allowed-file source)))
                         (homun-api--fail 'invalid "no definition of %s in the cockpit's Elisp" name))))
          (set-default var (eval (nth 2 form) t)))
      (if buffer
          (with-current-buffer (homun-api--buffer buffer)
            (set (make-local-variable var) value))
        (set-default var value)))
    (json-encode (list :name name :value (homun-api--printed (if (and buffer (not reset))
                                                                  (buffer-local-value var (get-buffer buffer))
                                                                (default-value var))
                                                              2000)
                       :local (homun-api--flag (and buffer (not reset)))))))

(defun homun-api--setting (var)
  "The row (VARIABLE KIND DOC . PROPS) of the settings page for VAR."
  (or (seq-some (lambda (group) (assq var (cdr group))) claude-settings-groups)
      (homun-api--fail 'invalid "%s is not on the settings page (settings list)" var)))

(defun homun-api--setting-ok (row value)
  "Non-nil when VALUE fits the settings ROW."
  (pcase-let ((`(,_ ,kind ,_ . ,props) row))
    (let ((in-range (lambda (n) (<= (or (plist-get props :min) n) n (or (plist-get props :max) n)))))
      (pcase kind
        ('boolean (booleanp value))
        ('choice (memq value (plist-get props :choices)))
        ('set (and (proper-list-p value)
                   (seq-every-p (lambda (v) (memq v (plist-get props :choices))) value)))
        ('number (and (numberp value) (funcall in-range value)))
        ('integer (and (integerp value) (funcall in-range value)))
        ('distance (or (null value) (and (integerp value) (funcall in-range value))))))))

(homun-api-define "settings get" "The rows of the user's settings page: variable, kind, value, default, limits, choices."
    ()
  (require 'claude-settings)
  (homun-api--json-rows
   (mapcan (lambda (group)
             (mapcar (pcase-lambda (`(,var ,kind ,_ . ,props))
                       (append (list :var var :kind kind
                                     :value (homun-api--printed (default-value var) 200)
                                     :default (homun-api--printed (claude-settings--default-of var) 200))
                               (and (plist-get props :min) (list :min (plist-get props :min)))
                               (and (plist-get props :max) (list :max (plist-get props :max)))
                               (and (plist-get props :choices)
                                    (list :choices (vconcat (plist-get props :choices))))))
                     (seq-filter (lambda (row) (boundp (car row))) (cdr group))))
           claude-settings-groups)))

(homun-api-define "settings set" "Set one variable of the user's settings page to VALUE (Lisp data: 6, 0.4, t, nil, diff, (border tick)) and save it; RESET puts its default back. It is checked against the row's kind, limits and choices."
    ((var symbol :required t) (value data) (reset bool))
  :approve (lambda (var &rest _)
             (when (get var 'risky-local-variable) (format "set %s, a setting that decides for Cal" var)))
  (require 'claude-settings)
  (let ((row (homun-api--setting var)))
    (unless (boundp var) (homun-api--fail 'invalid "%s is not loaded yet" var))
    (when reset (setq value (claude-settings--default-of var)))
    (unless (homun-api--setting-ok row value)
      (homun-api--fail 'invalid "%s: %S is not a valid %s value" var value (nth 1 row)))
    (claude-settings-set var value)
    (claude-settings--flush)
    (json-encode (list :var var :value (homun-api--printed (default-value var) 200)))))

(homun-api-define "library check" "Is NAME loaded as a feature, where is its library, is it a function or a variable and which file defines it."
    ((name string :required t))
  (let ((symbol (intern-soft name)))
    (json-encode (list :name name
                       :feature (homun-api--flag (and symbol (featurep symbol)))
                       :library (locate-library name)
                       :function (homun-api--flag (and symbol (fboundp symbol)))
                       :variable (homun-api--flag (and symbol (boundp symbol)))
                       :file (and symbol (or (symbol-file symbol 'defun)
                                             (symbol-file symbol 'defvar)))))))

(homun-api-define "mode set" "Turn the minor mode MODE on or off: in BUFFER, or without it everywhere (a global mode once, a local one in every buffer where it differs).  A mode not named claude-*, homun-* or widgetry-* asks Cal first."
    ((mode symbol :required t) (state enum :required t :choices ("on" "off")) (buffer string))
  :approve (lambda (mode &rest _)
             (unless (string-match-p homun-api--own-names (symbol-name mode))
               "a mode outside the cockpit's own claude-*, homun-*, widgetry-*"))
  (unless (and (fboundp mode) (memq mode minor-mode-list))
    (homun-api--fail 'invalid "%s is not a minor mode" mode))
  (let* ((on (equal state "on"))
         (flip (lambda (b)
                 (with-current-buffer b
                   (unless (eq on (and (boundp mode) (symbol-value mode) t))
                     (funcall mode (if on 1 -1))
                     t))))
         (buffers (cond (buffer (list (or (get-buffer buffer)
                                          (homun-api--fail 'invalid "no buffer %s" buffer))))
                        ((and (boundp mode) (not (local-variable-if-set-p mode)))
                         (list (current-buffer)))
                        (t (seq-remove (lambda (b) (string-prefix-p " " (buffer-name b)))
                                       (buffer-list))))))
    (json-encode (list :mode mode :state state
                       :changed (length (delq nil (mapcar flip buffers)))))))

(defun homun-api--view-clipboard ()
  "How many characters the clipboard and the primary selection hold; never what
they hold."
  (let ((size (lambda (type)
                (let ((text (ignore-errors (gui-get-selection type))))
                  (and (stringp text) (length text))))))
    (json-encode (list :clipboard (funcall size 'CLIPBOARD) :primary (funcall size 'PRIMARY)))))

;;; Measurements: what the daemon spends its time on.  Nothing here changes a setting;
;; the two that take longer than a call may (profile, bench) run from a timer and
;; keep their answer for `profile report' and `bench report'.

(defun homun-api--callable (function)
  "FUNCTION as a short name."
  (if (symbolp function) (symbol-name function)
    ;; compiled code prints as raw bytes, which cut an answer short
    (replace-regexp-in-string "[^[:print:]]" "?" (homun-api--printed function 90))))

(defun homun-api--seconds (time)
  (if time (float-time time) 0.0))

(defvar homun-api--profile nil "The answer of the last `profile start', or its state.")

(defun homun-api--profile-lines (nodes total depth max-depth floor)
  "Lines for the calltree NODES of at least FLOOR samples, down to MAX-DEPTH."
  (mapcan (lambda (node)
            (let ((count (profiler-calltree-count node)))
              (when (>= count floor)
                (cons (format "%s%5.1f%% %6d %s" (make-string depth ?\s)
                              (/ (* 100.0 count) total) count
                              (homun-api--callable (profiler-calltree-entry node)))
                      (and (< depth max-depth)
                           (homun-api--profile-lines (profiler-calltree-children node)
                                                     total (1+ depth) max-depth floor))))))
          (sort (copy-sequence nodes)
                (lambda (a b) (> (profiler-calltree-count a) (profiler-calltree-count b))))))

(defun homun-api--profile-finish (seconds started keys gcs gc-time)
  "Stop the CPU profiler and keep its report as text."
  (profiler-cpu-stop)
  (setq homun-api--profile
        (condition-case err
            (let* ((log (profiler-cpu-log))
                   (tree (profiler-calltree-children (profiler-calltree-build log)))
                   (leaves (profiler-calltree-children (profiler-calltree-build log :reverse t)))
                   (total (max 1 (apply #'+ (mapcar #'profiler-calltree-count tree))))
                   (floor (max 1 (round (* 0.01 total)))))
              (string-join
               (append
                (list (format "cpu profile: asked %d s, ran %.1f s, %d samples, %d keys typed, %d gcs taking %.2f s, idle %.0f s at the end"
                              seconds (float-time (time-since started)) total
                              (- num-input-keys keys) (- gcs-done gcs) (- gc-elapsed gc-time)
                              (homun-api--seconds (current-idle-time)))
                      "call tree (share, samples):")
                (seq-take (homun-api--profile-lines tree total 0 14 floor) 140)
                (list "by function itself (callers below it):")
                (seq-take (homun-api--profile-lines leaves total 0 1 floor) 60))
               "
"))
          (error (format "profile failed: %s" (error-message-string err)))))
  (homun-freeze-watch-profiler-reclaim))

(defun homun-api--profile-start (seconds)
  (require 'profiler)
  (require 'homun-freeze-watch)
  ;; The freeze watch owns the profiler; it lends it for the profile and takes it back after
  (unless (and (not (eq homun-api--profile 'running)) (homun-freeze-watch-profiler-lend))
    (homun-api--fail 'failed "a profile is running"))
  (profiler-cpu-start profiler-sampling-interval)
  (setq homun-api--profile 'running)
  (run-at-time seconds nil #'homun-api--profile-finish seconds (current-time)
               num-input-keys gcs-done gc-elapsed)
  (format "profiling for %d s" seconds))

(defvar homun-api--bench nil "The answer of the last `bench start', or its state.")

(defun homun-api--bench-run (target runs)
  (setq homun-api--bench
        (condition-case err
            (let ((result
                   (pcase target
                     ("board" (with-current-buffer "*claude-board*"
                                (benchmark-run runs (claude-board--draw))))
                     ("transcript" (with-current-buffer (homun-api--transcript-buffer nil)
                                     (let ((inhibit-read-only t))
                                       (benchmark-run runs
                                         (claude-transcript-refresh claude-transcript--turns)))))
                     ("display" (benchmark-run runs
                                  (dolist (frame (frame-list))
                                    (dolist (window (window-list frame 'no-minibuffer))
                                      (force-window-update window)))
                                  (redisplay t))))))
              (format "%s: %d runs, %.1f ms each, %d gcs taking %.1f ms in all"
                      target runs (/ (* 1000.0 (nth 0 result)) runs)
                      (nth 1 result) (* 1000.0 (nth 2 result))))
          (error (format "%s failed: %s" target (error-message-string err))))))

(homun-api-define "profile start" "Measure in the background: TARGET cpu profiles the CPU for SECONDS; board, transcript or display time RUNS redraws of the board, the first transcript's full render or every window.  `profile report' has the answer."
    ((target enum :required t :choices ("cpu" "board" "transcript" "display"))
     (seconds int :default 60 :max 300) (runs int :default 1 :max 20))
  (if (equal target "cpu") (homun-api--profile-start seconds)
    (setq homun-api--bench 'running)
    (run-at-time 0 nil #'homun-api--bench-run target runs)
    (format "timing %s" target)))

(homun-api-define "profile report" "The answer of the last `profile start': for cpu (the default) the call tree and the functions by their own time, in samples (1 ms each); for bench the last redraw timing."
    ((target enum :default "cpu" :choices ("cpu" "bench")))
  (setq homun-api-result-max 16000)
  (pcase (if (equal target "cpu") homun-api--profile homun-api--bench)
    ('nil (format "no %s yet" (if (equal target "cpu") "profile" "bench")))
    ('running "still running")
    (text text)))

(defun homun-api--view-timers ()
  "The timers and the idle timers: function, arguments, repeat interval, seconds
until due (the idle delay for an idle timer)."
  (setq homun-api-result-max 16000)
  (let ((row (lambda (idle)
               (lambda (timer)
                 (list :function (homun-api--callable (timer--function timer))
                       :args (homun-api--short
                              (mapconcat (lambda (arg)
                                           (if (bufferp arg) (format "%s" arg)
                                             (homun-api--printed arg 30)))
                                         (timer--args timer) " ")
                              60)
                       :repeat (timer--repeat-delay timer)
                       :idle (homun-api--flag idle)
                       :due (let ((at (float-time (timer--time timer))))
                              (/ (round (* 10 (if idle at (- at (float-time))))) 10.0)))))))
    (homun-api--json-rows (append (mapcar (funcall row nil) timer-list)
                                  (mapcar (funcall row t) timer-idle-list)))))

(defun homun-api--view-gc (live)
  "Garbage collection so far: count, seconds, the thresholds and what was
allocated (conses, floats, vector cells, symbols, string chars, intervals,
strings). Call it twice for a rate. LIVE runs one collection and adds what is
alive: per kind its size, used and free count."
  (json-encode (append (list :time (float-time) :gcs gcs-done :elapsed gc-elapsed
                             :threshold gc-cons-threshold :percentage gc-cons-percentage
                             :gcmh (homun-api--flag (bound-and-true-p gcmh-mode))
                             :allocated (vconcat (memory-use-counts)))
                       (and live (list :live (mapcar #'vconcat (garbage-collect)))))))

(defun homun-api--view-stats (max)
  "The daemon's process (CPU seconds so far, resident and virtual KiB, threads),
the user's idle seconds and key count, the load average, and the other processes
by CPU seconds. Call it twice for a rate."
  (let* ((cpu (lambda (attrs) (+ (homun-api--seconds (alist-get 'utime attrs))
                                 (homun-api--seconds (alist-get 'stime attrs)))))
         (own (process-attributes (emacs-pid)))
         (others (delq nil (mapcar (lambda (pid)
                                     (and (/= pid (emacs-pid))
                                          (when-let* ((attrs (process-attributes pid)))
                                            (list :pid pid :comm (alist-get 'comm attrs)
                                                  :cpu (funcall cpu attrs)
                                                  :rss (alist-get 'rss attrs)))))
                                   (list-system-processes)))))
    (homun-api--json-rows
     (seq-take (sort others (lambda (a b) (> (plist-get a :cpu) (plist-get b :cpu)))) max)
     :time (float-time) :cpu (funcall cpu own) :rss (alist-get 'rss own)
     :vsize (alist-get 'vsize own) :threads (alist-get 'thcount own)
     :idle (homun-api--seconds (current-idle-time)) :keys num-input-keys
     :load (vconcat (load-average t)) :processes (length others))))

(defun homun-api--view-notify ()
  "The file notification watches: path, callback, still valid."
  (require 'filenotify)
  (let (rows)
    (maphash (lambda (descriptor watch)
               (push (list :path (file-notify--watch-absolute-filename watch)
                           :callback (homun-api--callable (file-notify--watch-callback watch))
                           :valid (homun-api--flag (file-notify-valid-p descriptor)))
                     rows))
             file-notify-descriptors)
    (homun-api--json-rows rows)))

(defun homun-api--view-processes ()
  "Emacs's subprocesses and connections: name, status, pid, command, filter,
sentinel, buffer."
  (setq homun-api-result-max 16000)
  (homun-api--json-rows
   (mapcar (lambda (process)
             (list :name (process-name process) :status (process-status process)
                   :pid (process-id process)
                   :command (homun-api--short (format "%s" (process-command process)) 80)
                   :filter (homun-api--callable (process-filter process))
                   :sentinel (homun-api--callable (process-sentinel process))
                   :buffer (and (process-buffer process)
                                (buffer-name (process-buffer process)))))
           (process-list))))

(defun homun-api--view-ticks (max)
  "Per buffer how often its text changed (chars-modified tick), its size, overlays
and windows, most changed first. Call it twice for a rate of redraws."
  (setq homun-api-result-max 16000)
  (homun-api--json-rows
   (seq-take
    (sort (mapcar (lambda (buffer)
                    (with-current-buffer buffer
                      (list :name (buffer-name) :tick (buffer-chars-modified-tick)
                            :size (buffer-size)
                            :overlays (length (overlays-in (point-min) (point-max)))
                            :windows (length (get-buffer-window-list buffer nil t)))))
                  (buffer-list))
          (lambda (a b) (> (plist-get a :tick) (plist-get b :tick))))
    max)
   :time (float-time)))

(homun-api-define "daemon get" "Look at the daemon, read-only.  VIEW ping: up, version, pid; probe: pid, uptime and the error lines *Messages* got in the last hour, as JSON; statistics: its process, the user's idle time and the other processes by CPU (MAX); garbage-collection: garbage collection so far (LIVE runs one and adds what is alive); timers, processes, file-watches: the timers, subprocesses and file watches; buffer-changes: buffers by text changes (MAX); messages: the last MAX lines of *Messages*, newest first, MATCH a regexp; clipboard: how long the clipboard and primary selection are, never what they hold.  Call statistics, garbage-collection or buffer-changes twice for a rate."
    ((view enum :required t :choices ("ping" "probe" "statistics" "garbage-collection" "timers" "processes" "file-watches"
                                      "buffer-changes" "messages" "clipboard"))
     (max int :max 200) (match string) (live bool))
  (pcase view
    ("ping" (homun-api--ping))
    ("probe" (require 'claude-doctor) (json-serialize (claude-doctor-probe)))
    ("statistics" (homun-api--view-stats (min 40 (or max 10))))
    ("garbage-collection" (homun-api--view-gc live))
    ("timers" (homun-api--view-timers))
    ("processes" (homun-api--view-processes))
    ("file-watches" (homun-api--view-notify))
    ("buffer-changes" (homun-api--view-ticks (or max 40)))
    ("messages" (homun-api--view-messages (or max 30) match))
    ("clipboard" (homun-api--view-clipboard))))

(provide 'homun-api)
;;; homun-api.el ends here
