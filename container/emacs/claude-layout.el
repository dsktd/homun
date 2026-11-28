;;; claude-layout.el --- Old names of homun-layout.el -*- lexical-binding: t -*-

;; The cockpit layout is `homun-layout'.  This keeps the old feature, command, function and
;; setting names working until their callers are gone.  The old slots map onto regions:
;; main is the transcript, slate is the stage.

(require 'homun-layout)

(dolist (pair '((claude-layout-apply . homun-layout-apply)
                (claude-layout-restore . homun-layout-restore)
                (claude-layout-focus-toggle . homun-layout-focus-toggle)
                (claude-layout-show . homun-layout-show)
                (claude-layout-pop . homun-layout-pop)
                (claude-layout--place . homun-layout-show)
                (claude-layout-lock-apply . homun-layout-lock-apply)
                (claude-layout-save-to-file . homun-layout-save-to-file)
                (claude-layout-narrow-view . homun-layout-narrow-view)
                (claude-layout-narrow-tabs . homun-layout-narrow-tabs)
                (claude-layout--build . homun-layout--build)
                (claude-layout--pick . homun-layout--pick)
                (claude-layout--shape . homun-layout--shape)
                (claude-layout--keep . homun-layout--keep)))
  (defalias (car pair) (cdr pair)))

(dolist (pair '((claude-layout-lock . homun-layout-lock)
                (claude-layout-compose-lines . homun-layout-compose-lines)
                (claude-layout-narrow-columns . homun-layout-narrow-columns)
                (claude-layout-narrow-margin . homun-layout-narrow-margin)
                (claude-layout-orientation . homun-layout-orientation)
                (claude-layout-portrait-enter . homun-layout-portrait-enter)
                (claude-layout-portrait-leave . homun-layout-portrait-leave)
                (claude-layout-settle-seconds . homun-layout-settle-seconds)
                (claude-layout-lock-mode-line . homun-layout-lock-mode-line)))
  ;; A daemon that ran the old file keeps its values (settings included)
  (unless (eq (indirect-variable (car pair)) (cdr pair))
    (when (boundp (car pair))
      (set (cdr pair) (symbol-value (car pair)))
      (makunbound (car pair)))
    (defvaralias (car pair) (cdr pair))))

(homun-layout-adopt-slots)

(defun claude-layout--windows (&optional frame)
  "The region windows of FRAME as (SLOT . WINDOW), by the old slot names."
  (mapcar (lambda (r) (cons (or (car (rassq (car r) homun-layout-old-names)) (car r)) (cdr r)))
          (homun-layout--windows frame)))

(provide 'claude-layout)
;;; claude-layout.el ends here
