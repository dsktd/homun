;;; claude.el --- What the claude-emacs CLI calls over emacsclient -*- coding: utf-8; lexical-binding: t -*-

;; Each command is one `emacsclient -e' form from bin/claude-emacs. They show
;; things in a GUI frame, creating one when the daemon has none, and never
;; block: `claude-ask' returns at once and writes the answer to a file under
;; answers/ when the user submits it, which the CLI waits for.

(require 'claude-identity)
(declare-function dbus-call-method-asynchronously "dbus")
(declare-function doom-init-fonts-h "doom-ui")
(declare-function magit-status-setup-buffer "magit-status")

(defvar claude-service-dir (expand-file-name "~/claude/.services/emacs/")
  "The emacs service's directory: socket/, state/ and answers/ live here.")

(defvar claude-answers-dir (expand-file-name "answers/" claude-service-dir)
  "Where `claude-ask' writes answers: <id> on submit, <id>.declined on decline.")

(defvar claude-main-session-file (expand-file-name "~/.claude/manager-session")
  "The pin file naming the main (Manager) session's id.")

(defun claude-main-session-id ()
  "The id of the pinned main session, or nil without a valid pin."
  (when-let* ((id (ignore-errors
                    (with-temp-buffer
                      (insert-file-contents claude-main-session-file)
                      (string-trim (buffer-string)))))
              ((string-match-p "\\`[[:alnum:]-]+\\'" id)))
    id))

(defun claude-display-reachable-p ()
  "Non-nil when the Wayland socket in WAYLAND_DISPLAY accepts a connection.
A pgtk Emacs exits outright when GTK cannot open a display, so every new
frame is checked first: no display costs a frame, never the daemon."
  (let ((socket (getenv "WAYLAND_DISPLAY")))
    (and socket (file-name-absolute-p socket) (file-exists-p socket)
         (ignore-errors
           (delete-process
            (make-network-process :name "claude-display-probe" :family 'local
                                  :service socket :noquery t))
           t))))

(defun claude--gui-frame ()
  "A frame on the display, made when the daemon only has its terminal frame."
  (or (seq-find (lambda (f) (frame-parameter f 'window-system)) (frame-list))
      (unless (claude-display-reachable-p)
        (user-error "No Wayland display at %s" (getenv "WAYLAND_DISPLAY")))
      (let ((frame (make-frame
                    `((window-system . ,(if (featurep 'pgtk) 'pgtk 'x))))))
        ;; Doom sets its font and theme from this hook, which only
        ;; `emacsclient -c' frames run
        (when (fboundp 'doom-init-theme-h)
          (with-selected-frame frame
            (doom-init-fonts-h)
            (doom-init-theme-h)))
        frame)))

(defmacro claude--with-frame (&rest body)
  "Run BODY with a GUI frame selected, then give that frame focus.
In batch there is no display: BODY runs in the current frame."
  (declare (indent 0))
  `(if noninteractive
       (progn ,@body)
     (let ((frame (claude--gui-frame)))
       (with-selected-frame frame ,@body)
       (select-frame-set-input-focus frame))))

;;; Buffer look shared by the Homun buffers

(defvar-local claude-updated nil
  "When this buffer last redrew, as a time value; see `claude-header'.")

(defun claude-confirm (prompt)
  "Ask PROMPT with `y-or-n-p' before an outward or destructive action; batch runs
say yes."
  (or noninteractive (y-or-n-p prompt)))

;; Every key hint the views show goes through `homun-key-hint': one switch, off by default.
(defcustom homun-key-hints nil
  "Non-nil shows key hints in header lines, mode lines and buffer text.
The ? menu, `describe-mode' and tooltips name keys regardless."
  :type 'boolean :group 'homun
  :set (lambda (symbol value)
         (set-default symbol value)
         (force-mode-line-update t)))

(defun homun-key-hint (text)
  "TEXT when `homun-key-hints' is on, else \"\".  Every hint is shown through this."
  (if homun-key-hints text ""))

(defvar-local claude--hint-current nil
  "This buffer's hint element of `mode-line-misc-info'.")

(defun claude--hint-fit (text)
  "TEXT, key hints split on \" · \" or \" | \", with leading items dropped until it
fits."
  (let* ((items (split-string text " [·|] " t))
         (room (max 10 (- (window-width) 45))))
    (while (and (cdr items) (> (length (string-join items " · ")) room))
      (setq items (cdr items)))
    (string-join items " · ")))

(defun claude--hint-segment (hint)
  "A `mode-line-misc-info' element showing HINT dim, trimmed from the left when
narrow."
  `(:eval (when-let* ((text (homun-key-hint (if (functionp ',hint) (funcall ',hint) ,hint)))
                      ((not (string-empty-p text))))
            (propertize (concat " " (claude--hint-fit text) " ") 'face 'shadow))))

(defun claude--mode-line-hidden-p ()
  "Non-nil when the window being drawn shows no mode line."
  (let ((window (selected-window)))
    (or (eq (window-parameter window 'mode-line-format) 'none)
        (null (buffer-local-value 'mode-line-format (window-buffer window))))))

(defun claude--hint-header-segment (hint)
  "Like `claude--hint-segment', for the header line: HINT after a separator, shown
only in a window without a mode line (transcript, compose, phone), which has no
place for it."
  `(:eval (when-let* (((claude--mode-line-hidden-p))
                      (text (homun-key-hint (if (functionp ',hint) (funcall ',hint) ,hint)))
                      ((not (string-empty-p text))))
            (propertize (concat "  " (claude--hint-fit text)) 'face 'shadow))))

(defvar-local claude-stale-after nil
  "Seconds without a redraw after which the header line says the view is stale;
nil: never.")

(defun claude-stale-badge (&optional updated after)
  "The badge \"[stale 3m]\" in the `warning' face when UPDATED (default
`claude-updated') is more than AFTER (default `claude-stale-after') seconds old,
else nil. Every view that polls shows the same badge in its header line."
  (let ((updated (or updated claude-updated)) (after (or after claude-stale-after)))
    (when (and updated after)
      (let ((age (float-time (time-since updated))))
        (when (> age after)
          (propertize (format " [stale %s]" (if (< age 3600)
                                                (format "%dm" (max 1 (round (/ age 60))))
                                              (format "%dh" (round (/ age 3600)))))
                      'face 'warning))))))

(defvar-local claude--header-args nil
  "The (TITLE HINT) this buffer's `claude-header' was built from, for
`homun-key-hints-refresh'.")

(defun claude-header (title hint)
  "A `header-line-format' of TITLE and the redraw time, as \"Title · updated HH:MM\".
The key HINT (a string, or a function returning one or nil) goes to the bottom:
it is added to this buffer's `mode-line-misc-info', which the mode
line (doom-modeline too) shows at its right.  Call `claude-touch' at each redraw
to move the time."
  (setq claude--header-args (list title hint))
  (let ((segment (claude--hint-segment hint)))
    (setq-local mode-line-misc-info
                (append (remove claude--hint-current mode-line-misc-info) (list segment))
                claude--hint-current segment))
  (list (propertize (concat " " title) 'face 'bold)
        '(:eval (when claude-updated
                  (propertize (format-time-string " · updated %R" claude-updated)
                              'face 'shadow)))
        '(:eval (claude-stale-badge))
        (claude--hint-header-segment hint)))

(declare-function claude-board--header "claude-board")
(declare-function claude-transcript--set-header "claude-transcript")
(defun homun-key-hints-refresh ()
  "Rebuild the header line and mode-line hint of every open view, from the code as
loaded."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (cond ((and (fboundp 'claude-board--header) (derived-mode-p 'claude-board-mode))
             (setq header-line-format (claude-board--header)))
            ((and (fboundp 'claude-transcript--set-header) (derived-mode-p 'claude-transcript-mode))
             (claude-transcript--set-header (or (car claude--header-args) "Transcript")))
            ((and claude--header-args (consp header-line-format))
             (setq header-line-format (apply #'claude-header claude--header-args))))))
  (force-mode-line-update t))

(defun claude-touch ()
  "Record now as the redraw time of this buffer."
  (setq claude-updated (current-time)))

(defun claude--notify (summary body)
  "Desktop notification through the container's notify proxy, if there is one."
  (when (executable-find "notify-send")
    (ignore-errors (call-process "notify-send" nil 0 nil summary body))))

(defun claude-open (file &optional line)
  "Visit FILE, at LINE when given, in a frame."
  (claude--with-frame
    (find-file file)
    (when line
      (goto-char (point-min))
      (forward-line (1- line))))
  file)

(defun claude-open-dir (dir)
  "Show DIR in the selected window: magit in a git work tree, else dired.
Used by `claude-frame-start' for a `dir' focus."
  (let ((default-directory (file-name-as-directory dir)))
    (if (and (fboundp 'magit-toplevel) (magit-toplevel))
        (magit-status-setup-buffer default-directory)
      (dired default-directory)))
  dir)

(defun claude-diff (a b)
  "Compare files A and B with ediff."
  (claude--with-frame (ediff-files a b))
  t)

(defun claude--report-buffer (file &optional title)
  "A read-only buffer of FILE named after TITLE (`q' closes it)."
  (let ((buffer (get-buffer-create
                 (format "*claude report: %s*" (or title (file-name-nondirectory file))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents file))
      (let ((buffer-file-name file))
        (set-auto-mode))
      (view-mode 1))
    buffer))

(defun claude-report (file &optional title)
  "Show FILE read-only in a frame, in a buffer named after TITLE."
  (let ((buffer (claude--report-buffer file title)))
    (claude--with-frame (switch-to-buffer buffer))
    (buffer-name buffer)))

(defun claude-say (text)
  "Show TEXT in the echo area."
  (message "%s" text)
  text)

;;; ask

(defvar-local claude-ask-id nil)
(defvar-local claude-ask-answer-start nil)
(defvar-local claude-ask-timed-out nil)

(defun claude--ask-buffer-name (id)
  (format "*claude ask %s*" id))

(defvar claude-ask-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-ask-submit)
    (define-key map (kbd "C-c C-k") #'claude-ask-decline)
    map))

(declare-function evil-define-key* "evil-core")
(with-eval-after-load 'evil
  (evil-define-key* 'normal claude-ask-mode-map
    (kbd "ZZ") #'claude-ask-submit
    (kbd "ZQ") #'claude-ask-decline))

(define-derived-mode claude-ask-mode text-mode "Claude-Ask"
  "Answer Claude's question below the line; C-c C-c sends it, C-c C-k declines.")

(defun claude-ask (text id)
  "Put question TEXT in its own *claude ask ID* buffer; the answer lands in
answers/ID.
Returns ID."
  (make-directory claude-answers-dir t)
  (let ((buffer (get-buffer-create (claude--ask-buffer-name id))))
    (with-current-buffer buffer
      (claude-ask-mode)
      (setq claude-ask-id id)
      ;; The question is read-only; the answer goes after it (rear-nonsticky)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (concat text "\n\n") 'read-only t 'front-sticky t)
                (propertize (concat (make-string 72 ?-) "\n"
                                    (homun-key-hint "Answer below. C-c C-c (ZZ) sends it, C-c C-k (ZQ) declines.\n"))
                            'read-only t 'front-sticky t 'rear-nonsticky t
                            'face 'font-lock-comment-face)))
      (setq claude-ask-answer-start (point-marker)))
    (claude--with-frame
      (switch-to-buffer buffer)
      (goto-char (point-max))
      (when (fboundp 'evil-insert-state) (evil-insert-state)))
    (claude--notify "Claude asks" text)
    id))

(defun claude-ask-timeout (id)
  "Mark ask ID's buffer: the CLI stopped waiting, so an answer goes nowhere."
  (when-let* ((buffer (get-buffer (claude--ask-buffer-name id))))
    (with-current-buffer buffer
      (setq claude-ask-timed-out t
            header-line-format
            (propertize " Timed out: Claude stopped waiting, an answer here is not delivered (q or C-c C-k closes)"
                        'face 'error))))
  id)

(defun claude-ask--finish (answer suffix &optional keep)
  "Write ANSWER to answers/<id><SUFFIX> atomically and drop the buffer unless KEEP.
Nothing is written once the ask timed out: nobody would read it."
  (unless claude-ask-id (user-error "Not a claude ask buffer"))
  (if claude-ask-timed-out
      (message "Claude stopped waiting for this answer; not delivered")
    (let* ((file (expand-file-name (concat claude-ask-id suffix) claude-answers-dir))
           (tmp (concat file ".tmp")))
      (write-region answer nil tmp nil 'silent)
      (rename-file tmp file t)))
  (unless keep (kill-buffer)))

(defun claude-ask-submit ()
  "Send what is below the line to Claude."
  (interactive)
  (claude-ask--finish
   (string-trim (buffer-substring-no-properties claude-ask-answer-start (point-max)))
   ""))

(defun claude-ask-decline ()
  "Tell Claude there is no answer."
  (interactive)
  (unless (claude-confirm "Decline this question? ") (user-error "Not declined"))
  (claude-ask--finish "" ".declined"))

(autoload 'claude-compose "claude-compose" "Compose a message to the manager's main session." t)
;; its advice and keys on the transcript and board maps come with the file
(autoload 'org-claude-modern "org-claude")
(defalias 'claude-org-modern #'org-claude-modern
  "Turn on org-modern in this buffer when installed (see `org-claude-modern').")

(autoload (quote claude-compact) "claude-compact" "Send /compact to the manager." t)
(autoload 'claude-questions "claude-questions")
(autoload 'claude-questions-submit "claude-questions" nil t)
(autoload 'claude-questions-decline "claude-questions" nil t)
(autoload 'claude-questions-menu "claude-questions" nil t)
(autoload 'claude-questions-show "claude-questions" nil t)

(autoload 'claude-pick "claude-pick")
(autoload 'claude-review "claude-review")
(autoload 'claude-board "claude-board" "Live table of running agents and jobs." t)

(defgroup claude nil "Claude's Emacs." :group 'tools)

;;; sched: the scheduler's upcoming fires in org-agenda

(defcustom claude-sched-url (expand-file-name "~/claude/.services/scheduler/agenda.org")
  "The scheduler's agenda, an org file of its upcoming fires, written by its
service."
  :type 'string)

(defcustom claude-sched-file (expand-file-name "~/.cache/claude/sched.org")
  "Where `claude-sched-refresh' keeps the agenda; it is in `org-agenda-files'."
  :type 'file)

(defcustom claude-sched-command
  (list "nu" (expand-file-name "~/claude/_tools/homun/bin/claude-sched"))
  "The claude-sched CLI, which validates what the commands below send it."
  :type '(repeat string))

(defvar claude-sched--fetching nil "The running agenda fetch, or nil.")

(defun claude-sched--run (command done)
  "Run COMMAND in the background; call DONE with its exit status and output."
  (make-process :name "claude-sched" :noquery t :command command
                :buffer (generate-new-buffer " *claude-sched*" t)
                :sentinel (lambda (process _event)
                            (unless (process-live-p process)
                              (let ((buffer (process-buffer process)))
                                (unwind-protect
                                    (funcall done (process-exit-status process)
                                             (with-current-buffer buffer (string-trim (buffer-string))))
                                  (kill-buffer buffer)))))))

(defun claude-sched-refresh ()
  "Fetch the agenda into `claude-sched-file' in the background; on failure keep the
old file."
  (interactive)
  ;; a remote cockpit has no host agenda to copy: nothing to refresh there
  (when (and (not (process-live-p claude-sched--fetching)) (file-exists-p claude-sched-url))
    (make-directory (file-name-directory claude-sched-file) t)
    (let ((tmp (concat claude-sched-file ".part")))
      (condition-case err
          (setq claude-sched--fetching
                (claude-sched--run
                 (list "cp" claude-sched-url tmp)
                 (lambda (status _out)
                   (if (eq status 0)
                       (rename-file tmp claude-sched-file t)
                     (ignore-errors (delete-file tmp))
                     (message "claude-sched: not refreshed (cp exit %s)" status)))))
        (error (message "claude-sched: not refreshed: %s" (error-message-string err)))))))

(defun claude-sched--call (&rest args)
  "Run the claude-sched CLI with ARGS in the background, show its output, and
refresh the agenda."
  (claude-sched--run (append claude-sched-command args)
                     (lambda (status out)
                       (message "claude-sched %s: %s" (string-join args " ") out)
                       (unless (eq status 0) (message "claude-sched failed (exit %s)" status))
                       (claude-sched-refresh))))

(defun claude-sched-add (name cron prompt)
  "Add schedule NAME firing on CRON (5 fields) with PROMPT."
  (interactive (list (read-string "Name: ") (read-string "Cron (5 fields): ")
                     (read-string "Prompt: ")))
  (claude-sched--call "add" name "cron" cron "prompt" prompt))

(defun claude-sched-toggle (name enable)
  "Enable (ENABLE non-nil) or disable schedule NAME."
  (interactive (list (read-string "Schedule: ") (y-or-n-p "Enable (n disables)? ")))
  (claude-sched--call (if enable "enable" "disable") name))

(defun claude-sched-run (name)
  "Fire schedule NAME now."
  (interactive "sFire schedule now: ")
  (claude-sched--call "run" name))

(defvar claude-sched--timer nil "The repeating `claude-sched-refresh' timer; one at a time.")
(defun claude-sched--arm ()
  "Cancel the refresh timer and start one."
  (when (timerp claude-sched--timer) (cancel-timer claude-sched--timer))
  (setq claude-sched--timer (run-with-timer 0 300 #'claude-sched-refresh)))
(defun claude-sched--before-agenda (&rest _) (claude-sched-refresh))
(unless noninteractive (claude-sched--arm))
(with-eval-after-load 'org-agenda
  (add-to-list 'org-agenda-files claude-sched-file)
  (advice-mapc (lambda (f _)
                 (when (or (eq f #'claude-sched--before-agenda)
                           (and (not (symbolp f)) (string-match-p "claude-sched-refresh" (prin1-to-string f))))
                   (advice-remove 'org-agenda f)))
               'org-agenda)
  (advice-add 'org-agenda :before #'claude-sched--before-agenda))

;;; Org tidy: realign every table when an Org buffer is saved (questions, tracker, notes).
(defun claude-org-tidy ()
  "Align all tables in the current Org buffer."
  (when (derived-mode-p 'org-mode)
    (org-table-map-tables #'org-table-align t)))
(defun claude-org-tidy-on-save ()
  (add-hook 'before-save-hook #'claude-org-tidy nil t))
(add-hook 'org-mode-hook #'claude-org-tidy-on-save)

;;;; Keys every Homun view shares

(declare-function evil-define-key* "evil-core")

(defun homun-bind-common (map refresh)
  "Give view keymap MAP the keys all Homun views share: gr (and g) REFRESH, q, ?.
In Evil's normal and motion states too, so a view differs only in its own keys."
  (define-key map (kbd "g") refresh)
  (define-key map (kbd "q") #'quit-window)
  (define-key map (kbd "?") #'describe-mode)
  (with-eval-after-load 'evil
    (evil-define-key* '(normal motion) map
      (kbd "gr") refresh (kbd "q") #'quit-window (kbd "?") #'describe-mode)))

(declare-function which-key-add-major-mode-key-based-replacements "which-key")

(defun homun-bind-leader (mode map bindings)
  "Under evil, bind BINDINGS, an alist of (KEY . COMMAND), at SPC m KEY in MAP.
MAP is the keymap symbol of MODE.  For keys that would shadow an evil motion
(f n e t s l u ...): Doom's `define-localleader-key!' when there is one, the
literal keys otherwise.  The plain MAP keeps its own bindings for non-evil use."
  (if (fboundp 'define-localleader-key!)
      (eval `(define-localleader-key! :keymaps ',map
               ,@(mapcan (lambda (b) (list (car b) `#',(cdr b))) bindings))
            t)
    (dolist (b bindings)
      (evil-define-key* '(normal motion) (symbol-value map)
                        (kbd (concat "SPC m " (car b))) (cdr b))))
  (when (fboundp 'which-key-add-major-mode-key-based-replacements)
    (which-key-add-major-mode-key-based-replacements mode "SPC m" "homun")))

(provide 'claude)

;; After `provide': these libraries require `claude', so with one already loaded a hook that
;; ran earlier would require it again while it loads.
(with-eval-after-load 'claude-transcript (require 'claude-compose))
(with-eval-after-load 'claude-board (require 'claude-compose))
(with-eval-after-load 'claude-transcript (require 'claude-approve))
(with-eval-after-load 'claude-transcript (require 'claude-transcript-focus))
(with-eval-after-load 'claude-transcript (require 'homun-iface))
;;; claude.el ends here
;; The `claude-errwatch' hook is soft: errwatch loads after this file.
(declare-function claude-errwatch-record "claude-errwatch")
(declare-function dbus-init-bus "dbus")

(defun claude-browse-url--fail (url why)
  "Say opening URL on the host failed for WHY; copy URL, count it in the error watch."
  (kill-new url)
  (message "Could not open %s on the host (%s); URL copied to the kill ring" url why)
  (when (fboundp 'claude-errwatch-record)
    (claude-errwatch-record "handled" "claude-browse-url" (list 'portal-failed why))))

(defun claude-browse-url--call (url)
  "Send the OpenURI call for URL asynchronously; a timer reports a call that fails."
  (let ((done nil))
    ;; An error reply never runs the handler, so the timer catches it.
    (dbus-call-method-asynchronously :session "org.freedesktop.portal.Desktop"
                                     "/org/freedesktop/portal/desktop"
                                     "org.freedesktop.portal.OpenURI" "OpenURI"
                                     (lambda (&rest _) (setq done t)) :timeout 5000
                                     "" url '(:array :signature "{sv}"))
    (run-at-time 6 nil
                 (lambda ()
                   (unless done
                     (claude-browse-url--fail url "no answer from the portal"))))))

(defun claude-browse-url (url &rest _)
  "Ask the host to open URL with its default handler (OpenURI portal).
Only http, https, mailto and ftp go to the host.  A lost session bus connection
(the proxy restarted) is set up again once and the call retried.  If D-Bus is
missing, the portal errors or does not answer within 5 s, say so, copy URL and
count it in the error watch."
  (if (not (string-match-p "\\`\\(https?\\|mailto\\|ftp\\):" url))
      (message "Not opening %s on the host: only http, https, mailto and ftp links" url)
    (require 'dbus)
    (condition-case err
        (condition-case first
            (claude-browse-url--call url)
          (dbus-error
           (if (string-match-p "No connection to bus" (error-message-string first))
               (progn (dbus-init-bus :session) (claude-browse-url--call url))
             (signal (car first) (cdr first)))))
      (error (claude-browse-url--fail url (error-message-string err))))))
