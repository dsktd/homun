;;; claude-transcript-plan-test.el --- ERT for the plan entry of claude-transcript.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-transcript-plan-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-transcript)

(defun claude-plan-test--file (json)
  (let ((f (make-temp-file "plan" nil ".json")))
    (with-temp-file f (insert json))
    f))

(defconst claude-plan-test--json
  "{\"title\":\"T\",\"updated\":1000,\"steps\":[{\"text\":\"a\",\"state\":\"done\",\"note\":\"\"},{\"text\":\"b\",\"state\":\"failed\",\"note\":\"403\"},{\"text\":\"c\",\"state\":\"odd\"}]}")

(ert-deftest claude-plan-read-parses ()
  (let ((plan (claude-transcript-plan-read (claude-plan-test--file claude-plan-test--json))))
    (should (equal (plist-get plan :title) "T"))
    (should (equal (mapcar (lambda (s) (plist-get s :state)) (plist-get plan :steps))
                   '("done" "failed" "next")))
    (should (equal (plist-get (cadr (plist-get plan :steps)) :note) "403"))
    (should-not (plist-get (car (plist-get plan :steps)) :note))))

(ert-deftest claude-plan-read-bad-file ()
  (should-not (claude-transcript-plan-read (claude-plan-test--file "nope")))
  (should-not (claude-transcript-plan-read "/nonexistent/plan.json")))

(ert-deftest claude-plan-card-marks-and-notes ()
  (let* ((plan (claude-transcript-plan-read (claude-plan-test--file claude-plan-test--json)))
         (text (with-temp-buffer (claude-transcript--plan-body plan))))
    (should (string-match-p "✓ a" text))
    (should (string-match-p "✗ b\n +403" text))
    (should (string-match-p "· c" text))
    (should (eq (get-text-property (string-search "✗" text) 'face text) 'homun-stage-failed))))

(ert-deftest claude-plan-active-hides-old-all-done ()
  (let ((done '(:updated 1000 :steps ((:state "done"))))
        (open '(:updated 1000 :steps ((:state "done") (:state "you")))))
    (should (claude-transcript-plan-active-p done 1100))
    (should-not (claude-transcript-plan-active-p done 1700))
    (should (claude-transcript-plan-active-p open 99999))
    (should-not (claude-transcript-plan-active-p nil 0))))

(provide 'claude-transcript-plan-test)
