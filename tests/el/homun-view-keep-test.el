;;; homun-view-keep-test.el --- re-renders keep point and window start  -*- lexical-binding: t -*-
(require 'ert)
(require 'homun-api)
(require 'homun-stage-store)
(require 'claude-compose)

(ert-deftest homun-view-stage-render-keeps-point ()
  (let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
         (homun-stage-scenes (make-hash-table :test #'equal))
         (homun-api-log-file (make-temp-file "api-log"))
         (root '((type . "col") (id . "root")
                 (children . (((type . "text") (id . "a") (text . "first"))
                              ((type . "text") (id . "b") (text . "second line"))
                              ((type . "text") (id . "c") (text . "third")))))))
    (unwind-protect
        (save-window-excursion
          (homun-stage-show "x" "keep" "Keep" root "pinned")
          (let ((s (homun-stage-scene "keep")) (buf (get-buffer "*stage keep*")))
            (switch-to-buffer buf)
            (goto-char (point-min)) (forward-line 1) (forward-char 3)
            (let ((line (line-number-at-pos)) (col (current-column)))
              (homun-stage-render s)
              (should (= line (line-number-at-pos (window-point))))
              (should (= col (save-excursion (goto-char (window-point)) (current-column)))))))
      (when-let* ((b (get-buffer "*stage keep*"))) (kill-buffer b))
      (delete-directory homun-stage-dir t))))

(ert-deftest homun-view-compose-same-text-is-untouched ()
  (with-temp-buffer
    (insert "hello world")
    (goto-char 3)
    (claude-compose--set-input "hello world")
    (should (= (point) 3))
    (claude-compose--set-input "other")
    (should (equal (buffer-string) "other"))))

(provide 'homun-view-keep-test)
