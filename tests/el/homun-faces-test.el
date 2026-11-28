;;; homun-faces-test.el --- faces inherit the theme, no fixed hex colours  -*- lexical-binding: t -*-
(require 'ert)
(require 'claude-transcript)
(require 'claude-follow)
(require 'claude-phone)
(require 'homun-stage)

(ert-deftest homun-faces-no-hex-in-themed-faces ()
  (dolist (f '(claude-transcript-you-body claude-transcript-you-header
               claude-transcript-claude-body claude-transcript-claude-header
               claude-follow-recent homun-stage-stale
               claude-phone-meter-ok claude-phone-meter-warn claude-phone-meter-bad))
    (should (facep f))
    (should-not (string-match-p "\"#[0-9a-fA-F]\\{6\\}\"" (format "%S" (face-default-spec f))))))

(ert-deftest homun-faces-inherit-standard ()
  (should (memq 'secondary-selection
                (ensure-list (face-attribute 'claude-follow-recent :inherit nil))))
  (should (eq 'error (face-attribute 'homun-stage-stale :inherit nil)))
  (should (eq 'success (face-attribute 'claude-phone-meter-ok :inherit nil))))

(ert-deftest homun-faces-phone-theme-reads-the-theme ()
  (let ((claude-phone-frame nil))
    (claude-phone-theme (selected-frame))
    (should (eq claude-phone-frame (selected-frame)))
    (should (stringp (face-attribute 'widgetry-tag :background (selected-frame))))))

(provide 'homun-faces-test)
