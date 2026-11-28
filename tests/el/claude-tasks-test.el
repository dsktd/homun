;;; claude-tasks-test.el --- ERT for the background task reader -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-tasks-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-tasks)

(defconst claude-tasks-test--lines
  (list
   ;; A shell command asked into the background, and its start
   "{\"type\":\"assistant\",\"timestamp\":\"2026-11-23T10:00:00Z\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"sleep 300\",\"description\":\"Wait a while\",\"run_in_background\":true}}]}}"
   "{\"type\":\"user\",\"timestamp\":\"2026-11-23T10:00:01Z\",\"message\":{\"content\":[{\"tool_use_id\":\"t1\",\"type\":\"tool_result\",\"content\":\"started\"}]},\"toolUseResult\":{\"backgroundTaskId\":\"b111\"}}"
   ;; Two agents
   "{\"type\":\"user\",\"timestamp\":\"2026-11-23T10:00:02Z\",\"message\":{\"content\":[{\"tool_use_id\":\"t2\",\"type\":\"tool_result\",\"content\":\"x\"}]},\"toolUseResult\":{\"status\":\"async_launched\",\"agentId\":\"a222\",\"description\":\"Dig\",\"resolvedModel\":\"m\"}}"
   "{\"type\":\"user\",\"timestamp\":\"2026-11-23T10:00:03Z\",\"message\":{\"content\":[{\"tool_use_id\":\"t3\",\"type\":\"tool_result\",\"content\":\"x\"}]},\"toolUseResult\":{\"status\":\"async_launched\",\"agentId\":\"a333\",\"description\":\"Sweep\"}}"
   ;; One ends between turns
   "{\"type\":\"user\",\"timestamp\":\"2026-11-23T10:05:00Z\",\"origin\":{\"kind\":\"task-notification\"},\"message\":{\"content\":\"<task-notification>\\n<task-id>a222</task-id>\\n<status>completed</status>\\n<summary>done</summary>\\n</task-notification>\"}}")
  "A session with a shell job and two agents, one of them finished.")

(defmacro claude-tasks-test--with (&rest body)
  "Run BODY with `file' a transcript of the test lines and no session records."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "claude-tasks" t))
          (file (expand-file-name "s1.jsonl" dir))
          (claude-tasks-sessions-dir (expand-file-name "sessions/" dir))
          (claude-tasks--background (make-hash-table :test #'equal))
          (claude-tasks--background-recent (make-hash-table :test #'equal)))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert (string-join claude-tasks-test--lines "\n") "\n"))
           ,@body)
       (delete-directory dir t))))

(defun claude-tasks-test--status (tasks id)
  (plist-get (seq-find (lambda (task) (equal (plist-get task :id) id)) tasks) :status))

(ert-deftest claude-tasks-background-reads-starts-and-ends ()
  (claude-tasks-test--with
    (let* ((tasks (claude-tasks--background file))
           (shell (car tasks)))
      (should (equal (mapcar (lambda (task) (plist-get task :id)) tasks) '("b111" "a222" "a333")))
      (should (eq (plist-get shell :kind) 'shell))
      (should (equal (plist-get shell :desc) "Wait a while"))
      (should (equal (plist-get shell :command) "sleep 300"))
      (should (equal (plist-get shell :session) "s1"))
      (should (eq (claude-tasks-test--status tasks "b111") 'running))
      (should (eq (claude-tasks-test--status tasks "a222") 'done))
      (should (eq (claude-tasks-test--status tasks "a333") 'running)))))

(ert-deftest claude-tasks-background-reads-only-what-is-new ()
  (claude-tasks-test--with
    (claude-tasks--background file)
    (let ((offset (car (gethash file claude-tasks--background))))
      (should (= offset (file-attribute-size (file-attributes file))))
      ;; A notification that arrives during a turn is a queued command; half a line waits
      (write-region (concat "{\"type\":\"attachment\",\"timestamp\":\"2026-11-23T10:06:00Z\",\"attachment\":{\"type\":\"queued_command\",\"prompt\":\"<task-notification>\\n<task-id>b111</task-id>\\n<status>killed</status>\\n</task-notification>\"}}\n"
                            "{\"type\":\"user\",\"origin\":{\"kind\":\"task-notification\"},\"mess")
                    nil file t 'silent)
      (clrhash claude-tasks--background-recent)
      (let ((tasks (claude-tasks--background file)))
        (should (eq (claude-tasks-test--status tasks "b111") 'stopped))
        (should (eq (claude-tasks-test--status tasks "a333") 'running))
        (should (< offset (car (gethash file claude-tasks--background))
                   (file-attribute-size (file-attributes file))))))))

(ert-deftest claude-tasks-background-before-a-restart-is-stopped ()
  (claude-tasks-test--with
    (make-directory claude-tasks-sessions-dir t)
    (with-temp-file (expand-file-name "7.json" claude-tasks-sessions-dir)
      (insert (format "{\"pid\":7,\"sessionId\":\"s1\",\"startedAt\":%d}"
                      (* 1000 (floor (float-time (date-to-time "2026-11-23T10:00:02.500Z")))))))
    (let ((tasks (claude-tasks--background file)))
      ;; Started before the process: gone with the old one; after it: still running
      (should (eq (claude-tasks-test--status tasks "b111") 'stopped))
      (should (eq (claude-tasks-test--status tasks "a333") 'running))
      (should (eq (claude-tasks-test--status tasks "a222") 'done)))))

(provide 'claude-tasks-test)
;;; claude-tasks-test.el ends here

;;; Activity

(defun claude-tasks-test--entry (json)
  (json-parse-string json :object-type 'alist :array-type 'list))

(defun claude-tasks-test--assistant (&rest blocks)
  "A transcript line of an assistant entry with the content BLOCKS (JSON texts)."
  (format "{\"type\":\"assistant\",\"timestamp\":\"2026-11-23T14:32:05Z\",\"message\":{\"content\":[%s]}}"
          (string-join blocks ",")))

(defun claude-tasks-test--use (id tool input)
  (format "{\"type\":\"tool_use\",\"id\":\"%s\",\"name\":\"%s\",\"input\":%s}" id tool input))

(defun claude-tasks-test--result (id &optional error)
  (format "{\"type\":\"user\",\"timestamp\":\"2026-11-23T14:32:09Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"%s\",\"is_error\":%s,\"content\":\"x\"}]}}"
          id (if error "true" "false")))

(ert-deftest claude-tasks-activity-kind-of-a-tool ()
  (dolist (pair '(("Read" . read) ("Grep" . read) ("Glob" . read)
                  ("Edit" . edit) ("Write" . edit) ("NotebookEdit" . edit)
                  ("Bash" . bash) ("Agent" . agent) ("Task" . agent)
                  ("AskUserQuestion" . wait) ("mcp__x__y" . bash)))
    (should (eq (cdr pair) (claude-tasks-activity-kind (car pair))))))

(ert-deftest claude-tasks-activity-classify-an-assistant-entry ()
  (let ((events (claude-tasks-activity-classify
                 (claude-tasks-test--entry
                  (claude-tasks-test--assistant
                   "{\"type\":\"thinking\",\"thinking\":\"hm\"}"
                   "{\"type\":\"text\",\"text\":\"Reading  the\\nfile now.\"}"
                   "{\"type\":\"text\",\"text\":\"  \"}"
                   (claude-tasks-test--use "t1" "Edit" "{\"file_path\":\"/a/b/run.nu\",\"old_string\":\"x\"}")
                   (claude-tasks-test--use "t2" "Bash" "{\"command\":\"ls -l\",\"description\":\"List files\"}"))))))
    (should (equal '(think text edit bash) (mapcar (lambda (e) (plist-get e :kind)) events)))
    (should (equal "Reading the file now." (plist-get (nth 1 events) :summary)))
    (should (equal '("Edit" "run.nu" "t1")
                   (mapcar (lambda (key) (plist-get (nth 2 events) key)) '(:tool :summary :id))))
    (should (equal "List files" (plist-get (nth 3 events) :summary)))
    (should (= (plist-get (car events) :time) (float-time (date-to-time "2026-11-23T14:32:05Z"))))))

(ert-deftest claude-tasks-activity-classify-questions-results-and-errors ()
  (let ((ask (car (claude-tasks-activity-classify
                   (claude-tasks-test--entry
                    (claude-tasks-test--assistant
                     (claude-tasks-test--use "q1" "AskUserQuestion"
                                             "{\"questions\":[{\"question\":\"Which one?\"}]}")))))))
    (should (eq 'wait (plist-get ask :kind)))
    (should (plist-get ask :pending))
    (should (equal "Which one?" (plist-get ask :summary))))
  (should (equal '((:kind answer :id "t1"))
                 (claude-tasks-activity-classify (claude-tasks-test--entry (claude-tasks-test--result "t1")))))
  (let ((err (car (claude-tasks-activity-classify
                   (claude-tasks-test--entry (claude-tasks-test--result "t1" t))))))
    (should (eq 'err (plist-get err :kind)))
    (should (equal "t1" (plist-get err :id))))
  ;; An API error, in either of the forms a transcript has
  (dolist (line '("{\"type\":\"system\",\"subtype\":\"api_error\",\"content\":\"overloaded\"}"
                  "{\"type\":\"assistant\",\"isApiErrorMessage\":true,\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"overloaded\"}]}}"))
    (let ((err (claude-tasks-activity-classify (claude-tasks-test--entry line))))
      (should (= 1 (length err)))
      (should (equal '(err "API" "overloaded")
                     (mapcar (lambda (key) (plist-get (car err) key)) '(:kind :tool :summary))))))
  ;; What the user typed is not activity
  (should-not (claude-tasks-activity-classify
               (claude-tasks-test--entry "{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}"))))

(ert-deftest claude-tasks-activity-reads-only-what-was-added ()
  (let ((file (make-temp-file "activity" nil ".jsonl"))
        (claude-tasks--activity (make-hash-table :test #'equal))
        (kinds (lambda (events) (mapcar (lambda (e) (plist-get e :kind)) events))))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (claude-tasks-test--assistant
                     (claude-tasks-test--use "t1" "Read" "{\"file_path\":\"/a/x.el\"}"))
                    "\n"
                    (claude-tasks-test--assistant
                     (claude-tasks-test--use "q1" "AskUserQuestion" "{\"questions\":[{\"question\":\"Go?\"}]}"))
                    "\n"
                    ;; A line still being written is left for the next read
                    "{\"type\":\"assistant\",\"mess"))
          (let ((events (claude-tasks-activity file)))
            (should (equal '(read wait) (funcall kinds events)))
            (should (plist-get (cadr events) :pending)))
          (let ((offset (car (gethash file claude-tasks--activity))))
            (should (equal '(read wait) (funcall kinds (claude-tasks-activity file))))
            (should (= offset (car (gethash file claude-tasks--activity)))))
          ;; The rest of that line, the answer to the question, and a failed call
          (write-region (concat "age\":{\"content\":[{\"type\":\"thinking\"}]}}\n"
                                (claude-tasks-test--result "q1") "\n"
                                (claude-tasks-test--result "t1" t) "\n")
                        nil file t 'silent)
          (let ((events (claude-tasks-activity file)))
            (should (equal '(read wait think err) (funcall kinds events)))
            (should-not (plist-get (cadr events) :pending))
            ;; The error names the call that failed
            (should (equal '("Read" "x.el")
                           (list (plist-get (nth 3 events) :tool) (plist-get (nth 3 events) :summary)))))
          ;; Only the newest are kept, and a shorter file is a new one
          (let ((claude-tasks-activity-keep 2))
            (write-region (concat (claude-tasks-test--assistant "{\"type\":\"thinking\"}") "\n")
                          nil file t 'silent)
            (should (equal '(err think) (funcall kinds (claude-tasks-activity file)))))
          (with-temp-file file
            (insert (claude-tasks-test--assistant "{\"type\":\"text\",\"text\":\"new\"}") "\n"))
          (should (equal '(text) (funcall kinds (claude-tasks-activity file)))))
      (delete-file file))))

(ert-deftest claude-tasks-activity-first-read-is-the-tail ()
  (let ((file (make-temp-file "activity" nil ".jsonl"))
        (claude-tasks--activity (make-hash-table :test #'equal))
        (line (concat (claude-tasks-test--assistant "{\"type\":\"thinking\"}") "\n")))
    (unwind-protect
        (progn
          (with-temp-file file (dotimes (_ 10) (insert line)))
          ;; Two and a half lines from the end: the cut line is skipped
          (let ((claude-tasks-activity-first-read (floor (* 2.5 (length line)))))
            (should (= 2 (length (claude-tasks-activity file))))))
      (delete-file file))))
