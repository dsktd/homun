;;; homun-stage-kit-test.el --- ERT for the stage scene kit -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/homun-stage-kit-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'homun-stage-kit)

(defvar homun-stage-kit-test--now 1000.0)

(defconst homun-stage-kit-test--spec
  '((type . "col")
    (children
     ((type . "text") (text . "Kit"))
     ((type . "ring") (id . "r") (label . "Build homun") (topic . "stage.p"))
     ((type . "tests") (id . "t") (buffer . "*kit-build*"))
     ((type . "log") (id . "l") (buffer . "*kit-build*") (lines . 3))
     ((type . "files") (id . "f") (dir . "/w"))
     ((type . "commits") (id . "c") (dir . "/w"))
     ((type . "budget") (id . "b")))))

(defmacro homun-stage-kit-test--with (&rest body)
  "Run BODY with the kit scene \"kit\" shown, its data stored, on a fake clock; no timers."
  (declare (indent 0))
  `(let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-stage-kit--data (make-hash-table :test #'equal))
          (homun-stage-kit-test--now 1000.0)
          (homun-clock-time-function (lambda () homun-stage-kit-test--now))
          (homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
          (homun-clock--wanted nil) (homun-clock-focused-function (lambda () t))
          (homun-stage-kit--buffers nil) (homun-stage-kit--timer nil)
          (homun-stage-kit-event-functions nil)
          (homun-stage-kit-visible-function (lambda (_) t)))
     (cl-letf (((symbol-function 'homun-stage-kit--arm) #'ignore)
               ((symbol-function 'homun-clock--start) #'ignore))
       (homun-stage-kit-test--data 5 1 '("compiling" "test a ok" "test b ok"))
       (homun-stage-kit-put '("topic" "stage.p") 0.5)
       (homun-stage-kit-put '("status" "/w") '(("src/a.el" "M" 999.5) ("b.el" "??" 100.0)))
       (homun-stage-kit-put '("commits" "/w" nil) '(:base "abc" :commits (("111" "one") ("222" "two"))))
       (homun-stage-kit-put '("budget") 42)
       (unwind-protect
           (progn (homun-stage-show "t" "kit" "Kit" homun-stage-kit-test--spec "ephemeral") ,@body)
         (dolist (b (buffer-list)) (when (string-prefix-p "*stage " (buffer-name b)) (kill-buffer b)))
         (delete-directory homun-stage-dir t)))))

(defun homun-stage-kit-test--data (pass fail lines)
  (homun-stage-kit-put '("build" "*kit-build*" nil)
                       (list :name "*kit-build*" :total (length lines) :lines lines :pass pass :fail fail)))

(defun homun-stage-kit-test--buf () (get-buffer (homun-stage-buffer-name "kit")))
(defun homun-stage-kit-test--text () (with-current-buffer (homun-stage-kit-test--buf) (buffer-string)))
(defun homun-stage-kit-test--tick (dt)
  (cl-incf homun-stage-kit-test--now dt)
  (homun-stage-kit-tick nil))
(defun homun-stage-kit-test--settle ()
  (dotimes (_ 60) (homun-stage-kit-test--tick (/ 1.0 30))))

(defun homun-stage-kit-test--runs (id)
  "How many separate runs of text carry the node ID."
  (with-current-buffer (homun-stage-kit-test--buf)
    (let ((pos (point-min)) (n 0) (in nil))
      (while (< pos (point-max))
        (let ((here (and (equal (get-text-property pos 'homun-stage-node) id)
                         ;; a newline between two lines of one part joins them
                         t)))
          (when (and here (not in)) (cl-incf n))
          (setq in (or here (and in (eq (char-after pos) ?\n)))))
        (cl-incf pos))
      n)))

(ert-deftest homun-stage-kit-parts-render-from-spec ()
  (homun-stage-kit-test--with
    (let ((text (homun-stage-kit-test--text)))
      (should (string-match-p "◑ Build homun.* 50%" text))
      (should (string-match-p "✓ 5 .*✗ 1" text))
      (should (string-match-p "│ test b ok" text))
      (should (string-match-p "• a\\.el" text))
      (should (string-match-p "+ b\\.el" text))
      (should (string-match-p "main ─●─◉" text))
      (should (string-match-p "222 two" text))
      (should (string-match-p "5h budget .* 42%" text)))
    (with-current-buffer (homun-stage-kit-test--buf)
      (goto-char (point-min)) (search-forward "a.el")
      (should (equal (get-text-property (point) 'homun-kit-open) '(file "/w/src/a.el")))
      (goto-char (point-min)) (search-forward "◉")
      (should (equal (get-text-property (1- (point)) 'homun-kit-open) '(commit "/w" "222"))))
    (should (string-match-p "tests ✓ 5" (homun-stage-text '((type . "tests") (buffer . "*kit-build*")))))
    (should-error (homun-stage-validate '((type . "files"))) :type 'homun-stage-invalid)))

(ert-deftest homun-stage-kit-tick-leaves-unchanged-spans ()
  (homun-stage-kit-test--with
    (with-current-buffer (homun-stage-kit-test--buf)
      (homun-stage-kit-test--tick 30.0)   ; the file heat cools: let it settle
      (let ((tick (buffer-chars-modified-tick)) (homun-stage-kit--writes 0))
        (homun-stage-kit-test--tick 0.0)
        (should (= homun-stage-kit--writes 0))
        (should (= tick (buffer-chars-modified-tick))))
      (let* ((before (buffer-string)) (lines (split-string before "\n")) (homun-stage-kit--writes 0))
        (homun-stage-kit-test--data 6 1 '("compiling" "test a ok" "test b ok"))
        (homun-stage-kit-test--settle)
        (should (= homun-stage-kit--writes 1)) ; one counter tick, one line
        (cl-loop for old in lines for new in (split-string (buffer-string) "\n")
                 unless (string-match-p "tests" old) do (should (equal old new)))
        (should (string-match-p "✓ 6" (buffer-string)))))))

(ert-deftest homun-stage-kit-each-part-once ()
  (homun-stage-kit-test--with
    (cl-flet ((once () (dolist (id '("r" "t" "l" "f" "c" "b")) (should (= 1 (homun-stage-kit-test--runs id))))))
      (once)
      (homun-stage-kit-test--data 9 0 '("a" "b" "c" "d" "e" "f"))
      (homun-stage-kit-put '("topic" "stage.p") 1.0)
      (homun-stage-kit-test--settle)
      (once)
      (should (string-match-p "│ f" (homun-stage-kit-test--text)))
      (should (= 1 (with-temp-buffer (insert (homun-stage-kit-test--text)) (how-many "5h budget" (point-min)))))
      (homun-stage-render (homun-stage-scene "kit"))
      (once)
      (should (= 6 (length (buffer-local-value 'homun-stage-kit--insts (homun-stage-kit-test--buf))))))))

(ert-deftest homun-stage-kit-agents-scene ()
  (let ((homun-stage-kit--builds '(("/w" build-fail 1.0))) (homun-stage-kit--banner nil))
    (let ((spec (homun-stage-kit-agents-spec '(("a1" "Fix it" 900 "/w") ("a2" "Other" 950 nil)))))
      (should (homun-stage-validate spec))
      (should (string-match-p "build failed" (format "%S" spec)))
      (should (= 1 (cl-count "a1-commits" (flatten-tree spec) :test #'equal))))))

(ert-deftest homun-stage-kit-frame-time ()
  "Four agents' parts, data changing every frame: report the mean and worst tick."
  (homun-stage-kit-test--with
    (homun-stage-show "t" "kit" "Kit" (homun-stage-kit-agents-spec
                                       (cl-loop for i below 4 collect (list (format "a%d" i) "Agent" 900 "/w")))
                      "ephemeral")
    (let ((worst 0) (sum 0) (n 200) (gcs 0))
      (dotimes (i n)
        (homun-stage-kit-put '("build" nil "/w") (list :name "x" :total i :pass i :fail (/ i 50)
                                                       :lines (mapcar #'number-to-string (number-sequence (max 0 (- i 10)) i))))
        (let ((t0 (float-time)) (gc gcs-done))
          (homun-stage-kit-test--tick (/ 1.0 30))
          (let ((d (- (float-time) t0)))
            (setq sum (+ sum d))
            ;; a frame that ran a GC is the collector's time (the cockpit's claude-gc defers it to idle)
            (if (> gcs-done gc) (cl-incf gcs) (setq worst (max worst d))))))
      (message "kit frame: mean %.3f ms, worst %.3f ms without GC, %d of %d frames ran a GC (-Q threshold)"
               (* 1000 (/ sum n)) (* 1000 worst) gcs n)
      (should (< worst 0.004)))))
