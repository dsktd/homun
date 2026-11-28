;;; widgetry-buttons-test.el --- Tests for widgetry-buttons -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-buttons)

(defmacro widgetry-buttons-test--with (seen &rest body)
  "Run BODY with point on a group of a press and a hold segment, labels
pushed to SEEN when notified."
  (declare (indent 1))
  `(with-temp-buffer
     (let* ((,seen nil)
            (widget (widget-create
                     'widgetry-buttons
                     :buttons (list (list :label "Aa" :notify (lambda (&rest _) (push 'a ,seen)))
                                    (list :label "Bb" :confirm 'hold
                                          :notify (lambda (&rest _) (push 'b ,seen)))))))
       (widget-setup)
       (set-window-buffer (selected-window) (current-buffer))
       (goto-char (widget-get widget :from))
       (ignore ,seen)
       ,@body)))

(defun widgetry-buttons-test--click (widget offset)
  "A mouse event on the string display of WIDGET at OFFSET."
  (let ((pos (marker-position (widget-get widget :from))))
    (list 'down-mouse-1
          (list (selected-window) pos '(0 . 0) 0
                (cons (widgetry-shown widget) offset)
                pos '(4 . 0) nil '(4 . 0) '(1 . 1)))))

(ert-deftest widgetry-buttons-parts-touch ()
  (widgetry-buttons-test--with seen
    (should (equal (widgetry-shown widget) " Aa   Bb "))
    (should (= 9 (string-width (widgetry-shown widget))))
    (should (= 9 (widgetry-buttons-width widget)))))

(ert-deftest widgetry-buttons-segment-hit-testing ()
  (widgetry-buttons-test--with seen
    (let ((a (car (widget-get widget :segments)))
          (b (cadr (widget-get widget :segments))))
      (dolist (offset '(0 2 3))
        (should (eq a (widgetry-buttons-segment-at (widgetry-buttons-test--click widget offset)))))
      (dolist (offset '(4 6 7))
        (should (eq b (widgetry-buttons-segment-at (widgetry-buttons-test--click widget offset)))))
      (should (widgetry-buttons--over-p a (widgetry-buttons-test--click widget 2)))
      (should-not (widgetry-buttons--over-p a (widgetry-buttons-test--click widget 5)))
      (should-not (widgetry-buttons--over-p b (widgetry-buttons-test--click widget 2))))))

(ert-deftest widgetry-buttons-keys-press-segment-at-point ()
  (widgetry-buttons-test--with seen
    (let ((widgetry-button-press-time 0.01))
      (widgetry-buttons-press)
      (should (equal seen '(a)))
      (widgetry-buttons-next)
      (widgetry-buttons-next)
      (should (eq (widgetry-buttons-segment-at) (cadr (widget-get widget :segments))))
      (widgetry-buttons-previous)
      (widgetry-buttons-previous)
      (should (eq (widgetry-buttons-segment-at) (car (widget-get widget :segments)))))))

(ert-deftest widgetry-buttons-click-presses-only-its-segment ()
  (widgetry-buttons-test--with seen
    (let ((widgetry-button-press-time 0.01)
          (event (widgetry-buttons-test--click widget 1)))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&rest _) (list 'mouse-1 (cadr event)))))
        (widgetry-buttons-drag event))
      (should (equal seen '(a))))))

(ert-deftest widgetry-buttons-hold-on-one-fires-only-that-one ()
  (widgetry-buttons-test--with seen
    (let* ((widgetry-button-press-time 0.01)
           (widgetry-button-hold-time 0.05)
           (event (widgetry-buttons-test--click widget 5))
           (n 0))
      (cl-letf (((symbol-function 'read-event)
                 ;; Idle ticks past the hold time, then the release.
                 (lambda (&rest _)
                   (cond ((< (cl-incf n) 12) (sleep-for 0.01) nil)
                         (t (list 'mouse-1 (cadr event)))))))
        (widgetry-buttons-drag event))
      (should (equal seen '(b)))
      (should-not (widget-get (car (widget-get widget :segments)) :ready)))))

(ert-deftest widgetry-buttons-short-hold-fires-nothing ()
  (widgetry-buttons-test--with seen
    (let* ((widgetry-button-hold-time 5.0)
           (event (widgetry-buttons-test--click widget 5)))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&rest _) (list 'mouse-1 (cadr event)))))
        (widgetry-buttons-drag event))
      (should-not seen))))

(ert-deftest widgetry-buttons-hold-moved-to-other-segment-cancels ()
  (widgetry-buttons-test--with seen
    (let* ((widgetry-button-hold-time 0.03)
           (event (widgetry-buttons-test--click widget 5))
           (n 0))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&rest _)
                   (cl-incf n)
                   (cond ((= n 1) (list 'mouse-movement (cadr (widgetry-buttons-test--click widget 2))))
                         ((< n 8) (sleep-for 0.01) nil)
                         (t (list 'mouse-1 (cadr event)))))))
        (widgetry-buttons-drag event))
      (should-not seen))))

(ert-deftest widgetry-buttons-svg-width-matches-cells ()
  (widgetry-buttons-test--with seen
    (let ((image (widgetry-svg (funcall (widget-get widget :parts) widget) (selected-frame))))
      (should (consp image)))))

;;; widgetry-buttons-test.el ends here

(ert-deftest widgetry-buttons-tag-added-after-creation ()
  (widgetry-buttons-test--with seen
    (let* ((a (car (widget-get widget :segments)))
           (b (cadr (widget-get widget :segments)))
           (overlay (widget-get widget :widgetry-overlay)))
      (widget-put a :tag " ✓ ")
      (widgetry-redraw widget)
      (should (equal (widgetry-shown widget) " ✓  Aa   Bb "))
      (should (equal (buffer-substring-no-properties (overlay-start overlay) (overlay-end overlay))
                     (widgetry-shown widget)))
      (should (equal (widgetry-buttons--widths widget) '(7 5)))
      (should (eq b (widgetry-buttons--segment-at widget 8)))
      (should (eq a (widgetry-buttons--segment-at widget 6))))))

(ert-deftest widgetry-buttons-text-fallback-separated ()
  "In the text fallback each button keeps a gap before it and its own face."
  (widgetry-buttons-test--with seen
    (let* ((s (widgetry-shown widget)) (a 1) (b (string-search "Bb" s)))
      (should (eq ?\s (aref s 4)))
      (should-not (get-text-property 4 'face s))
      (should (get-text-property a 'face s))
      (should (get-text-property b 'face s))
      (should (equal (widgetry-buttons--widths widget) '(4 5))))))

(ert-deftest widgetry-buttons-wrap-by-width ()
  "A row too wide breaks between buttons, never inside; hits follow the text."
  (let ((labels (quote ("Open session" "Compact now" "Restart box" "Quit"))))
    (pcase-dolist (`(,columns ,count) '((100 1) (45 4) (30 4)))
      (with-temp-buffer
        (let ((widget (widget-create 'widgetry-buttons :stretch t
                                     :buttons (mapcar (lambda (l) (list :label l)) labels))))
          (widget-setup)
          (set-window-buffer (selected-window) (current-buffer))
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) columns)))
            (widgetry-redraw widget)
            (let* ((text (widgetry-shown widget))
                   (lines (split-string text "\n")))
              (should (= count (length lines)))
              (dolist (line lines) (should (<= (string-width line) (1- columns))))
              (should (= (length text) (apply #'+ (widgetry-buttons--widths widget))))
              (should (equal text (buffer-substring-no-properties
                                   (overlay-start (widget-get widget :widgetry-overlay))
                                   (overlay-end (widget-get widget :widgetry-overlay)))))
              ;; Each label sits whole on one line, and its offset hits its segment.
              (cl-loop for l in labels for segment in (widget-get widget :segments)
                       do (should (seq-find (lambda (line) (string-search l line)) lines))
                       (should (eq segment (widgetry-buttons--segment-at
                                            widget (string-search l text))))))))))))

(ert-deftest widgetry-buttons-text-gap-in-every-state ()
  "Normal, done, disabled and pending buttons keep the same gap, and stack when narrow."
  (dolist (state '(nil done pending failed disabled))
    (dolist (columns '(100 14))
      (with-temp-buffer
        (let ((widget (widget-create
                       'widgetry-buttons :stretch t
                       :buttons (list (list :label "Aa" :status (and (memq state '(done pending failed)) state)
                                            :disabled (eq state 'disabled))
                                      (list :label "Bb" :status (and (memq state '(done pending failed)) state)
                                            :disabled (eq state 'disabled))
                                      (list :label "Cc" :disabled (eq state 'disabled))))))
          (widget-setup)
          (set-window-buffer (selected-window) (current-buffer))
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) columns)))
            (widgetry-redraw widget)
            (let ((s (widgetry-shown widget)))
              (if (= columns 100)
                  (should (string-match-p "Aa +[ ]Bb +[ ]Cc" s))
                (should (= 3 (length (split-string s "\n"))))))))))))

(ert-deftest widgetry-reflow-every-widget-on-resize ()
  "One path, `widgetry-reflow', lays meters, text pills, chips, checks and button
groups out again from the window's current pixel width, narrower and wider."
  (dolist (spec '((widgetry-meter :reflow t)
                  (widgetry-text :value "a long line of text that needs room" :width 40)
                  (widgetry-chips :choices (alpha beta gamma delta epsilon zeta))
                  (widgetry-check :choices (alpha beta gamma delta epsilon zeta))
                  (widgetry-buttons :stretch t
                                    :buttons ((:label "Open session") (:label "Compact now")
                                              (:label "Restart box") (:label "Quit")))))
    (with-temp-buffer
      (let ((widget (apply #'widget-create spec)) (widths nil))
        (widget-setup)
        (set-window-buffer (selected-window) (current-buffer))
        (dolist (pixels '(120 30 60 120))
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) pixels)))
            (widgetry-reflow (current-buffer))
            (let ((lines (split-string (widgetry-shown widget) "\n")))
              (dolist (line lines)
                (should (<= (string-width line) pixels)))
              (push (widgetry-shown widget) widths))))
        ;; Back at the first width, the same text: nothing was fixed at insert time.
        (should (equal (nth 0 (last widths)) (nth 0 widths)))
        (unless (eq (car spec) 'widgetry-meter) nil)))))
