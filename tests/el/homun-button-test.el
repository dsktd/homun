;;; homun-button-test.el --- ERT for the button keymap -*- lexical-binding: t -*-

(require 'ert)
(require 'homun-button)

(ert-deftest homun-button-touch-binds-every-line ()
  "On the phone a tap in the header, tab or mode line runs the button itself."
  (let ((map (homun-button--keymap #'ignore t)))
    (dolist (line '(header-line tab-line mode-line))
      (should (commandp (lookup-key map (vector line 'touchscreen-begin)))))))

(provide 'homun-button-test)
