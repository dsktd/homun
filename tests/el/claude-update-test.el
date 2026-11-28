;;; claude-update-test.el --- ERT for the restart reasons of claude-update.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-update-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'claude-update)

(defmacro claude-update-test--with (overrides &rest body)
  "Run BODY with the readers behind the restart block stubbed.
OVERRIDES is a plist of :pending, :building, :staged, :starting, :busy and :stage."
  (declare (indent 1))
  `(let ((o ,overrides))
     (cl-letf (((symbol-function 'claude-update-pending-p) (lambda () (plist-get o :pending)))
               ((symbol-function 'claude-update-building-p) (lambda () (plist-get o :building)))
               ((symbol-function 'claude-update-staged-p) (lambda () (plist-get o :staged)))
               ((symbol-function 'claude-update--starting-p) (lambda () (plist-get o :starting)))
               ((symbol-function 'claude-update--busy) (lambda () (plist-get o :busy)))
               ((symbol-function 'claude-update--stage) (lambda () (plist-get o :stage))))
       ,@body)))

(ert-deftest claude-update-restart-block-names-each-cause ()
  (dolist (case '(((:pending t) . "recreate already requested")
                  ((:building t :stage ("building" 1 "14/31")) . "update in progress · step 14/31")
                  ((:building t :stage ("building" 1 "0/0")) . "update in progress")
                  ((:staged t :starting t) . "container still starting")
                  ((:staged t :busy unknown) . "busy state unknown")
                  ((:staged t :busy ("agent one" "agent two")) . "2 running: agent one…")
                  ((:staged t :busy ("agent one")) . "1 running: agent one")))
    (claude-update-test--with (car case)
      (should (equal (car (claude-update--restart-block)) (cdr case)))
      (should (stringp (cdr (claude-update--restart-block))))
      (should (equal (claude-update-restart-reason) (concat "Recreate off: " (cdr case)))))))

(ert-deftest claude-update-restart-free-when-idle ()
  (claude-update-test--with '()
    (should-not (claude-update--restart-block))
    (should-not (claude-update-restart-reason))))

(provide 'claude-update-test)
;;; claude-update-test.el ends here

;; Staged rev 357cb2d is a squash published from 9c1ed31; the running 1b5c2b5 from 9cb9c1c.
(ert-deftest claude-update-counts-attribute-staged-commits-to-recreate ()
  (let* ((running "1b5c2b5ae9353c783b6128ac97baba5516958ae1")
         (staged "357cb2dfc50858f55ed51f0fdd1eba630f84433d")
         (src-running "9cb9c1c6222521fad0d5bc4c0fe03ad958271065")
         (src-staged "9c1ed3106c4755982395497cbda31612b93e0f5f")
         (claude-update--counts nil)
         (claude-update--sources (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'claude-update--read)
               (lambda (name)
                 (pcase name
                   ("running-rev" running)
                   ("staged.json" (format "{\n  \"image\": \"x\",\n  \"rev\": \"%s\"\n}" staged)))))
              ((symbol-function 'claude-update--git-in)
               (lambda (_dir args)
                 (when (equal (seq-take args 3) '("log" "-1" "--format=%B"))
                   (list "Subject" "" (concat "Source-Rev: " (if (equal (nth 3 args) staged)
                                                                 src-staged src-running))))))
              ((symbol-function 'claude-update--git)
               (lambda (&rest args)
                 (pcase args
                   (`("rev-parse" "--verify" "--quiet" ,rev) (list (string-remove-suffix "^{commit}" rev)))
                   (`("log" "--format=%s" ,range)
                    (cond ((equal range (concat src-staged "..HEAD")) (make-list 3 "new"))
                          ((equal range (concat src-running ".." src-staged)) (make-list 20 "built")))))))
              ((symbol-function 'claude-update--read-dummy) #'ignore))
      (let ((counts (claude-update-counts)))
        (should (= 3 (length (plist-get counts :pending))))
        (should (= 20 (length (plist-get counts :recreate))))))))

(ert-deftest claude-update-spin-runs-on-clock ()
  (require 'homun-clock)
  (let ((homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
        (homun-clock-visible-function (lambda () t))
        (homun-clock-focused-function (lambda () t))
        (building t))
    (cl-letf (((symbol-function 'claude-update--spinning-p) (lambda () building)))
      (unwind-protect
          (progn
            (claude-update--spin-start)
            (should (assq 'claude-update-spin homun-clock--clients))
            (should (= 1 (homun-clock-timers)))
            (setq building nil)
            (homun-clock-tick)
            (should (= 0 (homun-clock-timers))))
        (homun-clock--stop)))))
