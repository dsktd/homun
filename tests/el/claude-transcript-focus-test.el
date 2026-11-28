;;; claude-transcript-focus-test.el --- ERT for claude-transcript-focus.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require (quote claude)) ; homun-key-hint for the transcript buffer
(require 'claude-transcript-focus)

(defun claude-transcript-focus-tests--line (type uuid content &optional extra)
  "A session line of TYPE and UUID with message CONTENT."
  (concat (json-encode `((type . ,type) (uuid . ,uuid) (timestamp . "2026-11-27T10:00:00Z")
                         (message . ((role . ,(if (equal type "user") "user" "assistant"))
                                     (content . ,content)))
                         ,@extra))
          "\n"))

(defconst claude-transcript-focus-tests--session
  (concat
   (claude-transcript-focus-tests--line "user" "u1" "Please read the notes")
   (claude-transcript-focus-tests--line
    "assistant" "a1" (vector '((type . "text") (text . "First **part**."))))
   (claude-transcript-focus-tests--line
    "assistant" "a2" (vector '((type . "tool_use") (id . "t1") (name . "Bash")
                               (input . ((command . "ls SECRET-TOOL"))))))
   (claude-transcript-focus-tests--line
    "user" "r1" (vector '((type . "tool_result") (tool_use_id . "t1") (content . "TOOL-OUTPUT"))))
   (claude-transcript-focus-tests--line
    "assistant" "a3" (vector '((type . "thinking") (thinking . "HIDDEN-THOUGHT"))
                             '((type . "text") (text . "Second part."))))
   (claude-transcript-focus-tests--line "user" "u2" "Thanks"))
  "A conversation with a tool call between two assistant texts.")

(defmacro claude-transcript-focus-tests--with (&rest body)
  "Run BODY in a focus buffer of the session, bound to `file'."
  (declare (indent defun))
  `(let* ((dir (make-temp-file "claude-focus" t))
          (file (expand-file-name "session.jsonl" dir)))
     (write-region claude-transcript-focus-tests--session nil file nil 'silent)
     (let ((buffer (claude-transcript-focus-buffer file)))
       (unwind-protect (with-current-buffer buffer ,@body)
         (kill-buffer buffer)
         (delete-directory dir t)))))

(ert-deftest claude-transcript-focus-no-tools ()
  "Tool calls, results and thinking are not drawn; the conversation is."
  (claude-transcript-focus-tests--with
    (let ((text (buffer-string)))
      (should (string-search "Please read the notes" text))
      (should (string-search "First part." text))
      (should (string-search "Second part." text))
      (dolist (hidden '("SECRET-TOOL" "TOOL-OUTPUT" "HIDDEN-THOUGHT" "Bash" "**"))
        (should-not (string-search hidden text))))))

(ert-deftest claude-transcript-focus-merges ()
  "The two assistant texts around the tool call are one turn: one speaker line."
  (claude-transcript-focus-tests--with
    (let (turns (pos (point-min)))
      (while pos
        (when-let* ((uuid (get-text-property pos 'claude-transcript-focus-turn)))
          (push uuid turns))
        (setq pos (next-single-property-change pos 'claude-transcript-focus-turn)))
      (should (equal (nreverse turns) '("u1" "a1" "u2"))))))

(ert-deftest claude-transcript-focus-you-distinct ()
  "The user's turns are on their card; the assistant's are not."
  (claude-transcript-focus-tests--with
    (let ((you (string-search "Please" (buffer-string)))
          (claude (string-search "Second" (buffer-string))))
      (should (memq 'claude-transcript-focus-you-card
                    (ensure-list (get-text-property (1+ you) 'face))))
      (should-not (memq 'claude-transcript-focus-you-card
                        (ensure-list (get-text-property (1+ claude) 'face))))
      (should (eq (get-text-property (1+ you) 'claude-transcript-focus-who) 'you)))))

(ert-deftest claude-transcript-focus-round-trip ()
  "From a message in the transcript to the focus view and back lands on it."
  (claude-transcript-focus-tests--with
    (let ((transcript (claude-transcript-focus--source-buffer file)))
      (unwind-protect
          (progn
            (with-current-buffer transcript
              (should (claude-transcript-focus--source-goto "a3"))
              (should (equal (claude-transcript-focus--source-uuid) "a3")))
            (should (claude-transcript-focus--goto "a3"))
            (should (looking-at-p "Second part"))
            (let ((uuid (get-text-property (point) 'claude-transcript-focus-uuid)))
              (with-current-buffer transcript
                (goto-char (point-min))
                (should (claude-transcript-focus--source-goto uuid))
                (should (equal (claude-transcript-focus--source-uuid) "a3")))))
        (kill-buffer transcript)))))

(ert-deftest claude-transcript-focus-append ()
  "New lines are appended: the text drawn before is untouched."
  (claude-transcript-focus-tests--with
    (let ((before (buffer-string))
          (marker (copy-marker (point-min))))
      (write-region (claude-transcript-focus-tests--line
                     "assistant" "a4" (vector '((type . "text") (text . "Third part."))))
                    nil file t 'silent)
      (claude-transcript-focus--update (current-buffer))
      (should (string-prefix-p before (buffer-string)))
      (should (= marker (point-min)))
      (should (string-search "Third part." (buffer-string)))
      (should (save-excursion (claude-transcript-focus--goto "a4"))))))

(ert-deftest claude-transcript-focus-markdown ()
  "Headings, lists, quotes and long code blocks are drawn without their markers."
  (let ((text (claude-transcript-focus--render-text
               (concat "# Title\n\n- one\n- two\n\n> quoted\n\n```sh\n"
                       (mapconcat #'number-to-string (number-sequence 1 30) "\n")
                       "\n```\n"))))
    (should (string-search "Title" text))
    (should-not (string-search "#" text))
    (should (string-search "•  one" text))
    (should (string-search "quoted" text))
    (should-not (string-search "> " text))
    (should (string-search "▸ 15 more lines" text))))

(ert-deftest claude-transcript-focus-test-speakers-align ()
  "Both speakers' turns share the indent and the room above; only the user's is tinted."
  (with-temp-buffer
    (let ((claude-transcript-focus--last nil))
      (claude-transcript-focus--insert-turn 'you "u1" "10:00" "Hello")
      (claude-transcript-focus--insert-turn 'claude "a1" "10:01" "Hi"))
    (let ((you (text-property-any (point-min) (point-max) 'claude-transcript-focus-who 'you))
          (claude (text-property-any (point-min) (point-max) 'claude-transcript-focus-who 'claude)))
      (should (equal (get-text-property 0 'display (get-text-property (1+ you) 'line-prefix))
                     (get-text-property 0 'display (get-text-property (1+ claude) 'line-prefix))))
      (should (string-prefix-p "\n" (buffer-substring-no-properties you (point-max)))))))

;;;; Widgets

(defconst claude-transcript-focus-tests--widgets
  "Pick:\n\n```widgetry\n(buttons (a \"Option A\") (b \"Option B\"))\n```\n\nOr [Go](homun:click/go)."
  "A message with a widgetry block and a click link.")

(defun claude-transcript-focus-tests--specs ()
  "The (TYPE . ID) of every transcript widget in this buffer, in order."
  (let ((pos (point-min)) out)
    (while (< pos (point-max))
      (when-let* ((w (widget-at pos))
                  (spec (widget-get w :claude-spec)))
        (unless (equal (car out) (cons (plist-get spec :type) (plist-get spec :id)))
          (push (cons (plist-get spec :type) (plist-get spec :id)) out)))
      (setq pos (1+ pos)))
    (nreverse out)))

(ert-deftest claude-transcript-focus-widgets-are-the-transcripts ()
  "Claude's widgets in the focus view are the transcript's: the same widgets, keys and faces."
  (let ((claude-transcript--widget-states (make-hash-table :test #'equal)))
    (let ((focus (with-temp-buffer
                   (claude-transcript-focus-mode)
                   (let ((inhibit-read-only t) (claude-transcript-focus--last nil))
                     (claude-transcript-focus--insert-turn
                      'claude "a1" "10:00" claude-transcript-focus-tests--widgets))
                   (let ((pos (seq-find #'widget-at (number-sequence (point-min) (1- (point-max))))))
                     (should (get-char-property pos 'keymap))
                     ;; Drawn as a button by widgetry's overlay, not as text
                     (should (seq-some (lambda (o) (overlay-get o 'display)) (overlays-at pos))))
                   ;; The link's source stays, hidden, for the answer to be written into
                   (goto-char (point-min))
                   (should (invisible-p (search-forward "homun:click")))
                   (claude-transcript-focus-tests--specs)))
          (transcript
           (let ((file (make-temp-file "claude-focus" nil ".jsonl"
                                       (claude-transcript-focus-tests--line
                                        "assistant" "a1"
                                        (vector `((type . "text")
                                                  (text . ,claude-transcript-focus-tests--widgets)))))))
             (unwind-protect
                 (with-temp-buffer
                   (claude-transcript-mode)
                   (setq claude-transcript--file file)
                   (claude-transcript--render claude-transcript-tail-turns)
                   (claude-transcript-focus-tests--specs))
               (delete-file file)))))
      (should focus)
      (should (equal focus transcript)))))

(ert-deftest claude-transcript-focus-widget-click-sends ()
  "A click in the focus view sends the transcript's [clicked ID on UUID]; no blocker
refusal applies to an ordinary widget."
  (require 'claude-click)
  (let* ((claude-transcript--widget-states (make-hash-table :test #'equal))
         sent
         (claude-transcript-widget-sender (lambda (text done &rest _) (push text sent) (funcall done))))
    (with-temp-buffer
      (claude-transcript-focus-mode)
      (let ((inhibit-read-only t) (claude-transcript-focus--last nil))
        (claude-transcript-focus--insert-turn 'claude "a1" "10:00" "Or [Go](homun:click/go)."))
      (let ((pos (seq-find (lambda (p) (widget-at p)) (number-sequence (point-min) (1- (point-max))))))
        (should pos)
        (should-not (get-text-property pos 'claude-transcript-focus-blockers))
        (claude-click--guard pos)
        (widget-apply-action (widget-at pos))
        (should (string-prefix-p "[clicked go on a1]" (car sent)))))))

(ert-deftest claude-transcript-focus-speaker-tight ()
  "The message follows its speaker line with no blank line between."
  (with-temp-buffer
    (let ((claude-transcript-focus--last nil))
      (claude-transcript-focus--insert-turn 'claude "a1" "10:00" "Hello"))
    (should (string-match-p "10:00\n\\(\n\\)?Hello" (buffer-substring-no-properties
                                                         (point-min) (point-max))))
    (should-not (string-match-p "10:00\n\n" (buffer-substring-no-properties
                                               (point-min) (point-max))))))

;;;; Blockers

(defvar claude-transcript-focus-tests--request
  '((id . "1-1") (tool . "Bash") (summary . "make it") (agent_name . "Tally")
    (input . ((command . "make it")))))

(defmacro claude-transcript-focus-tests--blocked (requests &rest body)
  "Run BODY in a focus buffer of the main session with REQUESTS pending."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'claude-compose--main-file-p) (lambda (_) t)))
     (let ((claude-approve--pending ,requests) (claude-approve--waiting nil))
       (claude-transcript-focus-tests--with
         (claude-transcript-focus--tail)
         ,@body))))

(ert-deftest claude-transcript-focus-blockers-follow-requests ()
  "The card of a pending request is the last thing drawn, and goes with the request."
  (claude-transcript-focus-tests--blocked (list claude-transcript-focus-tests--request)
    (should (string-search "Tally waiting for permission" (buffer-string)))
    (should (string-search "make it" (buffer-string)))
    (should (get-text-property (1- (point-max)) 'claude-transcript-focus-blockers))
    (should-not (string-search "Thanks" (buffer-substring (claude-transcript-focus--tail-start)
                                                          (point-max))))
    (setq claude-approve--pending nil)
    (claude-transcript-focus-blockers-changed)
    (should-not (string-search "waiting for permission" (buffer-string)))
    (should (= (point-max) (claude-transcript-focus--tail-start)))))

(ert-deftest claude-transcript-focus-blockers-refuse-click ()
  "ui click never presses a blocker."
  (require 'claude-click)
  (claude-transcript-focus-tests--blocked (list claude-transcript-focus-tests--request)
    (let ((pos (+ (claude-transcript-focus--tail-start) 3)))
      (should-error (claude-click--guard pos) :type 'user-error))))

(ert-deftest claude-transcript-focus-blockers-widget ()
  "An unanswered widget waits at the tail until a message follows it."
  (claude-transcript-focus-tests--blocked nil
    (claude-transcript-focus--tail
     (list (json-parse-string
            (claude-transcript-focus-tests--line
             "assistant" "a9" (vector '((type . "text")
                                        (text . "Pick:\n\n```widgetry\n(a \"Option A\") (b \"Option B\")\n```"))))
            :object-type 'alist)))
    (should (string-search "waiting for your choice" (buffer-string)))
    (claude-transcript-focus--tail
     (list (json-parse-string (claude-transcript-focus-tests--line "user" "u9" "ok")
                              :object-type 'alist)))
    (should-not (string-search "waiting for your choice" (buffer-string)))))

(ert-deftest claude-transcript-focus-blockers-other-session ()
  "A session that is not the main one shows no blockers."
  (let ((claude-approve--pending (list claude-transcript-focus-tests--request)))
    (claude-transcript-focus-tests--with
      (claude-transcript-focus--tail)
      (should-not (string-search "waiting for permission" (buffer-string))))))

(provide 'claude-transcript-focus-test)
;;; claude-transcript-focus-test.el ends here
