;;; claude-gc.el --- When the cockpit collects garbage: once the user pauses -*- lexical-binding: t -*-

;; One collection of the cockpit's heap is a pause of about 0.1 s whatever was allocated.
;; At Emacs's stock threshold (800 kB, also what gcmh falls back to between commands) the
;; timers, file watches and server calls trigger one every few seconds, which shows as
;; hitches while typing (13 a minute measured, 2026-11-23).  So: a threshold timers do not
;; reach for a long while, and gcmh's own collection a fixed few seconds after the last
;; command.  Both flavours load this from cockpit.el; Doom sets gcmh up before its
;; config.el, so these values are the later ones.

;;; Code:

(defconst claude-gc-idle-threshold (* 32 1024 1024)
  "Bytes allocated between two collections outside a command.")

(defconst claude-gc-idle-delay 5
  "Seconds after the last command before gcmh collects.")

(defvar gcmh-low-cons-threshold)
(defvar gcmh-high-cons-threshold)
(defvar gcmh-idle-delay)
(declare-function gcmh-mode "gcmh")

(defun claude-gc-apply ()
  "Set the collection thresholds, through gcmh when the configuration has it."
  (if (not (require 'gcmh nil t))
      (setq gc-cons-threshold claude-gc-idle-threshold)
    (setq gcmh-low-cons-threshold claude-gc-idle-threshold
          gcmh-high-cons-threshold (* 2 claude-gc-idle-threshold)
          gcmh-idle-delay claude-gc-idle-delay)
    (gcmh-mode 1)))

(claude-gc-apply)

(provide 'claude-gc)
;;; claude-gc.el ends here
