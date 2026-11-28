;;; homun-scroll.el --- Smooth scrolling for the desktop cockpit -*- lexical-binding: t -*-

;; Pixel-precise wheel and touchpad scrolling with momentum, and interpolated page scrolling,
;; stepped every 4 ms so frames are limited by redisplay (about 2 ms on the big transcript, which
;; keeps 120 Hz and more).  pgtk has no frame-synchronization switch: GTK paints on the Wayland
;; frame clock.  The phone has its own touch glide (`claude-remote-momentum-setup') and is left alone.

;;; Code:

(require 'pixel-scroll)

(defcustom homun-smooth-scroll t
  "Non-nil: smooth, interpolated scrolling on the desktop."
  :type 'boolean
  :group 'homun)

(defconst homun-smooth-scroll-remaps
  '((scroll-up-command . pixel-scroll-interpolate-down)
    (scroll-down-command . pixel-scroll-interpolate-up)
    (evil-scroll-page-down . pixel-scroll-interpolate-down)
    (evil-scroll-page-up . pixel-scroll-interpolate-up))
  "Page-scroll commands and their interpolated replacements.")

(defun homun-smooth-scroll-apply ()
  "Turn smooth scrolling on or off from `homun-smooth-scroll'; never on Android."
  (let ((on (and homun-smooth-scroll (not (eq system-type 'android)))))
    (setq pixel-scroll-precision-use-momentum on
          pixel-scroll-precision-interpolate-page on
          pixel-scroll-precision-interpolation-between-scroll 0.004
          pixel-scroll-precision-interpolation-total-time 0.1
          pixel-scroll-precision-interpolation-factor 2.0)
    (pixel-scroll-precision-mode (if on 1 -1))
    (pcase-dolist (`(,from . ,to) homun-smooth-scroll-remaps)
      (define-key global-map (vector 'remap from) (and on to)))))

(homun-smooth-scroll-apply)

(provide 'homun-scroll)
;;; homun-scroll.el ends here
