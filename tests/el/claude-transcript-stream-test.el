;;; claude-transcript-stream-test.el --- ERT for claude-transcript-stream.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'claude-transcript)
(require 'homun-stage-agent)

(defconst claude-transcript-stream-tests--fixture
  (expand-file-name "claude-transcript-fixture.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun claude-transcript-stream-tests--delta (text)
  `((type . "stream_event")
    (event . ((type . "content_block_delta") (delta . ((type . "text_delta") (text . ,text)))))))

(defmacro claude-transcript-stream-tests--with (&rest body)
  "BODY with a fresh block state and a main transcript buffer of a copy of the fixture."
  (declare (indent defun))
  `(let* ((dir (make-temp-file "claude-transcript-stream" t))
          (file (expand-file-name "session.jsonl" dir))
          (claude-transcript-projects-directory dir)
          (claude-transcript-stream--text "") (claude-transcript-stream--state 'idle)
          (claude-transcript-stream--drawn t) (claude-transcript-stream--drawn-at 0)
          (claude-transcript-stream-unhandled 0)
          (claude-transcript-stream--run (list :log (expand-file-name "unhandled.jsonl" dir)))
          (claude-transcript-stream-dir dir)
          (homun-clock--clients nil) (homun-clock--periods nil))
     (copy-file claude-transcript-stream-tests--fixture file)
     (cl-letf (((symbol-function 'claude-transcript--main-buffer-p) #'always)
               ((symbol-function 'homun-clock-register) #'ignore))
       (with-temp-buffer
         (claude-transcript-mode)
         (setq claude-transcript--file file)
         (claude-transcript--render claude-transcript-tail-turns)
         (unwind-protect (progn ,@body)
           (delete-directory dir t))))))

(defun claude-transcript-stream-tests--shown ()
  (when-let* ((start (text-property-any (point-min) (point-max) 'claude-transcript-streaming t)))
    (buffer-substring-no-properties
     start (or (next-single-property-change start 'claude-transcript-streaming) (point-max)))))

(ert-deftest claude-transcript-stream-erase-by-markers ()
  "The entry is erased by its own markers: text marked streaming elsewhere stays."
  (claude-transcript-stream-tests--with
    (let ((inhibit-read-only t))
      (save-excursion (goto-char (point-min))
                      (insert (propertize "stray\n" 'claude-transcript-streaming t))))
    (claude-transcript-stream-fold (list (claude-transcript-stream-tests--delta "Hi there")))
    (claude-transcript-stream-tick)
    (should (string-match-p "Hi there" (buffer-string)))
    (claude-transcript-stream-clear)
    (setq claude-transcript-stream--drawn-at 0)
    (claude-transcript-stream-tick)
    (should-not (string-match-p "Hi there" (buffer-string)))
    (should (string-match-p "stray" (buffer-string)))
    (should-not claude-transcript-stream--span)))

(ert-deftest claude-transcript-stream-code-fontified-once ()
  "A redraw fontifies only the code block that changed; the finished entry reuses them."
  (claude-transcript-stream-tests--with
    (clrhash claude-transcript-stream--memo)
    (let ((calls 0) (fontify (symbol-function 'claude-transcript--fontify)))
      (cl-letf (((symbol-function 'claude-transcript--fontify)
                 (lambda (&rest args) (cl-incf calls) (apply fontify args))))
        (claude-transcript-stream-fold
         (list (claude-transcript-stream-tests--delta "A\n\n```sh\necho a\n```\n\nB\n")))
        (dotimes (i 5)
          (claude-transcript-stream-fold
           (list (claude-transcript-stream-tests--delta (format "more %d\n" i))))
          (setq claude-transcript-stream--drawn-at 0)
          (claude-transcript-stream-tick))
        (should (= 1 calls))))))

(ert-deftest claude-transcript-stream-text-bounded ()
  "The kept block stays within twice the shown characters, its newest text whole."
  (let ((claude-transcript-stream-chars 10) (text ""))
    (dotimes (_ 50) (setq text (claude-transcript-stream--grow text "abc")))
    (should (<= (length text) 20))
    (should (string-suffix-p "abc" text))))

(ert-deftest claude-transcript-stream-grows-and-coalesces ()
  "Deltas grow one entry; a redraw waits for the interval."
  (claude-transcript-stream-tests--with
    (claude-transcript-stream-fold (list '((type . "stream_event") (event . ((type . "message_start"))))
                                         (claude-transcript-stream-tests--delta "Hel")))
    (claude-transcript-stream-tick)
    (should (string-match-p "Hel" (claude-transcript-stream-tests--shown)))
    (claude-transcript-stream-fold (list (claude-transcript-stream-tests--delta "lo")))
    (claude-transcript-stream-tick)            ; inside the interval: not yet
    (should-not (string-match-p "Hello" (claude-transcript-stream-tests--shown)))
    (setq claude-transcript-stream--drawn-at 0)
    (claude-transcript-stream-tick)
    (should (string-match-p "Hello" (claude-transcript-stream-tests--shown)))
    (should (string-match-p (regexp-quote claude-agent-name) (claude-transcript-stream-tests--shown)))))

(ert-deftest claude-transcript-stream-replaced-by-final ()
  "`assistant' finishes the block; the next finished entry replaces it."
  (claude-transcript-stream-tests--with
    (claude-transcript-stream-fold (list (claude-transcript-stream-tests--delta "Hi")))
    (claude-transcript-stream-tick)
    (claude-transcript-stream-fold '(((type . "assistant") (message . ((content . "Hi"))))))
    (should (eq claude-transcript-stream--state 'done))
    (claude-transcript-stream-landed)
    (setq claude-transcript-stream--drawn-at 0)
    (claude-transcript-stream-tick)
    (should-not (claude-transcript-stream-tests--shown))))

(ert-deftest claude-transcript-stream-interrupt-and-restart ()
  "A result (an interrupt ends in one) and a new session's init drop the block."
  (dolist (end '(((type . "result") (subtype . "error_during_execution"))
                 ((type . "system") (subtype . "init"))))
    (claude-transcript-stream-tests--with
      (claude-transcript-stream-fold (list (claude-transcript-stream-tests--delta "half")))
      (claude-transcript-stream-fold (list end))
      (setq claude-transcript-stream--drawn-at 0)
      (claude-transcript-stream-tick)
      (should (eq claude-transcript-stream--state 'idle))
      (should-not (claude-transcript-stream-tests--shown)))))

(ert-deftest claude-transcript-stream-unknown-event-logged ()
  "An unknown stream event is counted and kept in unhandled.jsonl."
  (claude-transcript-stream-tests--with
    (claude-transcript-stream-fold '(((type . "stream_event") (event . ((type . "brand_new"))))))
    (should (= 1 claude-transcript-stream-unhandled))
    (should (file-exists-p (expand-file-name "unhandled.jsonl" dir)))))

(ert-deftest claude-transcript-stream-follows-file ()
  "The desktop feed starts at the unfinished turn and reads what the file gains."
  (claude-transcript-stream-tests--with
    (let ((stream (expand-file-name "stream.jsonl" dir))
          (old (concat (json-encode (claude-transcript-stream-tests--delta "old")) "\n"
                       "{\"type\":\"result\"}\n")))
      (write-region old nil stream)
      (write-region (format "%d\n" (length old)) nil (expand-file-name "turns" dir))
      (write-region (concat (json-encode (claude-transcript-stream-tests--delta "new")) "\n")
                    nil stream t)
      (cl-letf (((symbol-function 'file-notify-add-watch) (lambda (&rest _) 'w)))
        (let (claude-transcript-stream--watch claude-transcript-stream--offset)
          (claude-transcript-stream-follow)
          (should (equal claude-transcript-stream--text "new")))))))

(ert-deftest claude-transcript-stream-phone-record ()
  "The gateway's live record sets the block."
  (claude-transcript-stream-tests--with
    (claude-transcript-stream-set '(:text "abc" :state "streaming" :at 1.0))
    (claude-transcript-stream-tick)
    (should (string-match-p "abc" (claude-transcript-stream-tests--shown)))
    (claude-transcript-stream-set '(:text "" :state "idle"))
    (setq claude-transcript-stream--drawn-at 0)
    (claude-transcript-stream-tick)
    (should-not (claude-transcript-stream-tests--shown))))

(defun claude-transcript-stream-tests--props (text)
  "TEXT of the one assistant entry at the end of the buffer, with its text properties."
  (let ((start (save-excursion (goto-char (point-max))
                               (search-backward claude-agent-name nil t)
                               (line-beginning-position))))
    (ignore text)
    (let ((s (buffer-substring start (point-max))))
      (remove-text-properties 0 (length s) '(claude-transcript-streaming nil read-only nil
                                             magit-section nil keymap nil) s)
      (let ((out nil) (i 0))
        (while (< i (length s))
          (push (list (aref s i) (get-text-property i 'face s) (get-text-property i 'line-prefix s)) out)
          (setq i (1+ i)))
        (nreverse out)))))

(ert-deftest claude-transcript-stream-first-delta-styled-as-final ()
  "From the first delta the entry has the name row and faces the finished message has."
  (claude-transcript-stream-tests--with
    (claude-transcript-stream-fold (list (claude-transcript-stream-tests--delta "Hello **bold** world")))
    (claude-transcript-stream-tick)
    (let ((live (claude-transcript-stream-tests--props "Hello **bold** world"))
          (shown (claude-transcript-stream-tests--shown)))
      (should (string-match-p (regexp-quote claude-agent-name) shown))
      (should-not (string-match-p "streaming" shown))
      (claude-transcript-stream-fold '(((type . "assistant"))))
      (claude-transcript--insert-entries
       (list `((type . "assistant") (uuid . "u1")
               (timestamp . ,(format-time-string "%FT%TZ" nil t))
               (message . ((content . [((type . "text") (text . "Hello **bold** world"))]))))))
      (should-not (claude-transcript-stream-tests--shown))
      (let ((final (claude-transcript-stream-tests--props "Hello **bold** world")))
        (should (equal (mapcar #'car live) (mapcar #'car final)))
        (should (equal (mapcar #'cadr live) (mapcar #'cadr final)))))))
