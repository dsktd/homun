;;; claude-questions.el --- Org files of questions the user answers -*- lexical-binding: t -*-

;;; Commentary:

;; `claude-questions' opens an Org file of the manager's questions in an
;; `org-claude-mode' buffer; the answers land in answers/ as JSON, where
;; `claude-emacs questions' waits for them.  The format is shown in
;; questions-example.org and described in the wrapper's docs/development.md.
;;
;;;; Terminology
;;
;; A question is a heading with an :ID: property.  Its choices are the
;; checkbox items of its own text; `- [ ] Other: ...' is a write-in whose
;; text after the colon is the answer, `- [ ] Skip / wrong question' pushes
;; back.  Notes are `#+begin_note' blocks (the older `** Answer' heading and
;; `#+begin_answer' block still work).  A `*** Manager' heading is the manager's reply
;; and never part of the answer.
;;
;;;; Structure
;;
;; A question is OPEN (the default state), STAGED (answered, saved, folded), N/A (its :WHEN:
;; condition fails: dimmed and folded) or DONE (sent).  Saving stages, a
;; checkbox change re-checks the conditions, and a submit sends what is
;; answered: the last one, once nothing is left open, closes the buffer.
;;
;; Chaining: every waiting `claude-emacs questions' call registers its id and
;; file.  Before a frame closes (last submit, decline or killing the buffer)
;; the oldest other registered buffer that still has open questions takes its
;; place in the same frame; the header says how many come after it.  The
;; frame closes when none are left.  A registered id is stale, and skipped,
;; once its buffer is gone, its caller timed out, its file is gone or its
;; answers (or decline marker) are written.  "Close all" in the menu leaves
;; every buffer alive for later.  Each buffer keeps answering its own caller.
;;
;;;; Conditions
;;
;; :WHEN: is an AND of space-separated terms, `id=choice' (that choice of
;; question id is ticked) or `!id=choice' (it is not); quote a choice with
;; spaces as id="two words".  A question that is N/A counts as nothing
;; ticked, so conditions chain.

;;; Code:

(declare-function claude-bus-tell "claude-bus")
(require 'homun-stage)
(require 'homun-layout)
(require 'subr-x)
(require 'org-element)
(require 'org-claude)
(require 'claude)
(require 'transient)

;;;; Customization

(defvar claude-questions-skip-choice "Skip / wrong question"
  "The choice that pushes back on a question instead of answering it.")

(defvar claude-questions-other-regexp "\\`other:[ \t]*"
  "What starts a write-in choice; the text after it is the answer.")

;;;; State

(defvar-local claude-questions--parts 0 "Partial submits sent so far.")
(defvar-local claude-questions--frame nil "The frame made for this buffer, if any.")
(defvar-local claude-questions-hide-na nil "Non-nil hides N/A questions entirely.")
(defvar-local claude-questions--more 0 "Pending buffers after this one.")

(defvar claude-questions-changed-hook nil "Functions called when a waiting call comes or goes.")

(defvar claude-questions--waiting nil
  "The waiting calls as (ID . FILE), oldest first.")

;;;; Pending buffers

(defun claude-questions--register (id file)
  "Add the waiting call ID, whose questions are FILE, after the others."
  (setq claude-questions--waiting
        (append (assoc-delete-all id claude-questions--waiting) (list (cons id file))))
  (run-hooks 'claude-questions-changed-hook))

(defun claude-questions--unregister (id)
  "Forget the waiting call ID."
  (setq claude-questions--waiting (assoc-delete-all id claude-questions--waiting))
  (run-hooks 'claude-questions-changed-hook))

(defun claude-questions--open-p (q)
  "Non-nil when Q still waits for an answer: not DONE and not N/A."
  (not (member (alist-get 'state q) '("DONE" "N/A"))))

(defun claude-questions--pending-buffer (entry)
  "The buffer of waiting ENTRY (ID . FILE) when it is worth showing, else nil."
  (let* ((id (car entry))
         (buffer (get-buffer (claude--ask-buffer-name id))))
    (and buffer
         (file-exists-p (cdr entry))
         (not (file-exists-p (expand-file-name id claude-answers-dir)))
         (not (file-exists-p (expand-file-name (concat id ".declined") claude-answers-dir)))
         (with-current-buffer buffer
           (and (not claude-ask-timed-out)
                (seq-some #'claude-questions--open-p (claude-questions--all))))
         buffer)))

(defun claude-questions--pending (&optional except)
  "The buffers with open questions, oldest first, without EXCEPT."
  (delq except (delq nil (mapcar #'claude-questions--pending-buffer
                                 claude-questions--waiting))))

(defun claude-questions--count-more ()
  "Tell each pending buffer how many come after it, for its header line."
  (let ((pending (claude-questions--pending)))
    (dolist (buffer pending)
      (with-current-buffer buffer
        (setq claude-questions--more (1- (length pending)))))))

(defun claude-questions--show-next (buffer)
  "Show the next pending buffer in the window of BUFFER; non-nil when there is one.
It takes over the frame made for BUFFER, so closing it closes that frame."
  (let ((next (car (claude-questions--pending buffer)))
        (window (get-buffer-window buffer t)))
    (when (and next window)
      (homun-layout-show next window)
      (with-current-buffer next
        (unless claude-questions--frame
          (setq claude-questions--frame (buffer-local-value 'claude-questions--frame buffer))))
      (when (eq (window-frame window) (selected-frame))
        (save-current-buffer (select-window window)))
      (claude-questions--count-more)
      t)))

;;;; Reading the buffer

(defun claude-questions--own-p (element question)
  "Non-nil when ELEMENT belongs to QUESTION, not to a the manager reply in it."
  (let ((parent (org-element-property :parent element))
        (own t))
    (while (and own parent (not (eq parent question)))
      (when (and (eq (org-element-type parent) 'headline)
                 (equal (org-element-property :raw-value parent) "Manager"))
        (setq own nil))
      (setq parent (org-element-property :parent parent)))
    own))

(defun claude-questions--contents (element)
  "The trimmed text inside ELEMENT, or \"\"."
  (let ((begin (org-element-property :contents-begin element))
        (end (org-element-property :contents-end element)))
    (if (and begin end) (string-trim (buffer-substring-no-properties begin end)) "")))

(defun claude-questions--item-of (element)
  "The nearest list item containing ELEMENT, or nil."
  (org-element-lineage element '(item)))

(defun claude-questions--blocks (question type)
  "The texts of QUESTION's own special blocks of TYPE, outside its list items.
A block indented under a checkbox item belongs to that item."
  (org-element-map question 'special-block
    (lambda (b)
      (when (and (equal (downcase (org-element-property :type b)) type)
                 (claude-questions--own-p b question)
                 (not (claude-questions--item-of b)))
        (claude-questions--contents b)))))

(defun claude-questions--buffer-notes ()
  "The texts of the note blocks before the first heading."
  (org-element-map (org-element-parse-buffer) 'special-block
    (lambda (b)
      (when (and (equal (downcase (org-element-property :type b)) "note")
                 (not (org-element-lineage b '(headline))))
        (let ((text (claude-questions--contents b)))
          (unless (string-empty-p text) text))))))

(defun claude-questions--item-notes (item)
  "The joined text of the note blocks that belong to ITEM itself, or \"\"."
  (string-join
   (seq-remove #'string-empty-p
               (org-element-map item 'special-block
                 (lambda (b)
                   (when (and (equal (downcase (org-element-property :type b)) "note")
                              (eq (claude-questions--item-of b) item))
                     (claude-questions--contents b)))))
   "\n\n"))

(defun claude-questions--answer-text (question)
  "The text of QUESTION's `** Answer' heading or answer block, or nil."
  (or (org-element-map question 'headline
        (lambda (h)
          (when (and (not (eq h question))
                     (equal (org-element-property :raw-value h) "Answer"))
            (claude-questions--contents h)))
        nil t)
      (car (claude-questions--blocks question "answer"))))

(defun claude-questions--items (question)
  "QUESTION's checkbox items as (TEXT TICKED NOTES)."
  (org-element-map question 'item
    (lambda (i)
      (when (and (org-element-property :checkbox i)
                 (claude-questions--own-p i question))
        (list (or (org-element-map i 'paragraph #'claude-questions--contents nil t) "")
              (eq (org-element-property :checkbox i) 'on)
              (claude-questions--item-notes i))))))

(defun claude-questions--choice (text)
  "The answer TEXT of a ticked item gives: a write-in's text, nil when blank."
  (let ((case-fold-search t))
    (if (string-match claude-questions-other-regexp text)
        (let ((written (string-trim (substring text (match-end 0)))))
          (unless (string-match-p "\\`_*\\'" written) written))
      text)))

(defun claude-questions--read (question)
  "QUESTION, a headline element, as an alist of what the user gave."
  (let* ((items (claude-questions--items question))
         (ticked (mapcar #'car (seq-filter #'cadr items)))
         (skipped (and (member claude-questions-skip-choice ticked) t))
         (choices (unless skipped
                    (delq nil (mapcar #'claude-questions--choice
                                      (remove claude-questions-skip-choice ticked)))))
         (answer (claude-questions--answer-text question))
         (choice-notes (delq nil (mapcar (lambda (i)
                                           (unless (string-empty-p (nth 2 i))
                                             (cons (intern (car i)) (nth 2 i))))
                                         items)))
         (notes (string-join (claude-questions--blocks question "note") "\n\n"))
         (text (string-join (seq-remove #'string-empty-p (list (or answer "") notes)) "\n\n")))
    `((id . ,(org-element-property :ID question))
      (question . ,(org-element-property :raw-value question))
      (state . ,(org-element-property :todo-keyword question))
      (when . ,(org-element-property :WHEN question))
      (one . ,(not (equal (org-element-property :SELECT question) "many")))
      (begin . ,(org-element-property :begin question))
      (items . ,(and items t))
      (choices . ,choices)
      (skipped . ,skipped)
      (notes . ,notes)
      (choice-notes . ,choice-notes)
      (text . ,text))))

(defun claude-questions--all ()
  "Every question in the buffer, read, in order."
  (org-element-map (org-element-parse-buffer) 'headline
    (lambda (h) (when (org-element-property :ID h) (claude-questions--read h)))))

(defun claude-questions--answered-p (q)
  "Non-nil when Q is answered: pushed back, a choice made, or text written."
  (let-alist q
    (cond (.skipped t)
          (.items (and .choices t))
          (t (not (string-empty-p .text))))))

;;;; Conditions

(defun claude-questions--parse-when (when)
  "WHEN as a list of (NEGATED ID . CHOICE); nil for no condition."
  (let ((start 0) (terms nil))
    (while (string-match "[ \t]*\\([^ \t]\\)" (or when "") start)
      (setq start (match-beginning 1))
      (unless (eq (string-match "\\(!?\\)\\([^=! \t\"]+\\)=\\(\"\\([^\"]+\\)\"\\|[^ \t\"]+\\)"
                                when start)
                  start)
        (user-error "Bad :WHEN: at %S (id=choice or !id=choice)" (substring when start)))
      (push (cons (equal (match-string 1 when) "!")
                  (cons (match-string 2 when) (or (match-string 4 when) (match-string 3 when))))
            terms)
      (setq start (match-end 0)))
    (nreverse terms)))

(defun claude-questions--holds-p (terms ticks)
  "Non-nil when every one of TERMS holds against TICKS, an alist (ID . CHOICES)."
  (seq-every-p (lambda (term)
                 (let ((on (seq-some (lambda (c) (string-equal-ignore-case c (cddr term)))
                                     (cdr (assoc (cadr term) ticks)))))
                   (if (car term) (not on) on)))
               terms))

(defun claude-questions--na (questions)
  "The ids of QUESTIONS whose condition fails; DONE ones never do.
A question that is N/A counts as nothing ticked, so the check repeats
until the set stops changing."
  (let ((na nil) (last t))
    (while (not (equal na last))
      (setq last na
            na (let ((ticks (mapcar (lambda (q)
                                      (let-alist q
                                        (cons .id (unless (member .id last)
                                                    (if .skipped
                                                        (list claude-questions-skip-choice)
                                                      .choices)))))
                                    questions)))
                 (delq nil
                       (mapcar (lambda (q)
                                 (let-alist q
                                   (when (and (not (equal .state "DONE"))
                                              (not (claude-questions--holds-p
                                                    (claude-questions--parse-when .when) ticks)))
                                     .id)))
                               questions)))))
    na))

;;;; Marking

(defun claude-questions--set-state (q state)
  "Give Q's heading the TODO STATE (nil clears it), without logging."
  (unless (equal (alist-get 'state q) state)
    (save-excursion
      (goto-char (alist-get 'begin q))
      (let ((inhibit-message t)
            (message-log-max nil)
            (org-inhibit-logging t)
            (org-log-done nil)
            (org-todo-log-states nil))
        (org-todo (or state 'none))))))

(defun claude-questions--fold (q)
  "Fold Q's subtree to its heading."
  (save-excursion
    (goto-char (alist-get 'begin q))
    (outline-hide-subtree)))

(defun claude-questions--dim ()
  "Dim every N/A question, or hide it when `claude-questions-hide-na' is set."
  (remove-overlays (point-min) (point-max) 'claude-questions-na t)
  (org-map-entries
   (lambda ()
     (let ((overlay (make-overlay (point) (save-excursion (org-end-of-subtree t t)))))
       (overlay-put overlay 'claude-questions-na t)
       (overlay-put overlay 'face 'shadow)
       (overlay-put overlay 'invisible claude-questions-hide-na)))
   "TODO=\"N/A\""))

(defun claude-questions-refresh (&optional stage)
  "Mark the questions whose condition fails N/A and bring back the rest.
With STAGE, also mark answered questions STAGED and fold them, and clear
STAGED from those no longer answered."
  (interactive)
  (let* ((questions (claude-questions--all))
         (na (claude-questions--na questions))
         (inhibit-read-only t))
    ;; From the end, so marking one never moves the next one's start
    (dolist (q (reverse questions))
      (let-alist q
        (cond ((equal .state "DONE"))
              ((member .id na)
               (claude-questions--set-state q "N/A")
               (claude-questions--fold q))
              ((and stage (claude-questions--answered-p q))
               (claude-questions--set-state q "STAGED")
               (claude-questions--fold q))
              ((or stage (member .state '(nil "N/A")))
               (claude-questions--set-state q "OPEN")))))
    (claude-questions--dim)))

(defun claude-questions--stage ()
  "Stage answered questions before the buffer is saved."
  (claude-questions-refresh t))

(defun claude-questions--recheck ()
  "Re-check the conditions after a checkbox changed."
  (claude-questions-refresh))

(defun claude-questions-toggle-na ()
  "Hide N/A questions entirely, or show them dimmed again."
  (interactive)
  (setq claude-questions-hide-na (not claude-questions-hide-na))
  (claude-questions--dim)
  (message "N/A questions %s" (if claude-questions-hide-na "hidden" "shown dimmed")))

;;;; Answers

(defun claude-questions--json (q status)
  "Q as the answer object `claude-emacs questions' prints, with STATUS."
  (let-alist q
    (when (and (equal status "answered") .one (not .skipped) (cdr .choices))
      (user-error "Question %s takes one choice, %d are ticked" .id (length .choices)))
    (homun-ask-answer .id .question (and (equal status "answered") .choices) .text status
                      (cons 'notes .notes) (cons 'choice_notes .choice-notes)
                      (cons 'skipped (if .skipped t :false)))))

;; Notes above the first heading travel with every submit as the pseudo-entry
;; `_buffer' (status `buffer'); `claude-emacs questions' lifts it into the
;; top-level `notes' of a stream line.
(defun claude-questions--buffer-json ()
  "The `_buffer' pseudo-entry for the buffer's notes, as a list, or nil."
  (let ((blocks (claude-questions--buffer-notes)))
    (when blocks
      (list `((id . "_buffer") (question . "") (choices . []) (text . ,(string-join blocks "\n\n"))
              (notes . ,(string-join blocks "\n\n")) (blocks . ,(vconcat blocks))
              (choice_notes) (skipped . :false) (status . "buffer"))))))

(defun claude-questions--answer-file (suffix)
  (expand-file-name (concat claude-ask-id suffix) claude-answers-dir))

(defun claude-questions--write (json suffix)
  "Write JSON to answers/<id><SUFFIX> atomically."
  (let* ((file (claude-questions--answer-file suffix))
         (tmp (concat file ".tmp")))
    (write-region json nil tmp nil 'silent)
    (rename-file tmp file t)))

(defun claude-questions--closed ()
  "Closing the buffer without the last submit declines what is left.
The next pending buffer takes its window, so the frame stays."
  (when claude-ask-id
    (claude-questions--unregister claude-ask-id)
    (when (and (not claude-ask-timed-out)
               (not (file-exists-p (claude-questions--answer-file "")))
               (not (file-exists-p (claude-questions--answer-file ".declined"))))
      (claude-ask--finish "" ".declined" t))
    (claude-questions--show-next (current-buffer))))

(defun claude-questions--close ()
  "Kill the buffer; the next pending one takes its frame, else the frame closes."
  (let* ((buffer (current-buffer))
         (frame claude-questions--frame)
         (advanced (claude-questions--show-next buffer)))
    (kill-buffer buffer)
    (claude-questions--count-more)
    (when (and (not advanced) frame (frame-live-p frame) (frame-deletable-p frame))
      (delete-frame frame))))

(defun claude-questions-close-all ()
  "Close the frame and leave every question buffer for later, unanswered."
  (interactive)
  (let ((frame claude-questions--frame))
    (if (and frame (frame-live-p frame) (frame-deletable-p frame))
        (delete-frame frame)
      (bury-buffer))))

(defun claude-questions-submit ()
  "Send the manager the answered questions and mark them DONE.
When nothing is left open (N/A counts as done) this is the last submit:
it also sends the N/A ones and closes the buffer.  Before that each
submit is a part the waiting CLI prints as it comes."
  (interactive)
  (unless claude-ask-id (user-error "Not a claude questions buffer"))
  (claude-questions-refresh t)
  (let* ((questions (seq-remove (lambda (q) (equal (alist-get 'state q) "DONE"))
                                (claude-questions--all)))
         (answered (seq-filter #'claude-questions--answered-p
                               (seq-remove (lambda (q) (equal (alist-get 'state q) "N/A")) questions)))
         (na (seq-filter (lambda (q) (equal (alist-get 'state q) "N/A")) questions))
         (last (= (length questions) (+ (length answered) (length na))))
         (json (json-serialize
                (vconcat (claude-questions--buffer-json)
                         (mapcar (lambda (q) (claude-questions--json q "answered")) answered)
                         (when last (mapcar (lambda (q) (claude-questions--json q "na")) na))))))
    (unless (or last answered) (user-error "Nothing is answered yet"))
    (let ((inhibit-read-only t))
      (dolist (q (reverse answered)) (claude-questions--set-state q "DONE")))
    (save-buffer)
    (cond (claude-ask-timed-out
           (message "Claude stopped waiting for these answers; not delivered"))
          (last (claude-questions--write json ""))
          (t (setq claude-questions--parts (1+ claude-questions--parts))
             (claude-questions--write json (format ".part-%d" claude-questions--parts))
             (message "Sent %d answer%s; %d question%s left"
                      (length answered) (if (cdr answered) "s" "")
                      (- (length questions) (length answered) (length na))
                      (if (= 1 (- (length questions) (length answered) (length na))) "" "s"))))
    (when last (claude-questions--close))))

(defun claude-questions-decline ()
  "Tell the manager there are no (more) answers on this buffer and move on to the
next."
  (interactive)
  (unless claude-ask-id (user-error "Not a claude questions buffer"))
  (unless (claude-confirm "Decline these questions? ") (user-error "Not declined"))
  (unless claude-ask-timed-out (claude-questions--write "" ".declined"))
  (claude-questions--close))

;;;; Asking the manager about a question

;; An `#+begin_ask' block goes to the manager at once, as a `dashboard' alarm on the
;; scheduler events (the dashboard's talk-back path), and is marked `sent'.
;; The manager answers with `claude-emacs reply', which puts a `*** Manager' heading
;; at the end of the question, silently.

(defvar claude-questions-events
  (or (getenv "CLAUDE_EVENTS") (expand-file-name "~/claude/.services/scheduler/events"))
  "The scheduler's event queue that the manager follows.")

(defun claude-questions--at-point ()
  "The question at point, read, or a `user-error'."
  (let ((here (point)))
    (or (car (last (seq-filter (lambda (q) (<= (alist-get 'begin q) here))
                               (claude-questions--all))))
        (user-error "Not in a question"))))

(defun claude-questions--unsent-asks (id)
  "The (BEGIN . TEXT) of question ID's own ask blocks not sent yet."
  (org-element-map (org-element-parse-buffer) 'headline
    (lambda (h)
      (when (equal (org-element-property :ID h) id)
        (org-element-map h 'special-block
          (lambda (b)
            (when (and (equal (downcase (org-element-property :type b)) "ask")
                       (not (org-element-property :parameters b))
                       (claude-questions--own-p b h))
              (cons (org-element-property :begin b) (claude-questions--contents b)))))))
    nil t))

(defun claude-questions--tell (text)
  "Send TEXT to the manager as a `dashboard' alarm: on the bus, else the scheduler
events."
  (require 'claude-bus)
  (claude-bus-tell 'manager "dashboard" text claude-questions-events))

(defun claude-questions-ask ()
  "Send the question's new ask blocks to the manager, without submitting anything."
  (interactive)
  (unless claude-ask-id (user-error "Not a claude questions buffer"))
  (let* ((q (claude-questions--at-point))
         (id (alist-get 'id q))
         (asks (seq-remove (lambda (a) (string-empty-p (cdr a)))
                           (claude-questions--unsent-asks id))))
    (unless asks (user-error "No new #+begin_ask block in question %s" id))
    (claude-questions--tell
     (format "dashboard: ask on question %s in %s: %s\nAsk: %s\nReply: claude-emacs reply %s %s <text>"
             id claude-ask-id (alist-get 'question q)
             (string-join (mapcar #'cdr asks) "\n\n") claude-ask-id id))
    (save-excursion
      (dolist (a (reverse asks))
        (goto-char (car a))
        (when (looking-at "[ \t]*#\\+begin_ask[ \t]*$")
          (goto-char (match-end 0))
          (insert " sent"))))
    (message "Asked %s about %s" claude-agent-name id)))

(defun claude-questions-reply (buffer-id id text)
  "Put the manager's reply TEXT under question ID of question buffer BUFFER-ID.
It goes in silently: point, folding and the echo area stay as they are."
  (let ((buffer (or (get-buffer (claude--ask-buffer-name buffer-id))
                    (error "No question buffer %s" buffer-id))))
    (with-current-buffer buffer
      (let ((q (or (seq-find (lambda (q) (equal (alist-get 'id q) id)) (claude-questions--all))
                   (error "No question %s in %s" id buffer-id)))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (alist-get 'begin q))
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n"))
          (insert "*** Manager\n" (string-trim text) "\n"))))
    "ok"))

;;;; Writing in a question

(defun claude-questions--body-end (q)
  "Where Q's own text ends: before its first child heading or the next question."
  (save-excursion
    (goto-char (alist-get 'begin q))
    (outline-next-heading)
    (unless (bolp) (insert "\n"))
    (point)))

(defun claude-questions--insert-block (type)
  "Open a TYPE block at the end of the question at point, point inside it."
  (let ((q (claude-questions--at-point)))
    (goto-char (alist-get 'begin q))
    (org-fold-show-subtree)
    (goto-char (claude-questions--body-end q))
    (unless (save-excursion (forward-line -1) (looking-at-p "[ \t]*$")) (insert "\n"))
    (insert (format "#+begin_%s\n\n#+end_%s\n" type type))
    (forward-line -2)))

(defun claude-questions--item-at-point ()
  "The checkbox item at point, or a `user-error'."
  (let ((item (org-element-lineage (org-element-at-point) '(item) t)))
    (while (and item (not (org-element-property :checkbox item)))
      (setq item (org-element-lineage item '(item))))
    (or item (user-error "Not on a checkbox item"))))

(defun claude-questions-add-choice-note ()
  "Write a note under the checkbox item at point; it belongs to that choice."
  (interactive)
  (let* ((item (claude-questions--item-at-point))
         (indent (make-string (+ 2 (save-excursion
                                     (goto-char (org-element-property :begin item))
                                     (current-indentation)))
                              ?\s)))
    (org-fold-show-subtree)
    (goto-char (org-element-property :end item))
    (skip-chars-backward " \t\n")
    (insert (format "\n%s#+begin_note\n%s\n%s#+end_note" indent indent indent))
    (forward-line -1)
    (end-of-line)))

(defun claude-questions-add-note ()
  "Write a note under the question at point."
  (interactive)
  (claude-questions--insert-block "note"))

(defun claude-questions-add-ask ()
  "Write something to ask the manager about the question at point (send it with
ask)."
  (interactive)
  (claude-questions--insert-block "ask"))

(defun claude-questions-push-back ()
  "Tick the question's skip choice, adding it when missing, and open a note."
  (interactive)
  (let* ((q (claude-questions--at-point))
         (end (claude-questions--body-end q))
         (box (concat "- [ ] " claude-questions-skip-choice)))
    (goto-char (alist-get 'begin q))
    (if (search-forward box end t)
        (replace-match (concat "- [X] " claude-questions-skip-choice) t t)
      (goto-char end)
      (insert "- [X] " claude-questions-skip-choice "\n"))
    (claude-questions-refresh)
    (claude-questions-add-note)))

;;;; Menu

(transient-define-prefix claude-questions-menu ()
  "Answer, ask about or send the manager's questions."
  [:description (lambda () (format "Questions %s" (or claude-ask-id "")))
   ["Question at point"
    ("n" "Note on this question" claude-questions-add-note)
    ("N" "Note on the choice at point" claude-questions-add-choice-note)
    ("A" "Write an ask block" claude-questions-add-ask)
    ("a" (lambda () (format "Ask %s now" claude-agent-name)) claude-questions-ask)
    ("w" "Push back (skip + note)" claude-questions-push-back)]
   ["Buffer"
    ("v" "Toggle N/A view" claude-questions-toggle-na)
    ("g" "Re-check conditions" claude-questions-refresh)
    ("s" "Submit answered" claude-questions-submit)
    ("x" "Decline" claude-questions-decline)
    ("c" "Close all, for later" claude-questions-close-all)]])

;;;; Opening

(defvar org-claude-mode-map)

(defun claude-questions-click (event)
  "Move point to the click EVENT and tick the choice there, if it is a checkbox
line."
  (interactive "e")
  (mouse-set-point event)
  (when (save-excursion (beginning-of-line) (looking-at-p "[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\) \\[[ X-]\\]"))
    (org-ctrl-c-ctrl-c)))

(defvar claude-questions-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'claude-questions-click)
    (define-key map (kbd "C-c C-SPC s") #'claude-questions-submit)
    (define-key map (kbd "C-c C-SPC q") #'claude-questions-decline)
    (define-key map (kbd "C-c C-SPC a") #'claude-questions-ask)
    (define-key map (kbd "C-c C-SPC C-SPC") #'claude-questions-menu)
    (define-key map (kbd "C-c ?") #'claude-questions-menu)
    map)
  "Keys of a question buffer, over `org-claude-mode-map'.")

(defun claude-questions--setup (id)
  "Make the current `org-claude-mode' buffer the question buffer of ID."
  (use-local-map (make-composed-keymap claude-questions-map org-claude-mode-map))
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "gr") #'claude-questions-refresh)
    (evil-local-set-key 'normal [mouse-1] #'claude-questions-click)
    (evil-local-set-key 'motion [mouse-1] #'claude-questions-click))
  (setq claude-ask-id id
        header-line-format
        (list (claude-header "Questions" (format "gr re-check | C-c C-SPC: C-SPC menu | s submit | a ask %s | q decline | C-c C-c ticks" claude-agent-name))
              '(:eval (when (> claude-questions--more 0)
                        (propertize (format "  %d more after this" claude-questions--more)
                                    'face 'warning)))))
  (add-hook 'before-save-hook #'claude-questions--stage nil t)
  (add-hook 'org-checkbox-statistics-hook #'claude-questions--recheck nil t)
  (add-hook 'kill-buffer-hook #'claude-questions--closed nil t)
  (claude-questions-refresh))

(defun claude-questions-open (file id)
  "Open Org FILE as the question buffer of ID, without showing it."
  (make-directory claude-answers-dir t)
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (revert-buffer t t t)
      (org-claude-mode)
      (org-fold-hide-drawer-all)
      (rename-buffer (claude--ask-buffer-name id))
      (claude-questions--setup id)
      (goto-char (point-min)))
    buffer))

(defun claude-questions (file id)
  "Open Org FILE as the questions for ID; answers land in answers/ID as JSON.
Returns \"no-display\" when there is no frame to show them in."
  (if (not (or noninteractive
               (seq-find (lambda (f) (frame-parameter f 'window-system)) (frame-list))
               (claude-display-reachable-p)))
      "no-display"
    (let ((buffer (claude-questions-open file id))
          (frames (frame-list)))
      (claude-questions--register id file)
      ;; A frame already showing questions keeps them: this one waits its turn
      (unless (seq-some (lambda (b) (get-buffer-window b 'visible))
                        (claude-questions--pending buffer))
        (claude--with-frame (switch-to-buffer buffer))
        (unless (memq (selected-frame) frames)
          (with-current-buffer buffer (setq claude-questions--frame (selected-frame)))))
      (claude-questions--count-more)
      (claude--notify "Claude has questions" (file-name-nondirectory file))
      "ok")))

;;;###autoload
(defun claude-questions-show ()
  "Close any frame showing question buffers and show the oldest pending one in a
new frame."
  (interactive)
  (let ((pending (claude-questions--pending)))
    (if (not pending)
        (message "No pending questions")
      (dolist (buffer pending)
        (dolist (window (get-buffer-window-list buffer nil t))
          (let ((frame (window-frame window)))
            (when (and (frame-live-p frame) (frame-deletable-p frame))
              (delete-frame frame)))))
      (let ((frames (frame-list))
            (buffer (car pending)))
        (claude--with-frame (switch-to-buffer buffer))
        (unless (memq (selected-frame) frames)
          (with-current-buffer buffer (setq claude-questions--frame (selected-frame))))
        (claude-questions--count-more)))))

(provide 'claude-questions)
;;; claude-questions.el ends here
