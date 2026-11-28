;;; claude-errwatch.el --- errors in the cockpit, handled or sent to the mechanic  -*- lexical-binding: t; -*-

;; Watches the daemon for errors: commands, process filters and sentinels (Emacs hands all
;; three to `command-error-function'), timers (`timer-event-handler' only `message's them, and
;; under `debug-on-error' calls the debugger, so each timer function is wrapped around the run)
;; and `display-warning' at :warning or :error.
;;
;; Each occurrence counts against a signature: kind, source (the function that ran), the error
;; symbol and the shape of the error data (functions as their arity, numbers and objects
;; blanked), so a closure printed differently each time is still one signature.  The 1st, 10th,
;; 100th... occurrence is a line in ~/claude/.services/emacs/errors.jsonl (rotated at 1 MiB)
;; with the innermost frames.  The first occurrence of a signature is handled at once; repeats
;; only bump its count.  Handling, without an LLM:
;;
;; - stale: `wrong-number-of-arguments' or `void-function' in Homun code within 10 minutes of
;;   loading Homun code is an advice or caller left from the old definitions: the Homun files
;;   of the source and the frames are loaded again, dependencies first, once per signature.
;;   The same signature again afterwards is a failed repair.
;; - runaway: a timer that errors more than `claude-errwatch-runaway-per-minute' times in a
;;   minute is cancelled, in *Messages* and in errors.jsonl as kind "timer-cancelled".
;; - anything else that is an error goes to the mechanic as one repair request per signature,
;;   at most 10 an hour (a held one stays in the list as unsent).  Warnings are counted, not sent.
;;
;; A failed repair raises one `emacs-error' alarm to the manager.  The watch never runs inside
;; itself and turns itself off after 3 failures of its own, saying so.

;;; Code:

(require 'homun-proc)
(require 'cl-lib)
(require 'subr-x)
(require 'nadvice)

(defconst claude-errwatch-file (expand-file-name "~/claude/.services/emacs/errors.jsonl")
  "Where occurrences are appended.")

(defconst claude-errwatch-rotate-bytes (* 1024 1024))
(defconst claude-errwatch-hourly-sends 10 "Sends in any hour, all signatures together.")
(defconst claude-errwatch-stale-window 600 "Seconds after a Homun load a stale error counts.")
(defvar claude-errwatch-runaway-per-minute 20 "Errors a minute after which a timer is cancelled.")

(defconst claude-errwatch-homun-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The directory of the cockpit's Elisp: what counts as Homun code.")

(defvar claude-errwatch-send-function #'claude-errwatch--send-mechanic
  "Called with the report text of a signature to send.  The one place the transport
lives.")
(defvar claude-errwatch-alarm-function #'claude-errwatch--alarm-manager
  "Called with the text of a failed auto-repair.")

(defvar claude-errwatch--signatures (make-hash-table :test #'equal)
  "Signature (kind source error-symbol shape) to a plist :count :first :last :sent
:file :where :example :frames :handled.")
(defvar claude-errwatch--times nil "Occurrence times, newest first, the last hour's.")
(defvar claude-errwatch--sends nil "Send times, newest first, the last hour's.")
(defvar claude-errwatch--timer-errors (make-hash-table :test #'eq :weakness 'key)
  "Timer to its error times in the last minute, newest first.")
(defvar claude-errwatch--last-load nil "When Homun code was last loaded, or nil.")
(defvar claude-errwatch--busy nil "Non-nil while the watch itself runs.")
(defvar claude-errwatch--failures 0)
(defvar claude-errwatch--on nil "Non-nil while the watch is started.")
(defvar claude-errwatch--previous-command-error nil
  "The `command-error-function' the watch wraps.")
(defvar claude-errwatch--rev nil)

;;; Names and shapes

(defun claude-errwatch--normalize (text)
  "TEXT with the parts that change between occurrences blanked, at most 200 chars."
  (let ((s (replace-regexp-in-string "#<[^>]*>" "#<>" text t t)))
    (setq s (replace-regexp-in-string "0x[0-9a-f]+\\|[0-9]+" "N" s t t))
    (truncate-string-to-width s 200)))

(defun claude-errwatch--rev ()
  (or claude-errwatch--rev
      (setq claude-errwatch--rev
            (or (ignore-errors
                  (let ((default-directory (expand-file-name "~/claude/_tools/homun/")))
                    (let ((r (homun-proc-sync "git" '("rev-parse" "--short" "HEAD") nil 5)))
                      (and (eql 0 (car r)) (car (split-string (cdr r) "\n" t))))))
                "unknown"))))

(defun claude-errwatch--fn-name (fn &optional width)
  "FN's symbol name; an anonymous function as #[MIN-MAX] (its printed form
names nothing and changes with every closure); else FN printed, cut to WIDTH."
  (cond ((symbolp fn) (symbol-name fn))
        ((functionp fn)
         (let ((a (func-arity fn)))
           (format "#[%s-%s]" (car a) (if (numberp (cdr a)) (cdr a) "&rest"))))
        (t (truncate-string-to-width (replace-regexp-in-string "[[:space:]\n]+" " " (format "%S" fn))
                                     (or width 200)))))

(defun claude-errwatch--shape (data)
  "The error DATA as its symbol and the shape of its arguments, a string."
  (if (stringp data) (claude-errwatch--normalize data)
    (mapconcat (lambda (x) (cond ((stringp x) (claude-errwatch--normalize x))
                                 ((or (symbolp x) (functionp x)) (claude-errwatch--fn-name x))
                                 ((numberp x) "N")
                                 (t (symbol-name (type-of x)))))
               (ensure-list (cdr data)) " ")))

(defun claude-errwatch--message (data)
  "DATA (an error or a warning's text) as one short line.
Functions show by name or arity."
  (if (stringp data) data
    (let ((print-length 4) (print-level 2))
      (format "%s: %s" (car data)
              (mapconcat (lambda (x) (if (and (functionp x) (not (symbolp x)))
                                         (claude-errwatch--fn-name x)
                                       (format "%S" x)))
                         (ensure-list (cdr data)) ", ")))))

(defun claude-errwatch--frames ()
  "The first 8 frames of the caller, innermost first, as names.
Frames of the watch (and of the handler that called this) are left out."
  (let ((names nil))
    (mapbacktrace (lambda (_evald fun _args _flags) (push (claude-errwatch--fn-name fun 80) names)))
    (seq-take (seq-remove (lambda (n) (or (string-prefix-p "claude-errwatch" n)
                                          (string-prefix-p "#[" n)
                                          (member n '("apply" "funcall" "mapbacktrace"
                                                      "handler-bind-1" "condition-case" "let"))))
                          (nreverse names))
              8)))

(defun claude-errwatch--homun-file (name)
  "The Homun source file defining the function NAME, or nil."
  (when-let* ((sym (intern-soft name))
              ((fboundp sym))
              (file (ignore-errors (symbol-file sym 'defun)))
              (el (expand-file-name (concat (file-name-base file) ".el") claude-errwatch-homun-dir))
              ((file-exists-p el)))
    el))

(defun claude-errwatch--source-file (source)
  "FILE of the definition of SOURCE (a name) when Emacs knows it, else nil."
  (when-let* ((sym (intern-soft source))
              ((fboundp sym))
              (file (ignore-errors (symbol-file sym 'defun))))
    (abbreviate-file-name (string-remove-suffix "c" file))))

;;; Recording

(defun claude-errwatch--prune (times &optional seconds)
  (let ((since (- (float-time) (or seconds 3600))))
    (seq-take-while (lambda (t0) (> t0 since)) times)))

(defun claude-errwatch--append (record)
  (let ((file claude-errwatch-file))
    (make-directory (file-name-directory file) t)
    (when (> (or (file-attribute-size (file-attributes file)) 0) claude-errwatch-rotate-bytes)
      (rename-file file (concat file ".1") t))
    (write-region (concat (json-serialize record) "\n") nil file t 'silent)))

(defun claude-errwatch--line (kind source message frames count)
  "One errors.jsonl record."
  `((ts . ,(format-time-string "%FT%T%z")) (kind . ,kind) (source . ,source)
    (message . ,(truncate-string-to-width message 500)) (count . ,count)
    (frames . ,(vconcat frames)) (file . ,(or (claude-errwatch--source-file source) :null))
    ;; the buffer current at the error names a fileless revert or a dead-buffer race
    (buffer . ,(buffer-name)) (mode . ,(symbol-name major-mode))
    (rev . ,(claude-errwatch--rev))))

(defun claude-errwatch--report-text (kind source entry &optional prefix)
  (truncate-string-to-width
   (format "%serrwatch: %s error in %s%s [buffer %s], %d time%s: %s; frames: %s"
           (or prefix "") kind source
           (if-let* ((f (plist-get entry :file))) (format " (%s)" f) "")
           (plist-get entry :where) (plist-get entry :count)
           (if (= (plist-get entry :count) 1) "" "s")
           (replace-regexp-in-string "[[:cntrl:]]+" " " (plist-get entry :example))
           (string-join (seq-take (plist-get entry :frames) 5) " < "))
   900))

(defun claude-errwatch--send (sig entry)
  "Send ENTRY of SIG to the mechanic unless the hour's sends are used up.
A held entry stays unsent in the list."
  (setq claude-errwatch--sends (claude-errwatch--prune claude-errwatch--sends))
  (when (< (length claude-errwatch--sends) claude-errwatch-hourly-sends)
    (push (float-time) claude-errwatch--sends)
    (plist-put entry :sent (float-time))
    (funcall claude-errwatch-send-function
             (claude-errwatch--report-text (nth 0 sig) (nth 1 sig) entry))))

(defun claude-errwatch-record (kind source data &optional frames)
  "Note an error of KIND (a string) from SOURCE (a string or nil).
DATA is the error, or a warning's text; FRAMES the caller's.  The first of a
signature is handled.  Return the signature's entry."
  (when (and claude-errwatch--on (not claude-errwatch--busy))
    (let ((claude-errwatch--busy t))
      (condition-case err
          (let* ((source (or source (car frames) "unknown"))
                 (sig (list kind source (and (consp data) (car data)) (claude-errwatch--shape data)))
                 (now (float-time))
                 (message (claude-errwatch--message data))
                 (entry (or (gethash sig claude-errwatch--signatures)
                            (puthash sig (list :count 0 :first now :last now :sent nil
                                               :file (claude-errwatch--source-file source)
                                               :where (format "%s, %s" (buffer-name) major-mode)
                                               :example (truncate-string-to-width message 300)
                                               :frames frames :handled nil)
                                     claude-errwatch--signatures)))
                 (count (1+ (plist-get entry :count))))
            (plist-put entry :count count)
            (plist-put entry :last now)
            (push now claude-errwatch--times)
            (setq claude-errwatch--times (seq-take (claude-errwatch--prune claude-errwatch--times) 1000))
            (when (let ((n count)) (while (and (> n 1) (zerop (% n 10))) (setq n (/ n 10))) (= n 1))
              (claude-errwatch--append (claude-errwatch--line kind source message frames count)))
            (claude-errwatch--handle sig entry)
            entry)
        (error (claude-errwatch--failed err))))))

(defun claude-errwatch--failed (err)
  (cl-incf claude-errwatch--failures)
  (message "claude-errwatch: failure of its own (%d of 3): %s"
           claude-errwatch--failures (error-message-string err))
  (when (>= claude-errwatch--failures 3)
    (claude-errwatch-stop)
    (message "claude-errwatch: OFF after 3 failures of its own")))

;;; Handling

(defun claude-errwatch--handle (sig entry)
  "Act on the first occurrence of SIG with ENTRY.
After a stale repair, a repeat means the repair failed."
  (pcase (plist-get entry :handled)
    ('nil
     (plist-put entry :handled
                (cond ((claude-errwatch--stale-files sig entry)
                       (run-at-time 0 nil #'claude-errwatch--repair sig entry)
                       'reloading)
                      ((member (car sig) '("warning" "handled")) 'counted)
                      (t (claude-errwatch--send sig entry) 'sent))))
    ('reloaded
     (plist-put entry :handled 'failed)
     (claude-errwatch--fail sig entry "came back after the reload"))))

(defun claude-errwatch--stale-files (sig entry)
  "The Homun files of ENTRY to load again when SIG is stale, or nil.
Dependencies come first."
  (when (and (memq (nth 2 sig) '(wrong-number-of-arguments void-function))
             claude-errwatch--last-load
             (< (- (float-time) claude-errwatch--last-load) claude-errwatch-stale-window))
    (claude-errwatch--dependency-order
     (delete-dups (delq nil (mapcar #'claude-errwatch--homun-file
                                    (cons (nth 1 sig) (plist-get entry :frames))))))))

(defun claude-errwatch--requires (file)
  "The features FILE requires, from `load-history'."
  (let ((entry (or (assoc file load-history)
                   (assoc (concat (file-name-sans-extension file) ".elc") load-history)
                   (seq-find (lambda (e) (and (stringp (car e))
                                              (equal (file-name-base (car e)) (file-name-base file))))
                             load-history))))
    (delq nil (mapcar (lambda (x) (and (eq (car-safe x) 'require) (cdr x))) (cdr entry)))))

(defun claude-errwatch--dependency-order (files)
  "FILES with every file before the files that require its feature."
  (let ((left files) (out nil))
    (while left
      (let ((next (or (seq-find (lambda (f) (not (seq-some (lambda (g) (and (not (eq f g))
                                                                               (memq (intern (file-name-base g))
                                                                                     (claude-errwatch--requires f))))
                                                                left)))
                                left)
                      (car left))))       ; a cycle: take them as they come
        (push next out)
        (setq left (delq next left))))
    (nreverse out)))

(defun claude-errwatch--repair (sig entry)
  "Load the files of stale SIG again; a load error is a failed repair."
  (let ((files (claude-errwatch--stale-files sig entry)))
    (condition-case err
        (progn (dolist (f files) (load f nil t t))
               (plist-put entry :handled 'reloaded)
               (message "claude-errwatch: reloaded %s for a stale %s in %s"
                        (mapconcat #'file-name-nondirectory files ", ") (nth 2 sig) (nth 1 sig))
               (claude-errwatch--append
                (claude-errwatch--line "reloaded" (nth 1 sig) (plist-get entry :example)
                                       (mapcar #'file-name-nondirectory files) 1)))
      (error (plist-put entry :handled 'failed)
             (claude-errwatch--fail sig entry (format "the reload failed: %s" (error-message-string err)))))))

(defun claude-errwatch--fail (sig entry why)
  "Say a repair of SIG failed (WHY): to the manager, and the error to the mechanic."
  (claude-errwatch--send sig entry)
  (funcall claude-errwatch-alarm-function
           (claude-errwatch--report-text (nth 0 sig) (nth 1 sig) entry
                                         (format "auto-repair failed (%s): " why))))

(defun claude-errwatch--runaway (timer source)
  "Count an error of TIMER (named SOURCE); cancel it when it errs too often.
Non-nil when cancelled."
  (let ((times (cons (float-time) (claude-errwatch--prune (gethash timer claude-errwatch--timer-errors) 60))))
    (puthash timer times claude-errwatch--timer-errors)
    (when (> (length times) claude-errwatch-runaway-per-minute)
      (cancel-timer timer)
      (remhash timer claude-errwatch--timer-errors)
      (let ((text (format "claude-errwatch: CANCELLED timer %s after %d errors in a minute"
                          source (length times))))
        (message "%s" text)
        (claude-errwatch-record "timer-cancelled" source text))
      t)))

;;; Sending

(defun claude-errwatch--send-mechanic (text)
  "Hand TEXT to the mechanic as a repair request, in the background."
  (claude-errwatch--spawn (list "python3" (expand-file-name "~/claude/_tools/homun/bin/claude-mechanic-request") "-")
                          text))

(defun claude-errwatch--alarm-manager (text)
  "Raise TEXT as an `emacs-error' alarm to the manager, in the background."
  (let ((process-environment (cons "HOMUN_ROLE=editor" process-environment)))
    (claude-errwatch--spawn (list "homun-msg" "send" "manager" "emacs-error" text))))

(defun claude-errwatch--spawn (command &optional input)
  (let ((proc (make-process :name "claude-errwatch-send" :buffer nil :noquery t
                            :connection-type 'pipe :command command
                            :sentinel #'ignore :stderr nil)))
    (when input (process-send-string proc input))
    (process-send-eof proc)))

;;; Hooks

(defun claude-errwatch--command-error (data context caller)
  "Hand DATA, CONTEXT and CALLER to the previous handler, then note the error."
  (unwind-protect
      (funcall (or claude-errwatch--previous-command-error #'command-error-default-function)
               data context caller)
    ;; Motion at a buffer or line edge, typing into read-only text and a search
    ;; with no match are the user's keys, not faults.
    (unless (memq (car-safe data) '(quit minibuffer-quit user-error
                                         beginning-of-buffer end-of-buffer
                                         beginning-of-line end-of-line
                                         buffer-read-only text-read-only
                                         search-failed))
      (let ((kind (cond ((and context (string-match-p "filter" context)) "filter")
                        ((and context (string-match-p "sentinel" context)) "sentinel")
                        (t "command"))))
        (claude-errwatch-record kind (format "%s" (or caller this-command "unknown")) data)))))

(defun claude-errwatch--timer (handler timer)
  "Run HANDLER on TIMER with its function wrapped.
An error is noted, then signalled on to `timer-event-handler', which shows it as
before.  A runaway timer is cancelled after the run (else it is re-armed)."
  (let* ((fn (timer--function timer)) (source (claude-errwatch--fn-name fn)) runaway)
    (setf (timer--function timer)
          (lambda (&rest args)
            (let (frames)
              (condition-case err
                  (handler-bind ((error (lambda (_) (setq frames (claude-errwatch--frames)))))
                    (apply fn args))
                (error (claude-errwatch-record "timer" source err frames)
                       (setq runaway (claude-errwatch--runaway timer source))
                       (signal (car err) (cdr err)))))))
    (unwind-protect (funcall handler timer)
      (setf (timer--function timer) fn)
      (when runaway (cancel-timer timer)))))

(defun claude-errwatch--warning (type message &optional level &rest _)
  (when (memq (or level :warning) '(:warning :error))
    (claude-errwatch-record (if (eq level :error) "error-warning" "warning")
                            (format "%s" (if (consp type) (car type) type))
                            (format "%s" message) (claude-errwatch--frames))))

(defun claude-errwatch--loaded (file)
  "Note when FILE, if it is Homun code, was loaded."
  (when (and (stringp file) (file-in-directory-p file claude-errwatch-homun-dir))
    (setq claude-errwatch--last-load (float-time))))

(defun claude-errwatch-start ()
  "Watch for errors; idempotent."
  (unless (eq command-error-function #'claude-errwatch--command-error)
    (setq claude-errwatch--previous-command-error command-error-function
          command-error-function #'claude-errwatch--command-error))
  (advice-add 'timer-event-handler :around #'claude-errwatch--timer)
  (advice-add 'display-warning :before #'claude-errwatch--warning)
  (add-hook 'after-load-functions #'claude-errwatch--loaded)
  ;; a live load over the older (kind source message) keys: those stay in errors.jsonl
  (maphash (lambda (k _) (unless (= (length k) 4) (remhash k claude-errwatch--signatures)))
           claude-errwatch--signatures)
  (setq claude-errwatch--failures 0 claude-errwatch--on t))

(defun claude-errwatch-stop ()
  (setq claude-errwatch--on nil)
  (when (eq command-error-function #'claude-errwatch--command-error)
    (setq command-error-function
          (or claude-errwatch--previous-command-error #'command-error-default-function)))
  (advice-remove 'timer-event-handler #'claude-errwatch--timer)
  (advice-remove 'display-warning #'claude-errwatch--warning)
  (remove-hook 'after-load-functions #'claude-errwatch--loaded))

;;; Reading

(defun claude-errwatch-count-1h ()
  (length (claude-errwatch--prune claude-errwatch--times)))

(defun claude-errwatch-failed-count ()
  "Signatures whose auto-repair failed."
  (let ((n 0))
    (maphash (lambda (_ e) (when (eq (plist-get e :handled) 'failed) (cl-incf n)))
             claude-errwatch--signatures)
    n))

(defun claude-errwatch-list (&optional limit)
  "The signatures, last seen first, as a vector of alists for `json-serialize'."
  (let ((rows nil))
    (maphash (lambda (sig e)
               (push `((kind . ,(nth 0 sig)) (source . ,(nth 1 sig))
                       (error . ,(if (nth 2 sig) (symbol-name (nth 2 sig)) :null))
                       (shape . ,(nth 3 sig)) (message . ,(plist-get e :example))
                       (count . ,(plist-get e :count))
                       (handled . ,(symbol-name (plist-get e :handled)))
                       (first . ,(format-time-string "%FT%T%z" (plist-get e :first)))
                       (last . ,(format-time-string "%FT%T%z" (plist-get e :last)))
                       (sent . ,(if (plist-get e :sent) t :false))
                       (frames . ,(vconcat (plist-get e :frames)))
                       (file . ,(or (plist-get e :file) :null)))
                     rows))
             claude-errwatch--signatures)
    (vconcat (seq-take (sort rows :key (lambda (r) (alist-get 'last r)) :reverse t)
                       (or limit 50)))))

(claude-errwatch-start)

(provide 'claude-errwatch)
;;; claude-errwatch.el ends here
