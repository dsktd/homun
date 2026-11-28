;;; claude-transcript-focus.el --- A reading view of the transcript -*- lexical-binding: t -*-

;; `claude-transcript-focus' shows the conversation of a transcript as a page to read: prose in a
;; proportional face on a centred measure, each turn a block under a small speaker line, the
;; user's turns on a tinted card, code on cards in the mono face.  Tool calls, thinking, notes
;; and hook output are left out; a finished agent is one quiet line.  It reads the same session
;; file with the transcript's own reader (`claude-transcript--entries-read', `--kind-of'), so the
;; two never disagree, and appends what the file gains: nothing is ever drawn twice.
;; Desktop only for now (the phone is a follow-up).

;;; Code:

(require 'claude-transcript)
(require 'cl-lib)
(require 'claude-approve)
(require 'homun-layout)
(require 'color)
(require 'subr-x)

(defgroup claude-transcript-focus nil
  "The reading view of the transcript."
  :group 'claude-transcript)

(defcustom claude-transcript-focus-measure 70
  "Characters of prose per line."
  :type 'integer)

(defcustom claude-transcript-focus-fold-lines 15
  "Code blocks longer than this many lines show this many and fold the rest."
  :type 'integer)

(defcustom claude-transcript-focus-user-name "You"
  "The name on the user's turns."
  :type 'string)

;;;; Faces
;; Families are the cockpit's own fonts (flake.nix): Noto Serif for prose, Noto Sans for the
;; small furniture, the frame's mono font (JetBrains Mono) for code.  Colours come from the theme.

(defface claude-transcript-focus-prose
  '((t :family "Noto Serif" :height 1.15))
  "Prose.")

(defface claude-transcript-focus-small
  '((t :family "Noto Sans" :height 0.85))
  "Speaker lines, labels and quiet lines.")

(defface claude-transcript-focus-name
  '((t :family "Noto Sans" :height 1.3 :weight semibold))
  "The size of both speakers' names, about 1.3 of the prose.")

(defface claude-transcript-focus-speaker
  '((t :inherit (claude-transcript-claude-name claude-transcript-focus-name)))
  "The assistant's name.")

(defface claude-transcript-focus-you
  '((t :inherit (claude-transcript-you-name claude-transcript-focus-name)))
  "The user's name.")

(defface claude-transcript-focus-dim
  '((t :inherit (shadow claude-transcript-focus-small)))
  "Times, code labels, fold buttons, the quiet lines.")

(defface claude-transcript-focus-h1
  '((t :inherit claude-transcript-focus-prose :height 1.45 :weight bold))
  "First-level heading.")

(defface claude-transcript-focus-h2
  '((t :inherit claude-transcript-focus-prose :height 1.25 :weight bold))
  "Second-level heading.")

(defface claude-transcript-focus-h3
  '((t :inherit claude-transcript-focus-prose :height 1.1 :weight semibold :slant italic))
  "Third and lower heading.")

(defface claude-transcript-focus-quote
  '((t :inherit claude-transcript-focus-prose :slant italic))
  "Quoted text.")

(defface claude-transcript-focus-rule
  '((t :inherit shadow))
  "The left rule of a quote.")

(defface claude-transcript-focus-code
  '((t :inherit fixed-pitch :height 0.95))
  "Code, inline and in blocks.")

(defface claude-transcript-focus-card
  '((t :extend t))
  "Background of a code card; its colour comes from the theme.")

(defface claude-transcript-focus-you-card
  '((t :extend t))
  "Background of the user's turns; its colour comes from the theme.")

(defface claude-transcript-focus-link
  '((t :inherit link))
  "Links.")

(defface claude-transcript-focus-choice
  '((t :inherit claude-transcript-focus-small :weight semibold))
  "A choice of a widget.")

;;;; State

(defvar-local claude-transcript-focus--file nil "The session file shown.")
(defvar-local claude-transcript-focus--offset 0 "Byte offset of the first unread line.")
(defvar-local claude-transcript-focus--watch nil "File watch or poll timer.")
(defvar-local claude-transcript-focus--last nil "Speaker of the last block, `you' or `claude'.")
(defvar-local claude-transcript-focus--agents nil
  "Hash table of an Agent call's tool use id to its description.")
(defvar-local claude-transcript-focus--widgets nil
  "Choice lines of the widgets the agent asked that no message has answered yet.")
(defvar-local claude-transcript-focus--tail-key nil "What the blockers at the tail show now.")
(defvar-local claude-transcript-focus--folds 0 "Folds made so far, for unique fold symbols.")

(defun claude-transcript-focus--mix (from to ratio)
  "The colour RATIO of the way from colour FROM to TO, or nil."
  (when-let* ((a (and from (color-name-to-rgb from)))
              (b (and to (color-name-to-rgb to))))
    (apply #'color-rgb-to-hex (append (cl-mapcar (lambda (x y) (+ x (* ratio (- y x)))) a b)
                                      '(2)))))

(defun claude-transcript-focus--tint ()
  "Tint the cards, mixing the theme's background with its foreground or accent."
  (let ((bg (face-background 'default nil t))
        (fg (face-foreground 'default nil t))
        (accent (face-foreground 'claude-transcript-you-name nil 'default)))
    (set-face-background 'claude-transcript-focus-card
                         (claude-transcript-focus--mix bg fg 0.06))
    (set-face-background 'claude-transcript-focus-you-card
                         (claude-transcript-focus--mix bg accent 0.08))))

;;;; Inline markup

(defconst claude-transcript-focus--inline-re
  (concat "`\\([^`\n]+\\)`"                                   ; 1 code
          "\\|\\*\\*\\([^*\n]+\\)\\*\\*"                      ; 2 bold
          "\\|\\[\\([^]\n]+\\)\\](\\([^) \n]+\\))"            ; 3 label 4 url
          "\\|\\(https?://[^] \t\n<>)\"]+[^] \t\n<>).,;:!?\"]\\)" ; 5 bare url
          "\\|\\(?:\\`\\|[^*[:alnum:]]\\)\\(\\*\\([^* \n][^*\n]*?\\)\\*\\)" ; 6 7 italic
          "\\|\\_<_\\([^_ \n][^_\n]*?\\)_\\_>")                ; 8 italic
  "Inline markup: code, bold, links, bare URLs, italics.")

(defvar-keymap claude-transcript-focus-link-map
  :doc "Keys on a link."
  "RET" #'claude-transcript-focus-open-link
  "<mouse-1>" #'claude-transcript-focus-open-link
  "<mouse-2>" #'claude-transcript-focus-open-link)

(defun claude-transcript-focus-open-link (&optional event)
  "Open the link at point (or at the mouse EVENT) on the host."
  (interactive (list last-nonmenu-event))
  (let ((pos (if (mouse-event-p event) (posn-point (event-start event)) (point))))
    (when-let* ((url (get-text-property pos 'claude-transcript-focus-url)))
      (browse-url url))))

(defun claude-transcript-focus--link (label url)
  "LABEL as a link to URL; a homun: link is a widget, drawn as a choice."
  (if (string-prefix-p "homun:" url)
      (propertize (concat (if (string-match-p "state=done" url) "✓ " "") label)
                  'face 'claude-transcript-focus-choice)
    (propertize label 'face 'claude-transcript-focus-link 'mouse-face 'highlight
                'claude-transcript-focus-url url 'keymap claude-transcript-focus-link-map
                'help-echo url)))

(defun claude-transcript-focus--inline (text)
  "TEXT with its inline markup drawn (markers removed), in no base face.
In a message that may hold widgets its homun: links become the transcript's
own widget sources, drawn by `claude-transcript--widgets-make' after insertion."
  (let ((text (claude-transcript--fmt-homun-links text)) (start 0) parts)
    (while (string-match claude-transcript-focus--inline-re text start)
      (let ((from (or (match-beginning 6) (match-beginning 0))))
        (push (substring text start from) parts)
        (push (cond
               ((get-text-property from 'claude-transcript-widget text)
                (substring text from (match-end 0)))
               ((match-beginning 1)
                (propertize (match-string 1 text) 'face 'claude-transcript-focus-code))
               ((match-beginning 2)
                (claude-transcript-focus--styled (match-string 2 text) 'bold))
               ((match-beginning 3)
                (claude-transcript-focus--link (match-string 3 text) (match-string 4 text)))
               ((match-beginning 5)
                (claude-transcript-focus--link (match-string 5 text) (match-string 5 text)))
               ((match-beginning 7)
                (claude-transcript-focus--styled (match-string 7 text) 'italic))
               (t (claude-transcript-focus--styled (match-string 8 text) 'italic)))
              parts)
        (setq start (match-end 0))))
    (push (substring text start) parts)
    (apply #'concat (nreverse parts))))

(defun claude-transcript-focus--styled (text face)
  "TEXT with its own inline markup, then FACE on top."
  (let ((string (claude-transcript-focus--inline text)))
    (add-face-text-property 0 (length string) face t string)
    string))

;;;; Blocks

(defun claude-transcript-focus--space (pixels)
  "A string showing as PIXELS of blank space."
  (propertize " " 'display `(space :width (,(max 0 pixels)))))

(defun claude-transcript-focus--width (string)
  "Pixel width of STRING (its length in batch, where nothing is drawn)."
  (if (display-graphic-p) (string-pixel-width string) (length string)))

(defun claude-transcript-focus--gap (&optional height)
  "A blank line of HEIGHT (a fraction of the prose line) between blocks."
  (propertize "\n" 'face `(:height ,(or height 0.6))))

(defun claude-transcript-focus--paragraph (lines face &optional prefix wrap)
  "LINES joined as one paragraph in FACE, with line PREFIX and WRAP prefix."
  (let ((string (concat (claude-transcript-focus--inline (string-join lines " ")) "\n")))
    (add-face-text-property 0 (length string) face t string)
    (when prefix
      (add-text-properties 0 (length string) `(line-prefix ,prefix wrap-prefix ,(or wrap prefix))
                           string))
    string))

(defun claude-transcript-focus--item (indent marker lines)
  "A list item: MARKER hanging at INDENT (in leading spaces), LINES after it."
  (let* ((bullet (propertize (if (string-match-p "[0-9]" marker) (concat marker " ") "•  ")
                             'face 'claude-transcript-focus-prose))
         (em (claude-transcript-focus--width (propertize "m" 'face 'claude-transcript-focus-prose)))
         (left (* em (+ 1 (/ indent 2))))
         (string (claude-transcript-focus--paragraph lines 'claude-transcript-focus-prose)))
    (concat (propertize bullet 'line-prefix (claude-transcript-focus--space left))
            (propertize string
                        'line-prefix (claude-transcript-focus--space left)
                        'wrap-prefix (claude-transcript-focus--space
                                      (+ left (claude-transcript-focus--width bullet)))))))

(defvar-keymap claude-transcript-focus-fold-map
  :doc "Keys on a fold button."
  "RET" #'claude-transcript-focus-toggle-fold
  "<mouse-1>" #'claude-transcript-focus-toggle-fold)

(defun claude-transcript-focus--code (code language)
  "CODE of LANGUAGE as a card: a dim label, the code in the mono face, a fold past
`claude-transcript-focus-fold-lines' lines."
  (let* ((lines (split-string (string-trim-right code "\n") "\n"))
         (pad (propertize " " 'display '(space :width 1.5)))
         (body (claude-transcript--fmt-code (concat (string-join lines "\n") "\n") language))
         (fold (and (> (length lines) (+ claude-transcript-focus-fold-lines 2))
                    (intern (format "claude-transcript-focus-fold-%d"
                                    (cl-incf claude-transcript-focus--folds)))))
         (cut (and fold (let ((pos 0))
                          (dotimes (_ claude-transcript-focus-fold-lines)
                            (setq pos (1+ (string-search "\n" body pos))))
                          pos))))
    (add-face-text-property 0 (length body) 'claude-transcript-focus-code t body)
    (when fold
      (put-text-property cut (length body) 'invisible fold body)
      (setq body (concat (substring body 0 cut)
                         (propertize (format "▸ %d more lines\n" (- (length lines)
                                                                    claude-transcript-focus-fold-lines))
                                     'face 'claude-transcript-focus-dim 'mouse-face 'highlight
                                     'claude-transcript-focus-fold fold
                                     'keymap claude-transcript-focus-fold-map
                                     'help-echo "Show the whole block")
                         (substring body cut))))
    (let ((card (concat (propertize (concat (if (string-empty-p language) "code" language) "\n")
                                    'face 'claude-transcript-focus-dim)
                        body)))
      (add-face-text-property 0 (length card) 'claude-transcript-focus-card t card)
      (add-text-properties 0 (length card) `(line-prefix ,pad wrap-prefix ,pad) card)
      (concat (propertize "\n" 'face '(:height 0.3 :inherit claude-transcript-focus-card))
              card
              (propertize "\n" 'face '(:height 0.3 :inherit claude-transcript-focus-card))))))

(defun claude-transcript-focus-toggle-fold (&optional event)
  "Show or fold the rest of the code block at point (or at the mouse EVENT)."
  (interactive (list last-nonmenu-event))
  (let ((pos (if (mouse-event-p event) (posn-point (event-start event)) (point))))
    (when-let* ((fold (get-text-property pos 'claude-transcript-focus-fold)))
      (if (memq fold (ensure-list buffer-invisibility-spec))
          (remove-from-invisibility-spec fold)
        (add-to-invisibility-spec fold)))))

(defun claude-transcript-focus--table (lines)
  "Table LINES drawn aligned by the transcript, in the mono face."
  (let ((string (claude-transcript--fmt-table (concat (string-join lines "\n") "\n"))))
    (add-face-text-property 0 (length string) 'claude-transcript-focus-code t string)
    string))

(defun claude-transcript-focus--widgetry (code)
  "A widgetry block CODE as one line of its choices; a chosen one alone, ticked."
  (let ((start 0) choices)
    (while (string-match "(\\([[:alnum:]_-]+\\)[ \t\n]+\"\\([^\"]*\\)\"" code start)
      (push (cons (match-string 1 code) (match-string 2 code)) choices)
      (setq start (match-end 0)))
    (setq choices (nreverse choices))
    (let* ((chosen (and (string-match ":chosen[ \t]+\\([[:alnum:]_-]+\\)" code)
                        (assoc (match-string 1 code) choices)))
           (line (if chosen
                     (propertize (concat "✓ " (cdr chosen)) 'face 'claude-transcript-focus-choice)
                   (mapconcat (lambda (c) (propertize (cdr c) 'face 'claude-transcript-focus-choice))
                              choices (propertize "  ·  " 'face 'claude-transcript-focus-dim)))))
      (concat line "\n"))))

(defconst claude-transcript-focus--fence-re
  "^[ \t]*```\\([[:alnum:]_+-]*\\)[^\n]*\n\\(\\(?:.*\n\\)*?\\)[ \t]*```[ \t]*\\(?:\n\\|\\'\\)"
  "A fenced code block: 1 language, 2 code.")

(defun claude-transcript-focus--prose-blocks (text)
  "The blocks of TEXT (no fences in it) as a list of strings."
  (let ((lines (split-string text "\n")) blocks)
    (while lines
      (let ((line (car lines)))
        (cond
         ((string-blank-p line) (pop lines))
         ((string-match "\\`\\(#+\\)[ \t]+\\(.*\\)" line)
          (pop lines)
          (let ((level (length (match-string 1 line))))
            (push (claude-transcript-focus--paragraph
                   (list (match-string 2 line))
                   (pcase level (1 'claude-transcript-focus-h1) (2 'claude-transcript-focus-h2)
                          (_ 'claude-transcript-focus-h3)))
                  blocks)))
         ((string-match-p "\\`[ \t]*|" line)
          (let (rows)
            (while (and lines (string-match-p "\\`[ \t]*|" (car lines))) (push (pop lines) rows))
            (push (claude-transcript-focus--table (nreverse rows)) blocks)))
         ((string-match-p "\\`[ \t]*>" line)
          (let (rows)
            (while (and lines (string-match "\\`[ \t]*> ?\\(.*\\)" (car lines)))
              (push (match-string 1 (pop lines)) rows))
            (let ((rule (concat (propertize "▎" 'face 'claude-transcript-focus-rule)
                                (propertize " " 'display '(space :width 1)))))
              (push (claude-transcript-focus--paragraph (nreverse rows) 'claude-transcript-focus-quote
                                                        rule)
                    blocks))))
         ((string-match "\\`\\( *\\)\\([-*+]\\|[0-9]+[.)]\\)[ \t]+\\(.*\\)" line)
          (let ((indent (length (match-string 1 line)))
                (marker (match-string 2 line))
                (rows (list (match-string 3 line))))
            (pop lines)
            ;; Continuation lines: indented, not a new item
            (while (and lines (string-match "\\`[ \t]+\\([^-*+ \t0-9].*\\)" (car lines)))
              (push (match-string 1 (pop lines)) rows))
            (push (claude-transcript-focus--item indent marker (nreverse rows)) blocks)
            ;; Items of one list sit close: no gap between them
            (when (and lines (string-match-p "\\`\\( *\\)\\([-*+]\\|[0-9]+[.)]\\)[ \t]" (car lines)))
              (push 'tight blocks))))
         (t
          (let (rows)
            (while (and lines (not (string-blank-p (car lines)))
                        (not (string-match-p "\\`\\(#+[ \t]\\|[ \t]*[|>]\\|[ \t]*\\([-*+]\\|[0-9]+[.)]\\)[ \t]\\)"
                                             (car lines))))
              (push (string-trim (pop lines)) rows))
            (push (claude-transcript-focus--paragraph (nreverse rows) 'claude-transcript-focus-prose)
                  blocks))))))
    (nreverse blocks)))

(defun claude-transcript-focus--blocks (text)
  "TEXT, Markdown, as a list of block strings (and `tight' between list items)."
  (let ((start 0) blocks)
    (while (string-match claude-transcript-focus--fence-re text start)
      (let ((language (match-string 1 text))
            (code (match-string 2 text))
            (end (match-end 0)))
        (setq blocks (nconc blocks (claude-transcript-focus--prose-blocks
                                    (substring text start (match-beginning 0)))
                            (list (if (member language '("widgetry" "widgetry-demo"))
                                      (or (claude-transcript--fmt-widgetry
                                           (substring text (match-beginning 0) end) code
                                           (equal language "widgetry-demo"))
                                          (claude-transcript-focus--widgetry code))
                                    (claude-transcript-focus--code code language)))))
        (setq start end)))
    (nconc blocks (claude-transcript-focus--prose-blocks (substring text start)))))

(defun claude-transcript-focus--render-text (text)
  "TEXT, Markdown, as the string of a message body."
  (let (parts tight)
    (dolist (block (claude-transcript-focus--blocks text))
      (if (eq block 'tight)
          (setq tight t)
        (when (and parts (not tight)) (push (claude-transcript-focus--gap) parts))
        (setq tight nil)
        (push block parts)))
    (apply #'concat (nreverse parts))))

;;;; Turns

(defun claude-transcript-focus--speaker-line (who time)
  "The small speaker line of WHO (`you' or `claude') at TIME."
  (concat (propertize (if (eq who 'you) claude-transcript-focus-user-name
                        (or (plist-get claude-transcript--speaker :name)
                            (and (stringp claude-transcript--speaker) claude-transcript--speaker)
                            claude-agent-name))
                      'face (if (eq who 'you) 'claude-transcript-focus-you
                              'claude-transcript-focus-speaker))
          (propertize (concat "   " (or time "")) 'face 'claude-transcript-focus-dim)
          ;; The message follows at once: no blank line, only a little room
          (propertize "\n" 'line-spacing 0.1)))

(defun claude-transcript-focus--block (start end &optional face)
  "The buffer from START to END as a turn block in FACE: room before every line,
alike for both speakers."
  (let ((pad (propertize " " 'display '(space :width 1.5) 'face face))
        (pos start))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'line-prefix nil end))
            (old (get-text-property pos 'line-prefix))
            (wrap (get-text-property pos 'wrap-prefix)))
        (put-text-property pos next 'line-prefix (concat pad old))
        (put-text-property pos next 'wrap-prefix (concat pad (or wrap old)))
        (setq pos next)))
    (when face (add-face-text-property start end face t))))

(defun claude-transcript-focus--insert-turn (who uuid time text)
  "Insert TEXT of WHO (`you' or `claude') of entry UUID at TIME at the end.
A turn of the speaker of the one before continues its block."
  (let* ((continues (eq who claude-transcript-focus--last))
         ;; Claude's widgets are the transcript's own: one rendering path for both views
         (claude-transcript--widget-message (and (eq who 'claude) uuid))
         (claude-transcript--widget-refs (and (eq who 'claude) (claude-transcript--link-refs text)))
         (claude-transcript--widget-blocks 0)
         (claude-transcript--widget-lines 0)
         (body (concat (if continues (claude-transcript-focus--gap)
                         (claude-transcript-focus--speaker-line who time))
                       (claude-transcript-focus--render-text text))))
    (unless (or continues (bobp))
      (insert (claude-transcript-focus--gap 1.4)))
    (let ((start (point)))
      ;; Both speakers' blocks share one shape: room above the speaker line and below
      ;; the last line, the same indent; only the user's is tinted.
      (insert (if continues "" (claude-transcript-focus--gap 0.3))
              body (claude-transcript-focus--gap 0.3))
      (when claude-transcript--widget-message
        (claude-transcript--widgets-make start (point)))
      (claude-transcript-focus--block start (point)
                                      (and (eq who 'you) 'claude-transcript-focus-you-card))
      (add-text-properties start (point) `(claude-transcript-focus-uuid ,uuid
                                           claude-transcript-focus-who ,who))
      (unless continues
        (put-text-property start (1+ start) 'claude-transcript-focus-turn uuid)))
    (setq claude-transcript-focus--last who)))

(defun claude-transcript-focus--finish-name (text)
  "The name of the agent whose finish TEXT says it is done, or nil."
  (let* ((info (claude-transcript--parse-finish text))
         (summary (or (plist-get info :summary) "")))
    (cond ((gethash (plist-get info :tool-use-id) claude-transcript-focus--agents))
          ((string-match "\"\\([^\"]+\\)\"" summary) (match-string 1 summary))
          ((plist-get info :from)))))

(defun claude-transcript-focus--note-agents (content)
  "Remember the descriptions of the Agent calls in CONTENT."
  (seq-doseq (block content)
    (when (and (equal (alist-get 'type block) "tool_use")
               (equal (alist-get 'name block) "Agent"))
      (puthash (alist-get 'id block)
               (alist-get 'description (alist-get 'input block))
               claude-transcript-focus--agents))))

(defun claude-transcript-focus--insert-entry (entry)
  "Insert ENTRY, when it is conversation, at the end.\nA finish of a job without a name draws nothing."
  (let ((uuid (alist-get 'uuid entry))
        (time (claude-transcript--fmt-time (alist-get 'timestamp entry))))
    (pcase (claude-transcript--kind-of entry)
      ('prompt
       (setq claude-transcript-focus--widgets nil) ; any message of Cal's answers what was asked
       (let ((text (claude-transcript--unwrap-channel
                    (claude-transcript--text-of (claude-transcript--content-of entry)))))
         (unless (or (string-blank-p text) (claude-transcript--widget-click-p text)
                     (claude-transcript--local-command text))
           (claude-transcript-focus--insert-turn 'you uuid time text))))
      ('assistant
       (claude-transcript-focus--note-agents (claude-transcript--content-of entry))
       (let ((text (string-join (delq nil (mapcar (lambda (block)
                                                    (and (equal (alist-get 'type block) "text")
                                                         (alist-get 'text block)))
                                                  (claude-transcript--content-of entry)))
                                "\n\n")))
         (unless (string-blank-p text)
           (claude-transcript-focus--note-widgets text)
           (claude-transcript-focus--insert-turn 'claude uuid time text))))
      ('finish
       (when-let* ((name (claude-transcript-focus--finish-name
                          (claude-transcript--text-of (claude-transcript--content-of entry))))
                   (start (point)))
         (insert (claude-transcript-focus--gap 1.0)
                 (propertize (format "agent: %s finished\n" name) 'face 'claude-transcript-focus-dim))
         (put-text-property start (point) 'claude-transcript-focus-uuid uuid)
         (setq claude-transcript-focus--last nil))))))

(defun claude-transcript-focus--append (entries)
  "Append ENTRIES before the blockers; windows that showed the end keep showing it."
  (claude-transcript-focus--tail entries))

(defun claude-transcript-focus--update (buffer)
  "Append what the file of BUFFER gained since it was last read."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((size (file-attribute-size (file-attributes claude-transcript-focus--file))))
        (when (and size (> size claude-transcript-focus--offset))
          (let ((read (claude-transcript--entries-read claude-transcript-focus--file
                                                       claude-transcript-focus--offset)))
            (setq claude-transcript-focus--offset (cdr read))
            (claude-transcript-focus--append (car read))))))))

(defun claude-transcript-focus--watch ()
  "Watch the file for new lines."
  (let ((buffer (current-buffer)))
    (setq claude-transcript-focus--watch
          (if file-notify--library
              (file-notify-add-watch claude-transcript-focus--file '(change)
                                     (lambda (_) (claude-transcript-focus--update buffer)))
            (run-at-time claude-transcript-poll-interval claude-transcript-poll-interval
                         #'claude-transcript-focus--update buffer)))))

(defun claude-transcript-focus--unwatch ()
  "Stop watching the file."
  (cond ((timerp claude-transcript-focus--watch) (cancel-timer claude-transcript-focus--watch))
        (claude-transcript-focus--watch (file-notify-rm-watch claude-transcript-focus--watch)))
  (setq claude-transcript-focus--watch nil))

;;;; Blockers
;; At the tail, where the next message will appear, whatever holds the agent up on Cal: the
;; permission cards of the approve queue (the same nodes, guard and hold included), unanswered
;; widgets, open questions, a dialog waiting in the terminal.  Drawn from the sources on every
;; change, never remembered: a blocker is on screen exactly while its source still has it.

(defvar claude-approve--pending)
(defvar claude-approve--waiting)
(defvar claude-approve--open)
(declare-function claude-approve-armed-p "claude-approve")
(declare-function claude-approve--card "claude-approve")
(declare-function claude-approve--agent "claude-approve")
(declare-function claude-questions--pending "claude-questions")
(declare-function homun-stage-env "homun-stage")
(declare-function homun-stage-insert "homun-stage")

(defun claude-transcript-focus--note-widgets (text)
  "Remember the unanswered widgets of assistant TEXT, in place of earlier ones."
  (let ((start 0) lines)
    (while (string-match claude-transcript-focus--fence-re text start)
      (setq start (match-end 0))
      (when (and (equal (match-string 1 text) "widgetry")
                 (not (string-match-p ":chosen" (match-string 2 text))))
        (push (string-trim (claude-transcript-focus--widgetry (match-string 2 text))) lines)))
    (when lines (setq claude-transcript-focus--widgets (nreverse lines)))))

(defun claude-transcript-focus--blockers ()
  "What blocks the session shown, as a plist of its sources.
:requests :widgets :questions :waiting.  Only the main session has them: the
spool and the questions are not told apart by session."
  (when (claude-transcript--main-buffer-p)
    (list :requests (and (boundp 'claude-approve--pending) claude-approve--pending)
          :widgets claude-transcript-focus--widgets
          :questions (and (fboundp 'claude-questions--pending) (length (claude-questions--pending)))
          :waiting (and (boundp 'claude-approve--waiting) claude-approve--waiting))))

(defun claude-transcript-focus--note (text)
  "A quiet line TEXT of the blockers."
  (propertize (concat text "\n") 'face 'claude-transcript-focus-dim))

(defun claude-transcript-focus--insert-blockers (blockers)
  "Insert BLOCKERS at the end, marked as the tail."
  (let* ((requests (plist-get blockers :requests)) (now (float-time)) (start (point)))
    (insert (claude-transcript-focus--gap 1.4))
    (when requests
      (insert (claude-transcript-focus--note
               (format "%s waiting for permission" (claude-approve--agent (car requests)))))
      (dolist (r requests)
        (homun-stage-insert `((type . "col") (children . ,(claude-approve--card r now)))
                            (* 10 claude-transcript-focus-measure) (homun-stage-env))))
    (dolist (line (plist-get blockers :widgets))
      (insert (claude-transcript-focus--note "waiting for your choice")
              (propertize (concat line "\n") 'face 'claude-transcript-focus-choice)))
    (when (> (or (plist-get blockers :questions) 0) 0)
      (insert (claude-transcript-focus--note
               (format "%d question%s waiting for your answer" (plist-get blockers :questions)
                       (if (= 1 (plist-get blockers :questions)) "" "s")))))
    (when (and (plist-get blockers :waiting) (not requests))
      (insert (claude-transcript-focus--note "waiting for an answer in the terminal")))
    (put-text-property start (point) 'claude-transcript-focus-blockers t)))

(defun claude-transcript-focus--tail-start ()
  "Where the blockers start, or the end when none are drawn."
  (if (and (> (point-max) (point-min))
           (get-text-property (1- (point-max)) 'claude-transcript-focus-blockers))
      (or (previous-single-property-change (point-max) 'claude-transcript-focus-blockers)
          (point-min))
    (point-max)))

(defun claude-transcript-focus--tail-key (blockers)
  "What BLOCKERS draw, for telling a change from none."
  (list blockers claude-approve--open
        (mapcar (lambda (r) (claude-approve-armed-p (alist-get 'id r)))
                (plist-get blockers :requests))))

(defun claude-transcript-focus--tail (&optional entries)
  "Append ENTRIES, then draw the blockers again from their sources.
Windows that showed the end keep showing it; nothing changes when the blockers
are as drawn and there are no ENTRIES."
  (when (or entries (not (equal (claude-transcript-focus--tail-key (claude-transcript-focus--blockers))
                                claude-transcript-focus--tail-key)))
    (let* ((start (claude-transcript-focus--tail-start))
           (following (seq-filter (lambda (w) (>= (window-point w) start))
                                  (get-buffer-window-list (current-buffer) nil t)))
           (inhibit-read-only t))
      (save-excursion
        (delete-region start (point-max))
        (goto-char (point-max))
        (mapc #'claude-transcript-focus--insert-entry entries)
        (let ((blockers (claude-transcript-focus--blockers)))
          (setq claude-transcript-focus--tail-key (claude-transcript-focus--tail-key blockers))
          (when (and blockers (or (plist-get blockers :requests) (plist-get blockers :widgets)
                                  (> (or (plist-get blockers :questions) 0) 0)
                                  (plist-get blockers :waiting)))
            (claude-transcript-focus--insert-blockers blockers))))
      (dolist (window following)
        (set-window-point window (point-max))
        (homun-layout-tail window)))))

(defun claude-transcript-focus-blockers-changed ()
  "Draw the blockers again in every focus view (`claude-approve-changed-hook')."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'claude-transcript-focus-mode)
      (with-current-buffer buffer (claude-transcript-focus--tail)))))

(add-hook 'claude-approve-changed-hook #'claude-transcript-focus-blockers-changed)
(add-hook 'claude-questions-changed-hook #'claude-transcript-focus-blockers-changed)

;;;; Layout

(defun claude-transcript-focus--margins (&optional window)
  "Centre the measure in WINDOW (each window of this buffer when nil)."
  (dolist (w (if (windowp window) (list window) (get-buffer-window-list nil nil t)))
    ;; Measured in W itself: a size hook may run while another frame is selected
    (with-selected-window w
      (when (derived-mode-p 'claude-transcript-focus-mode)
        (let* ((sample (propertize (substring (apply #'concat (make-list 4 "the quick brown fox jumps over a lazy dog, "))
                                              0 claude-transcript-focus-measure)
                                   'face 'claude-transcript-focus-prose))
               (columns (ceiling (/ (claude-transcript-focus--width sample)
                                    (float (frame-char-width (window-frame w))))))
               (margin (max 0 (/ (- (window-total-width w) columns 4) 2))))
          (set-window-margins w margin margin))))))

(defun claude-transcript-focus--size-changed (window-or-frame)
  "Recentre this view's windows in WINDOW-OR-FRAME.
The buffer-local hook gets a window, the global one a frame."
  (dolist (w (if (windowp window-or-frame) (list window-or-frame)
               (window-list window-or-frame 'never)))
    (when (with-current-buffer (window-buffer w) (derived-mode-p 'claude-transcript-focus-mode))
      (claude-transcript-focus--margins w))))

;;;; Navigation

(defun claude-transcript-focus-next-turn (&optional count)
  "Go to the start of the COUNTth next turn."
  (interactive "p")
  (dotimes (_ (or count 1))
    (when-let* ((next (next-single-property-change (1+ (min (point) (1- (point-max))))
                                                   'claude-transcript-focus-turn)))
      (goto-char (if (get-text-property next 'claude-transcript-focus-turn) next
                   (or (next-single-property-change next 'claude-transcript-focus-turn) next))))))

(defun claude-transcript-focus-previous-turn (&optional count)
  "Go to the start of the COUNTth previous turn."
  (interactive "p")
  (dotimes (_ (or count 1))
    (let ((pos (point)))
      (while (and (> pos (point-min))
                  (progn (setq pos (or (previous-single-property-change
                                        pos 'claude-transcript-focus-turn)
                                       (point-min)))
                         (not (get-text-property pos 'claude-transcript-focus-turn)))))
      (goto-char pos))))

(defun claude-transcript-focus--goto (uuid)
  "Go to the text of entry UUID; nil when it is not drawn."
  (when uuid
    (let ((pos (point-min)))
      (while (and pos (not (equal (get-text-property pos 'claude-transcript-focus-uuid) uuid)))
        (setq pos (next-single-property-change pos 'claude-transcript-focus-uuid)))
      (when pos (goto-char pos) (skip-chars-forward "\n") (point)))))

(defun claude-transcript-focus--source-uuid ()
  "The entry uuid of the message at point in a transcript, or nil."
  (let ((section (magit-current-section)) uuid)
    (while (and section (not uuid))
      (let ((value (oref section value)))
        (when (and (stringp value)
                   (memq (oref section type) '(claude-transcript-turn claude-transcript-text)))
          (setq uuid (car (split-string value "/")))))
      (setq section (oref section parent)))
    uuid))

(defun claude-transcript-focus--source-goto (uuid)
  "In a transcript, go to the message of entry UUID; nil when it is not there."
  (let ((pos (point-min)) found)
    (while (and (not found) pos (< pos (point-max)))
      (let ((section (get-text-property pos 'magit-section)))
        (when (and section (stringp (oref section value))
                   (memq (oref section type) '(claude-transcript-turn claude-transcript-text))
                   (equal (car (split-string (oref section value) "/")) uuid))
          (setq found (oref section start))))
      (setq pos (next-single-property-change pos 'magit-section)))
    (when found (goto-char found))))

;;;; The view

(defvar-keymap claude-transcript-focus-mode-map
  :parent special-mode-map
  "SPC" #'scroll-up-command
  "S-SPC" #'scroll-down-command
  "DEL" #'scroll-down-command
  "] ]" #'claude-transcript-focus-next-turn
  "[ [" #'claude-transcript-focus-previous-turn
  "M->" #'end-of-buffer
  "g" #'claude-transcript-focus-refresh
  "q" #'claude-transcript-focus-quit
  "?" #'describe-mode)

;; Outside the `defvar-keymap', so a live reload binds them in the existing map too.
(keymap-set claude-transcript-focus-mode-map "i" #'claude-transcript-focus-compose)
(keymap-set claude-transcript-focus-mode-map "a" #'claude-transcript-focus-compose)

(declare-function evil-insert-state "evil-states")

(defun claude-transcript-focus-compose ()
  "Select the compose window to type a message, in insert state under Evil."
  (interactive)
  (let ((window (or (homun-layout-window 'compose) (user-error "No compose window"))))
    (select-window window)
    (with-current-buffer (window-buffer window)
      (goto-char (point-max))
      (when (fboundp 'evil-insert-state) (evil-insert-state)))))

(declare-function evil-define-key* "evil-core")
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) claude-transcript-focus-mode-map
    (kbd "SPC") #'scroll-up-command (kbd "S-SPC") #'scroll-down-command
    (kbd "]]") #'claude-transcript-focus-next-turn (kbd "[[") #'claude-transcript-focus-previous-turn
    (kbd "gr") #'claude-transcript-focus-refresh
    (kbd "q") #'claude-transcript-focus-quit (kbd "?") #'describe-mode
    (kbd "i") #'claude-transcript-focus-compose (kbd "a") #'claude-transcript-focus-compose))

(defun claude-transcript-focus--imenu ()
  "One imenu entry per turn."
  (let ((pos (point-min)) index)
    (while (setq pos (next-single-property-change pos 'claude-transcript-focus-turn))
      (when (get-text-property pos 'claude-transcript-focus-turn)
        (push (cons (format "%s %s" (if (eq (get-text-property pos 'claude-transcript-focus-who) 'you)
                                        claude-transcript-focus-user-name claude-agent-name)
                            (string-trim (buffer-substring-no-properties
                                          (save-excursion (goto-char pos) (forward-line 2) (point))
                                          (save-excursion (goto-char pos) (forward-line 2)
                                                          (min (+ (point) 50) (line-end-position))))))
                    pos)
              index)))
    (nreverse index)))

(defun claude-transcript-focus--bare ()
  "No mode line and no header line: nothing but the page."
  (setq-local mode-line-format nil header-line-format nil))

(define-derived-mode claude-transcript-focus-mode special-mode "Focus"
  "Reading view of a transcript: the conversation alone, set for reading.
SPC and S-SPC page, ]] and [[ next and previous turn, g refresh, q back to the
transcript at the same message.

\\{claude-transcript-focus-mode-map}"
  (claude-transcript-focus--bare)
  ;; doom-modeline sets its own on `after-change-major-mode-hook', after this body
  (add-hook 'after-change-major-mode-hook #'claude-transcript-focus--bare 90 t)
  (setq-local line-spacing 0.25
              truncate-lines nil
              word-wrap t
              cursor-type 'bar
              bidi-paragraph-direction 'left-to-right
              bidi-inhibit-bpa t
              left-fringe-width 0
              right-fringe-width 0
              imenu-create-index-function #'claude-transcript-focus--imenu)
  (setq-local font-lock-fontify-region-function #'ignore
              font-lock-unfontify-region-function #'ignore)
  (claude-transcript-focus--tint)
  ;; The widget sources the transcript's renderer leaves before each widget
  (add-to-invisibility-spec 'claude-transcript-markup)
  (add-hook 'window-size-change-functions #'claude-transcript-focus--size-changed nil t)
  (add-hook 'kill-buffer-hook #'claude-transcript-focus--unwatch nil t))

(defun claude-transcript-focus--render ()
  "Draw the last turns of the file from scratch (open and `g' only)."
  (let ((inhibit-read-only t)
        (read (claude-transcript--tail-read claude-transcript-focus--file
                                            claude-transcript-tail-turns)))
    (erase-buffer)
    (setq claude-transcript-focus--last nil
          claude-transcript-focus--agents (make-hash-table :test #'equal)
          claude-transcript-focus--offset (cadr read))
    (setq claude-transcript-focus--widgets nil claude-transcript-focus--tail-key nil
          claude-transcript--widget-groups nil)
    (save-excursion (mapc #'claude-transcript-focus--insert-entry (car read)))
    (claude-transcript-focus--update (current-buffer))
    (claude-transcript-focus--tail)))

(defun claude-transcript-focus-refresh ()
  "Read the file again from its tail."
  (interactive)
  (let ((uuid (get-text-property (point) 'claude-transcript-focus-uuid)))
    (claude-transcript-focus--render)
    (or (claude-transcript-focus--goto uuid) (goto-char (point-max)))))

(defun claude-transcript-focus-buffer (file)
  "The focus buffer of FILE, made and drawn when new."
  (let ((name (format "*focus: %s*" (file-name-base file))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (claude-transcript-focus-mode)
          (setq claude-transcript-focus--file file)
          (claude-transcript-focus--render)
          (claude-transcript-focus--watch)
          (goto-char (point-max))
          (current-buffer)))))

(defun claude-transcript-focus--source-buffer (file)
  "A transcript buffer of FILE."
  (or (seq-find (lambda (b) (with-current-buffer b
                              (and (derived-mode-p 'claude-transcript-mode)
                                   (equal claude-transcript--file file))))
                (buffer-list))
      (claude-transcript-buffer file)))

;;;###autoload
(defun claude-transcript-focus ()
  "Toggle the reading view of the transcript shown, keeping the message at point.
From a transcript open its focus view; from the focus view go back.
In a frame with the layout that is a frame-level toggle: the view over the
compose box, nothing else."
  (interactive)
  (cond ((derived-mode-p 'claude-transcript-focus-mode) (claude-transcript-focus-quit))
        ((and (homun-layout-window 'transcript) (not (frame-parameter nil 'homun-layout-focus)))
         (homun-layout-focus-toggle))
        (t (claude-transcript-focus--open))))

(defun claude-transcript-focus--open ()
  "Show the focus view of the transcript in the selected window, at the message
at point."
  (let* ((file (if (derived-mode-p 'claude-transcript-mode) claude-transcript--file
                 (claude-transcript-read-session)))
         (uuid (and (derived-mode-p 'claude-transcript-mode) (claude-transcript-focus--source-uuid)))
         (buffer (claude-transcript-focus-buffer file)))
    (homun-layout-show buffer (selected-window))
    (with-current-buffer buffer
      (claude-transcript-focus--margins (selected-window))
      (if (claude-transcript-focus--goto uuid)
          (set-window-point (selected-window) (point))
        (set-window-point (selected-window) (point-max))))))

(defun claude-transcript-focus-quit ()
  "Back to the transcript, at the message at point; in focus layout, the whole
layout comes back."
  (interactive)
  (let* ((uuid (get-text-property (point) 'claude-transcript-focus-uuid))
         (buffer (claude-transcript-focus--source-buffer claude-transcript-focus--file)))
    (when (frame-parameter nil 'homun-layout-focus)
      (homun-layout-focus-toggle))
    (let ((window (or (homun-layout-window 'transcript) (selected-window))))
      (homun-layout-show buffer window)
      (select-window window)
      (with-current-buffer buffer
        (when (claude-transcript-focus--source-goto uuid)
          (set-window-point window (point)))))))

;;;; API

(require 'homun-api)
(declare-function homun-api--transcript-buffer "homun-api")

(defun claude-transcript-focus--api-open (name slot back redraw)
  "Show the focus view of transcript NAME (the first) in SLOT, unselected.
Return a summary.
BACK turns before the end start the window; else it shows the end.
REDRAW draws the view anew."
  (let* ((file (buffer-local-value 'claude-transcript--file (homun-api--transcript-buffer name)))
         (old (get-buffer (format "*focus: %s*" (file-name-base file))))
         (_ (when (and redraw old) (kill-buffer old)))
         (start (float-time))
         (fresh (not (get-buffer (format "*focus: %s*" (file-name-base file)))))
         (buffer (claude-transcript-focus-buffer file))
         (ms (* 1000 (- (float-time) start)))
         (window (homun-layout-window (if (equal slot "main") 'transcript 'stage))))
    (unless window (error "No %s window" slot))
    (homun-layout-show buffer window)
    (claude-transcript-focus--margins window)
    (if (not (and back (> back 0)))
        (homun-layout-tail window)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (claude-transcript-focus-previous-turn back)
          (homun-layout-point window (point) (point)))))
    (format "%s in window %s, %d chars%s" (buffer-name buffer) window (buffer-size buffer)
            (if fresh (format ", drawn in %.0f ms" ms) ""))))

(homun-api-register "transcript focus"
                    "Show the focus view (reading view) of a transcript (the first, or BUFFER) in SLOT, without selecting it."
                    '((buffer string) (slot enum :choices ("slate" "main") :default "slate") (back int :max 200) (redraw bool))
                    #'claude-transcript-focus--api-open)

(define-key claude-transcript-mode-map (kbd "r") #'claude-transcript-focus)
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) claude-transcript-mode-map (kbd "gf") #'claude-transcript-focus))

(provide 'claude-transcript-focus)
;;; claude-transcript-focus.el ends here
