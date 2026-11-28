;;; widgetry-activity-test.el --- Tests for widgetry-activity -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-activity)

(ert-deftest widgetry-activity-kinds-have-a-glyph-a-face-and-a-word ()
  (dolist (kind '(think text read edit bash agent wait err idle))
    (should (= 1 (string-width (widgetry-activity-glyph kind))))
    (should (facep (widgetry-activity-face kind)))
    (should (stringp (widgetry-activity-doing kind))))
  (should (equal "◆" (widgetry-activity-glyph 'agent)))
  (should (eq 'widgetry-activity-edit (widgetry-activity-face 'edit)))
  (should (equal "editing" (widgetry-activity-doing 'edit)))
  ;; An unknown kind shows as idle
  (should (equal "·" (widgetry-activity-glyph 'other))))

(defconst widgetry-activity-test--events
  (list (list :kind 'read :tool "Read" :summary "a.el" :time 0)
        (list :kind 'wait :tool "AskUserQuestion" :summary "Go?" :pending t)
        (list :kind 'edit :tool "Edit" :summary "run.nu"
              :time (float-time (encode-time '(5 32 14 23 11 2026 nil nil nil))))))

(ert-deftest widgetry-activity-strip-is-width-cells-newest-right ()
  (let ((strip (widgetry-activity-strip widgetry-activity-test--events 5)))
    (should (equal "··▪!▪" (substring-no-properties strip)))
    (should (= 5 (string-width strip)))
    (should (eq 'widgetry-activity-idle (get-text-property 0 'face strip)))
    (should (eq 'widgetry-activity-read (get-text-property 2 'face strip)))
    (should (eq 'widgetry-activity-edit (get-text-property 4 'face strip)))
    ;; Only the newest cell is marked so, and only the unanswered wait
    (should (equal '(nil nil nil nil t)
                   (mapcar (lambda (i) (get-text-property i 'widgetry-activity-newest strip))
                           (number-sequence 0 4))))
    (should (equal '(nil nil nil t nil)
                   (mapcar (lambda (i) (get-text-property i 'widgetry-activity-wait strip))
                           (number-sequence 0 4)))))
  ;; More events than cells: the newest are kept
  (should (equal "!▪" (substring-no-properties
                       (widgetry-activity-strip widgetry-activity-test--events 2))))
  (should (equal "···" (substring-no-properties (widgetry-activity-strip nil 3)))))

(ert-deftest widgetry-activity-hover-text ()
  (let ((strip (widgetry-activity-strip widgetry-activity-test--events 5)))
    (should (equal "edit · Edit run.nu · 14:32:05\ncurrently: editing"
                   (get-text-property 4 'help-echo strip)))
    (should (equal "wait · AskUserQuestion Go?" (get-text-property 3 'help-echo strip)))
    (should (equal "idle" (get-text-property 0 'help-echo strip))))
  (should (equal "think" (widgetry-activity-describe '(:kind think)))))

(ert-deftest widgetry-activity-blink-hides-and-shows-waits ()
  (with-temp-buffer
    (insert (widgetry-activity-strip widgetry-activity-test--events 5))
    (set-window-buffer (selected-window) (current-buffer))
    (let ((hidden (lambda () (seq-filter (lambda (o) (overlay-get o 'widgetry-activity-blink))
                                         (overlays-in (point-min) (point-max))))))
      (widgetry-activity-blink)
      (should widgetry-activity--blink)
      (should (assoc (cons 'widgetry-blink (current-buffer)) homun-clock--clients))
      (widgetry-activity--blink-tick (current-buffer))
      (should (equal '(4 . 5) (let ((o (car (funcall hidden))))
                                (cons (overlay-start o) (overlay-end o)))))
      (widgetry-activity--blink-tick (current-buffer))
      (should-not (funcall hidden))
      ;; Answered: the next tick finds no wait and unregisters
      (remove-text-properties (point-min) (point-max) '(widgetry-activity-wait nil))
      (should-not (widgetry-activity--blink-tick (current-buffer)))
      (should-not widgetry-activity--blink)
      (should-not (assoc (cons 'widgetry-blink (current-buffer)) homun-clock--clients)))))

(ert-deftest widgetry-activity-latest-names-the-newest ()
  (let ((latest (widgetry-activity-latest widgetry-activity-test--events)))
    (should (equal "● edit " (substring-no-properties latest)))
    (should (= widgetry-activity-latest-width (string-width latest)))
    (should (eq 'widgetry-activity-edit (get-text-property 0 'face latest)))
    (should (eq 'widgetry-activity-edit (get-text-property 2 'face latest))))
  (should (equal "● idle " (substring-no-properties (widgetry-activity-latest nil))))
  ;; The dot of an unanswered wait blinks with its cell
  (should (get-text-property 0 'widgetry-activity-wait
                             (widgetry-activity-latest '((:kind wait :pending t)))))
  (should-not (get-text-property 0 'widgetry-activity-wait
                                 (widgetry-activity-latest '((:kind wait))))))

(ert-deftest widgetry-activity-blocks-grow-with-duration ()
  (let* ((events '((:kind read :time 100 :tool "Read") (:kind think) (:kind edit :time 130)
                   (:kind bash :time 140)))
         (blocks (widgetry-activity-blocks events 8 10 160)))
    ;; 80 s to 160 s: nothing for 20 s, reading for 30 s, an edit for 10 s, a command since
    (should (equal "··██████" (substring-no-properties blocks)))
    (should (equal '(widgetry-activity-idle widgetry-activity-idle
                     widgetry-activity-read widgetry-activity-read widgetry-activity-read
                     widgetry-activity-edit widgetry-activity-bash widgetry-activity-bash)
                   (mapcar (lambda (i) (get-text-property i 'face blocks)) (number-sequence 0 7))))
    (should (string-prefix-p "read · Read" (get-text-property 2 'help-echo blocks)))
    ;; Quiet for longer than IDLE-AFTER counts as idle
    (should (equal "··██·███" (substring-no-properties
                               (widgetry-activity-blocks events 8 10 160 20))))
    (should (equal "····" (substring-no-properties (widgetry-activity-blocks nil 4 10 160))))))

(provide 'widgetry-activity-test)
;;; widgetry-activity-test.el ends here

(ert-deftest widgetry-activity-pulse-runs-on-clock ()
  (let ((homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
        (widgetry-activity--pulses nil)
        (homun-clock-visible-function (lambda () t))
        (homun-clock-focused-function (lambda () t))
        (widgetry-flash-style 'invert) (widgetry-flash-time 0.0))
    (unwind-protect
        (with-temp-buffer
          (insert (propertize "x" 'widgetry-activity-newest t))
          (widgetry-activity-pulse (point-min) (point-max))
          (should (= 1 (length widgetry-activity--pulses)))
          (should (= 1 (homun-clock-timers)))
          (sleep-for 0.01)
          (homun-clock-tick)
          (should (null widgetry-activity--pulses))
          (should (null (overlays-in (point-min) (point-max))))
          (should (= 0 (homun-clock-timers))))
      (homun-clock--stop))))
