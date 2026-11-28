;;; claude-remote-report.el --- A remote cockpit reports its own trouble to the gateway -*- lexical-binding: t -*-

;; Remote management of a paired device (design 3.6b): the user never relays an error from a
;; phone by hand.  This Emacs sends, as telemetry actions over its authenticated gateway
;; connection, every error with its backtrace, *Warnings* entries, the new tail of *Messages*
;; and, once per start, its startup log.  The gateway keeps them per device and alarms the
;; manager once per new error signature.
;;
;;   errors     `debugger' is wrapped while `debug-on-error' is on: the wrapper records the
;;              error and its backtrace and returns, so the error goes on as before (the user's
;;              command stops as it always did, timers and filters carry on); nothing waits
;;   warnings   `display-warning' is advised
;;   messages   new lines of *Messages*, at most one batch a `claude-remote-report-interval'
;;   startup    *Messages* and *Warnings* as they were when the stream first came up
;;
;; Entries wait in a queue (capped) until the stream is up, so init errors from before it are
;; sent once connected.  An error signature (type and first line of the message) is sent once
;; a `claude-remote-report-interval'; repeats are counted and go with the next one.
;;
;; The gateway may also send this device commands (stream event device): check answers with
;; `claude-remote-report-status', a snapshot from a fixed allow-list of facts; upgrade runs
;; `homun-update' of the bootstrap block: fetch the files again and load them.

(require 'cl-lib)
(require 'subr-x)
(require 'backtrace)
(require 'json)

(declare-function claude-remote--request "claude-remote")
(declare-function homun-update "init")
(declare-function claude-remote--outbox "claude-remote")
(defvar claude-remote-connected)
(defvar claude-remote-device)
(defvar claude-remote--cursor)
(defvar homun-version)

(defcustom claude-remote-report-interval 60
  "Seconds between batches of *Messages*, and between two sends of one error
signature."
  :type 'integer :group 'claude-remote)

(defvar claude-remote-report--queue nil "Entries to send, newest first: plists of strings.")
(defconst claude-remote-report--queue-max 200)
(defvar claude-remote-report--sigs (make-hash-table :test #'equal) "Signature -> (TIME . REPEATS).")
(defvar claude-remote-report--sending nil)
(defvar claude-remote-report--inside nil "Non-nil while recording, so a fault here is not recorded.")
(defvar claude-remote-report--debugger nil "The `debugger' this wrapped.")
(defvar claude-remote-report--messages-pos nil "The end of *Messages* sent so far.")
(defvar claude-remote-report--startup-sent nil)
(defvar claude-remote-report--timer nil)

(defun claude-remote-report--push (type text &rest more)
  "Queue an entry of TYPE with TEXT and the string plist MORE, then try to send."
  (push (append (list :type type :text text) more) claude-remote-report--queue)
  (when (> (length claude-remote-report--queue) claude-remote-report--queue-max)
    (setq claude-remote-report--queue (seq-take claude-remote-report--queue claude-remote-report--queue-max)))
  (when (bound-and-true-p claude-remote-connected) (run-at-time 0 nil #'claude-remote-report-flush)))

(defun claude-remote-report-flush ()
  "Send the queued entries, oldest first, while the gateway answers."
  (when (and claude-remote-report--queue (not claude-remote-report--sending)
             (fboundp 'claude-remote--request) (bound-and-true-p claude-remote-connected))
    (let ((entry (car (last claude-remote-report--queue))))
      (setq claude-remote-report--sending t)
      (claude-remote--request
       "POST" "act"
       (list :id (format "%s-t%s" claude-remote-device (format-time-string "%s%N"))
             :ts (floor (float-time)) :kind "telemetry" :args entry :argv [])
       (lambda (reply)
         (setq claude-remote-report--sending nil)
         (when (and (car reply) (< (car reply) 500))
           ;; sent, or refused for good: either way it leaves the queue
           (setq claude-remote-report--queue (delq entry claude-remote-report--queue))
           (claude-remote-report-flush)))))))

;;; Errors

(defun claude-remote-report--sig (err)
  (format "%s: %s" (car-safe err) (truncate-string-to-width (error-message-string err) 120)))

(defun claude-remote-report-error (err &optional backtrace)
  "Record the error ERR (a condition) with the text BACKTRACE."
  (let* ((sig (claude-remote-report--sig err))
         (seen (gethash sig claude-remote-report--sigs)))
    (if (and seen (< (- (float-time) (car seen)) claude-remote-report-interval))
        (setcdr seen (1+ (cdr seen)))
      (puthash sig (cons (float-time) 0) claude-remote-report--sigs)
      (apply #'claude-remote-report--push "error"
             (concat sig "\n" (or backtrace ""))
             :sig (secure-hash 'sha1 sig)
             (and seen (> (cdr seen) 0) (list :count (number-to-string (1+ (cdr seen)))))))))

(defun claude-remote-report--debugger-fn (&rest args)
  "Record an error or a `debug' call with its backtrace, then return.
A phone has no keyboard to leave the debugger with, so nothing is ever handed to
the old one: the error goes on as unhandled by us, and a plain `debug' call just
returns."
  (unless claude-remote-report--inside
    (let ((claude-remote-report--inside t) (debug-on-error nil) (inhibit-quit t))
      (ignore-errors
        (claude-remote-report-error
         (if (eq (car args) 'error) (cadr args) (list 'debug (format "%S" args)))
         (truncate-string-to-width
          (backtrace-to-string (backtrace-get-frames #'claude-remote-report--debugger-fn))
          8000)))))
  nil)

;;; Warnings and messages

(defun claude-remote-report--warning (type message &optional level _buffer)
  ;; the byte compiler's notes while package.el installs are noise; its errors are not
  (unless (or claude-remote-report--inside
              (and (eq (if (consp type) (car type) type) 'bytecomp) (not (eq level :error))))
    (let ((claude-remote-report--inside t))
      (ignore-errors
        (claude-remote-report--push "warning" (format "%s %S: %s" (or level :warning) type message))))))

(defun claude-remote-report--buffer-text (name &optional from)
  (when-let* ((buf (get-buffer name)))
    (with-current-buffer buf
      (let ((start (max (point-min) (or from (- (point-max) 8000)))))
        (buffer-substring-no-properties start (point-max))))))

(defun claude-remote-report--messages ()
  "Queue the lines added to *Messages* since the last batch, once each."
  (when-let* ((buf (get-buffer "*Messages*")))
    (let* ((end (with-current-buffer buf (point-max)))
           (from (and claude-remote-report--messages-pos
                      (<= claude-remote-report--messages-pos end) claude-remote-report--messages-pos)))
      (when (and from (> end from))
        (let ((lines (delete-dups (split-string (claude-remote-report--buffer-text "*Messages*" (max from (- end 8000)))
                                                "\n" t))))
          (claude-remote-report--push "messages" (string-join lines "\n"))))
      (setq claude-remote-report--messages-pos end))))

(defun claude-remote-report--connected ()
  "The stream is up: send the startup log once, then what waited."
  (unless claude-remote-report--startup-sent
    (setq claude-remote-report--startup-sent t)
    (claude-remote-report--push
     "startup"
     (format "init %s\n--- *Warnings*\n%s\n--- *Messages*\n%s" (emacs-init-time)
             (or (claude-remote-report--buffer-text "*Warnings*") "")
             (or (claude-remote-report--buffer-text "*Messages*") "")))
    (setq claude-remote-report--messages-pos
          (when-let* ((buf (get-buffer "*Messages*"))) (with-current-buffer buf (point-max))))
    (claude-remote-report-status))
  (claude-remote-report-flush))

;;; Status and commands

(defun claude-remote-report--facts ()
  "The device's status: a fixed allow-list of facts, nothing else."
  `((time . ,(format-time-string "%FT%TZ" nil t))
    (emacs . ,emacs-version)
    (system . ,system-configuration)
    (android . ,(and (eq system-type 'android) (boundp 'android-build-fingerprint)
                     (symbol-value 'android-build-fingerprint)))
    (homun . ,(bound-and-true-p homun-version))
    (connected . ,(if (bound-and-true-p claude-remote-connected) t :false))
    (cursor . ,(or (bound-and-true-p claude-remote--cursor) ""))
    (outbox . ,(length (and (fboundp 'claude-remote--outbox) (claude-remote--outbox))))
    (queued . ,(length claude-remote-report--queue))
    (init_time . ,(emacs-init-time))
    (reporting . ,(if (and debug-on-error (eq debugger #'claude-remote-report--debugger-fn)) t :false))
    (uptime . ,(emacs-uptime))
    (frame . ,(format "%sx%s" (frame-width) (frame-height)))
    (buttons . ,(when-let* ((w (and (fboundp 'widgetry-buttons-measure)
                                     (get-buffer-window "*claude-transcript*" t))))
                  (format "%S" (widgetry-buttons-measure w))))))

(defun claude-remote-report-status ()
  "Send this device's status snapshot."
  (interactive)
  (claude-remote-report--push "status" (json-encode (claude-remote-report--facts))))

(defun claude-remote-report--command (kind _source data)
  "Act on a gateway command for this device: check or upgrade, nothing else."
  (when (equal kind "device")
    (pcase (plist-get data :cmd)
      ("check" (claude-remote-report-status))
      ("upgrade"
       (condition-case err
           (progn (homun-update)
                  (claude-remote-report--push "upgrade" (format "updated to %s" (bound-and-true-p homun-version))))
         (error (claude-remote-report--push "upgrade" (format "upgrade failed: %s" (error-message-string err)))))
       (claude-remote-report-status)))))

;;;###autoload
(defun claude-remote-report-start ()
  "Start reporting this Emacs's trouble to the gateway."
  ;; startup restores `debug-on-error' after init: take it again once Emacs is up
  (unless after-init-time (add-hook 'emacs-startup-hook #'claude-remote-report-start))
  (unless (eq debugger #'claude-remote-report--debugger-fn)
    (setq claude-remote-report--debugger debugger debugger #'claude-remote-report--debugger-fn))
  (setq debug-on-error t)
  (advice-add 'display-warning :before #'claude-remote-report--warning)
  (add-hook 'claude-remote-record-functions #'claude-remote-report--command)
  (add-hook 'claude-remote-connected-hook #'claude-remote-report--connected)
  (unless (timerp claude-remote-report--timer)
    (setq claude-remote-report--timer
          (run-at-time claude-remote-report-interval claude-remote-report-interval #'claude-remote-report--messages))))

(defun claude-remote-report-stop ()
  "Stop reporting."
  (when (eq debugger #'claude-remote-report--debugger-fn)
    (setq debugger (or claude-remote-report--debugger #'debug)))
  (setq debug-on-error nil)
  (advice-remove 'display-warning #'claude-remote-report--warning)
  (when (timerp claude-remote-report--timer) (cancel-timer claude-remote-report--timer))
  (setq claude-remote-report--timer nil))

(provide 'claude-remote-report)
;;; claude-remote-report.el ends here
