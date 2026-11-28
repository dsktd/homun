;;; claude-approve.el --- Approve the manager's permission prompts from the transcript -*- coding: utf-8; lexical-binding: t -*-

;; A PermissionRequest hook (`homund approve', or the session broker for a headless role) writes
;; a request file into `claude-approve-dir'/requests/ and waits for the answer; the record names
;; the tool, its input, the cwd, the worktree root, the agent and the risk class homund gave it.
;; Every pending request is one card of the one `approve' system scene on the Stage: a box (for
;; Allow/Deny selected), a risk dot, the agent, the command, Allow and Deny; the expander shows
;; where, why, the diff or code and a cheap preview (made off the redraw path).  The scene is a
;; function of the pending requests (`claude-approve-render'), so a card exists exactly while
;; its request is pending: answered here, in the terminal or by the phone, or past its window,
;; it goes at the next look.  A press writes `allow' or `deny' to answers/ID (temp file, then
;; rename) and appends one line to journal.jsonl.
;;
;; Input safety: the scene is displayed, never selected, and no key decides anything: every
;; decision is a button.  A new card shows dim text in place of its buttons for
;; `claude-approve-guard' seconds and ignores presses meanwhile (per request id, not per
;; redraw).  Allow on a destructive, outside-worktree or unclassified request confirms by hold,
;; and so does Allow selected when any ticked card needs one.
;;
;; Quiet mode (`claude-approve-quiet', off by default) writes the marker answers/quiet; while it
;; exists the hook allows read-only requests itself, with no card and nothing waiting on Emacs,
;; and journals them `via "auto"'; the queue's ticker lists the recent ones.
;;
;; The phone draws the very same scene: the root carries the requests as data and a remote
;; cockpit rebuilds it with its own clock, so the guard runs on the device too; its presses go
;; to the gateway through `claude-approve-answer-function'.
;;
;; Nothing here runs while nothing waits: a change in requests/ or in the event log (file
;; notifications) asks for a look, and looks repeat every `claude-approve-interval' only while
;; a request or a terminal dialog is pending (a request also goes stale by time alone).
;;
;; Trust: the answers directory is mounted read-only in every container but the editor's, so only
;; this Emacs can write an answer or the quiet marker.  No homun-api entry answers one, and
;; `ui_click' refuses these cards, on purpose.

(require 'cl-lib)
(require 'filenotify)
(require 'json)
(require 'claude-identity)
(require 'claude-transcript)
(require 'subr-x)
(require 'homun-stage-store)
(require 'widgetry-selection)
(defvar homun-stage-actions)
(defvar claude-events--items)
(defvar claude-events-dir)

(defvar claude-approve-dir (expand-file-name "~/claude/.services/approve/")
  "Directory of the hook's requests/ and Emacs's answers/.")

(defvar claude-approve-interval 1
  "Seconds between looks at the requests while something is pending, and from a new
event to the look it asks for.")

(defvar claude-approve-delay 0.1 "Seconds from a change in requests/ to the look at it.")

(defvar claude-approve-timeout 60
  "Seconds a request is good for when it does not say (the hook's default window).")

(defvar claude-approve-changed-hook nil
  "Functions called after the scene was made to show the pending requests.")
(defvar claude-approve--timer nil "The next look at the requests, when one is due.")
(defvar claude-approve--watch nil
  "The watch on requests/; nil when it could not be set, and looks then never stop.")
(defvar claude-approve--answers-watch nil "The watch on answers/.")
(defvar claude-approve--events-watch nil "The watch on the event log's directory.")
(defvar claude-approve--seen nil "Ids already announced in the echo area.")

(defun claude-approve--requests ()
  "The pending requests, oldest first, as alists (id tool summary since)."
  (let ((dir (expand-file-name "requests/" claude-approve-dir)) requests)
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\`[0-9]+-[0-9]+\\.json\\'"))
        (when-let* ((json (ignore-errors
                            (with-temp-buffer
                              (insert-file-contents file)
                              (json-parse-buffer :object-type 'alist)))))
          (unless (or (claude-approve--stale-p json)
                      (file-exists-p (expand-file-name (alist-get 'id json)
                                                       (expand-file-name "answers/" claude-approve-dir))))
            (push json requests)))))
    (nreverse requests)))

(defun claude-approve--stale-p (request &optional now)
  "Non-nil when REQUEST is older than its window: the hook has given up."
  (let ((since (alist-get 'since request))
        (timeout (alist-get 'timeout request)))
    (and (numberp since)
         (> (- (or now (float-time)) since)
            (if (numberp timeout) timeout claude-approve-timeout)))))

(defun claude-approve--terminal-wait ()
  "Non-nil when a dialog waits for an answer in the terminal: the event log's
newest permission or elicitation notice has no tool result or stop after it."
  (when (boundp 'claude-events--items)
    (let ((waiting nil) (settled nil))
      ;; Newest first: stop at the first event that decides it
      (cl-loop for item in claude-events--items
               for event = (plist-get item :event)
               until (or waiting settled)
               do (cond ((member event '("PostToolUse" "PostToolUseFailure" "Stop" "StopFailure"
                                         "UserPromptSubmit" "SessionStart" "SessionEnd"))
                         (setq settled t))
                        ((and (equal event "Notification")
                              (member (plist-get item :kind)
                                      '("permission_prompt" "elicitation_dialog")))
                         (setq waiting t))))
      waiting)))

(defvar claude-approve-answer-function nil
  "When non-nil, a function of ID and VERDICT that answers instead of the spool (a
remote cockpit).")

(defun claude-approve--journal (id answer)
  "Append the one journal line of ANSWER to request ID."
  (let ((file (expand-file-name "journal.jsonl" claude-approve-dir)))
    (make-directory claude-approve-dir t)
    (write-region (concat (json-serialize `(:time ,(format-time-string "%FT%TZ" nil t) :id ,id
                                            :answer ,answer :via "desktop"))
                          "\n")
                  nil file t 'silent)))

(defun claude-approve-deny-with (reason)
  "The deny verdict that tells the session REASON."
  (json-serialize (list :behavior "deny" :message reason)))

(defun claude-approve-answer (id verdict)
  "Answer request ID with VERDICT, \"allow\", \"deny\" or a JSON decision
\(an allow with answers, `claude-approve-deny-with' a reason)."
  (unless (and (or (member verdict '("allow" "deny"))
                   (and (stringp verdict) (string-match-p "\\`{\"behavior\":\"\\(allow\\|deny\\)\"" verdict)))
               (string-match-p "\\`[0-9]+-[0-9]+\\'" id))
    (error "Bad answer"))
  (if claude-approve-answer-function
      (funcall claude-approve-answer-function id verdict)
    (let* ((dir (expand-file-name "answers/" claude-approve-dir))
           (file (expand-file-name id dir))
           (temp (concat file ".tmp")))
      (make-directory dir t)
      (write-region verdict nil temp nil 'silent)
      (rename-file temp file t)
      (claude-approve--journal id (if (member verdict '("allow" "deny")) verdict "answers"))))
  (claude-approve--answered id))

(defun claude-approve--cleanup (_requests)
  "Delete answers whose request file is gone (the hook took it, or never wrote it)."
  (let ((dir (expand-file-name "answers/" claude-approve-dir)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\`[0-9]+-[0-9]+\\'"))
        (unless (file-exists-p (expand-file-name (concat (file-name-nondirectory file) ".json")
                                                 (expand-file-name "requests/" claude-approve-dir)))
          (ignore-errors (delete-file file)))))))

(defvar claude-approve--picks (make-hash-table :test 'equal)
  "Request id -> alist (question . label) chosen so far on an AskUserQuestion card.")

(defun claude-approve--send-answers (id questions)
  "Answer the AskUserQuestion request ID with the picks made for QUESTIONS."
  (let ((picks (gethash id claude-approve--picks)))
    (if (< (length picks) (length questions))
        (user-error "Answer every question first")
      (claude-approve-answer
       id (json-serialize
           `(:behavior "allow"
             :updatedInput (:answers ,(let ((h (make-hash-table :test 'equal)))
                                        (pcase-dolist (`(,q . ,label) picks) (puthash q label h))
                                        h))))
      )
      (remhash id claude-approve--picks))))

(defun claude-approve--pick (id question label multiple questions)
  "Record LABEL as the answer to QUESTION on card ID; send at once when that
finishes it."
  (let* ((picks (gethash id claude-approve--picks))
         (old (cdr (assoc question picks)))
         (new (if (and multiple old) (concat old ", " label) label)))
    (puthash id (cons (cons question new) (assoc-delete-all question picks)) claude-approve--picks)
    (if (and (not multiple) (= (length questions) 1))
        (claude-approve--send-answers id questions)
      (message "%s: %s" question new))))

(defun claude-approve--diff (request)
  "The unified-style diff REQUEST asks for (an edit or a write), or nil."
  (let ((input (alist-get 'input request)))
    (pcase (alist-get 'tool request)
      ((or "Edit" "MultiEdit")
       (when (or (alist-get 'old_string input) (alist-get 'new_string input))
         (concat (format "%s\n" (or (alist-get 'file_path input) ""))
                 (claude-approve--prefixed "-" (alist-get 'old_string input))
                 (claude-approve--prefixed "+" (alist-get 'new_string input)))))
      ("Write"
       (concat (format "%s\n" (or (alist-get 'file_path input) ""))
               (claude-approve--prefixed "+" (alist-get 'content input)))))))

(defun claude-approve--prefixed (mark text)
  (mapconcat (lambda (l) (concat mark l "\n")) (split-string (or text "") "\n") ""))

;;; Code shown on the card: formatted and fontified for reading; the request is untouched.

(defvar claude-approve-pp-limit 20000 "Longest Elisp text pretty-printed; longer is shown as written.")

(defun claude-approve--break-shell (command)
  "COMMAND with a line break after each top-level && || | ; (outside quotes).
Display only."
  (let ((out nil) (quote-char nil) (i 0) (n (length command)))
    (while (< i n)
      (let* ((c (aref command i))
             (len (if (and (memq c '(?& ?|)) (< (1+ i) n) (eq (aref command (1+ i)) c)) 2 1)))
        (cond
         ((eq c ?\\) (push (substring command i (min n (+ i 2))) out) (setq i (+ i 2)))
         (quote-char (when (eq c quote-char) (setq quote-char nil)) (push (string c) out) (cl-incf i))
         ((memq c '(?' ?\")) (setq quote-char c) (push (string c) out) (cl-incf i))
         ((and (memq c '(?& ?| ?\;)) (< (+ i len) n) (eq (aref command (+ i len)) ?\s))
          (push (concat (substring command i (+ i len)) "\n  ") out)
          (setq i (+ i len 1)))
         (t (push (string c) out) (cl-incf i)))))
    (apply #'concat (nreverse out))))

(defun claude-approve--pp (text)
  "TEXT of Elisp pretty-printed form by form; TEXT itself when too long or
unreadable."
  (or (and (<= (length text) claude-approve-pp-limit)
           (condition-case nil
               (let ((pos 0) forms)
                 (while (string-match-p "[^ \t\n]" (substring text pos))
                   (let ((r (read-from-string text pos)))
                     (push (string-trim-right (pp-to-string (car r))) forms)
                     (setq pos (cdr r))))
                 (and forms (string-join (nreverse forms) "\n")))
             (error nil)))
      text))

(defun claude-approve--code (request)
  "The code REQUEST asks to run as (TEXT . MODE), formatted for reading, or nil."
  (let* ((input (alist-get 'input request))
         (shell (alist-get 'command input))
         (elisp (or (alist-get 'code input) (alist-get 'expression input) (alist-get 'form input))))
    (cond ((stringp shell) (cons (claude-approve--break-shell shell) 'sh-mode))
          ((stringp elisp) (cons (claude-approve--pp elisp) 'emacs-lisp-mode)))))

(defun claude-approve--faced (string)
  "STRING with its `font-lock-face' copied to `face', for the Stage text."
  (let ((s (copy-sequence string)) (pos 0))
    (while (< pos (length s))
      (let ((next (next-single-property-change pos 'font-lock-face s (length s)))
            (face (get-text-property pos 'font-lock-face s)))
        (when face (put-text-property pos next 'face face s))
        (setq pos next)))
    s))

(defun claude-approve--code-text (request)
  "The fontified display text of REQUEST's code, all of it, or nil."
  (when-let* ((code (claude-approve--code request)))
    (let ((claude-transcript-fontify-limit most-positive-fixnum))
      (claude-approve--faced (claude-transcript--fontify (car code) (cdr code))))))

;;; Risk: the class the hook wrote (homund's `risk' module); a request without one is unclassified

(defun claude-approve--risk (request)
  "The risk class of REQUEST as a symbol; `unknown' when the hook named none."
  (pcase (alist-get 'risk request)
    ("read-only" 'read-only) ("writes" 'writes) ("network" 'network)
    ("outside" 'outside) ("destructive" 'destructive) (_ 'unknown)))

(defun claude-approve--hold-p (request)
  "Non-nil when allowing REQUEST needs a hold: destructive, outside the worktree,
or unclassified."
  (memq (claude-approve--risk request) '(destructive outside unknown)))

(defun claude-approve--explain (class)
  "The canned plain-language line of CLASS (templates, no model)."
  (pcase class
    ('destructive "destructive: deletes or overwrites for good; nothing goes to a trash.")
    ('outside "outside worktree: touches a path outside the agent's worktree, where git does not track it.")
    ('network "network: sends or fetches data over the network.")
    ('writes "writes: changes files inside the worktree; git can show and undo it.")
    ('read-only "read-only: only reads.")
    (_ "unclassified: the hook named no risk class.")))

(defun claude-approve--dot-face (class)
  (pcase class ((or 'destructive 'outside 'unknown) "err") ('network "warn") ('writes "ok") (_ "dim")))

;;; Previews: cheap and read-only, made off the redraw path, kept per request

(defvar claude-approve-preview-timeout 3 "Seconds a preview command may run.")
(defvar claude-approve--previews (make-hash-table :test 'equal)
  "Request id -> its preview text, or `pending' while it is made.")

(defun claude-approve--preview-done (id text)
  (when (gethash id claude-approve--previews)
    (puthash id (if (string-empty-p (string-trim text)) "(nothing)" (string-trim-right text))
             claude-approve--previews)
    (claude-approve--redraw)))

(defun claude-approve--preview-start (request)
  "Start making REQUEST's preview: the files an rm's globs match, the commits a
push sends."
  (let* ((id (alist-get 'id request))
         (cmd (alist-get 'command (alist-get 'input request)))
         (dir (file-name-as-directory (or (alist-get 'cwd request) "/"))))
    (cond
     ((and (stringp cmd) (string-match "\\`rm \\(?:-[a-zA-Z]+ \\)*\\([^;&|$`]*\\)\\'" cmd))
      (puthash id 'pending claude-approve--previews)
      (let ((globs (split-string (match-string 1 cmd))))
        (run-at-time 0 nil
                     (lambda ()
                       (let* ((default-directory dir)
                              (files (seq-take (mapcan #'file-expand-wildcards globs) 1000)))
                         (claude-approve--preview-done
                          id (format "would delete %d: %s" (length files)
                                     (string-join (seq-take files 8) " "))))))))
     ((and (stringp cmd) (string-prefix-p "git push" cmd) (file-directory-p dir))
      (puthash id 'pending claude-approve--previews)
      (let* ((buf (generate-new-buffer " *approve-preview*"))
             (proc (let ((default-directory dir))
                     (make-process :name "approve-preview" :buffer buf :noquery t
                                   :command '("git" "log" "--oneline" "-20" "@{u}..")
                                   :sentinel (lambda (p _)
                                               (unless (process-live-p p)
                                                 (claude-approve--preview-done
                                                  id (with-current-buffer buf (buffer-string)))
                                                 (kill-buffer buf)))))))
        (run-at-time claude-approve-preview-timeout nil
                     (lambda () (when (process-live-p proc) (delete-process proc)))))))))

(defun claude-approve--preview (request)
  "The preview text of REQUEST so far, or nil."
  (let ((p (gethash (alist-get 'id request) claude-approve--previews)))
    (if (eq p 'pending) "…" p)))

;;; State: the pending requests drawn, and per request id its card's view

(defvar claude-approve-guard 1.0 "Seconds a new card ignores presses.")

(defconst claude-approve-scene-id "approve" "The one scene of the approval queue.")

(defvar claude-approve--pending nil
  "The pending requests the scene draws, oldest first: the one source of the cards.")
(defvar claude-approve--ticker nil "The auto-allowed requests line, or nil.")
(defvar claude-approve--waiting nil "Non-nil while a dialog waits in the terminal.")
(defvar claude-approve--shown (make-hash-table :test 'equal) "Request id -> time its card appeared.")
(defvar claude-approve--open nil "Request ids whose card is expanded.")
(defvar claude-approve--selection
  (widgetry-selection-create nil (lambda (_) (claude-approve--redraw)))
  "Which queued requests are ticked for the bulk Allow and Deny.")

(defun claude-approve--ask-p (request) (equal (alist-get 'tool request) "AskUserQuestion"))

(defun claude-approve-armed-p (id &optional now)
  "Non-nil once the card of request ID has been up for `claude-approve-guard'."
  (when-let* ((since (gethash id claude-approve--shown)))
    (>= (- (or now (float-time)) since) claude-approve-guard)))

(defun claude-approve--find (id)
  (cl-find id claude-approve--pending :key (lambda (r) (alist-get 'id r)) :test #'equal))

;;; The scene

(defconst claude-approve-agent-width 12)
(defconst claude-approve-command-width 56)

(defun claude-approve--button (id suffix label &optional face hold tag)
  `((type . "widget") (kind . "button") (id . ,(format "approve-%s-%s" id suffix))
    (label . ,label) ,@(when tag `((tag . ,tag))) ,@(when face `((face . ,face)))
    ,@(when hold '((confirm . "hold")))))

(defun claude-approve--agent (request)
  "Who asks: the agent's name, the subagent's type, else main."
  (let ((agent (alist-get 'agent request)) (name (alist-get 'agent_name request)))
    (cond ((and (stringp name) (not (string-empty-p name))) name)
          ((and (listp agent) (alist-get 'type agent) (not (string-empty-p (alist-get 'type agent))))
           (alist-get 'type agent))
          ((stringp agent) agent)
          (t "main"))))

(defun claude-approve--oneline (request)
  "REQUEST as one line: the command fontified, else the tool and its subject."
  (let* ((input (alist-get 'input request)) (cmd (alist-get 'command input))
         (file (alist-get 'file_path input)) (root (alist-get 'root request)))
    (truncate-string-to-width
     (cond ((stringp cmd)
            (claude-approve--faced (claude-transcript--fontify (string-replace "\n" " " cmd) 'sh-mode)))
           ((stringp file) (format "%s %s" (alist-get 'tool request)
                                   (if (stringp root) (file-relative-name file root) file)))
           (t (format "%s %s" (alist-get 'tool request)
                      (string-replace "\n" " " (or (alist-get 'summary request) "")))))
     claude-approve-command-width nil nil "…")))

(defun claude-approve--line (request)
  "The summary text of REQUEST's card: risk dot, agent, the one line."
  (let ((class (claude-approve--risk request)))
    (concat (propertize "●" 'face (pcase (claude-approve--dot-face class)
                                    ("err" 'error) ("warn" 'warning) ("ok" 'success) (_ 'shadow)))
            " " (propertize (truncate-string-to-width (claude-approve--agent request)
                                                      claude-approve-agent-width nil ?\s "…")
                            'face 'shadow)
            " " (claude-approve--oneline request))))

(defun claude-approve--details (request)
  "The nodes under REQUEST's expanded card: where, why, the hold notice, preview."
  (let* ((id (alist-get 'id request)) (class (claude-approve--risk request))
         (diff (claude-approve--diff request)) (code (and (not diff) (claude-approve--code-text request)))
         (preview (claude-approve--preview request))
         (dim (lambda (key text) `((type . "text") (id . ,(format "%s-%s" key id)) (face . "dim")
                                   (text . ,(concat "    " text))))))
    `(,(funcall dim "where" (string-join (delq nil (list (and (alist-get 'cwd request)
                                                              (abbreviate-file-name (alist-get 'cwd request)))
                                                         (alist-get 'description (alist-get 'input request))
                                                         (alist-get 'summary request)))
                                         " · "))
      ,(funcall dim "explain" (claude-approve--explain class))
      ,@(when (claude-approve--hold-p request) (list (funcall dim "hold" "Allow needs a hold to confirm.")))
      ,@(when diff `(((type . "diffview") (id . ,(format "diff-%s" id)) (diff . ,diff))))
      ,@(when code `(((type . "text") (id . ,(format "code-%s" id)) (text . ,code))))
      ,@(when preview (list (funcall dim "preview" (string-replace "\n" "\n    " preview)))))))

(defun claude-approve--ask-nodes (id request)
  "The question text and option buttons of the AskUserQuestion REQUEST."
  (cl-loop for q in (append (alist-get 'questions (alist-get 'input request)) nil) for i from 0
           append `(((type . "text") (id . ,(format "q%d-%s" i id)) (face . "accent")
                     (text . ,(format "    %s%s" (alist-get 'question q)
                                      (if (eq t (alist-get 'multiSelect q)) " (several)" ""))))
                    ((type . "row") (id . ,(format "o%d-%s" i id))
                     (children . ,(cl-loop for o in (append (alist-get 'options q) nil) for j from 0
                                           collect (claude-approve--button
                                                    id (format "q%d-%d" i j) (alist-get 'label o)
                                                    nil nil (format " %s " (alist-get 'label o)))))))))

(defun claude-approve--card (request now)
  "The nodes of REQUEST's card: one line, the question or details, a blank after."
  (let* ((id (alist-get 'id request)) (ask (claude-approve--ask-p request))
         (armed (claude-approve-armed-p id now))
         (multi (cl-some (lambda (q) (eq t (alist-get 'multiSelect q)))
                         (alist-get 'questions (alist-get 'input request)))))
    `(((type . "row") (id . ,(format "head-%s" id))
       (children
        ,@(if ask `(((type . "text") (id . ,(format "nobox-%s" id)) (text . "  ")))
            `(((type . "widget") (kind . "check") (id . ,(format "approve-%s-tick" id))
               (value . ,(if (widgetry-selection-selected-p claude-approve--selection id) t :false)))))
        ,(claude-approve--button id "open" (if (member id claude-approve--open) "▾" "▸"))
        ((type . "text") (id . ,(format "line-%s" id)) (text . ,(claude-approve--line request)))
        ,@(cond ((not armed)
                 `(((type . "text") (id . ,(format "wait-%s" id)) (face . "dim")
                    (text . ,(if ask " Decline " " Allow  Deny ")))))
                (ask (append (when multi (list (claude-approve--button id "send" "Send" "ok")))
                             (list (claude-approve--button id "deny" "Decline" "err"))))
                (t (list (claude-approve--button id "allow" "Allow" "ok" (claude-approve--hold-p request))
                         (claude-approve--button id "deny" "Deny" "err"))))))
      ,@(when (and ask armed) (claude-approve--ask-nodes id request))
      ,@(when (member id claude-approve--open) (claude-approve--details request))
      ((type . "text") (id . ,(format "gap-%s" id)) (text . "")))))

(defun claude-approve-scene (requests &optional now waiting ticker)
  "The scene root of the queue of REQUESTS: a header, one card each, the ticker.
WAITING says a dialog waits in the terminal; TICKER is the auto-allowed line.
The root carries REQUESTS, WAITING and TICKER as data, so the phone builds the
same scene with its own clock."
  (let* ((sel claude-approve--selection)
         (queue (cl-remove-if #'claude-approve--ask-p requests))
         (danger (cl-some (lambda (r) (and (widgetry-selection-selected-p sel (alist-get 'id r))
                                            (claude-approve--hold-p r)))
                          queue)))
    (widgetry-selection-set-ids sel (mapcar (lambda (r) (alist-get 'id r)) queue))
    `((type . "col") (requests . ,(vconcat requests)) (waiting . ,(if waiting t :false))
      (ticker . ,(or ticker ""))
      (children
       ((type . "text") (id . "title") (face . "title")
        (text . ,(format "Permissions: %d waiting" (length requests))))
       ,@(when waiting
           '(((type . "text") (id . "waiting") (face . "warn") (text . "Waiting for an answer in the terminal"))))
       ,@(when queue
           `(((type . "row") (id . "header")
              (children
               ((type . "widget") (kind . "check") (id . "approve-all")
                (value . ,(pcase (widgetry-selection-state sel) ('all t) ('some "some") (_ :false))))
               ((type . "text") (id . "count") (face . "dim") (text . ,(widgetry-selection-summary sel)))
               ,@(unless (eq (widgetry-selection-state sel) 'none)
                   (list (claude-approve--button "sel" "allow" "Allow selected" "ok" danger)
                         (claude-approve--button "sel" "deny" "Deny selected" "err")))))))
       ((type . "text") (id . "gap") (text . ""))
       ,@(cl-loop for r in requests append (claude-approve--card r now))
       ,@(when (and ticker (not (string-empty-p ticker)))
           `(((type . "text") (id . "ticker") (face . "dim") (text . ,ticker))))))))

;;; Presses: every decision is a button, guarded per card; no key decides

(defun claude-approve--guarded (id fn)
  "FN, unless the card of request ID is still in its guard time or gone."
  (lambda (&rest args)
    (cond ((not (claude-approve--find id)) (message "claude-approve: %s is no longer pending" id))
          ((not (claude-approve-armed-p id)) (message "claude-approve: press on %s ignored, card just appeared" id))
          (t (apply fn args)))))

(defun claude-approve--bulk (verdict)
  "Answer every ticked, armed request with VERDICT."
  (dolist (id (copy-sequence (widgetry-selection-selected claude-approve--selection)))
    (if (claude-approve-armed-p id) (claude-approve-answer id verdict)
      (message "claude-approve: %s skipped, card just appeared" id))))

(defun claude-approve--toggle-open (id)
  (setq claude-approve--open (if (member id claude-approve--open) (remove id claude-approve--open)
                               (cons id claude-approve--open)))
  (when-let* (((member id claude-approve--open))
              (r (claude-approve--find id))
              ((not (gethash id claude-approve--previews))))
    (claude-approve--preview-start r))
  (claude-approve--redraw))

(defun claude-approve--actions (request)
  "Alist of button node id to the function a press of it calls, for REQUEST."
  (let* ((id (alist-get 'id request))
         (questions (append (alist-get 'questions (alist-get 'input request)) nil))
         (key (lambda (suffix) (format "approve-%s-%s" id suffix)))
         (guard (lambda (fn) (claude-approve--guarded id fn))))
    (append
     `((,(funcall key "open") . ,(lambda () (claude-approve--toggle-open id)))
       (,(funcall key "tick") . ,(lambda (&rest _) (widgetry-selection-toggle claude-approve--selection id)))
       (,(funcall key "deny") . ,(funcall guard (lambda () (claude-approve-answer id "deny")))))
     (if questions
         (cons (cons (funcall key "send") (funcall guard (lambda () (claude-approve--send-answers id questions))))
               (cl-loop for q in questions for i from 0
                        append (cl-loop for o in (append (alist-get 'options q) nil) for j from 0
                                        collect (let ((text (alist-get 'question q)) (label (alist-get 'label o))
                                                      (multiple (eq t (alist-get 'multiSelect q))))
                                                  (cons (funcall key (format "q%d-%d" i j))
                                                        (funcall guard (lambda () (claude-approve--pick
                                                                                   id text label multiple
                                                                                   questions))))))))
       `((,(funcall key "allow") . ,(funcall guard (lambda () (claude-approve-answer id "allow")))))))))

(defun claude-approve--arm ()
  "Make the buttons of exactly the pending cards and the header answer."
  (maphash (lambda (k _) (when (string-prefix-p "approve-" k) (remhash k homun-stage-actions)))
           homun-stage-actions)
  (dolist (r claude-approve--pending)
    (pcase-dolist (`(,node . ,fn) (claude-approve--actions r))
      (puthash node fn homun-stage-actions)))
  (when claude-approve--pending
    (puthash "approve-all" (lambda (&rest _) (widgetry-selection-toggle-all claude-approve--selection))
             homun-stage-actions)
    (puthash "approve-sel-allow" (lambda () (claude-approve--bulk "allow")) homun-stage-actions)
    (puthash "approve-sel-deny" (lambda () (claude-approve--bulk "deny")) homun-stage-actions)))

(defun claude-approve--tint (scene)
  "Tint the lines of the ticked cards (`homun-stage-render-functions')."
  (when (equal (homun-stage-scene-id scene) claude-approve-scene-id)
    (remove-overlays (point-min) (point-max) 'widgetry-selection-tint t)
    (dolist (id (widgetry-selection-selected claude-approve--selection))
      (save-excursion
        (goto-char (point-min))
        (when (text-property-search-forward 'homun-stage-node (format "line-%s" id) t)
          (widgetry-selection-tint (line-beginning-position) (min (point-max) (1+ (line-end-position)))))))))

(add-hook 'homun-stage-render-functions #'claude-approve--tint)

;;; Drawing: the scene is a function of the pending requests, so a card exists iff its request does

(defvar claude-approve--guard-timer nil)

(defun claude-approve-render (requests &optional waiting ticker)
  "Make the scene show exactly REQUESTS (and the terminal WAITING line, the
TICKER); close it when there is neither.  The desktop calls it with the spool, a
remote cockpit with what the gateway carried."
  (let* ((now (float-time)) (ids (mapcar (lambda (r) (alist-get 'id r)) requests))
         (open (gethash claude-approve-scene-id homun-stage-scenes)))
    (setq claude-approve--pending requests claude-approve--waiting waiting claude-approve--ticker ticker
          claude-approve--open (seq-intersection claude-approve--open ids))
    (dolist (table (list claude-approve--shown claude-approve--previews claude-approve--picks))
      (dolist (k (hash-table-keys table)) (unless (member k ids) (remhash k table))))
    (dolist (id ids) (unless (gethash id claude-approve--shown) (puthash id now claude-approve--shown)))
    (claude-approve--arm)
    (if (or requests waiting)
        (let ((root (claude-approve-scene requests now waiting ticker)))
          (unless (and open (equal root (homun-stage-scene-root open)))
            (homun-stage-show "approve" claude-approve-scene-id
                              (format "Permissions (%d)" (length requests)) root "system")
            (unless (or open (bound-and-true-p homun-layout-phone)) ; the phone's own card shows it
              (homun-stage-display claude-approve-scene-id)))
          ;; Redraw when the youngest card's guard ends, to swap its dim text for buttons
          (when-let* ((wait (cl-loop for id in ids for left = (- (+ (gethash id claude-approve--shown)
                                                                    claude-approve-guard)
                                                                 now)
                                     when (> left 0) maximize left)))
            (when (timerp claude-approve--guard-timer) (cancel-timer claude-approve--guard-timer))
            (setq claude-approve--guard-timer (run-at-time (+ wait 0.05) nil #'claude-approve--redraw))))
      (when open (homun-stage-close "approve" claude-approve-scene-id)))
    (run-hooks 'claude-approve-changed-hook)))

(defun claude-approve--redraw ()
  "Draw the scene again from the requests it has, for a change of view only."
  (claude-approve-render claude-approve--pending claude-approve--waiting claude-approve--ticker))

(defun claude-approve--answered (id)
  "Request ID was answered here: its card goes at once."
  (if claude-approve-answer-function
      (claude-approve-render (cl-remove id claude-approve--pending :key (lambda (r) (alist-get 'id r))
                                        :test #'equal)
                             claude-approve--waiting claude-approve--ticker)
    (claude-approve--draw)))

(defvar claude-approve-ticker-window 600 "Seconds an auto-allowed request stays on the ticker.")

(defun claude-approve--ticker-text (&optional now)
  "The ticker of the newest requests quiet mode allowed in the last
`claude-approve-ticker-window' seconds, or nil."
  (let* ((file (expand-file-name "journal.jsonl" claude-approve-dir))
         (size (file-attribute-size (file-attributes file)))
         (since (- (or now (float-time)) claude-approve-ticker-window))
         (rows nil))
    (when size
      (with-temp-buffer
        (insert-file-contents file nil (max 0 (- size 16384)) size)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((row (ignore-errors (json-parse-string line :object-type 'alist)))
                      ((equal (alist-get 'via row) "auto"))
                      (time (ignore-errors (float-time (date-to-time (alist-get 'time row)))))
                      ((> time since)))
            (push (format "%s %s" (alist-get 'agent row "") (alist-get 'summary row "")) rows)))))
    (when rows
      (concat "auto: " (mapconcat (lambda (s) (truncate-string-to-width s 40 nil nil "…"))
                                  (seq-take rows 5) " · ")))))

(defun claude-approve--draw ()
  "Make the Stage show exactly the pending requests, in the one queue scene."
  (unless claude-approve-answer-function ; a remote cockpit shows what the gateway sends
    (claude-approve--draw-1)))

(defun claude-approve--draw-1 ()
  (let* ((requests (claude-approve--requests))
         (ids (mapcar (lambda (r) (alist-get 'id r)) requests))
         (waiting (and (not ids) (claude-approve--terminal-wait))))
    (claude-approve--cleanup requests)
    (dolist (r requests)
      (unless (gethash (alist-get 'id r) claude-approve--shown)
        (message "%s asks permission: %s %s" (claude-approve--agent r) (alist-get 'tool r)
                 (truncate-string-to-width (or (alist-get 'summary r) "") 60))))
    (claude-approve-render requests waiting (and ids (claude-approve--ticker-text)))
    ;; Look again while something is pending, or all the time when requests/ is not watched
    (when (or ids waiting (not (file-notify-valid-p claude-approve--watch)))
      (claude-approve--look-in claude-approve-interval))))

;;; Quiet mode: the hook allows read-only requests itself while answers/quiet exists

(defun claude-approve--quiet-sync (&optional _symbol value op where)
  "Make the marker answers/quiet match `claude-approve-quiet', or VALUE when the
variable watcher calls it for a global `set' (OP); a let or a buffer-local WHERE
changes nothing."
  (let ((marker (expand-file-name "answers/quiet" claude-approve-dir))
        (on (if op (and (eq op 'set) value) (default-value 'claude-approve-quiet))))
    (cond ((or where (memq op '(let unlet defvaralias))))
          (on (make-directory (file-name-directory marker) t)
              (write-region "" nil marker nil 'silent))
          ((file-exists-p marker) (delete-file marker)))))

(defcustom claude-approve-quiet nil
  "Non-nil: the PermissionRequest hook allows read-only requests itself, journaled
`via \"auto\"' and listed on the queue's ticker.  Off by default."
  :type 'boolean :group 'claude)
(put 'claude-approve-quiet 'risky-local-variable t)
(add-variable-watcher 'claude-approve-quiet #'claude-approve--quiet-sync)

(defun claude-approve--look-in (seconds)
  "Look at the requests in SECONDS, unless a look is due before that."
  (let ((due (and (memq claude-approve--timer timer-list)
                  (- (float-time (timer--time claude-approve--timer)) (float-time)))))
    (unless (and due (<= due seconds))
      (when due (cancel-timer claude-approve--timer))
      (setq claude-approve--timer
            (run-with-timer seconds nil
                            (lambda () (with-demoted-errors "claude-approve: %S"
                                         (claude-approve--draw))))))))

(defun claude-approve--watch-dir (dir delay)
  "Look at the requests DELAY seconds after a change in DIR; the watch, or nil."
  (ignore-errors
    (file-notify-add-watch dir '(change) (lambda (_) (claude-approve--look-in delay)))))

;;;###autoload
(defun claude-approve-start ()
  "Watch for permission requests."
  (interactive)
  (when (timerp claude-approve--timer) (cancel-timer claude-approve--timer))
  (mapc #'file-notify-rm-watch (list claude-approve--watch claude-approve--answers-watch
                         claude-approve--events-watch))
  (let ((requests (expand-file-name "requests/" claude-approve-dir))
        (answers (expand-file-name "answers/" claude-approve-dir)))
    (ignore-errors (make-directory requests t))
    (ignore-errors (make-directory answers t))
    (setq claude-approve--watch
          (claude-approve--watch-dir requests claude-approve-delay)
          claude-approve--answers-watch
          (claude-approve--watch-dir answers claude-approve-delay)
          claude-approve--events-watch
          (claude-approve--watch-dir (bound-and-true-p claude-events-dir) claude-approve-interval)))
  (claude-approve--quiet-sync)
  ;; Scenes of the old one-scene-per-request cards, left in the store
  (dolist (sid (hash-table-keys homun-stage-scenes))
    (when (string-match-p "\\`approve-[0-9]+-[0-9]+\\'" sid) (ignore-errors (homun-stage-close "approve" sid))))
  (claude-approve--look-in claude-approve-delay))

(claude-approve-start)
(provide 'claude-approve)
;;; claude-approve.el ends here
