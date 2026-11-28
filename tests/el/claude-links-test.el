;;; claude-links-test.el --- ERT for agents tied to tasks -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-links-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-links)

(defconst claude-links-test--stream
  (list
   "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"a1\",\"description\":\"Count lines\",\"task_type\":\"local_agent\",\"prompt\":\"Count.\\ntask: fix-the-fold\\nBe brief.\",\"session_id\":\"s1\"}"
   "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"b1\",\"description\":\"sleep\",\"task_type\":\"local_bash\",\"session_id\":\"s1\"}"
   "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"a2\",\"description\":\"Old one\",\"task_type\":\"local_agent\",\"prompt\":\"x\",\"session_id\":\"s1\"}"
   "{\"type\":\"system\",\"subtype\":\"task_notification\",\"task_id\":\"a2\",\"status\":\"completed\",\"summary\":\"Did it.\",\"session_id\":\"s1\"}")
  "A headless stream: an agent with a task id, a shell, and an agent that ended.")

(defmacro claude-links-test--with (&rest body)
  "Run BODY with `dir' a directory holding a stream, a todos file and an empty store."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "claude-links" t))
          (stream (expand-file-name "stream.jsonl" dir))
          (claude-links-file (expand-file-name "links.jsonl" dir))
          (claude-links--rows nil)
          (claude-links--streams (make-hash-table :test #'equal))
          (claude-todos-dir (file-name-as-directory dir))
          (claude-main-session-file (expand-file-name "no-pin" dir))
          (process-environment (cons (concat "TASK_LINKS=" claude-links-file) process-environment))
          (claude-links-command
           (list "python3" (expand-file-name "../../container/claude-task-links"
                                             (file-name-directory (symbol-file 'claude-links-test--stream)))
                 "apply")))
     (unwind-protect
         (progn
           (with-temp-file stream
             (insert (string-join claude-links-test--stream "\n") "\n"))
           ,@body)
       (delete-directory dir t))))

(defun claude-links-test--sync (agents)
  "Send the events of AGENTS to the writer and wait for it."
  (cl-letf (((symbol-function 'claude-links--agents) (lambda () agents)))
    (claude-links-sync)
    (while (process-live-p claude-links--process) (accept-process-output nil 0.05))))

(ert-deftest claude-links-task-id-of-a-brief ()
  (should (equal (claude-tasks--task-id "Do it.\nTask: t-42 \nmore") "t-42"))
  (should-not (claude-tasks--task-id "the task: is in the middle of a line")))

(ert-deftest claude-links-stream-names-agents-only ()
  (claude-links-test--with
    (let ((agents (sort (claude-links--stream-agents stream)
                        (lambda (a b) (string< (plist-get a :id) (plist-get b :id))))))
      (should (equal (mapcar (lambda (a) (plist-get a :id)) agents) '("a1" "a2")))
      (should (equal (plist-get (car agents) :task) "fix-the-fold"))
      (should (eq (plist-get (cadr agents) :status) 'done))
      ;; Nothing is read twice
      (should (= (length (claude-links--stream-agents stream)) 2)))))

(ert-deftest claude-links-start-then-end-reach-store-and-todos ()
  (claude-links-test--with
    (let ((todos (claude-todos-file)))
      (with-temp-file todos (insert "* Mine\n** TODO Fix the fold\n"))
      ;; Only the running agent starts: the one that ended before was never stored
      (claude-links-test--sync (claude-links--stream-agents stream))
      (should (equal (alist-get 'status (claude-links-row "a1")) "running"))
      (should-not (claude-links-row "a2"))
      (should (string-match-p "\\*\\* STRT Fix the fold\n:PROPERTIES:\n:AGENT: \\[\\[homun-agent:a1]]"
                              (with-temp-buffer (insert-file-contents todos) (buffer-string))))
      ;; The same agents again change nothing; its end closes the row and the heading
      (should-not (claude-links-events (claude-links--stream-agents stream)))
      (claude-links-test--sync '((:id "a1" :status failed :summary "It broke.")))
      (should (equal (alist-get 'status (claude-links-row "a1")) "failed"))
      (should (string-match-p "\\*\\* FAILED Fix the fold\n\\(?:.*\n\\)*- failed, agent a1: It broke\\."
                              (with-temp-buffer (insert-file-contents todos) (buffer-string)))))))

;;; claude-links-test.el ends here
