;;; homun-stage-agent-test.el --- The agent preset: a subagent stream live on the Stage -*- lexical-binding: t -*-

(require 'ert)
(require 'homun-stage-agent)

(defconst homun-stage-agent-test--fixture
  (expand-file-name "agent-fixture.jsonl" (file-name-directory (or load-file-name buffer-file-name))))

(defmacro homun-stage-agent-test--with (&rest body)
  `(let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-stage-bindings (make-hash-table :test #'equal))
          (homun-stage-bind--times (make-hash-table :test #'equal))
          (homun-stage-bind--born (make-hash-table :test #'equal))
          (homun-stage-bind--dirty nil) (homun-stage-stale nil)
          (homun-stage-bind--no-timer t)
          (homun-stage-agent--runs (make-hash-table :test #'equal))
          (homun-clock--clients nil))
     (cl-letf (((symbol-function 'homun-clock-dirty) #'ignore))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (string-prefix-p "*stage " (buffer-name b)) (kill-buffer b)))
         (delete-directory homun-stage-dir t)))))

(defun homun-stage-agent-test--face-at (text)
  (let ((pos (string-search text (buffer-string))))
    (get-text-property pos 'face (buffer-string))))

(ert-deftest homun-stage-agent-live-stream ()
  (homun-stage-agent-test--with
   (let* ((id (homun-stage-agent-open homun-stage-agent-test--fixture))
          (steps (gethash (format "agent.%s.steps" id) homun-stage-bindings)))
     (should (gethash id homun-stage-scenes))
     (should (string-search "Fix the widget" (gethash (format "agent.%s.head" id) homun-stage-bindings)))
     (should (string-search "» Looking at the widget first." steps))
     (should-not (string-search "Second line" steps))
     (should (string-search "$ " steps))
     (should (eq (let ((s steps)) (get-text-property (string-search "+(defun w () t)" s) 'face s))
                 'diff-added))
     (should (eq (let ((s steps)) (get-text-property (string-search "-(defun w ())" s) 'face s))
                 'diff-removed))
     ;; the bound scene draws it
     (homun-stage-bind--frame nil)
     (with-current-buffer (homun-stage-buffer-name id)
       (should (string-search "» Looking at the widget first." (buffer-string)))))))

(defconst homun-stage-agent-test--stream
  (expand-file-name "../fixtures/stream/events.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest homun-stage-agent-every-stream-event-is-handled ()
  (homun-stage-agent-test--with
   (let* ((log (expand-file-name "unhandled.jsonl" homun-stage-dir))
          (id (homun-stage-agent--open "session-test" "Test" homun-stage-agent-test--stream 0 1 log))
          (head (gethash (format "agent.%s.head" id) homun-stage-bindings))
          (steps (gethash (format "agent.%s.steps" id) homun-stage-bindings)))
     (dolist (want '("session claude-test · /work" "∴ Pondering widgets." "» Looking now."
                     "⇢ researcher: Probe" "⇠ Probe completed · 512 tok" "denied Bash: [Destructive]"
                     "rate limit five_hour: allowed_warning" "done · $0.0123 · 2.5 s · 40 out"
                     "fresh session (role-recycle)" "session process exited (0)" "title Tester"))
       (should (string-search want steps)))
     (should-not (string-search "subagent words" steps))
     (should (string-search "5h 83% 7d 40%" head))
     (should (string-search "2 unhandled" head))
     (let ((kept (with-temp-buffer
                   (insert-file-contents log)
                   (mapcar (lambda (l) (json-parse-string l :object-type 'alist))
                           (split-string (buffer-string) "\n" t)))))
       (should (equal '("system" "unparsed") (mapcar (lambda (k) (alist-get 'type k)) kept)))
       (should (equal "brand_new_thing" (alist-get 'subtype (car kept))))))))

(ert-deftest homun-stage-agent-grows-with-the-transcript ()
  (homun-stage-agent-test--with
   (let* ((file (make-temp-file "agent-" nil ".jsonl"))
          (id (progn (write-region "{\"type\":\"user\",\"message\":{\"content\":\"Go\"}}\n" nil file)
                     (homun-stage-agent-open file)))
          (topic (format "agent.%s.steps" id)))
     (should (equal "" (gethash topic homun-stage-bindings)))
     (write-region (concat "{\"type\":\"assistant\",\"message\":{\"content\":"
                           "[{\"type\":\"text\",\"text\":\"Now\"}]}}\n")
                   nil file t)
     (should (homun-stage-agent--poll id))
     (should (string-search "» Now" (gethash topic homun-stage-bindings)))
     (delete-file file))))

(ert-deftest homun-stage-agent-live-tool-use ()
  "A tool_use block being streamed shows its name and the input so far."
  (let* ((run (list :live ""))
        (ev (lambda (e) (homun-stage-agent--delta run (json-parse-string e :object-type 'alist)))))
    (funcall ev "{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"name\":\"Read\"}}")
    (funcall ev "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file\"}}")
    (should (string-match-p "Read" (plist-get run :live)))
    (should (string-match-p "{\"file" (plist-get run :live)))))
