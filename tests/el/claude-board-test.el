;;; claude-board-test.el --- ERT for the meters of claude-board.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-board-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-board)
(require 'claude-handoff)
(require 'claude-approve)
(require 'claude-bus)

(defun claude-board-test--usage (&rest pairs)
  (let ((h (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) h))
    h))

(ert-deftest claude-board-context-tokens-sums-input-and-cache ()
  (should (= 1110 (claude-board-context-tokens
                   (claude-board-test--usage "input_tokens" 10 "cache_read_input_tokens" 1000
                                             "cache_creation_input_tokens" 100
                                             "output_tokens" 999))))
  (should (= 5 (claude-board-context-tokens (claude-board-test--usage "input_tokens" 5))))
  (should-not (claude-board-context-tokens (claude-board-test--usage "output_tokens" 5))))

(ert-deftest claude-board-window-rule ()
  (should (= 200000 (claude-board-window "claude-opus-5-5" 1000)))
  (should (= 1000000 (claude-board-window "claude-opus-5-5[1m]" 1000)))
  (should (= 1000000 (claude-board-window nil 200001)))
  (should (= 200000 (claude-board-window nil 200000))))

(ert-deftest widgetry-meter-level-face-thresholds ()
  (should (eq 'widgetry-meter-fill-ok (widgetry-meter-level-face 0.59)))
  (should (eq 'widgetry-meter-fill-warn (widgetry-meter-level-face 0.6)))
  (should (eq 'widgetry-meter-fill-warn (widgetry-meter-level-face 0.84)))
  (should (eq 'widgetry-meter-fill-high (widgetry-meter-level-face 0.85))))

(ert-deftest claude-board-context-from-transcript-tail ()
  (let ((file (make-temp-file "board" nil ".jsonl"))
        (claude-agent-db "/nonexistent/usage.sqlite")
        (claude-board--window-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\":\"assistant\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"cache_read_input_tokens\":299999}}}\n"
                    "{\"type\":\"user\"}\n"))
          (should (equal '(300000 1000000) (claude-board--context file))))
      (delete-file file))))

(ert-deftest claude-board-window-from-samples ()
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (let* ((claude-agent-db (make-temp-file "board" nil ".sqlite"))
         (claude-board--window-cache (make-hash-table :test #'equal))
         (db (sqlite-open claude-agent-db)))
    (unwind-protect
        (progn
          (sqlite-execute db "create table samples (ts, session_id, model, context_window_size)")
          (sqlite-execute db "insert into samples values (1, 's1', 'm-a', 200000), (2, 's1', 'm-a', 1000000), (3, 's2', 'm-b', 500000)")
          (sqlite-close db)
          ;; The session's newest sample, whatever the model id suggests
          (should (= 1000000 (claude-board--window-size "s1" "m-a" 10)))
          ;; No session row (a subagent): the model's
          (should (= 500000 (claude-board--window-size nil "m-b" 10)))
          ;; Neither: the guess
          (should (= 200000 (claude-board--window-size "s9" "m-z" 10)))
          (should (= 1000000 (claude-board--window-size nil "m-z[1m]" 10))))
      (delete-file claude-agent-db))))

(ert-deftest claude-board-window-without-a-database ()
  (let ((claude-agent-db "/nonexistent/usage.sqlite")
        (claude-board--window-cache (make-hash-table :test #'equal)))
    (should (= 200000 (claude-board--window-size "s1" "m" 10)))))

(ert-deftest claude-board-fmt-window ()
  (should (equal "1M" (claude-board--fmt-window 1000000)))
  (should (equal "200k" (claude-board--fmt-window 200000)))
  (should (equal "1500k" (claude-board--fmt-window 1500000))))

(ert-deftest claude-board-state-of-a-task ()
  (let ((now (float-time)))
    ;; Live work runs, whatever was said before
    (should (eq 'running (claude-board--state (list :kind 'subagent :running t :active now))))
    (should (eq 'running (claude-board--state (list :kind 'job :running t) 'done)))
    ;; A notification decides how it ended
    (should (eq 'failed (claude-board--state (list :kind 'subagent :running nil :active now) 'failed)))
    (should (eq 'stopped (claude-board--state (list :kind 'subagent :running nil :active now) 'stopped)))
    ;; Without one: finished is done, gone quiet is stopped
    (should (eq 'done (claude-board--state (list :kind 'subagent :running nil :active now))))
    (should (eq 'stopped (claude-board--state
                          (list :kind 'subagent :running t
                                :active (- now claude-board-quiet-after 10)))))))

(ert-deftest claude-board-task-cell-has-a-state-dot ()
  (cl-letf (((symbol-function 'claude-board--background-status) #'ignore))
    (let ((cell (claude-board--task-cell (list :kind 'job :running t :desc "build"))))
      (should (equal (substring-no-properties cell) "● build"))
      (should (eq (get-text-property 0 'face cell) 'widgetry-status-pending))
      (should (equal (get-text-property 0 'help-echo cell) "running")))
    ;; A child row keeps its branch in front
    (should (equal (substring-no-properties
                    (claude-board--task-cell (list :kind 'subagent :running nil :desc "└ dig")))
                   "● └ dig"))
    ;; The blank takes the place of the parent's emoji, after the dot
    (let ((cell (claude-board--task-cell
                 (list :kind 'subagent :running nil :desc "└ dig" :emoji "🧮"))))
      (should (equal (substring-no-properties cell) "●  └ dig"))
      (should (eq 'space (car (get-text-property 2 'display cell)))))
    ;; A shell child gets its slot and branch like an agent child, "$ " after them
    (let ((cell (claude-board--task-cell
                 (list :kind 'shell :running t :desc "└ sleep 9" :emoji "🧮"))))
      (should (equal (substring-no-properties cell) "●  └ $ sleep 9"))
      (should (eq 'space (car (get-text-property 2 'display cell)))))
    (should (equal "🧮" (claude-board--emoji-of (list :desc "🧮 manager"))))
    (should (equal "" (claude-board--emoji-of (list :desc "manager"))))))


(ert-deftest claude-board-tree-marks-middle-and-last-children ()
  (progn
    (should (eq 'mid (plist-get (nth 1 (claude-board--tree
                                        (list (list :kind 'main :desc "🧮 T" :session "s")
                                              (list :kind 'subagent :desc "a" :session "s")
                                              (list :kind 'subagent :desc "b" :session "s"))))
                                :tree)))))

(ert-deftest claude-board-point-follows-the-task ()
  (let ((a (list :kind 'subagent :desc "a" :transcript "/x/a"))
        (b (list :kind 'subagent :desc "b" :transcript "/x/b")))
    (with-temp-buffer
      (claude-board-mode)
      (let ((inhibit-read-only t))
        (make-vtable :columns '("T") :objects (list a b) :getter (lambda (o _c _t) (plist-get o :desc))))
      (setq claude-board--selected "/x/b")
      (claude-board--goto-selected (list a b))
      (should (eq b (vtable-current-object)))
      (let ((inhibit-read-only t)) (erase-buffer)
        (make-vtable :columns '("T") :objects (list b a) :getter (lambda (o _c _t) (plist-get o :desc))))
      (claude-board--goto-selected (list b a))
      (should (eq b (vtable-current-object)))
      (setq claude-board--selected "/gone")
      (claude-board--goto-selected (list b a))
      (should (eq b (vtable-current-object))))))

(ert-deftest claude-board-layout-by-width ()
  (let ((names (lambda (chars) (mapcar #'car (claude-board-layout chars))))
        (total (lambda (chars) (let ((l (claude-board-layout chars)))
                                 (+ (apply #'+ (mapcar #'caddr l))
                                    (* claude-board-column-gap (1- (length l))))))))
    (should (equal '("Task" "Type" "Model" "Age" "Context" "Activity") (funcall names 120)))
    ;; Task takes every character the others leave: 120 less the others and the gaps
    (should (equal 57 (nth 2 (assoc "Task" (claude-board-layout 120)))))
    ;; Type goes first, the activity strip last; Task is never dropped and never narrower
    (should (equal '("Task" "Model" "Age" "Context" "Activity") (funcall names 80)))
    (should (equal '("Task" "Context" "Activity") (funcall names 50)))
    (should (equal '("Task") (funcall names 35)))
    (dolist (n '(120 80 50 35))
      (should (>= (nth 2 (assoc "Task" (claude-board-layout n))) 24)))
    (dolist (n '(120 80 50 35)) (should (<= (funcall total n) n)))))

(ert-deftest claude-board-meter-width-narrow ()
  (should (= 24 (claude-board-meter-width 120 18)))
  (should (= 24 (claude-board-meter-width 49 0)))
  (should (= 21 (claude-board-meter-width 25 0)))
  (should (= 6 (claude-board-meter-width 8 0))))

(defmacro claude-board-test--with-board (&rest body)
  "Run BODY in an empty board shown in the selected window, its sources stubbed."
  `(cl-letf (((symbol-function 'claude-board--mains) #'ignore)
             ((symbol-function 'claude-board--handoffs) #'ignore)
             ((symbol-function 'claude-board--tasks) #'ignore)
             ((symbol-function 'claude-board--meters) #'ignore)
             ((symbol-function 'claude-touch) #'ignore))
     (with-temp-buffer
       (claude-board-mode)
       (set-window-buffer (selected-window) (current-buffer))
       (unwind-protect (progn ,@body)
         (when claude-board--resize-timer (cancel-timer claude-board--resize-timer))))))

(ert-deftest claude-board-redraw-does-not-trigger-itself ()
  (claude-board-test--with-board
   (let ((draws 0))
     (add-function :before (symbol-function 'claude-board--draw) (lambda () (setq draws (1+ draws)))
                   '((name . count)))
     (unwind-protect
         (progn
           (claude-board--draw)
           ;; The size hook after a draw: same width, so nothing is scheduled
           (claude-board--resized (selected-window))
           (should-not claude-board--resize-timer)
           ;; A real change schedules one redraw, however often the hook runs,
           ;; and the hook itself draws nothing
           (setq claude-board--width (1+ claude-board--width))
           (claude-board--resized (selected-window))
           (claude-board--resized (selected-window))
           (should (timerp claude-board--resize-timer))
           (should (= 1 (seq-count (lambda (timer)
                                     (eq (timer--function timer) #'claude-board--resize-redraw))
                                   timer-idle-list)))
           (should (= draws 1))
           ;; The timer draws once and leaves nothing pending; a second run is a no-op
           (cancel-timer claude-board--resize-timer)
           (claude-board--resize-redraw (current-buffer))
           (should (= draws 2))
           (should-not claude-board--resize-timer)
           (claude-board--resize-redraw (current-buffer))
           (claude-board--resized (selected-window))
           (should (= draws 2))
           (should-not claude-board--resize-timer)
           ;; While a draw runs, the hook is ignored
           (setq claude-board--width (1+ claude-board--width))
           (let ((claude-board--drawing t))
             (claude-board--resized (selected-window)))
           (should-not claude-board--resize-timer))
       (remove-function (symbol-function 'claude-board--draw) 'count)))))

(ert-deftest claude-board-pixel-widths-fill-the-body ()
  (let ((total (lambda (widths char) (+ (apply #'+ widths)
                                        (* claude-board-column-gap char (1- (length widths)))))))
    ;; Whatever the window and the character measure, the columns and gaps add up to the body
    (dolist (case '((120 1082 9) (120 1080 9) (80 727 9) (50 400 8) (35 245 7) (200 2001 10)))
      (pcase-let* ((`(,chars ,body ,char) case)
                   (layout (claude-board-layout chars))
                   (widths (claude-board-pixel-widths layout body char)))
        (should (= (length widths) (length layout)))
        (should (= body (funcall total widths char)))))
    ;; A fixed column with glyphs wider than a character grows to them, at the cost of the last one
    (let* ((layout (claude-board-layout 120))
           (plain (claude-board-pixel-widths layout 1082 9))
           (wide (claude-board-pixel-widths layout 1082 9 '(nil nil nil nil 115 nil))))
      (should (= 115 (nth 4 wide)))
      (should (= (nth 5 plain) (nth 5 wide)))
      (should (= 25 (- (car plain) (car wide))))
      (should (= 1082 (funcall total wide 9))))))

;; A batch frame does not lay out stretch glyphs, so the line is added up from its
;; text and the pixel widths of its display spaces.
(defun claude-board-test--line-pixels ()
  "Pixels of the line at point: characters, and spaces by their (space :width (N))."
  (let ((pixels 0))
    (dolist (pos (number-sequence (pos-bol) (1- (pos-eol))) pixels)
      (setq pixels (+ pixels (pcase (get-text-property pos 'display)
                               (`(space :width (,n)) n)
                               (`(space :align-to ,_) 0)
                               (_ (char-width (char-after pos)))))))))

(ert-deftest claude-board-table-lines-fill-the-window ()
  (let ((tasks (list (list :kind 'job :running t :desc "build" :type "job" :model "m")
                     (list :kind 'job :running t :desc (make-string 300 ?x) :type "job"))))
    (cl-letf (((symbol-function 'claude-board--background-status) #'ignore))
      (claude-board-test--with-board
       (let ((inhibit-read-only t)
             (body (claude-board--body-pixels)))
         (claude-board--table tasks (claude-board-layout (claude-board--chars)))
         (goto-char (point-min))
         (should (= 3 (count-lines (point-min) (point-max))))
         (while (not (eobp))
           (should (= body (claude-board-test--line-pixels)))
           (forward-line 1)))))))

(ert-deftest claude-board-activity-cell-from-transcript-and-requests ()
  (let ((file (make-temp-file "board" nil ".jsonl"))
        (claude-tasks--activity (make-hash-table :test #'equal))
        (claude-board-activity-cells 4)
        (claude-board--requests
         '(((id . "1-1") (tool . "Bash") (summary . "rm x") (since . 100) (agent . :null))
           ((id . "1-2") (tool . "Edit") (summary . "a.el") (since . 101)
            (agent . ((id . "abc") (type . "dev")))))))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Agent\",\"input\":{\"description\":\"Dig\"}}]}}\n"))
          ;; The Manager's row: its transcript, then the request that names no agent
          (let ((cell (claude-board--activity-cell (list :kind 'main :role 'manager :transcript file))))
            (should (equal "·▪◆!" (substring-no-properties cell)))
            (should (get-text-property 3 'widgetry-activity-wait cell))
            (should (string-prefix-p "wait · Bash rm x" (get-text-property 3 'help-echo cell))))
          ;; A subagent's row takes the request that names it, another role's none
          (should (equal "·▪◆!" (substring-no-properties
                                 (claude-board--activity-cell
                                  (list :kind 'subagent :id "abc" :transcript file)))))
          (should (equal "··▪◆" (substring-no-properties
                                 (claude-board--activity-cell
                                  (list :kind 'main :role 'mechanic :transcript file)))))
          ;; No transcript, no strip
          (should (equal "" (claude-board--activity-cell (list :kind 'job)))))
      (delete-file file))))

(ert-deftest claude-board-activity-detail-widens-the-rows ()
  (let ((task (list :kind 'job :transcript "/nonexistent.jsonl"))
        (claude-board--requests nil)
        (claude-board-activity-cells 14))
    (let ((claude-board-activity-detail nil))
      (should (= 14 (nth 2 (assoc "Activity" (claude-board-layout 140)))))
      (should (= 14 (string-width (claude-board--activity-cell task)))))
    (let ((claude-board-activity-detail t))
      (should (= 22 (nth 2 (assoc "Activity" (claude-board-layout 140)))))
      (should (string-suffix-p " ● idle " (substring-no-properties (claude-board--activity-cell task))))
      (should (= 22 (string-width (claude-board--activity-cell task)))))))

(defun claude-board-test--tasks ()
  (list (list :kind 'job :running t :desc "a" :type "job" :transcript "/x/a" :started 10)
        (list :kind 'job :running t :desc "b" :type "job" :transcript "/x/b" :started 20)))

(ert-deftest claude-board-last-line-is-the-task-tooltip ()
  (cl-letf (((symbol-function 'claude-board--background-status) #'ignore)
            ((symbol-function 'claude-board--last-line) (lambda (task) (concat "said " (plist-get task :desc)))))
    (claude-board-test--with-board
     (let ((inhibit-read-only t) (tasks (claude-board-test--tasks)))
       (claude-board--table tasks (claude-board-layout (claude-board--chars)))
       ;; Header and two rows: no sub-lines
       (should (= 3 (count-lines (point-min) (point-max))))
       (goto-char (point-min))
       (search-forward "● a")
       (should (equal "said a" (get-text-property (1- (point)) 'help-echo)))
       (should (eq (car tasks) (get-text-property (point) 'claude-board-task)))))))

(ert-deftest claude-board-order-ignores-activity ()
  (let* ((a (list :desc "a" :transcript "/x/a" :started 10 :active 1))
         (b (list :desc "b" :transcript "/x/b" :started 20 :active 2))
         (c (list :desc "c" :transcript "/x/c" :started 30 :active 3))
         (order (lambda (tasks) (mapcar (lambda (task) (plist-get task :desc))
                                        (sort (copy-sequence tasks) #'claude-board--before-p)))))
    (should (equal '("a" "b" "c") (funcall order (list c a b))))
    ;; Events on any row, in any order, move nothing
    (dolist (active '((9 1 5) (1 9 5) (5 5 9)))
      (plist-put a :active (nth 0 active)) (plist-put b :active (nth 1 active))
      (plist-put c :active (nth 2 active))
      (should (equal '("a" "b" "c") (funcall order (list b c a)))))
    ;; A new row appends
    (should (equal '("a" "b" "c" "d")
                   (funcall order (list (list :desc "d" :started 40) c b a))))))

(ert-deftest claude-board-draw-skips-when-nothing-changed ()
  (claude-board-test--with-board
   (cl-letf (((symbol-function 'claude-board--signature) (lambda (&rest _) 'same)))
     (claude-board--draw)
     (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "marker"))
     (claude-board--draw)
     (should (string-suffix-p "marker" (buffer-string)))
     (claude-board--draw t)
     (should-not (string-suffix-p "marker" (buffer-string))))))

(ert-deftest claude-board-idle-ticks-change-nothing ()
  "Heartbeat and timed-redraw frames on an unchanged board leave its text alone."
  (claude-board-test--with-board
   (cl-letf (((symbol-function 'claude-board--signature) (lambda (&rest _) 'same))
             ((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window))))
     (claude-board--draw)
     (let ((tick (buffer-modified-tick)) (buffer (current-buffer))
           (claude-board-interval 0))
       (dotimes (_ 50)
         (claude-board--heartbeat-frame nil)
         (claude-board--frame buffer))
       (should (= tick (buffer-modified-tick)))
       (should (string-prefix-p " " claude-board--heartbeat-string))))))

(ert-deftest claude-board-keys-act-on-the-task-at-point ()
  (cl-letf (((symbol-function 'claude-board--background-status) #'ignore)
            ((symbol-function 'claude-board--last-line) (lambda (task) (concat "said " (plist-get task :desc)))))
    (claude-board-test--with-board
     (let* ((inhibit-read-only t)
            (tasks (list (list :kind 'job :running t :desc "a" :type "job" :transcript "/x/a" :started 10)
                         (list :kind 'job :running t :desc "b" :type "job" :transcript "/x/b" :started 20)
                         (list :kind 'job :running t :desc "c" :type "job" :transcript "/x/c" :started 30)))
            (task (cadr tasks)))
       (claude-board--table tasks (claude-board-layout (claude-board--chars)))
       (goto-char (point-min))
       (search-forward "● b")
       (should (eq task (claude-board--task)))
       (let (opened)
         (cl-letf (((symbol-function 'claude-update-status) #'ignore)
                   ((symbol-function 'claude-transcript-open) #'ignore)
                   ((symbol-function 'claude-board--kill-agent-transcripts) #'ignore)
                   ((symbol-function 'claude-cockpit) (lambda (file) (setq opened file))))
           (claude-board-open))
         (should (equal "/x/b" opened)))))))

(provide 'claude-board-test)

(ert-deftest claude-board-alarm-trail-folds-to-one-line ()
  (cl-letf (((symbol-function 'claude-board--chars) (lambda () 60)))
    (let ((claude-board--alarms '(("manager" (:ts 100 :alarm "old" :msg "a"))
                                  ("mechanic" (:ts 200 :alarm "repair" :msg "b\nc"))))
          (claude-board-alarms-open nil))
      (with-temp-buffer
        (insert "table")
        (goto-char (point-min))
        (claude-board--alarm-trail)
        (should (string-prefix-p "table\n" (buffer-string)))
        (should (string-match-p "Alarms: 2, latest .* repair\n\\'" (buffer-string)))
        (should (= 2 (count-lines (point-min) (point-max)))))
      (with-temp-buffer
        (let ((claude-board-alarms-open t))
          (claude-board--alarm-trail))
        (dolist (line (split-string (buffer-string) "\n"))
          (should (<= (string-width line) 60)))
        (should (= 3 (count-lines (point-min) (point-max))))))))

(ert-deftest claude-board-unchanged-draw-lists-no-directory ()
  "A second draw over an unchanged transcript tree reads none of its directories:
every listing is reused."
  (let* ((root (make-temp-file "board-tree" t))
         (elsewhere (file-name-as-directory (make-temp-file "board-elsewhere" t)))
         (claude-agent-projects root)
         (claude-agent--listings (make-hash-table :test #'equal))
         (claude-board-role-dirs `((manager . ,root)))
         (claude-tasks-headless-globs nil)
         ;; The board's directories outside the projects tree, out of the way
         (claude-handoff-dir (expand-file-name "missing/" elsewhere))
         (claude-approve-dir elsewhere)
         (claude-bus-dir (expand-file-name "missing/" elsewhere))
         (old (time-subtract nil 3600))
         (reads 0))
    (unwind-protect
        (progn
          (dotimes (i 30)
            (let ((file (expand-file-name (format "p%d/s%02d.jsonl" (% i 3) i) root)))
              (make-directory (file-name-directory file) t)
              (write-region "{}\n" nil file nil 'silent)
              (when (zerop (% i 5))
                (make-directory (expand-file-name (format "p%d/s%02d/subagents/workflows/w" (% i 3) i) root) t))))
          (dolist (dir (cons root (seq-filter #'file-directory-p (directory-files-recursively root "" t))))
            (set-file-times dir old))
          (cl-letf (((symbol-function 'claude-main-session-id) (lambda () nil)))
            (with-temp-buffer
              (claude-board--draw t)
              (dolist (fn '(directory-files directory-files-and-attributes file-expand-wildcards))
                (advice-add fn :before (lambda (file &rest _)
                                        (when (file-in-directory-p file root) (cl-incf reads)))
                            '((name . count))))
              (unwind-protect (claude-board--draw)
                (dolist (fn '(directory-files directory-files-and-attributes file-expand-wildcards))
                  (advice-remove fn 'count)))))
          (should (= 0 reads)))
      (delete-directory root t)
      (delete-directory elsewhere t))))

(ert-deftest claude-board-heartbeat-tick-changes-only-header ()
  (with-temp-buffer
    (insert "body")
    (set-window-buffer (selected-window) (current-buffer))
    (let ((tick (buffer-chars-modified-tick)) (text (buffer-string))
          (claude-board--heartbeat-index 0) (claude-board--heartbeat-string "")
          (homun-freeze-watch-largest-gap (cons (- (float-time) 180) 1.2)))
      (claude-board--heartbeat-tick (selected-window))
      (should (= tick (buffer-chars-modified-tick)))
      (should (equal text (buffer-string)))
      (should (string-match-p "⠙ largest stall 3m (1\\.2 s)" claude-board--heartbeat-string)))))

(ert-deftest claude-board-watch-files-once-per-board ()
  ;; Every draw used to call the file watch: each added watches and a fresh throttle,
  ;; and every file change then redrew once per throttle, which added more.
  (let* ((dir (make-temp-file "board" t))
         (claude-tasks-jobs-dir dir) (claude-tasks-watch-dir dir)
         (claude-tasks-ledger (expand-file-name "ledger.jsonl" dir))
         (claude-board--alarm-redraws nil) (adds 0))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'claude-board--alarm-follow) #'ignore)
                    ((symbol-function 'file-notify-add-watch) (lambda (&rest _) (cl-incf adds))))
            (claude-board--watch-files (current-buffer))
            (let ((after-one adds))
              (dotimes (_ 5) (claude-board--watch-files (current-buffer)))
              (should (= adds after-one))
              (should (= 1 (length claude-board--alarm-redraws))))))
      (delete-directory dir t))))
