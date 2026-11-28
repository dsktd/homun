;;; claude-transcript-test.el --- ERT for claude-transcript.el -*- lexical-binding: t; -*-
;; emacs --batch -L container/emacs -l tests/el/claude-transcript-test.el -f ert-run-tests-batch-and-exit
;; (with magit-section, consult and markdown-mode on the `load-path')

;;; Code:

(require 'ert)
(require 'claude-transcript)

(defconst claude-transcript-tests--fixture
  (expand-file-name "claude-transcript-fixture.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Session fixture whose last line is incomplete.")

(defmacro claude-transcript-tests--with-session (&rest body)
  "Run BODY in a transcript buffer of a copy of the fixture bound to `file'."
  (declare (indent defun))
  `(let* ((dir (make-temp-file "claude-transcript" t))
          (file (expand-file-name "session.jsonl" dir))
          (claude-transcript-projects-directory dir))
     (copy-file claude-transcript-tests--fixture file)
     (with-temp-buffer
       (claude-transcript-mode)
       (setq claude-transcript--file file)
       (claude-transcript--render claude-transcript-tail-turns)
       (unwind-protect (progn ,@body)
         (delete-directory dir t)))))

(defun claude-transcript-tests--section (type value)
  "Return the section of TYPE and VALUE in the current buffer."
  (seq-find (lambda (section) (equal (oref section value) value))
            (let (found)
              (magit-map-sections (lambda (section)
                                    (when (eq (oref section type) type)
                                      (push section found))))
              found)))

(defun claude-transcript-tests--append (file &rest lines)
  "Append LINES to FILE."
  (write-region (apply #'concat lines) nil file t 'silent))

(ert-deftest claude-transcript-tests-partial-line ()
  (let ((read (claude-transcript--entries-read claude-transcript-tests--fixture 0)))
    (should (= (length (car read)) 14))
    (should (< (cdr read) (file-attribute-size (file-attributes claude-transcript-tests--fixture))))
    (should-not (car (claude-transcript--entries-read claude-transcript-tests--fixture (cdr read))))))

(ert-deftest claude-transcript-tests-render ()
  (claude-transcript-tests--with-session
    (let ((text (buffer-string)))
      (should (string-search "Fix the wrapper warning" text))
      (should (string-search "second line of prompt" text))
      (should (string-search "Looking at the wrapper." text))
      (should (string-search " $ ls /tmp/example" text))
      (should (string-search "# List example files" text))
      (should (string-search "⚙ Read  /tmp/example/notes.txt" text))
      (should (string-search "Hand-off: from a83289aa" text))
      (should (string-search "System: compact_boundary" text))
      (should (string-search "Summary: compacted context" text))
      (should-not (string-search "turn_duration" text))
      ;; Collapsed bodies are not inserted yet.
      (should-not (string-search "Result:" text))
      (should-not (string-search "redacted hand-back" text)))
    (should (= (length (oref magit-root-section children)) 2))
    (let ((turn (car (oref magit-root-section children))))
      (should (equal (mapcar (lambda (s) (oref s type)) (oref turn children))
                     '(claude-transcript-text claude-transcript-tool claude-transcript-tool
                       claude-transcript-note claude-transcript-system
                       claude-transcript-summary))))))

(ert-deftest claude-transcript-tests-expand-truncates ()
  (claude-transcript-tests--with-session
    (let ((section (claude-transcript-tests--section 'claude-transcript-tool "toolu_read")))
      (magit-section-show section)
      (should (string-search "file_path: /tmp/example/notes.txt" (buffer-string)))
      (should (string-search "line 30\n" (buffer-string)))
      (should-not (string-search "line 31" (buffer-string)))
      (should (string-search "[show all 50 lines]" (buffer-string)))
      (goto-char (point-min))
      (search-forward "[show all")
      (push-button (1- (point)))
      (should (string-search "line 50" (buffer-string)))
      (should-not (string-search "[show all" (buffer-string)))
      (should (eq (magit-section-at (1- (oref section end))) section)))))

(ert-deftest claude-transcript-tests-live-append ()
  (claude-transcript-tests--with-session
    (let ((bash (claude-transcript-tests--section 'claude-transcript-tool "toolu_bash"))
          (late (claude-transcript-tests--section 'claude-transcript-tool "toolu_late")))
      (magit-section-show bash)
      (magit-section-show late)
      (should (string-search "(no result yet)" (buffer-string)))
      (goto-char (oref bash start))
      (let ((point (point)))
        (claude-transcript-tests--append
         file
         ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\","
         "\"tool_use_id\":\"toolu_late\",\"content\":\"found needle\"}]}}\n"
         "{\"type\":\"user\",\"uuid\":\"u3\",\"message\":{\"content\":\"Third prompt\"}}\n"
         "{\"type\":\"assistant\",\"uuid\":\"a6\",\"message\":{\"content\":"
         "[{\"type\":\"text\",\"text\":\"Third answer.\"}]}}\n")
        (claude-transcript--update (current-buffer))
        (should (= (point) point)))
      (should-not (oref bash hidden))
      (should (string-search "found needle" (buffer-string)))
      (should-not (string-search "(no result yet)" (buffer-string)))
      (let ((turns (oref magit-root-section children)))
        (should (= (length turns) 3))
        (should (equal (oref (car (oref (nth 2 turns) children)) type)
                       'claude-transcript-text))
        (should (= (oref (nth 2 turns) end) (point-max)))
        ;; One blank line separates the turns.
        (should (= (1+ (oref (nth 1 turns) end)) (oref (nth 2 turns) start))))
      (should (string-suffix-p "Third answer.\n" (buffer-string))))))

(ert-deftest claude-transcript-tests-copy-and-refresh ()
  (claude-transcript-tests--with-session
    (let ((bash (claude-transcript-tests--section 'claude-transcript-tool "toolu_bash")))
      (claude-transcript-copy bash)
      (should (string-search "\nls /tmp/example\n" (car kill-ring)))
      (should-not (string-search "command:" (car kill-ring)))
      (should (string-search "beta" (car kill-ring)))
      (magit-section-show bash)
      (goto-char (oref bash start))
      (claude-transcript-refresh)
      (let ((again (claude-transcript-tests--section 'claude-transcript-tool "toolu_bash")))
        (should-not (eq again bash))
        (should-not (oref again hidden))
        (should (= (point) (oref again start)))
        (should (oref (claude-transcript-tests--section 'claude-transcript-tool "toolu_read")
                      hidden))))))

(ert-deftest claude-transcript-tests-pasted-split ()
  (should (equal (claude-transcript--pasted-split "plain") '("plain")))
  (should (equal (claude-transcript--pasted-split
                  "hi\n<pasted_content id=\"5a82\">\na\nb\n</pasted_content id=\"5a82\">\nbye")
                 '("hi\n" (pasted . "a\nb") "\nbye")))
  (should (equal (claude-transcript--pasted-split
                  "<pasted_content>x</pasted_content><pasted_content id=\"1\">y</pasted_content>")
                 '((pasted . "x") (pasted . "y"))))
  ;; The literal empty tag is somebody's text, not a paste
  (should (equal (claude-transcript--pasted-split "see <pasted_content />")
                 '("see <pasted_content />"))))

(ert-deftest claude-transcript-tests-pasted-section ()
  (let* ((dir (make-temp-file "claude-transcript" t))
         (file (expand-file-name "session.jsonl" dir))
         (claude-transcript-projects-directory dir)
         (body (mapconcat #'number-to-string (number-sequence 1 12) "\n"))
         (paste (format "Look at this\n<pasted_content id=\"5a82\">\n%s\n</pasted_content id=\"5a82\">" body)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-serialize
                     `((type . "user") (uuid . "u1") (timestamp . "2026-11-18T03:51:22.692Z")
                       (message . ((role . "user") (content . ,paste)))))
                    "\n"
                    (json-serialize
                     `((type . "user") (uuid . "u2") (timestamp . "2026-11-18T03:52:22.692Z")
                       (message . ((role . "user")
                                   (content . "<pasted_content>[go](homun:click/x)</pasted_content>")))))
                    "\n"))
          (with-temp-buffer
            (claude-transcript-mode)
            (setq claude-transcript--file file)
            (claude-transcript--render claude-transcript-tail-turns)
            (let ((text (buffer-string))
                  (pastes nil))
              (magit-map-sections (lambda (section)
                                    (when (eq (oref section type) 'claude-transcript-paste)
                                      (push section pastes))))
              (setq pastes (nreverse pastes))
              (should (string-search "Look at this" text))
              (should (string-search "pasted · 12 lines" text))
              (should (string-search "pasted · 1 line\n" text))
              (should-not (string-search "5a82" text))
              (should-not (string-search "pasted_content" text))
              (should (= (length pastes) 2))
              (should (oref (car pastes) hidden))
              (should-not (oref (cadr pastes) hidden))
              ;; A link in pasted text stays text
              (should (string-search "[go](homun:click/x)" text)))))
      (delete-directory dir t))))

(defun claude-transcript-tests--faced-p (string substring)
  "Return non-nil when SUBSTRING in STRING has a `font-lock-face'."
  (get-text-property (string-search substring string) 'font-lock-face string))

(ert-deftest claude-transcript-tests-fence-elisp ()
  (let ((text (claude-transcript--fmt-markdown "Hi\n```elisp\n(defun foo () 1)\n```\nbye")))
    (should (claude-transcript-tests--faced-p text "defun"))
    (should-not (claude-transcript-tests--faced-p text "bye"))))

(ert-deftest claude-transcript-tests-fence-rust ()
  (require 'rust-mode nil t)
  (skip-unless (fboundp 'rust-mode))
  (let ((text (claude-transcript--fmt-markdown "```rust\nfn main() {}\n```")))
    (should (claude-transcript-tests--faced-p text "fn"))))

(ert-deftest claude-transcript-tests-fence-unknown-is-plain ()
  (let ((text (claude-transcript--fmt-markdown "```nosuchlang\nfn x\n```")))
    (should-not (claude-transcript-tests--faced-p text "fn"))))

(ert-deftest claude-transcript-tests-size-cap ()
  (let* ((claude-transcript-fontify-limit 10)
         (text (claude-transcript--fontify "(defun foo () 1)" 'emacs-lisp-mode)))
    (should (equal text "(defun foo () 1)"))
    (should-not (claude-transcript-tests--faced-p text "defun"))))

(ert-deftest claude-transcript-tests-tool-fields ()
  (let ((bash (claude-transcript--fmt-input "Bash" '((command . "if true; then echo 1; fi"))))
        (edit (claude-transcript--fmt-input "Edit" '((old_string . "a") (new_string . "b")))))
    (should (claude-transcript-tests--faced-p bash "if"))
    (should-not (string-search "command:" bash))
    (should (eq (get-text-property (string-search "a" edit) 'font-lock-face edit) 'diff-removed))
    (should (eq (get-text-property (string-search "b" edit) 'font-lock-face edit) 'diff-added))))

(ert-deftest claude-transcript-tests-command-body ()
  (let* ((claude-transcript-shfmt-command '("/nonexistent/shfmt"))
         (claude-transcript--shell-formatted (make-hash-table :test #'equal))
         (body (claude-transcript--fmt-input
                "Bash" '((command . "echo a") (description . "Say a") (timeout . 5000)
                         (run_in_background . t)))))
    (should (equal (substring-no-properties body)
                   "# Say a\necho a\ntimeout: 5000  run_in_background: true\n"))
    (should (eq (get-text-property 0 'face body) 'claude-transcript-command-comment))
    (should (gethash "echo a" claude-transcript--shell-formatted))))

(ert-deftest claude-transcript-tests-missing-grammar ()
  (let ((claude-transcript-language-modes '(("zzz" zzz-ts-mode)))
        (claude-transcript--modes (make-hash-table :test #'equal))
        (warnings nil))
    (cl-letf (((symbol-function 'zzz-ts-mode) (lambda () (error "No grammar")))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (let ((text (claude-transcript--fmt-markdown "```zzz\nfn x\n```")))
        (should-not (claude-transcript-tests--faced-p text "fn"))
        (should-not warnings)))))

;; A code block keeps its frame whatever its language: label, code face, hidden close
(defun claude-transcript-tests--framed-p (text language body)
  "Non-nil when TEXT shows BODY as a LANGUAGE block with its frame."
  (let* ((shown (claude-transcript--fmt-markdown text))
         (at (string-match (regexp-quote body) shown)))
    (and at
         (eq (get-text-property 0 'face shown) 'claude-transcript-code)
         (equal (substring-no-properties (get-text-property 0 'display shown)) language)
         (memq 'claude-transcript-code
               (ensure-list (get-text-property at 'face shown)))
         (eq (get-text-property (1- (length shown)) 'invisible shown)
             'claude-transcript-markup))))

(ert-deftest claude-transcript-tests-nu-block ()
  (require 'nushell-mode nil t)
  (let ((text "```nu\nlet x = 1 # note\n```\n"))
    (should (claude-transcript-tests--framed-p text "nu" "let x"))
    (when (claude-transcript--mode-of-language "nu")
      (should (claude-transcript-tests--faced-p
               (claude-transcript--fmt-markdown text) "let")))))

(ert-deftest claude-transcript-tests-unknown-language-block ()
  (let ((claude-transcript--modes (make-hash-table :test #'equal)))
    (should-not (claude-transcript--mode-of-language "nosuchlang"))
    (should (claude-transcript-tests--framed-p
             "```nosuchlang\nfoo bar\n```\n" "nosuchlang" "foo bar"))))

(ert-deftest claude-transcript-tests-indented-block ()
  (let ((shown (claude-transcript--fmt-markdown "1. Run:\n   ```nu\n   ls\n   ```\n2. Next\n")))
    (should (equal (get-text-property (string-match "   ls" shown) 'face shown)
                   'claude-transcript-code))
    (should (get-text-property (string-match "   ```\n" shown) 'invisible shown))))

(ert-deftest claude-transcript-tests-mode-text-properties-stay-out ()
  (cl-letf (((symbol-function 'zzz-mode)
             (lambda ()
               (put-text-property (point-min) (point-max) 'invisible t)
               (put-text-property (point-min) (1+ (point-min)) 'display "X")
               (put-text-property (point-min) (1+ (point-min)) 'face 'bold))))
    (let ((out (claude-transcript--fontify "abc\n" 'zzz-mode)))
      (should (equal out "abc\n"))
      (should-not (get-text-property 0 'invisible out))
      (should-not (get-text-property 0 'display out))
      (should (eq (get-text-property 0 'face out) 'bold)))))

(ert-deftest claude-transcript-tests-languages-in-use ()
  (dolist (case '(("bash" "echo hi") ("sh" "echo hi") ("rust" "fn main() {}")
                  ("elisp" "(setq x 1)") ("nix" "{ a = 1; }") ("json" "{\"a\": 1}")
                  ("toml" "a = 1") ("python" "def f(): pass") ("go" "func main() {}")
                  ("kotlin" "fun main() {}")))
    (let* ((language (car case))
           (body (cadr case))
           (text (format "```%s\n%s\n```\n" language body)))
      (ert-info (language)
        (should (claude-transcript-tests--framed-p text language body))
        (should (equal (substring-no-properties (claude-transcript--fontify body nil)) body))))))

(defconst claude-transcript-tests--finish
  (concat ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\","
          "\"tool_use_id\":\"toolu_late\",\"content\":\"found needle\"}]}}\n")
  "Text finishing the last line of the fixture.")

(defconst claude-transcript-tests--more
  (concat "{\"type\":\"user\",\"uuid\":\"u9\",\"message\":{\"content\":\"More\"}}\n"
          "{\"type\":\"assistant\",\"uuid\":\"a9\",\"message\":{\"content\":"
          "[{\"type\":\"text\",\"text\":\"Newest.\"}]}}\n")
  "Lines of a further turn.")

(ert-deftest claude-transcript-tests-follow ()
  (claude-transcript-tests--with-session
    (save-window-excursion
      (set-window-buffer nil (current-buffer))
      (set-window-point nil (point-max))
      (set-window-parameter nil 'claude-transcript-follow (cons t 1))
      (claude-transcript-tests--append file claude-transcript-tests--finish claude-transcript-tests--more)
      (claude-transcript--update (current-buffer))
      (should (= (window-point) (point-max)))
      (let ((claude-transcript-follow-preference t))
        (should (eq claude-transcript-follow 'on))
        (goto-char (point-min))
        (claude-transcript--follow-check)
        (should (eq claude-transcript-follow 'paused))
        (should-not (claude-transcript--stuck-windows))
        ;; Landing at the end by any other command does not resume; G does
        (goto-char (point-max))
        (claude-transcript--follow-check)
        (should (eq claude-transcript-follow 'paused))
        (let ((this-command 'end-of-buffer))
          (claude-transcript--follow-check))
        (should (eq claude-transcript-follow 'on))
        (claude-transcript-toggle-follow)
        (should (eq claude-transcript-follow 'off))
        (goto-char (point-max))
        (claude-transcript--follow-check)
        (should (eq claude-transcript-follow 'off))
        (claude-transcript-toggle-follow)
        (should (eq claude-transcript-follow 'on))))))

(ert-deftest claude-transcript-tests-follow-bottom ()
  "A paused buffer resumes only by an explicit move to the end, not by point
landing on the last line above an outbox; following stays on along the last
line; an old t or nil state is normalized."
  (claude-transcript-tests--with-session
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (propertize "\nYou queued\n" 'claude-transcript-outbox t)))
    (setq claude-transcript-follow 'paused)
    (goto-char (claude-transcript--tail-start))
    (skip-chars-backward " \t\n")
    (beginning-of-line)
    (claude-transcript--follow-check)
    (should (eq claude-transcript-follow 'paused))
    (let ((this-command 'evil-goto-line))
      (goto-char (1- (point-max)))
      (claude-transcript--follow-check))
    (should (eq claude-transcript-follow 'on))
    (goto-char (claude-transcript--tail-start))
    (skip-chars-backward " \t\n")
    (beginning-of-line)
    (claude-transcript--follow-check)
    (should (eq claude-transcript-follow 'on))
    (forward-line -2)
    (claude-transcript--follow-check)
    (should (eq claude-transcript-follow 'paused))
    (should (eq (claude-transcript--follow-normalize t) 'on))
    (should (eq (claude-transcript--follow-normalize nil) 'off))
    (setq claude-transcript-follow nil)
    (claude-transcript--follow-check)
    (should (eq claude-transcript-follow 'off))))

(ert-deftest claude-transcript-tests-follow-paused-redraw ()
  "New entries, an outbox redraw and a refresh while paused keep point and
window start, and leave the buffer paused, though the window showed the end."
  (claude-transcript-tests--with-session
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer nil (current-buffer))
      (set-window-parameter nil 'claude-transcript-follow (cons t 1))
      (goto-char (+ (point-min) 3))
      (set-window-start nil (point-min))
      (claude-transcript--follow-check)
      (should (eq claude-transcript-follow 'paused))
      (let ((pos (point)) (start (window-start)))
        (claude-transcript-tests--append file claude-transcript-tests--finish
                                         claude-transcript-tests--more)
        (claude-transcript--update (current-buffer))
        (claude-transcript--follow-check)
        (claude-transcript-refresh)
        (claude-transcript--follow-check)
        (should (= (point) pos))
        (should (= (window-point) pos))
        (should (= (window-start) start))
        (should (eq claude-transcript-follow 'paused))))))

;; Window height 3 lines of a tall fixture: scroll so that the end is or is not visible
(defun claude-transcript-tests--show (pos-fn)
  (set-window-buffer nil (current-buffer))
  (funcall pos-fn)
  (redisplay t))

(ert-deftest claude-transcript-tests-follow-scrolled-up ()
  (claude-transcript-tests--with-session
    (save-window-excursion
      (delete-other-windows)
      (let ((other (split-window)))
        (claude-transcript-tests--show
         (lambda () (set-window-point nil (point-max)) (recenter -1)))
        (set-window-buffer other (current-buffer))
        (set-window-point other (point-max))
        (set-window-start other (max (point-min) (- (point-max) 200)))
        (redisplay t)
        ;; At the bottom: both windows follow, selected or not (batch draws
        ;; nothing, so set the state the scroll hook would record)
        (dolist (w (list (selected-window) other))
          (set-window-parameter w 'claude-transcript-follow (cons t 1)))
        (claude-transcript-tests--append file claude-transcript-tests--finish
                                         claude-transcript-tests--more)
        (claude-transcript--update (current-buffer))
        (should (= (window-point) (point-max)))
        (should (= (window-point other) (point-max)))
        (should (= claude-transcript--unseen 0))
        ;; Scrolled up: stays, counts (pad so the whole text cannot fit)
        (dotimes (_ 8)
          (claude-transcript-tests--append file claude-transcript-tests--more))
        (claude-transcript--update (current-buffer))
        (progn
          (dolist (w (list (selected-window) other))
            (set-window-parameter w 'claude-transcript-follow (cons nil 1)))
          (set-window-point nil (point-min))
          (claude-transcript-tests--append file claude-transcript-tests--more)
          (claude-transcript--update (current-buffer))
          (should (= (window-point) (point-min)))
          (should (> claude-transcript--unseen 0))
          (should (claude-transcript--unseen-string)))
        ;; G resumes
        (claude-transcript-goto-end)
        (should (= (window-point) (point-max)))
        (should (= claude-transcript--unseen 0))))))

;;;; Widgets

(defconst claude-transcript-tests--widgets
  (concat "Rebuild? [Yes](homun:click/yes) or [No][n].\n"
          "Volume [40%](homun:meter?id=vol&value=0.4)\n"
          "[n]: homun:click/no\n"
          "```widgetry\n(buttons (now \"Now\") (later \"Later\"))\n```\n"
          "[x](https://example.com) [bad](homun:eval/x)")
  "A message with each widget form.")

(defun claude-transcript-tests--insert-widgets ()
  "Insert the widget message as message u1 in a fresh transcript buffer."
  (claude-transcript-mode)
  (let ((inhibit-read-only t)
        (claude-transcript--widget-message "u1"))
    (magit-insert-section (claude-transcript-text "u1/0")
      (claude-transcript--insert-message 'claude "Claude" 'bold 'bold "now"
                                         claude-transcript-tests--widgets))))

(defmacro claude-transcript-tests--with-widgets (&rest body)
  "Run BODY in a buffer holding the inserted widget message."
  (declare (indent defun))
  `(let ((claude-transcript-channel-log "/nonexistent")
         (claude-transcript--widget-states (make-hash-table :test #'equal)))
     (with-temp-buffer
       (claude-transcript-tests--insert-widgets)
       ,@body)))

(ert-deftest claude-transcript-tests-link-parse ()
  (let ((spec (claude-transcript--link-parse
               "homun:meter?id=vol&min=0&max=2&value=0.5&state=done&evil=1" "V")))
    (should (eq (plist-get spec :type) 'meter))
    (should (equal (plist-get spec :id) "vol"))
    (should (= (plist-get spec :value) 0.5))
    (should (plist-get spec :done))
    (should-not (plist-member spec :evil)))
  (should-not (claude-transcript--link-parse "homun:eval/x" "x"))
  (should-not (claude-transcript--link-parse "homun:click/a b" "x")))

;; Slider and vector links, and a hold row in a block
(ert-deftest claude-transcript-tests-link-parse-slider-vector ()
  (let ((slider (claude-transcript--link-parse "homun:slider?id=t&value=21.5&min=10&max=30" "T"))
        (vector (claude-transcript--link-parse "homun:vector?id=pos&value=1,2.5,-3" "P")))
    (should (eq (plist-get slider :type) 'slider))
    (should (= (plist-get slider :max) 30))
    (should (equal (plist-get vector :value) [1.0 2.5 -3.0])))
  (should-not (plist-get (claude-transcript--link-parse "homun:vector?id=p&value=1,x" "P") :value)))

(ert-deftest claude-transcript-tests-pending-tick-spins ()
  (dolist (state '(pending sending))
    (let ((tick (claude-transcript--tick state)))
      (should (get-text-property 0 'claude-transcript-pending tick))
      (should (eq (get-text-property 0 'face tick) 'widgetry-status-pending))
      (should (get-text-property 0 'help-echo tick))))
  (should-not (get-text-property 0 'claude-transcript-pending (claude-transcript--tick 'sent)))
  (with-temp-buffer
    (insert "log\n" (propertize (concat "x " (claude-transcript--tick 'pending) "\n")
                                'claude-transcript-outbox t))
    (claude-transcript--spin-draw)
    (should (member (get-text-property 7 'display) (append widgetry-spinner-frames nil)))
    (should-not (get-text-property 5 'display))))

(ert-deftest claude-transcript-tests-done-widgets-carry-status ()
  (with-temp-buffer
    (let ((click (claude-transcript--widget-make
                  '(:type click :id "a" :label "A" :done t) "u1" t))
          (open (claude-transcript--widget-make '(:type click :id "b" :label "B") "u1" nil))
          (submit (claude-transcript--widget-make '(:type submit :id "s") "u1" t)))
      (should (eq (widget-get click :status) 'done))
      (should-not (widget-get click :tag))
      (should-not (widget-get open :status))
      (should (eq (widget-get submit :status) 'done))
      (should (equal (widget-get submit :tag) " ➤ ")))))

(ert-deftest claude-transcript-tests-buttons-hold ()
  (let* ((claude-transcript--widget-message "u1")
         (source (claude-transcript--fmt-widgetry
                  "src" "(buttons :confirm hold (wipe \"Wipe\") (keep \"Keep\"))"))
         (items (plist-get (get-text-property 0 'claude-transcript-widget source) :items))
         (spec (seq-find #'consp items)))
    (should (eq 'hold (plist-get (car (plist-get spec :buttons)) :confirm)))
    (should (equal (claude-transcript--form-answer
                    '(buttons :confirm hold (wipe "Wipe")) nil "wipe")
                   '(buttons :chosen wipe :confirm hold (wipe "Wipe"))))))

(ert-deftest claude-transcript-tests-click-is-default ()
  (let* ((claude-transcript--widget-message "u1")
         (confirm (lambda (code)
                    (plist-get (car (plist-get
                                     (seq-find #'consp
                                               (plist-get (get-text-property
                                                           0 'claude-transcript-widget
                                                           (claude-transcript--fmt-widgetry "src" code))
                                                          :items))
                                     :buttons))
                               :confirm))))
    (should-not (funcall confirm "(buttons (a \"A\"))"))
    (should (eq 'hold (funcall confirm "(buttons :confirm hold (a \"A\"))")))
    (should (eq 'drag (funcall confirm "(buttons :confirm drag (a \"A\"))")))
    (should-not (plist-get (claude-transcript--link-parse "homun:click/a" "A") :confirm))
    (should (eq 'hold (plist-get (claude-transcript--link-parse "homun:click/a?confirm=hold" "A") :confirm)))
    (should (eq 'drag (plist-get (claude-transcript--link-parse "homun:click/a?confirm=drag" "A") :confirm)))
    (should-not (claude-transcript--confirm-mode nil))
    (should (eq t (claude-transcript--confirm-mode 'drag)))))

(ert-deftest claude-transcript-tests-block-colon-labels ()
  "Labels with colons and parentheses draw as widgets, with the closing fence once."
  (let ((claude-transcript--widget-message "u1")
        (claude-transcript--widget-blocks 0))
    (let ((text (claude-transcript--fmt-markdown
                 (concat "Pick:\n```widgetry\n(buttons (a \"Choose: hold (best)\") "
                         "(b \"Choose: plain click\"))\n```\n"))))
      (should (get-text-property 7 'claude-transcript-widget text))
      (should (= 2 (length (plist-get (seq-find #'consp (plist-get (get-text-property 7 'claude-transcript-widget text) :items))
                                      :buttons))))
      (should (= 2 (with-temp-buffer (insert text) (goto-char (point-min))
                                     (how-many "^```")))))))

(ert-deftest claude-transcript-tests-slider-vector-reply ()
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "[T](homun:slider?id=t&value=20&min=10&max=30) [P](homun:vector?id=pos&value=1,2,3)"))
    (claude-transcript-tests--with-widgets
      (let ((slider (gethash '("u1" . "t") claude-transcript--widget-groups))
            (vector (gethash '("u1" . "pos") claude-transcript--widget-groups)))
        (should (equal (claude-transcript--widget-reply (cadr slider) (list (car slider)))
                       "[set t=20.0 on u1] homun:slider?id=t&value=20.0&min=10.0&max=30.0&state=done"))
        (should (equal (claude-transcript--widget-reply (cadr vector) (list (car vector)))
                       "[set pos=1.0,2.0,3.0 on u1] homun:vector?id=pos&value=1.0,2.0,3.0&state=done"))))))

(ert-deftest claude-transcript-tests-widgetry-is-data ()
  (let ((claude-transcript--widget-message "u1"))
    (should (seq-some (lambda (item)
                        (and (stringp item) (string-match-p "unknown widgetry element" item)))
                      (plist-get (get-text-property
                                  0 'claude-transcript-widget
                                  (claude-transcript--fmt-widgetry
                                   "src" "(buttons (a (shell-command \"x\")))"))
                                 :items)))
    (should (claude-transcript--fmt-widgetry "src" "(progn (error \"x\"))"))
    (should (claude-transcript--fmt-widgetry "" "(buttons (a \"A\"))"))))

(ert-deftest claude-transcript-tests-widgets-drawn ()
  (skip-unless (featurep 'widgetry))
  (claude-transcript-tests--with-widgets
    (let ((groups claude-transcript--widget-groups))
      (should (= (length (gethash '("u1" . "line0") groups)) 2))
      (should (= (length (gethash '("u1" . "vol") groups)) 2))
      (should (= (length (gethash '("u1" . "block1") groups)) 2)))
    (should (string-search " Now " (buffer-string)))
    ;; The source is the text; the drawn widgets are left out
    (let ((source (claude-transcript--source-only (point-min) (point-max))))
      (should (string-search "[Yes](homun:click/yes)" source))
      (should (string-search "(buttons (now" source))
      (should-not (string-search " Now " source))
      (should (string-search "[x](https://example.com)" source)))))

(ert-deftest claude-transcript-tests-widget-answer-rewrites-source ()
  (skip-unless (featurep 'widgetry))
  (claude-transcript-tests--with-widgets
    (let* ((block (gethash '("u1" . "block1") claude-transcript--widget-groups))
           (inline (gethash '("u1" . "line0") claude-transcript--widget-groups))
           (meter (gethash '("u1" . "vol") claude-transcript--widget-groups)))
      (should (equal (claude-transcript--widget-reply (car inline) nil)
                     "[clicked yes on u1] homun:click/yes?state=done"))
      (widget-value-set (car meter) 0.55)
      (should (string-prefix-p "[set vol=0.55 on u1] homun:meter?id=vol&value=0.55"
                               (claude-transcript--widget-reply (cadr meter) (list (car meter)))))
      (claude-transcript--widget-answer (cadr block) block)
      (claude-transcript--widget-answer (car inline) inline)
      (let ((source (claude-transcript--source-only (point-min) (point-max))))
        (should (string-search "(buttons :chosen later (now \"Now\")" source))
        (should (string-search "[Yes](homun:click/yes?state=done)" source))
        (should (string-search "[No](homun:click/no)" source)))
      (should (widget-get (car block) :disabled)))))

(ert-deftest claude-transcript-tests-widget-click-draws-nothing ()
  (let ((claude-transcript--widget-states (make-hash-table :test #'equal))
        (claude-transcript--last nil) (claude-transcript--turn 'keep))
    (should (claude-transcript--widget-click-p "[clicked later on u1] homun:click/later"))
    (should (claude-transcript--widget-click-p "[set vol=0.4 on u1] homun:meter?id=vol&value=0.4"))
    (should-not (claude-transcript--widget-click-p "[clicked later] hi"))
    (should-not (claude-transcript--widget-click-p "hello [clicked a on u1]"))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (magit-insert-section (claude-transcript-root)
          ;; a click record inserts no prompt and marks its widget done
          (should (eq 'keep (claude-transcript--insert-prompt
                             '((uuid . "p1") (message (content . "[clicked later on u1] homun:click/later?state=done")))))))
        (should (string-empty-p (buffer-string)))
        (should (plist-get (gethash '("u1" . "later") claude-transcript--widget-states) :done))
        ;; a lookalike plain message still shows
        (magit-insert-section (claude-transcript-root)
          (claude-transcript--insert-prompt
           '((uuid . "p2") (message (content . "[clicked on the link] see")))))
        (should (string-search "[clicked on the link]" (buffer-string)))))))

(ert-deftest claude-transcript-tests-widget-state-from-log ()
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript--widget-states (make-hash-table :test #'equal)))
    (claude-transcript--widget-record "[clicked later on u1] homun:click/later?state=done")
    (claude-transcript--widget-record "[set vol=0.7 on u1] homun:meter?id=vol&value=0.7&state=done")
    (let ((claude-transcript-channel-log "/nonexistent"))
      (with-temp-buffer
        (claude-transcript-tests--insert-widgets)
        (let ((block (gethash '("u1" . "block1") claude-transcript--widget-groups))
              (meter (gethash '("u1" . "vol") claude-transcript--widget-groups)))
          ;; An answered row shows only its chosen segment, disabled and done
          (should (= 1 (length block)))
          (should (widget-get (car block) :disabled))
          (should (eq 'done (widget-get (car block) :status)))
          (should (= (widget-value (car meter)) 0.7)))))))

(ert-deftest claude-transcript-tests-answer-of-another-device-draws-done ()
  "A click made on device A, handed on as the gateway's widget record, is done on device B."
  (skip-unless (featurep 'widgetry))
  (require 'claude-remote)
  (claude-transcript-tests--with-widgets
    (let ((group (gethash '("u1" . "block1") claude-transcript--widget-groups)))
      (should (= 2 (length group)))
      (should-not (widget-get (car group) :disabled))
      (claude-remote--widget
       '(:uuid "u1" :id "later" :text "[clicked later on u1] homun:click/later?state=done"))
      (let ((later (seq-find (lambda (w) (equal (plist-get (widget-get w :claude-spec) :id) "later"))
                             (gethash '("u1" . "block1") claude-transcript--widget-groups))))
        (should (eq 'done (widget-get later :status)))
        (should (plist-get (widget-get later :claude-spec) :done)))
      ;; pressing it again here sends nothing
      (let (sent (claude-transcript-widget-sender (lambda (&rest args) (push args sent))))
        (claude-transcript--widget-pressed
         (seq-find #'claude-transcript--button-p
                   (gethash '("u1" . "block1") claude-transcript--widget-groups)))
        (should-not sent)))))

(ert-deftest claude-transcript-tests-answer-is-kept-in-the-shared-store ()
  "An answer sent here is a file under the store, which another read turns into state."
  (let* ((claude-transcript-widget-store (make-temp-file "widgets" t))
         (claude-transcript--widget-store-time nil)
         (claude-transcript--widget-states (make-hash-table :test #'equal)))
    (claude-transcript--widget-answered "[clicked later on u9] homun:click/later?state=done")
    (should (file-exists-p (expand-file-name "u9/later" claude-transcript-widget-store)))
    (clrhash claude-transcript--widget-states)
    (should (claude-transcript--widget-store-read))
    (should (plist-get (gethash '("u9" . "later") claude-transcript--widget-states) :done))
    (delete-directory claude-transcript-widget-store t)))

(ert-deftest claude-transcript-tests-text-parse-and-reply ()
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry\n(text note \"Note\" :value \"hi there\" :placeholder \"say\")\n```\n"))
    (claude-transcript-tests--with-widgets
      (let* ((group (gethash '("u1" . "block1") claude-transcript--widget-groups))
             (text (seq-find (lambda (w) (eq (widget-type w) 'widgetry-text)) group))
             (send (seq-find (lambda (w) (claude-transcript--button-p w)) group)))
        (should text)
        (should (equal (widget-value text) "hi there"))
        (should (equal (claude-transcript--widget-reply send (list text))
                       "[set note=\"hi there\" on u1] homun:text?id=note&value=hi%20there&state=done"))
        (should (equal (claude-transcript--form-answer
                        '(text note "Note" :value "a") (list text) "send")
                       '(text note "Note" :value "hi there" :done t)))))))

(ert-deftest claude-transcript-tests-text-edits-in-place-in-demo ()
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry-demo\n(text note \"Note\" :value \"hi\")\n```\n"))
    (claude-transcript-tests--with-widgets
      (let* ((group (gethash '("u1" . "demo1") claude-transcript--widget-groups))
             (text (seq-find (lambda (w) (eq (widget-type w) 'widgetry-text)) group))
             (overlay (widget-get text :widgetry-overlay)))
        (goto-char (overlay-start overlay))
        ;; The transcript's dispatcher finds the command in the widget keymap
        (should (eq (claude-transcript--widget-key [down-mouse-1] (point)) 'widgetry-text-edit))
        (should (eq (claude-transcript--widget-key (kbd "RET") (point)) 'widgetry-text-edit))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (let ((modified (buffer-modified-p)))
          (widgetry-text-edit)
          (should-not (overlay-get overlay 'display))
          (let ((start (overlay-start overlay)))
            (goto-char (+ start 3))
            (insert "!"))
          (widgetry-text-commit)
          (should (equal (widget-value text) "hi!"))
          (should (eq modified (buffer-modified-p)))
          (should buffer-read-only))))))

(ert-deftest claude-transcript-tests-text-as-form-item ()
  (let* ((claude-transcript--widget-message "u1")
         (source (claude-transcript--fmt-widgetry
                  "src" "(form (text a \"A\" :value \"x\") (toggle b \"B\"))"))
         (items (plist-get (get-text-property 0 'claude-transcript-widget source) :items))
         (spec (seq-find (lambda (i) (and (consp i) (eq (plist-get i :type) 'text))) items)))
    (should (equal (plist-get spec :text) "x"))))

(ert-deftest claude-transcript-tests-secret-parse ()
  (let* ((claude-transcript--widget-message "u1")
         (items (lambda (code)
                  (when-let* ((source (claude-transcript--fmt-widgetry "src" code)))
                    (seq-filter #'consp
                                (plist-get (get-text-property 0 'claude-transcript-widget source)
                                           :items)))))
         (spec (seq-find #'consp (funcall items "(secret tok \"Token\" :name dsktd-token)"))))
    (should (eq (plist-get spec :type) 'secret))
    (should (equal (plist-get spec :name) "dsktd-token"))
    (should (equal (plist-get spec :label) "Token"))
    ;; A name is a slot, never a path, and must be given
    (should-not (funcall items "(secret tok \"T\" :name \"../x\")"))
    (should-not (funcall items "(secret tok \"T\" :name ../x)"))
    (should-not (funcall items "(secret tok \"T\" :name Bad)"))
    (should-not (funcall items "(secret tok \"T\")"))
    (should (equal (claude-transcript--form-answer
                    '(secret tok "T" :name a) nil "tok")
                   '(secret tok "T" :name a :saved t)))))

(ert-deftest claude-transcript-tests-secret-write-and-accept ()
  (let* ((dir (make-temp-file "secrets" t))
         (claude-transcript-secrets-dir dir)
         (sent nil)
         (secret (copy-sequence "ghp_abcdef")))
    (unwind-protect
        (with-temp-buffer
          (let ((widget (list :claude-spec '(:id "tok" :name "dsktd-token") :claude-message "u9")))
            (cl-letf (((symbol-function 'widget-get)
                       (lambda (w key) (plist-get w key)))
                      ((symbol-function 'claude-transcript--widget-send)
                       (lambda (text _done) (setq sent text))))
              (should (claude-transcript--secret-accept secret widget))))
          (let ((file (expand-file-name "dsktd-token" dir)))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           "ghp_abcdef"))
            (should (= (file-modes file) #o600)))
          (should (equal sent "[set tok=saved dsktd-token 10 chars on u9]"))
          (should-not (string-match-p "ghp" sent))
          (should (equal (directory-files dir nil "\\`[^.]") '("dsktd-token")))
          (should (equal (directory-files dir nil "tmp") nil)))
      (delete-directory dir t))))

(ert-deftest claude-transcript-tests-source-rewrite-other-buffer ()
  "A rewrite run from another buffer (a sentinel in compose) edits the markers' buffer."
  (let ((transcript (generate-new-buffer " *rewrite-transcript*"))
        (compose (generate-new-buffer " *rewrite-compose*")))
    (unwind-protect
        (let* ((place (with-current-buffer transcript
                        (insert (make-string 200 ?x) "OLD" "tail")
                        (list (copy-marker 201) (copy-marker 204) '(:forms nil))))
               (widget (list :claude-source place)))
          (cl-letf (((symbol-function 'widget-get) (lambda (w key) (plist-get w key)))
                    ((symbol-function 'claude-transcript--source-text)
                     (lambda (&rest _) "NEW")))
            (with-current-buffer compose
              (claude-transcript--source-rewrite widget (list widget))
              (should (equal (buffer-string) "")))
            (with-current-buffer transcript
              (should (equal (buffer-substring 201 (point-max)) "NEWtail")))
            ;; Markers that point nowhere: nothing happens, no error
            (set-marker (car place) nil)
            (with-current-buffer compose
              (claude-transcript--source-rewrite widget (list widget)))))
      (kill-buffer transcript)
      (kill-buffer compose))))

;;; claude-transcript-test.el ends here

(defun claude-transcript-tests--at (text)
  "Return the position of the first TEXT in the buffer."
  (save-excursion (goto-char (point-min)) (search-forward text) (match-beginning 0)))

(defun claude-transcript-tests--has-face (pos face)
  "Return non-nil when the text at POS has FACE."
  (let ((value (get-text-property pos 'face)))
    (memq face (if (listp value) (flatten-tree value) (list value)))))

(defun claude-transcript-tests--bar (pos face)
  "Return non-nil when POS has a line and wrap prefix with a bar in FACE."
  (let ((line (get-text-property pos 'line-prefix)))
    (and line (equal line (get-text-property pos 'wrap-prefix))
         (eq (get-text-property 0 'face line) face))))

(ert-deftest claude-transcript-tests-kinds-differ ()
  (claude-transcript-tests--with-session
    (let ((you (claude-transcript-tests--at "You  "))
          (claude (claude-transcript-tests--at (concat claude-agent-name "  ")))
          (tool (claude-transcript-tests--at "⚙ Read"))
          (note (claude-transcript-tests--at "Hand-off: from")))
      (should (claude-transcript-tests--has-face you 'claude-transcript-you-name))
      (should (claude-transcript-tests--has-face you 'claude-transcript-you-body))
      (should (claude-transcript-tests--bar you 'claude-transcript-you-bar))
      (should (claude-transcript-tests--has-face claude 'claude-transcript-claude-name))
      (should-not (claude-transcript-tests--has-face claude 'claude-transcript-you-body))
      (should (claude-transcript-tests--bar claude 'claude-transcript-claude-bar))
      (should (claude-transcript-tests--has-face (+ tool 2) 'claude-transcript-tool-name))
      (should (claude-transcript-tests--has-face tool 'claude-transcript-tool))
      (should (claude-transcript-tests--bar tool 'claude-transcript-tool-bar))
      (should (claude-transcript-tests--has-face note 'claude-transcript-note))
      (should (claude-transcript-tests--bar note 'claude-transcript-note-bar))
      ;; Your second prompt line keeps the bar and background too.
      (should (claude-transcript-tests--bar (claude-transcript-tests--at "second line")
                                            'claude-transcript-you-bar))
      ;; A blank line starts the second turn, none sits between tool calls.
      (should (string-search "\n\nYou" (buffer-string)))
      (should (string-search "# List example files\n" (buffer-string)))
      (should-not (string-search "files\n\n" (buffer-string))))))

(ert-deftest claude-transcript-tests-result-dimmed-and-error ()
  (claude-transcript-tests--with-session
    (magit-section-show (claude-transcript-tests--section 'claude-transcript-tool "toolu_bash"))
    (let ((pos (claude-transcript-tests--at "alpha")))
      (should (claude-transcript-tests--has-face pos 'claude-transcript-result))
      (should (claude-transcript-tests--bar pos 'claude-transcript-tool-bar))
      (should (string-match-p "   \\'" (get-text-property pos 'wrap-prefix))))
    (claude-transcript-tests--append
     claude-transcript--file
     ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_late\",\"content\":\"found\"}]}}\n"
     "{\"type\":\"user\",\"uuid\":\"r9\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_bash\",\"content\":\"boom\",\"is_error\":true}]}}\n")
    (claude-transcript--update (current-buffer))
    (should (claude-transcript-tests--has-face (claude-transcript-tests--at "Result:")
                                               'claude-transcript-error))))

(ert-deftest claude-transcript-tests-channels ()
  (claude-transcript-tests--with-session
    (claude-transcript-tests--append
     claude-transcript--file
     ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_late\",\"content\":\"found\"}]}}\n"
     "{\"type\":\"user\",\"uuid\":\"k1\",\"message\":{\"role\":\"user\",\"content\":\"<channel source=\\\"scheduler\\\" alarm=\\\"x\\\">tick</channel>\"}}\n"
     "{\"type\":\"user\",\"uuid\":\"k2\",\"message\":{\"role\":\"user\",\"content\":\"<channel source=\\\"cal\\\">hello from cal</channel>\"}}\n")
    (claude-transcript--update (current-buffer))
    (let ((channel (claude-transcript-tests--at "Channel: scheduler")))
      (should (claude-transcript-tests--has-face channel 'claude-transcript-note))
      (should (claude-transcript-tests--bar channel 'claude-transcript-note-bar)))
    (let ((cal (claude-transcript-tests--at "hello from cal")))
      (should (claude-transcript-tests--has-face cal 'claude-transcript-you-body))
      (should (claude-transcript-tests--bar cal 'claude-transcript-you-bar)))
    (should-not (string-search "<channel" (buffer-string)))))

(ert-deftest claude-transcript-tests-parse-finish ()
  (let ((info (claude-transcript--parse-finish
               (concat "<task-notification>\n<task-id>a1</task-id>\n"
                       "<tool-use-id>toolu_x</tool-use-id>\n<status>completed</status>\n"
                       "<summary>Agent \"x\" finished</summary>\n<result>r</result>\n"
                       "<usage><subagent_tokens>85000</subagent_tokens><tool_uses>3</tool_uses>"
                       "<duration_ms>130000</duration_ms></usage>\n</task-notification>"))))
    (should (equal (plist-get info :task-id) "a1"))
    (should (equal (plist-get info :tool-use-id) "toolu_x"))
    (should (equal (plist-get info :status) "completed"))
    (should (= (plist-get info :tokens) 85000))
    (should (= (plist-get info :duration) 130000)))
  (let ((info (claude-transcript--parse-finish
               (concat "Another Claude session sent a message:\n<agent-message from=\"a1\">\n"
                       "[Subagent hand-back] x\nThe report follows:\n  line one\n  \n  line two\n"
                       "</agent-message>"))))
    (should (equal (plist-get info :from) "a1"))
    (should (equal (plist-get info :report) "line one\n\nline two"))))

(ert-deftest claude-transcript-tests-agent-finish-folds ()
  (claude-transcript-tests--with-session
    (claude-transcript-tests--append
     claude-transcript--file
     ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_late\",\"content\":\"found\"}]}}\n"
     "{\"type\":\"assistant\",\"uuid\":\"g1\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_ag\",\"name\":\"Agent\",\"input\":{\"description\":\"dig\"}}]}}\n"
     "{\"type\":\"user\",\"uuid\":\"g2\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_ag\",\"content\":\"Async agent launched successfully.\\nagentId: abc123 (x)\"}]}}\n")
    (claude-transcript--update (current-buffer))
    (should (string-search "⋯ running" (buffer-string)))
    (claude-transcript-tests--append
     claude-transcript--file
     "{\"type\":\"user\",\"uuid\":\"g3\",\"message\":{\"content\":\"<task-notification>\\n<task-id>abc123</task-id>\\n<status>completed</status>\\n<summary>Agent done</summary>\\n<usage><subagent_tokens>85000</subagent_tokens><duration_ms>130000</duration_ms></usage>\\n</task-notification>\"}}\n"
     "{\"type\":\"user\",\"uuid\":\"g4\",\"message\":{\"content\":\"<agent-message from=\\\"abc123\\\">\\nThe report follows:\\n  all good\\n</agent-message>\"}}\n"
     "{\"type\":\"user\",\"uuid\":\"g5\",\"message\":{\"content\":\"<task-notification>\\n<task-id>sh1</task-id>\\n<tool-use-id>toolu_none</tool-use-id>\\n<status>completed</status>\\n<summary>Background command \\\"x\\\" completed (exit code 0)</summary>\\n</task-notification>\"}}\n")
    (claude-transcript--update (current-buffer))
    (should (string-search "✓ finished 2m10s · 85k tok" (buffer-string)))
    (should-not (string-search "task-notification" (buffer-string)))
    (should-not (string-search "from abc123" (buffer-string)))
    (should (string-search "⏺ shell job sh1 done (exit 0)" (buffer-string)))
    (magit-section-show (claude-transcript-tests--section 'claude-transcript-tool "toolu_ag"))
    (should (string-search "all good" (buffer-string)))))

(ert-deftest claude-transcript-tests-agent-meta-finished ()
  (claude-transcript-tests--with-session
    (let ((dir (expand-file-name "subagents" (file-name-sans-extension claude-transcript--file))))
      (make-directory dir t)
      (write-region "{\"finished\":true}" nil (expand-file-name "agent-abc123.meta.json" dir))
      (claude-transcript-tests--append
       claude-transcript--file
       ",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_late\",\"content\":\"found\"}]}}\n"
       "{\"type\":\"assistant\",\"uuid\":\"g1\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_ag\",\"name\":\"Agent\",\"input\":{\"description\":\"dig\"}}]}}\n"
       "{\"type\":\"user\",\"uuid\":\"g2\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_ag\",\"content\":\"Async agent launched successfully.\\nagentId: abc123 (x)\"}]}}\n")
      (claude-transcript--update (current-buffer))
      (should (string-search "Agent  dig  ✓ finished" (buffer-string)))
      (should-not (string-search "⋯ running" (buffer-string))))))

(ert-deftest claude-transcript-tests-search-snippet ()
  (let ((snippet (claude-transcript-search--snippet "one\nTwo wrapper three" "WRAPPER")))
    (should (equal (substring-no-properties snippet) "one Two wrapper three"))
    (should (eq (get-text-property 8 'face snippet) 'claude-transcript-search-match)))
  (should-not (claude-transcript-search--snippet "nothing" "wrapper")))

(ert-deftest claude-transcript-tests-search-hits ()
  ;; A tool input is searched by value, not by key.
  (let* ((line "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls /tmp/example\"}}]}}")
         (hits (claude-transcript-search--hits line 7 "example")))
    (should (equal (plist-get (car hits) :who) "Bash"))
    (should (= (plist-get (car hits) :offset) 7))
    (should-not (claude-transcript-search--hits line 7 "command"))
    (should-not (claude-transcript-search--hits line 7 "uuid"))))

(ert-deftest claude-transcript-tests-search-turns-after ()
  (let* ((file claude-transcript-tests--fixture)
         (lines (with-temp-buffer (insert-file-contents file)
                                  (split-string (buffer-string) "\n" t)))
         (offset-of (lambda (n) (apply #'+ (mapcar (lambda (l) (1+ (string-bytes l)))
                                                   (seq-take lines n))))))
    ;; Line 2 is the first prompt, line 13 the second.
    (should (= (claude-transcript-search--turns-after file (funcall offset-of 1)) 1))
    (should (= (claude-transcript-search--turns-after file (funcall offset-of 3)) 1))
    (should (= (claude-transcript-search--turns-after file (funcall offset-of 12)) 0))))

(ert-deftest claude-transcript-tests-table ()
  (let* ((source "| Name | Size |\n|:-----|-----:|\n| **a** | 1 |\n| long `b` | 200 |\n")
         (text (concat "Before\n" source "After"))
         (shown (claude-transcript--fmt-markdown text))
         (from (string-search "| Name" shown))
         (table (get-text-property from 'display shown)))
    ;; The source stays, so copying gives the Markdown.
    (should (equal (substring-no-properties shown) text))
    (should (equal (split-string (substring-no-properties table) "\n")
                   '("Name   │ Size"
                     "───────┼─────"
                     "a      │    1"
                     "long b │  200")))
    (should-not (get-text-property (string-search "After" shown) 'display shown))))

(ert-deftest claude-transcript-tests-table-wrap ()
  (cl-letf (((symbol-function 'claude-transcript--table-width) (lambda () 20)))
    (let* ((table (get-text-property
                   0 'display
                   (claude-transcript--fmt-table
                    "| k | text |\n|---|---|\n| x | one two three four five six |\n")))
           (lines (split-string (substring-no-properties table) "\n")))
      (should (> (length lines) 3))
      (should (seq-every-p (lambda (line) (<= (string-width line) 20)) lines)))))

(ert-deftest claude-transcript-tests-time-after-name ()
  (should (equal (claude-transcript--after-name "12:34") "  12:34"))
  (should (equal (claude-transcript--after-name "") "")))

(ert-deftest claude-transcript-tests-hook-messages ()
  (let* ((entry `((type . "attachment") (uuid . "u") (timestamp . "2026-01-01T00:00:00Z")
                  (attachment . ((type . "hook_additional_context")
                                 (content . ["<channel source=\"cal\" ts=\"1\">one</channel>\n<channel source=\"scheduler\">x</channel><channel source=\"cal\" ts=\"2\">two\nlines</channel>\n"])))))
         (out (claude-transcript--hook-messages entry)))
    (should (= 2 (length out)))
    (should (eq 'prompt (claude-transcript--kind-of (car out))))
    (should (equal "two\nlines" (claude-transcript--unwrap-channel
                                 (claude-transcript--text-of (claude-transcript--content-of (cadr out)))))))
  (let ((plain '((type . "user") (message . ((content . "hi"))))))
    (should (equal (list plain) (claude-transcript--hook-messages plain)))))

(ert-deftest claude-transcript-tests-outbox-ticks ()
  (let ((text (claude-transcript--outbox-string
               (list (list :id "1" :text "hello" :state 'pending :time 0)
                     (list :id "2" :text "oops" :state 'failed :error "not listening" :time 0)))))
    (should (string-match-p "◌" text))
    (should (string-match-p "✗ not listening" text))
    (should (equal "not listening"
                   (get-text-property (string-match "✗" text) 'help-echo text)))))

(ert-deftest claude-transcript-tests-form-chips-once ()
  "A form with a chips item sends it once, as one pair and one link."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry\n(form :submit \"Go\" (chips x \"X\" :choices (\"a\" \"b\")))\n```\n"))
    (claude-transcript-tests--with-widgets
      (let* ((widgets (gethash '("u1" . "block1") claude-transcript--widget-groups))
             (chips (seq-filter (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'chips))
                                widgets))
             (submit (seq-find (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'submit))
                               widgets))
             (others (seq-remove #'claude-transcript--button-p widgets)))
        (should (= 1 (length chips)))
        (widget-value-set (car chips) '(b))
        (let ((reply (claude-transcript--widget-reply submit others)))
          (should (string-prefix-p "[set x=b on u1] homun:chips?id=x" reply))
          (should (= 1 (1- (length (split-string reply "homun:"))))))))))

(ert-deftest claude-transcript-tests-form-chips-redrawn-once ()
  "A message drawn twice keeps one widget per form item."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry\n(form :submit \"Go\" (chips x \"X\" :choices (\"a\" \"b\")))\n```\n"))
    (claude-transcript-tests--with-widgets
      (let ((start (point-min)) (end (point-max)))
        (let ((inhibit-read-only t)) (claude-transcript--widgets-make start end))
        (let* ((widgets (gethash '("u1" . "block1") claude-transcript--widget-groups))
               (chips (seq-filter (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'chips))
                                  widgets)))
          (should (= 1 (length chips))))))))

(ert-deftest claude-transcript-tests-outbox-matches-logged ()
  "An outbox item looks like the same text logged, apart from the tick."
  (let* ((text "hello **bold**\n\n- item one\n- item two")
         (out (claude-transcript--outbox-string
               (list (list :id "1" :text text :state 'pending :time 0))))
         (logged (with-temp-buffer
                   (let ((inhibit-read-only t) (claude-transcript--last nil)
                         (claude-transcript--turn nil))
                     (magit-insert-section (claude-transcript-root)
                       (claude-transcript--insert-prompt
                        `((uuid . "u") (timestamp . "1970-01-01T00:00:00Z")
                          (message . ((content . ,text))))))
                     (buffer-string))))
         (props (lambda (s)
                  (let (r (i (string-search "hello" s)))
                    (dolist (n (number-sequence 0 (- (length s) i 1)))
                      (push (list (get-text-property (+ i n) 'line-prefix s)
                                  (get-text-property (+ i n) 'wrap-prefix s)
                                  (get-text-property (+ i n) 'face s))
                            r))
                    r))))
    (should (equal (funcall props out) (funcall props logged)))))

(defun claude-transcript-tests--grow ()
  "Append a third prompt and answer, as the file watcher would."
  (claude-transcript-tests--append
   claude-transcript--file
   "{\"type\":\"user\",\"uuid\":\"u3\",\"message\":{\"content\":\"Third prompt\"}}\n"
   "{\"type\":\"assistant\",\"uuid\":\"a6\",\"message\":{\"content\":"
   "[{\"type\":\"text\",\"text\":\"Third answer.\"}]}}\n")
  (claude-transcript--update (current-buffer)))

(ert-deftest claude-transcript-tests-point-mid-stays ()
  (claude-transcript-tests--with-session
    (goto-char (+ (point-min) 10))
    (let ((pos (point)))
      (claude-transcript-tests--grow)
      (should (= (point) pos)))))

(ert-deftest claude-transcript-tests-point-end-follows ()
  (claude-transcript-tests--with-session
    (set-window-buffer (selected-window) (current-buffer))
    (set-window-parameter nil 'claude-transcript-follow (cons t 1))
    (goto-char (point-max))
    (claude-transcript-tests--grow)
    (should (= (point) (point-max)))))

(ert-deftest claude-transcript-tests-region-survives-refresh ()
  (claude-transcript-tests--with-session
    (transient-mark-mode 1)
    (goto-char (+ (point-min) 5))
    (push-mark (+ (point-min) 2) t t)
    (let ((beg (region-beginning)) (end (region-end)))
      (claude-transcript-refresh)
      (should (region-active-p))
      (should (= (region-beginning) beg))
      (should (= (region-end) end)))))

(ert-deftest claude-transcript-tests-answer-hides-unchosen ()
  "After a press only the chosen button shows: a row keeps one segment, a lone
unchosen click turns invisible, and a redraw draws the answered group so."
  (skip-unless (featurep 'widgetry))
  (claude-transcript-tests--with-widgets
    (let* ((block (gethash '("u1" . "block1") claude-transcript--widget-groups))
           (inline (gethash '("u1" . "line0") claude-transcript--widget-groups))
           (row (widget-get (cadr block) :group)))
      (claude-transcript--widget-answer (cadr block) block)
      (should (equal (widget-get row :segments) (list (cadr block))))
      (claude-transcript--widget-answer (car inline) inline)
      (should (overlay-get (widget-get (cadr inline) :widgetry-overlay) 'invisible))
      (should-not (overlay-get (widget-get (car inline) :widgetry-overlay) 'invisible))))
  (let ((claude-transcript-tests--widgets
         (concat "[Yes](homun:click/yes?state=done) or [No](homun:click/no)\n"
                 "```widgetry\n(buttons :chosen later (now \"Now\") (later \"Later\"))\n```\n")))
    (claude-transcript-tests--with-widgets
      (should (= 1 (length (gethash '("u1" . "line0") claude-transcript--widget-groups))))
      (should (= 1 (length (gethash '("u1" . "block1") claude-transcript--widget-groups)))))))

(ert-deftest claude-transcript-tests-checks ()
  "A checks group, alone in a block or as a link, sends one [set ID=a,c ...]."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry\n(checks pick \"Pick\" :choices (\"a\" \"b\" \"c\") :value (\"a\"))\n```\n"))
    (claude-transcript-tests--with-widgets
      (let* ((widgets (gethash '("u1" . "block1") claude-transcript--widget-groups))
             (checks (seq-find (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'checks))
                               widgets))
             (submit (seq-find (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'submit))
                               widgets)))
        (should (widget-get checks :checkbox))
        (should (string-search "☑ a" (widgetry-shown checks)))
        (widget-value-set checks '(a c))
        (should (equal (claude-transcript--widget-reply submit (list checks))
                       "[set pick=a,c on u1] homun:checks?id=pick&choices=a,b,c&value=a,c&state=done"))
        (claude-transcript--widget-answer submit widgets)
        (should (string-search "(checks pick \"Pick\" :choices (\"a\" \"b\" \"c\") :value (\"a\" \"c\") :done t)"
                               (claude-transcript--source-only (point-min) (point-max)))))))
  (let ((spec (claude-transcript--link-parse "homun:checks?id=p&choices=a,b&value=b" "P")))
    (should (eq (plist-get spec :type) 'checks))
    (should (equal (plist-get spec :picked) '("b")))))

;;; Claude Code's own records

(defun claude-transcript-tests--user (text)
  "Return a user entry holding TEXT."
  `((type . "user") (message . ((role . "user") (content . ,text)))))

(ert-deftest claude-transcript-tests-tagged-kinds ()
  (let ((kind (lambda (text) (claude-transcript--kind-of (claude-transcript-tests--user text)))))
    (should (eq (funcall kind "<local-command-caveat>x</local-command-caveat>") 'hidden))
    (should (eq (funcall kind "<command-name>/config</command-name><command-args></command-args>") 'tagged))
    (should (eq (funcall kind "<local-command-stdout>ok</local-command-stdout>") 'tagged))
    (should (eq (funcall kind "<future-thing>x</future-thing>") 'tagged))
    (should (eq (funcall kind "Scheduler alarms now arrive as <channel source=\"scheduler\"> events") 'note))
    (should (eq (funcall kind "plain words") 'prompt))
    (should (eq (funcall kind "<b>bold</b> start but more words") 'prompt))))

(ert-deftest claude-transcript-tests-harness-tags ()
  (let ((kind (lambda (text) (claude-transcript--kind-of (claude-transcript-tests--user text)))))
    (should (eq (funcall kind "<system-reminder>\nAttribution for git commits and pull requests you create\n</system-reminder>") 'hidden))
    (should (eq (funcall kind "<system-reminder>\n<total_tokens>15000000 tokens left</total_tokens>\n</system-reminder>") 'hidden))
    (should (eq (funcall kind "<system-reminder>\n<tools-used-before-summary>mcp__plugin_homun_scheduler__channel</tools-used-before-summary>\n</system-reminder>") 'hidden))
    (should (eq (funcall kind "<system-reminder>\nOnly you see that command's output.\n</system-reminder>") 'tagged))
    (should (equal (claude-transcript--reminder-heading
                    "<system-reminder>\nOnly you see that command's output.\nMore.\n</system-reminder>")
                   "⋯ reminder: Only you see that command's output."))
    (should (equal (claude-transcript--reminder-heading
                    (concat "<system-reminder>\n[SYSTEM NOTIFICATION - NOT USER INPUT]\n<task-notification>\n"
                            "<status>completed</status>\n<summary>Agent \"x\" finished</summary>\n"
                            "</task-notification>\n</system-reminder>"))
                   "⋯ task completed: Agent \"x\" finished"))
    (should (equal (claude-transcript--notification-heading
                    "<task-notification>\n<task-id>a</task-id>\n<status>failed</status>\n<summary>boom</summary>\n</task-notification>")
                   "⋯ task failed: boom"))
    (should (equal (claude-transcript--strip-hidden
                    "ran out.\n\n<tools-used-before-summary>Agent, Bash</tools-used-before-summary>\nSummary:\n1")
                   "ran out.\n\nSummary:\n1"))))

(ert-deftest claude-transcript-tests-tagged-headings ()
  (require 'claude-bus)
  (let ((claude-transcript-unrendered-file (make-temp-file "unrendered"))
        (claude-transcript-quick-summary nil)
        (claude-transcript--unrendered-seen nil))
    (cl-letf (((symbol-function 'claude-bus-send) #'ignore)) ; never the live bus
    (should (equal (claude-transcript--tagged-heading
                    "<command-name>/config</command-name><command-message>config</command-message><command-args>a b</command-args>")
                   "⌘ /config a b"))
    (should (equal (claude-transcript--tagged-heading
                    "<local-command-stdout>Set size to \e[1mlarge\e[22m</local-command-stdout>")
                   "⌘ → Set size to large"))
    (should (equal (claude-transcript--tagged-heading "<odd-tag>hello</odd-tag>")
                   "⋯ <odd-tag> (unrendered)"))
    (claude-transcript--tagged-heading "<odd-tag>again</odd-tag>")
    (with-temp-buffer
      (insert-file-contents claude-transcript-unrendered-file)
      (should (= 1 (count-lines (point-min) (point-max)))))))
)

(ert-deftest claude-transcript-card-ends-continuation ()
  "A message after a card has its name row again."
  (with-temp-buffer
    (claude-transcript-mode)
    (let ((inhibit-read-only t) (n 0)
          (claude-transcript--tools (make-hash-table :test (quote equal)))
          (claude-transcript--bodies (make-hash-table :test (quote eq)))
          (claude-transcript--tool-sections (make-hash-table :test (quote equal))))
      (cl-flet ((msg () (claude-transcript--insert-message
                         'claude "Claudia" 'default 'default "10:00" "hello")
                  (cl-incf n)))
        (magit-insert-section (root)
          (msg)
          (claude-transcript--insert-tool
           '((id . "t1") (name . "Bash") (input . ((command . "ls")))))
          (msg)))
      (should (= 2 (with-no-warnings
                     (let ((c 0)) (goto-char (point-min))
                          (while (search-forward "Claudia" nil t) (cl-incf c))
                          c)))))))

(ert-deftest claude-transcript-sticks-with-point-not-at-end ()
  "A window that showed the end follows new text though its point is elsewhere."
  (with-temp-buffer
    (insert "one\ntwo\n")
    (let ((other (split-window)))
      (set-window-buffer other (current-buffer))
      (set-window-point other (point-min))
      (cl-letf (((symbol-function 'homun-layout-tail)
                 (lambda (w) (set-window-point w (point-max)))))
        (claude-transcript--keeping-windows 1 (lambda () (insert "three\n")))
        (should (= (window-point other) (point-max)))
        (set-window-parameter other 'claude-transcript-follow (cons nil 5))
        (set-window-point other (point-min))
        (claude-transcript--keeping-windows 1 (lambda () (insert "four\n")))
        (should (= (window-point other) (point-min)))))))

(ert-deftest claude-transcript-sticks-after-shrink ()
  "A resize with no new text puts a following window back at the end."
  (with-temp-buffer
    (claude-transcript-mode)
    (let ((window (selected-window)) tailed)
      (set-window-buffer window (current-buffer))
      (set-window-parameter window 'claude-transcript-follow (cons t 1))
      (cl-letf (((symbol-function 'homun-layout-tail) (lambda (w) (push w tailed))))
        (claude-transcript--resized (window-frame window))
        (should (equal tailed (list window)))
        (setq tailed nil)
        (set-window-parameter window 'claude-transcript-follow (cons nil 5))
        (claude-transcript--resized (window-frame window))
        (should-not tailed)))))

(ert-deftest claude-transcript-height-change-keeps-follow-state ()
  "A scroll note that only follows a height change keeps the old state."
  (with-temp-buffer
    (claude-transcript-mode)
    (let ((window (selected-window)))
      (set-window-buffer window (current-buffer))
      (set-window-parameter window 'claude-transcript-follow (cons t 1))
      (claude-transcript--note-scroll window 1)
      (should (claude-transcript--following-p window)))))

(defvar touch-screen-delay)

(ert-deftest claude-transcript-tab-tap-has-one-shot-timer ()
  "Tracking a tap with a long-press function does not pass a bad repeat."
  (require 'homun-stage-store)
  (let ((touch-screen-delay 0.7))
    (cl-letf (((symbol-function 'touch-screen-track-tap) (lambda (&rest _) t)))
      (should (homun-stage--track-tap '(touchscreen-begin nil) #'ignore)))))

(ert-deftest claude-transcript-device-of ()
  (should (equal (claude-transcript--device-of "<channel source=\"user\" device=\"phone\" ts=\"1\">hi</channel>") "phone"))
  (should (equal (claude-transcript--device-of "<channel source=\"cal\" ts=\"1\">hi</channel>") "host"))
  (should-not (claude-transcript--device-of "plain"))
  (should (equal (claude-transcript--device-label nil) "You"))
  (should (string-prefix-p "You " (claude-transcript--device-label "tablet"))))

;; Cal saw an hl-line band over the entry at point in the transcript
(ert-deftest claude-transcript-no-hl-line ()
  "A transcript buffer keeps no current-line highlight, global or local."
  (require 'hl-line)
  (let ((was global-hl-line-mode))
    (unwind-protect
        (progn
          (global-hl-line-mode 1)
          (with-temp-buffer
            (insert "one\ntwo\n")
            (claude-transcript-mode)
            (goto-char (point-min))
            (global-hl-line-highlight)
            (should-not (seq-some (lambda (o) (memq (overlay-get o 'face)
                                                    '(hl-line hl-line-nonselected)))
                                  (overlays-in (point-min) (point-max))))
            (should-not hl-line-mode)))
      (global-hl-line-mode (if was 1 -1)))))

(ert-deftest claude-transcript-tests-inline-code-face-and-markers ()
  (let ((text (claude-transcript--fmt-markdown "two `wip/` branches, `x`.")))
    (should (facep 'markdown-inline-code-face))
    (dolist (pos '(4 5 8))
      (should (eq (get-text-property pos 'face text) 'markdown-inline-code-face)))
    (should (eq (get-text-property 4 'invisible text) 'claude-transcript-markup))
    (should (eq (get-text-property 9 'invisible text) 'claude-transcript-markup))
    (should-not (get-text-property 11 'face text))))

(provide 'claude-transcript-tests)

(ert-deftest claude-transcript-tests-spin-runs-on-clock ()
  (require 'widgetry)
  (defvar claude-compose--outbox)
  (let ((homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
        (homun-clock-visible-function (lambda () t))
        (homun-clock-focused-function (lambda () t))
        (claude-compose--outbox (list (list :state 'pending))))
    (unwind-protect
        (progn
          (claude-transcript--spin)
          (should (assq 'claude-transcript-spin homun-clock--clients))
          (should (= 1 (homun-clock-timers)))
          (setq claude-compose--outbox nil)
          (homun-clock-tick)
          (should (= 0 (homun-clock-timers))))
      (homun-clock--stop))))

(ert-deftest claude-transcript-phone-tool-heading-is-one-line ()
  "On the phone a Bash call is its description, else its command, on one line."
  (let ((claude-transcript-phone t))
    (let ((h (claude-transcript--fmt-tool "Bash" '((command . "ls -la /tmp") (description . "List tmp")))))
      (should (string-match-p "List tmp" h))
      (should-not (string-match-p "ls -la" h))
      (should-not (string-search "\n" (string-trim-right h "\n"))))
    (should (string-match-p "ls -la" (claude-transcript--fmt-tool "Bash" '((command . "ls -la")))))))

(ert-deftest claude-transcript-tests-bottom-button ()
  (claude-transcript-tests--with-session
    (save-window-excursion
      (set-window-buffer nil (current-buffer))
      (set-window-parameter nil 'claude-transcript-follow (cons nil 1))
      (should (string-match-p "Bottom" (claude-transcript--bottom-button)))
      (claude-transcript-goto-end)
      (should (car (window-parameter nil 'claude-transcript-follow)))
      (should-not (claude-transcript--bottom-button)))))

(ert-deftest claude-transcript-tests-phone-jump-pill ()
  "On the phone the jump-to-bottom button is a mode-line pill, shown only while not following."
  (claude-transcript-tests--with-session
    (save-window-excursion
      (let ((claude-transcript-phone t))
        (set-window-buffer nil (current-buffer))
        (setq claude-transcript--unseen 2)
        (should (string-match-p "↓ 2 new · end" (claude-transcript--jump-pill)))
        (set-window-parameter nil 'claude-transcript-follow (cons nil 1))
        (claude-transcript--phone-jump (selected-window))
        (should-not (window-parameter nil 'mode-line-format))
        (claude-transcript-goto-end)
        (should (eq (window-parameter nil 'mode-line-format) 'none))
        (should (string-match-p "↓ end" (claude-transcript--jump-pill)))))))

(ert-deftest claude-transcript-tests-queued-blocks ()
  "A message queued mid-turn in headless -p mode (prompt as text blocks) is a prompt with its device."
  (let* ((file (expand-file-name "claude-transcript-queued-fixture.jsonl"
                                 (file-name-directory claude-transcript-tests--fixture)))
         (entry (with-temp-buffer
                  (insert-file-contents file)
                  (json-parse-buffer :object-type 'alist :array-type 'array)))
         (out (claude-transcript--hook-messages entry))
         (text (claude-transcript--text-of (claude-transcript--content-of (car out)))))
    (should (= 1 (length out)))
    (should (eq 'prompt (claude-transcript--kind-of (car out))))
    (should (equal "phone" (claude-transcript--device-of text)))
    (should (equal "oh I did that one" (claude-transcript--unwrap-channel text)))))

(ert-deftest claude-transcript-tests-web-links-clickable ()
  (let* ((text (claude-transcript--fmt-web-links
                "see [the doc](https://a.example/x) and https://b.example/y?q=1, ok `https://c.example`"))
         (at (lambda (re) (string-match re text) (match-beginning 0))))
    (should (equal (get-text-property (funcall at "the doc") 'claude-transcript-url text)
                   "https://a.example/x"))
    (should (equal (get-text-property (funcall at "b.example") 'claude-transcript-url text)
                   "https://b.example/y?q=1"))
    ;; the hidden URL of a markdown link is not linked a second time
    (should-not (get-text-property (funcall at "a.example/x)") 'claude-transcript-url text))
    ;; a quick click is looked up as mouse-2 on `follow-link' text
    (should (eq (lookup-key claude-transcript-link-map [mouse-2]) #'claude-transcript-open-link))
    (should (eq (get-text-property (funcall at "the doc") 'face text) 'claude-transcript-link))))

(ert-deftest claude-transcript-tests-link-last-in-buffer-opens ()
  (let ((opened nil) (text (claude-transcript--fmt-web-links "see\n\nhttps://a.example/x")))
    (with-temp-buffer
      (insert text)
      (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (setq opened u))))
        (goto-char (point-max))
        (claude-transcript-open-link)
        (should (equal opened "https://a.example/x"))
        (setq opened nil)
        (goto-char (- (point-max) 3))
        (claude-transcript-open-link)
        (should (equal opened "https://a.example/x"))
        ;; an event position past this buffer's end is no error, just no link
        (should-not (claude-transcript--url-at
                     (list 'mouse-1 (list (selected-window) (+ 100 (point-max)) '(0 . 0) 0))))))))

(defconst claude-transcript-tests--choice-block
  (concat "```widgetry\n"
          "(choice text \"Text size\" (13 \"13 dp\") (15 \"15 dp\"))\n"
          "(choice tabs \"Navigation\" (tabs \"Tabs\") (swipe \"Swipe only\"))\n"
          "```\n"))

(ert-deftest claude-transcript-tests-choice-one-send ()
  "Choices of one block send together as one set, and the state persists in :chosen."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets claude-transcript-tests--choice-block))
    (claude-transcript-tests--with-widgets
      (let* ((widgets (gethash '("u1" . "block1") claude-transcript--widget-groups))
             (choices (seq-filter (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'choice))
                                  widgets))
             (submit (seq-find (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'submit))
                               widgets)))
        (should (= 2 (length choices)))
        (widget-value-set (car choices) (list (intern "13")))
        (widget-value-set (cadr choices) '(swipe))
        (should (string-prefix-p
                 "[set text=13 tabs=swipe on u1]"
                 (claude-transcript--widget-reply submit (seq-remove #'claude-transcript--button-p widgets))))
        (let ((text (claude-transcript--source-text
                     submit widgets (nth 2 (widget-get (car choices) :claude-source)))))
          (should (string-match-p ":chosen 13" text))
          (should (string-match-p ":chosen swipe" text))
          (should (string-match-p ":done t" text)))))))

(ert-deftest claude-transcript-tests-choice-deselect-sends-unanswered ()
  "A click on the chosen option clears a choice; Send then says it is unanswered."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets claude-transcript-tests--choice-block))
    (claude-transcript-tests--with-widgets
      (let* ((widgets (gethash '("u1" . "block1") claude-transcript--widget-groups))
             (choices (seq-filter (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'choice))
                                  widgets))
             (submit (seq-find (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'submit))
                               widgets)))
        (widgetry-chips--toggle (car choices) 0)
        (should (equal (widget-value (car choices)) (list (intern "13"))))
        (widgetry-chips--toggle (car choices) 0)
        (should (null (widget-value (car choices))))
        (widgetry-chips--toggle (cadr choices) 1)
        (should (string-prefix-p
                 "[set text=unanswered tabs=swipe on u1]"
                 (claude-transcript--widget-reply submit (seq-remove #'claude-transcript--button-p widgets))))
        (let ((text (claude-transcript--source-text
                     submit widgets (nth 2 (widget-get (car choices) :claude-source)))))
          (should-not (string-match-p ":chosen 13" text))
          (should (string-match-p ":chosen swipe" text)))))))

(ert-deftest claude-transcript-tests-choice-chosen-renders ()
  "A :chosen option is shown lit when the block is drawn."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry\n(choice a \"A\" :chosen y (x \"X\") (y \"Y\"))\n```\n"))
    (claude-transcript-tests--with-widgets
      (let ((w (seq-find (lambda (w) (eq (plist-get (widget-get w :claude-spec) :type) 'choice))
                         (gethash '("u1" . "block1") claude-transcript--widget-groups))))
        (should (equal '(y) (widget-value w)))))))

(ert-deftest claude-transcript-tests-unknown-element-visible ()
  "An unknown element in a block is shown as a warning, never dropped."
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets
         "```widgetry\n(bogus z \"Z\")\n(form (nope q \"Q\") (toggle t \"T\"))\n```\n"))
    (claude-transcript-tests--with-widgets
      (should (string-match-p "unknown widgetry element: (bogus z \"Z\")" (buffer-string)))
      (should (string-match-p "unknown widgetry element: (nope q \"Q\")" (buffer-string))))))

(ert-deftest claude-transcript-unknown-element-logged-once ()
  (let ((claude-transcript--unknown-logged nil) (logs 0))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _) (setq logs (1+ logs)))))
      (dotimes (_ 3) (claude-transcript--unknown-row '(checks)))
      (claude-transcript--unknown-row '(bogus)))
    (should (= logs 2))))

(ert-deftest claude-transcript-tests-compact-tick-runs-on-clock ()
  (let ((homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
        (homun-clock-visible-function (lambda () t))
        (homun-clock-focused-function (lambda () t)))
    (unwind-protect
        (with-temp-buffer
          (claude-transcript-mode)
          (should (assq 'claude-transcript-compact homun-clock--clients))
          (should (claude-transcript--compact-tick))
          (kill-buffer (current-buffer))
          (should-not (claude-transcript--compact-tick)))
      (homun-clock--stop))))

(ert-deftest claude-transcript-tests-imenu-and-outline ()
  (claude-transcript-tests--with-session
    (let ((index (claude-transcript-imenu-index)))
      (should index)
      (should (cl-every (lambda (e) (string-match-p "\\`[^:]+: " (car e))) index))
      (should (cl-some (lambda (e) (string-prefix-p "You: " (car e))) index))
      (should (apply #'< (mapcar #'cdr index)))
      (should (eq imenu-create-index-function #'claude-transcript-imenu-index))
      ;; outline headings are the same message starts
      (goto-char (point-min))
      (should (funcall outline-search-function nil t))
      (should (memq (line-beginning-position) (mapcar #'cdr index))))))

;;;; Row layout on narrow and wide windows

(defconst claude-transcript-tests--row-block
  (concat "```widgetry\n"
          "(choice mode \"Mode\" (a \"Alpha\") (b \"Bravo\") (c \"Charlie\") (d \"Delta\") (e \"Echo\"))\n"
          "(buttons (now \"Now\") (later \"Later\") (never \"Never\") (maybe \"Maybe so\") (soon \"Quite soon\"))\n"
          "```\n"))

(defun claude-transcript-tests--row-lines (width)
  "The drawn lines of the choice and buttons block in a window WIDTH columns wide."
  (let ((claude-transcript-tests--widgets claude-transcript-tests--row-block))
    (cl-letf (((symbol-function 'claude-transcript--row-width) (lambda () width)))
      (claude-transcript-tests--with-widgets
        (seq-filter
         (lambda (line) (string-match-p "\\`[^(]*\\(Mode\\|Alpha\\|Echo\\|Now\\|Later\\|Never\\|Maybe\\|soon\\)" line))
         (mapcar (lambda (line) (string-remove-prefix "```" line))
                 (cdddr (split-string (buffer-substring-no-properties (point-min) (point-max))
                                      "\n"))))))))

(ert-deftest claude-transcript-tests-rows-narrow-stack-and-wrap ()
  (skip-unless (featurep 'widgetry))
  (let* ((lines (claude-transcript-tests--row-lines 40))
         (pills (cdr (member "Mode" lines))))
    ;; The label alone on its line, then pills, none with anything left of them
    (should (member "Mode" lines))
    (should pills)
    (should (seq-every-p (lambda (l) (string-match-p "\\` ?[A-Z]" l)) pills))
    (should (seq-every-p (lambda (l) (<= (string-width l) 40)) lines))
    ;; The five buttons do not fit one line: they wrap
    (should (> (length (seq-filter (lambda (l) (string-match-p "Now\\|Later\\|Never\\|Maybe\\|soon" l))
                                   lines))
               1))))

(ert-deftest claude-transcript-tests-rows-wide-keep-label-and-pills-on-one-line ()
  (skip-unless (featurep 'widgetry))
  (let ((lines (claude-transcript-tests--row-lines 120)))
    (should (seq-some (lambda (l) (string-match-p "Mode +.*Alpha.*Echo" l)) lines))
    (should (seq-some (lambda (l) (string-match-p "Now.*Later.*Never.*soon" l)) lines))))

(ert-deftest claude-transcript-tests-wrapped-choice-stays-one-choice ()
  (skip-unless (featurep 'widgetry))
  (let ((claude-transcript-tests--widgets claude-transcript-tests--row-block))
    (cl-letf (((symbol-function 'claude-transcript--row-width) (lambda () 24)))
      (claude-transcript-tests--with-widgets
        (let* ((leader (seq-find (lambda (w) (eq (widget-type w) 'widgetry-chips))
                                 (gethash '("u1" . "block1") claude-transcript--widget-groups)))
               (follower (car (widget-get leader :siblings))))
          (should follower)
          (widgetry-chips--toggle leader 0)
          (should (equal (widget-value leader) '(a)))
          (widgetry-chips--toggle follower 0)
          (should (= 1 (length (widget-value leader))))
          (should-not (eq (car (widget-value leader)) 'a))
          (should (equal (widget-value follower) (widget-value leader))))))))

(ert-deftest claude-transcript-tests-outbox-spinner-end-to-end ()
  "A message being sent shows a turning spinner in the transcript; delivery clears it."
  (require 'widgetry)
  (require 'claude-compose)
  (let ((homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
        (homun-clock-visible-function (lambda () t))
        (homun-clock-focused-function (lambda () t))
        (claude-compose--outbox (list (list :id "1" :text "hello" :state 'sending :time 0.0)))
        (buffer (generate-new-buffer " *spin-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-compose--main-file-p) (lambda (_) t)))
          (with-current-buffer buffer
            (claude-transcript-mode)
            (setq claude-transcript--file "/tmp/x.jsonl"))
          (save-window-excursion
            (switch-to-buffer buffer)
            (claude-transcript--outbox-redraw)
            (with-current-buffer buffer
              (should (text-property-any (point-min) (point-max) 'claude-transcript-pending t)))
            (should (= 1 (homun-clock-timers)))
            (homun-clock-tick)
            (with-current-buffer buffer
              (let ((pos (text-property-any (point-min) (point-max) 'claude-transcript-pending t)))
                (should pos)
                (should (get-text-property pos 'display))))
            ;; Delivery: the message leaves the outbox, the tick and the clock stop
            (setq claude-compose--outbox nil)
            (claude-transcript--outbox-redraw)
            (with-current-buffer buffer
              (should-not (text-property-any (point-min) (point-max) 'claude-transcript-pending t)))
            (homun-clock-tick)
            (should-not (claude-transcript--spin-tick))))
      (homun-clock--stop)
      (kill-buffer buffer))))

(ert-deftest claude-transcript-tests-queued-survives-rebuild ()
  "A message queued while the manager is busy (compacting) shows as pending in the
transcript, and a rebuild of the buffer draws it again until it is delivered."
  (require 'claude-compose)
  (let ((claude-compose--outbox (list (list :id "q1" :text "queued hello" :state 'pending
                                            :time 0.0)))
        (file (make-temp-file "transcript" nil ".jsonl" ""))
        (buffer (generate-new-buffer " *queued-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-compose--main-file-p) (lambda (_) t)))
          (with-current-buffer buffer
            (claude-transcript-mode)
            (setq claude-transcript--file file)
            (claude-transcript--outbox-draw)
            (should (string-match-p "queued hello" (buffer-string)))
            ;; The compaction's rebuild starts from an empty buffer
            (claude-transcript--render 10)
            (should (string-match-p "queued hello" (buffer-string)))
            (should (text-property-any (point-min) (point-max) 'claude-transcript-pending t))
            (setq claude-compose--outbox nil)
            (claude-transcript--outbox-draw)
            (should-not (string-match-p "queued hello" (buffer-string)))))
      (kill-buffer buffer)
      (delete-file file))))

(defun claude-transcript-tests--direct (error)
  "Run a direct send ending in ERROR with timers captured; return (ITEM-STATES TIMERS OUTBOX)."
  (require 'claude-compose)
  (let ((claude-compose--outbox nil) done timers states
        (claude-compose-outbox-functions nil))
    (cl-letf (((symbol-function 'claude-compose--manager-p) (lambda () t))
              ((symbol-function 'run-at-time)
               (lambda (delay _r fn &rest _) (push (cons delay fn) timers) nil))
              ((symbol-function 'claude-agent-stream-send)
               (lambda (_dir _msg cb) (setq done cb))))
      (with-temp-buffer
        (claude-compose--send-direct "hi" "/tmp/stream")
        (push (plist-get (car claude-compose--outbox) :state) states)
        (funcall done error)
        ;; Delivered at once: still sending, the end is timed
        (push (plist-get (car claude-compose--outbox) :state) states)
        ;; (the outbox's own redraw timers have no delay)
        (setq timers (seq-filter (lambda (tm) (and (numberp (car tm)) (> (car tm) 0)))
                                 (nreverse timers)))
        (let ((first (pop timers)))
          (should (<= 0.5 (car first) 0.6))
          (funcall (cdr first)))
        (push (plist-get (car claude-compose--outbox) :state) states)
        (list (nreverse states)
              (seq-filter (lambda (tm) (and (numberp (car tm)) (> (car tm) 0))) timers)
              claude-compose--outbox)))))

(ert-deftest claude-transcript-tests-direct-send-spins-then-ticks ()
  "A direct send is sending for the minimum time, then sent with a timed exit."
  (pcase-let ((`(,states ,timers ,outbox) (claude-transcript-tests--direct nil)))
    (should (equal states '(sending sending sent)))
    (should (= 1 (length timers)))
    (should (= 1.0 (car (car timers))))
    ;; the tick is drawn from the state alone
    (should (string= "✓" (claude-transcript--tick (plist-get (car outbox) :state))))
    (should (= 1 (length outbox)))))

(ert-deftest claude-transcript-tests-direct-send-failure-stays ()
  "A refused direct send is failed with its error and a retry button, not dropped."
  (pcase-let ((`(,states ,_timers ,outbox) (claude-transcript-tests--direct "refused")))
    (should (equal states '(sending sending failed)))
    (should (equal (plist-get (car outbox) :error) "refused"))
    (let ((text (claude-transcript--outbox-string outbox)))
      (should (string-match-p "refused" text))
      (let ((pos (string-match "retry" text)))
        (should (eq (get-text-property pos 'keymap text) claude-transcript--retry-map))))))

(ert-deftest claude-transcript-tests-seen-waits-for-tick ()
  "A message logged while its mark shows is drawn from the outbox once: the outbox block
drops it, the logged line carries the mark, renewed from the item's state."
  (require 'claude-compose)
  (let* ((claude-compose-outbox-functions nil)
         (item (list :id "1" :text "hi" :state 'sending :time 0.0 :hold (+ (float-time) 5)))
         (claude-compose--outbox (list item)))
    (should (claude-compose-seen "hi"))
    (should (plist-get item :seen))
    (should-not (claude-compose-seen "hi"))     ; not matched twice
    (should (get-text-property 0 'claude-transcript-pending (claude-transcript--logged-tick "hi")))
    (plist-put item :state 'sent)
    (should (equal "✓" (substring-no-properties (claude-transcript--logged-tick "hi"))))
    ;; the logged line is renewed in place
    (with-temp-buffer
      (insert "x ")
      (claude-transcript--noting-marks (insert (claude-transcript--logged-tick "hi") "\n"))
      (plist-put item :state 'sent)
      (setq claude-compose--outbox nil)
      (claude-transcript--marks-draw)
      (should (equal "x ✓✓\n" (substring-no-properties (buffer-string))))
      (should-not claude-transcript--marks))))

(ert-deftest claude-transcript-tests-marks-tracked-not-scanned ()
  "Only ticks noted at insert are redrawn; an unchanged tick is left alone; a tick whose
item left the outbox is drawn once more and dropped from the list."
  (require 'claude-compose)
  (let* ((item (list :id "1" :text "hi" :state 'sent :time 0.0 :seen t))
         (claude-compose--outbox (list item)))
    (with-temp-buffer
      (claude-transcript--noting-marks (insert "a " (claude-transcript--logged-tick "hi") "\n"))
      ;; A mark not noted (as a scan would find it) stays as it is
      (insert "b " (propertize "?" 'claude-transcript-mark "hi") "\n")
      (should (= 1 (length claude-transcript--marks)))
      (let ((tick (car claude-transcript--marks)) (changes 0))
        (add-hook 'after-change-functions (lambda (&rest _) (cl-incf changes)) nil t)
        (claude-transcript--marks-draw)
        (should (= 0 changes))                    ; same state: nothing rewritten
        (should (eq tick (car claude-transcript--marks))))
      (setq claude-compose--outbox nil)
      (claude-transcript--marks-draw)
      (should (equal "a ✓✓\nb ?\n" (substring-no-properties (buffer-string))))
      (should-not claude-transcript--marks))))

(ert-deftest claude-transcript-tests-assistant-links-clickable-in-buffer ()
  "A bare URL and a Markdown link in a drawn assistant message open with mouse-1 and RET."
  (let ((claude-transcript-channel-log "/nonexistent")
        (claude-transcript--widget-states (make-hash-table :test #'equal))
        (opened nil))
    (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url opened))))
      (with-temp-buffer
        (claude-transcript-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (let ((inhibit-read-only t))
          (magit-insert-section (claude-transcript-text "u1/0")
           (claude-transcript--insert-message
           'claude "Claude" 'bold 'bold "now"
           "PR:\n\nhttps://github.com/x/y/pull/224\n\nsee [the doc](https://a.example/doc) ok\n")))
        (dolist (case '(("github.com/x/y" . "https://github.com/x/y/pull/224")
                        ("the doc" . "https://a.example/doc")))
          (goto-char (point-min))
          (search-forward (car case))
          (let ((pos (match-beginning 0)))
            (goto-char pos)
            (should (equal (get-char-property pos 'claude-transcript-url) (cdr case)))
            (dolist (key (list (kbd "RET") [mouse-1]))
              (setq opened nil)
              (let ((command (lookup-key (get-char-property pos 'keymap) key)))
                (should (commandp command))
                (let ((last-nonmenu-event
                       (if (eq (aref key 0) 'mouse-1)
                           (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0))
                         key)))
                  (call-interactively command)))
              (should (equal opened (list (cdr case)))))))))))

(ert-deftest claude-transcript-copy-block-rendered ()
  "C-c C-w copies the rendered block at point or above, bare, past stray fences."
  (with-temp-buffer
    (insert "a ``` stray\n" (claude-transcript--fmt-markdown
                            "Hi\n```nu\nls | first 1\n```\nmid\n```sh\necho 2\n```\nend"))
    (goto-char (point-min))
    (search-forward "ls |")
    (claude-transcript-copy-block)
    (should (equal (car kill-ring) "ls | first 1"))
    (search-forward "mid")
    (claude-transcript-copy-block)
    (should (equal (car kill-ring) "ls | first 1"))
    (search-forward "echo")
    (claude-transcript-copy-block)
    (should (equal (car kill-ring) "echo 2"))
    (goto-char (point-min))
    (should-error (claude-transcript-copy-block) :type 'user-error)))

(ert-deftest claude-transcript-tests-compact-running-ends-on-new-record ()
  "A running status ends when the main transcript gets a non-compaction record."
  (let* ((dir (make-temp-file "compact" t))
         (main (expand-file-name "m.jsonl" dir))
         (status (expand-file-name "status" dir))
         (since (- (float-time) 30))
         (stamp (lambda (d) (format-time-string "%FT%T.000Z" (+ since d) t))))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-compose--main-file) (lambda () main))
                  (claude-transcript--compact-file status))
          (with-temp-file status
            (insert (format "{\"state\":\"running\",\"since\":%f}" since)))
          (with-temp-file main
            (insert (format "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"%s\"}\n"
                            (funcall stamp 1))))
          (should (string-match-p "Compacting" (claude-transcript--compact-status)))
          (with-temp-file main
            (insert (format "{\"type\":\"user\",\"timestamp\":\"%s\",\"message\":{\"content\":\"Compaction canceled\"}}\n"
                            (funcall stamp 5))))
          (should-not (claude-transcript--compact-status)))
      (delete-directory dir t))))
