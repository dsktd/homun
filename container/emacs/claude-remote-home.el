;;; claude-remote-home.el --- The touch-first home of a remote cockpit -*- lexical-binding: t -*-

;; A phone has no keyboard for M-x, so everything a remote cockpit does is a tap away:
;;
;;   *homun*          the Board, Status and approval views under the strip and the tabs
;;   *homun compose*  Send and Cancel on top, the text below; tapping the text brings up the
;;                    on-screen keyboard (`touch-screen-display-keyboard')
;;   Homun menu       the same commands in the menu bar
;;
;; A button is a `homun-button`, a widgetry button: a tap is mouse-1.

(require 'homun-layout)
(require 'subr-x)
(require 'claude-bus)
(require 'claude-remote-live)
(require 'claude-phone)
(require 'homun-button)
(require 'claude-approve)
(require 'claude-task-detail)
(require 'claude-remote-swipe)
(defvar homun-stage-scenes)
(defvar homun-stage-actions)
(declare-function homun-stage-scene-id "homun-stage-store")

(declare-function claude-phone-confirm "claude-phone")
(declare-function claude-compose--route-for-file "claude-compose")
(declare-function claude-compose-route-role "claude-compose")
(declare-function claude-remote-act "claude-remote")
(declare-function claude-remote-transcript-file "claude-remote")
(declare-function claude-transcript-open "claude-transcript")
(declare-function claude-transcript--following-p "claude-transcript")
(declare-function claude-transcript--jump-pill "claude-transcript")
(declare-function claude-board "claude-board")
(declare-function claude-board--role-file "claude-board")
(defvar claude-board-main-dir)
(declare-function claude-remote--connect "claude-remote")
(declare-function claude-remote-stop "claude-remote")
(declare-function claude-remote-start "claude-remote")
(declare-function homun-update "init")
(defvar claude-remote-connected)
(defvar claude-remote-unhandled)
(defvar claude-remote-device)
(defvar homun-version)

(defcustom claude-remote-home-role "manager"
  "The role a compose from the phone goes to."
  :type 'string :group 'claude-remote)

(defconst claude-remote-home-buffer "*homun*")
(defconst claude-remote-home-compose-buffer "*claude-compose homun*" "Named for the layout's compose region.")
(defvar claude-remote-home--alarms nil "The newest messages to the user, newest first.")
(defvar claude-remote-home--tail nil)

(defun claude-remote-home--record (kind _source data)
  "Keep the host's glance record for the Board and Status views."
  (when (equal kind "glance")
    (setq claude-phone-glance data claude-phone-glance-time (float-time))
    (claude-remote-home-soon)))

(add-hook 'claude-remote-record-functions #'claude-remote-home--record)

(defun claude-remote-home--pick-role (role)
  "Compose writes to ROLE from now on."
  (setq claude-remote-home-role role)
  (claude-remote-home-draw))

(defun claude-remote-home--alarm (m)
  (push m claude-remote-home--alarms)
  (setq claude-remote-home--alarms (seq-take claude-remote-home--alarms 30))
  (claude-remote-home-draw))

(defun claude-remote-home--prepare (buffer)
  (with-current-buffer buffer
    (unless (derived-mode-p 'special-mode) (special-mode))
    (setq-local touch-screen-display-keyboard nil cursor-type nil mode-line-format nil)))

;;; The views: Talk is the transcript, Board, Status and the approval card are *homun*

(defvar claude-remote-home--view 'board "The view *homun* shows: `board', `status', `approval' or `detail'.")

(defun claude-remote-home--request-item (request)
  "The waiting item of the pending REQUEST: its answers are the queue's own guarded
actions; an Allow that needs a hold asks first, a Deny asks why."
  (let* ((id (alist-get 'id request)) (ask (claude-approve--ask-p request))
         (press (lambda (suffix) (lambda () (when-let* ((fn (gethash (format "approve-%s-%s" id suffix)
                                                                     homun-stage-actions)))
                                              (funcall fn))))))
    (list :title (format "%s: %s" (claude-approve--agent request) (alist-get 'tool request))
          :kind (if ask "question" "approval")
          :urgency 2
          :age (round (- (float-time) (or (alist-get 'since request) (float-time))))
          :body (concat (claude-approve--explain (claude-approve--risk request)) "\n"
                        (or (alist-get 'summary request) ""))
          :answers
          (if ask
              (append (cl-loop for q in (append (alist-get 'questions (alist-get 'input request)) nil)
                               for i from 0
                               append (cl-loop for o in (append (alist-get 'options q) nil) for j from 0
                                               collect (cons (alist-get 'label o)
                                                             (funcall press (format "q%d-%d" i j)))))
                      (list (cons "Decline" (funcall press "deny"))))
            (list (cons "Allow" (if (claude-approve--hold-p request)
                                    (lambda () (claude-phone-confirm
                                                (format "Allow %s? %s" (alist-get 'tool request)
                                                        (claude-approve--explain (claude-approve--risk request)))
                                                (funcall press "allow")))
                                  (funcall press "allow")))
                  (cons "Deny…" (claude-approve--guarded id (lambda () (claude-remote-home--deny id)))))))))

(defun claude-remote-home--deny (id)
  "Deny request ID, asking for a reason the session is told (empty: none)."
  (claude-phone-ask "Deny: why? (empty: no reason)"
                    (lambda (reason)
                      (claude-approve-answer id (if (string-empty-p reason) "deny" (claude-approve-deny-with reason))))))

(defun claude-remote-home--items ()
  "Waiting approvals and questions, then the messages to the user, as
`claude-phone-show' items."
  (append (mapcar #'claude-remote-home--request-item claude-approve--pending)
          (mapcar (lambda (m)
                    (list :title (format "%s: %s" (or (plist-get m :from) "") (or (plist-get m :alarm) ""))
                          :kind "message" :urgency 1
                          :age (round (- (float-time) (or (plist-get m :ts) (float-time))))
                          :body (or (plist-get m :msg) "")))
                  claude-remote-home--alarms)))

(defun claude-remote-home--waiting ()
  "The number of approvals and questions waiting."
  (length claude-approve--pending))

;; Set, not let-bound: the strip's and tabs' taps call them later, outside any drawing
(setq claude-phone-view-function #'claude-remote-home-view
      claude-phone-task-function #'claude-remote-home-task
      claude-phone-reconnect-function #'claude-remote-home-reconnect)

(defun claude-remote-home-strip ()
  "The phone's strip: the link, the five-hour usage and the waiting chip."
  (claude-phone-strip (claude-phone-link) (claude-phone--usage claude-phone-glance)
                      (claude-remote-home--waiting)))

(defun claude-remote-home-tabs ()
  "The phone's bottom line, its one owner: the tabs (the one shown underlined),
then the transcript's jump pill while the window drawn is scrolled up from the
end."
  (let ((jump (and (derived-mode-p 'claude-transcript-mode)
                   (not (claude-transcript--following-p (selected-window)))
                   (claude-transcript--jump-pill))))
    (claude-phone-tabs claude-phone-view (concat (claude-remote-home--queued) jump))))

(defun claude-remote-home--queued ()
  "\"queued N\" while sends wait in the outbox (offline, or a slow gateway), else
empty."
  (if (zerop claude-remote-queued) ""
    (propertize (format " queued %d " claude-remote-queued) 'face 'warning)))

;;; Text size: A- A A+ on Status, kept in the phone's own state directory

(defconst claude-remote-home-text-steps 10 "One step of the default face's :height (1/10 pt): about 1 pt.")
(defconst claude-remote-home-text-range '(80 . 240) "The smallest and largest :height.")
(defvar claude-remote-home--text-default nil "The :height before any change, what the A pill restores.")

(defun claude-remote-home--text-file ()
  (expand-file-name "text-size" (file-name-as-directory (expand-file-name claude-remote-dir))))

(defun claude-remote-home-text-size ()
  "The default face's :height now, in 1/10 pt."
  (face-attribute 'default :height nil t))

(setq claude-phone-seen-file (expand-file-name "seen" (file-name-as-directory (expand-file-name claude-remote-dir))))

(defun claude-remote-home--text-set (height)
  "Set the default face to HEIGHT within the range, remember it, and draw again."
  (unless claude-remote-home--text-default
    (setq claude-remote-home--text-default (claude-remote-home-text-size)))
  (let ((h (max (car claude-remote-home-text-range) (min (cdr claude-remote-home-text-range) height))))
    (set-face-attribute 'default nil :height h)
    (make-directory (file-name-directory (claude-remote-home--text-file)) t)
    (with-temp-file (claude-remote-home--text-file) (prin1 h (current-buffer)))
    (claude-remote-home-draw)))

(defun claude-remote-home-text-step (delta)
  "Change the text size by DELTA steps; 0 restores the default."
  (claude-remote-home--text-set
   (if (zerop delta)
       (or claude-remote-home--text-default (claude-remote-home-text-size))
     (+ (claude-remote-home-text-size) (* delta claude-remote-home-text-steps)))))

(defun claude-remote-home-text-restore ()
  "Apply the remembered text size, if any."
  (when (file-readable-p (claude-remote-home--text-file))
    (setq claude-remote-home--text-default (or claude-remote-home--text-default (claude-remote-home-text-size)))
    (let ((h (ignore-errors (with-temp-buffer (insert-file-contents (claude-remote-home--text-file))
                                              (read (current-buffer))))))
      (when (integerp h) (set-face-attribute 'default nil :height h)))))

(defun claude-remote-home--text-row ()
  "Insert the A-, A and A+ pills and the size shown."
  (dolist (b '(("A−" . -1) ("A" . 0) ("A+" . 1)))
    (let ((delta (cdr b)))
      (homun-button-insert (car b) 'secondary (lambda () (claude-remote-home-text-step delta))))
    (insert " "))
  (insert (propertize (format " %d dp · %d cols" (round (/ (claude-remote-home-text-size) 10.0))
                              (frame-width))
                      'face 'shadow)
          "\n\n"))

(defun claude-remote-home-api-body (reply)
  "The body of the gateway's api REPLY.
The gateway returns what emacsclient printed: a Lisp string \"ok\\nBODY\" or
\"err CODE\\nMESSAGE\".  A plain string is its own body; an err is signalled."
  (let* ((text (if (and (stringp reply) (string-prefix-p "\"" reply))
                   (car (read-from-string reply))
                 reply))
         (nl (and (stringp text) (string-search "\n" text))))
    (cond ((not (stringp text)) (error "no answer from the gateway"))
          ((and nl (string-prefix-p "err" text)) (error "%s" (substring text (1+ nl))))
          ((and nl (string= (substring text 0 nl) "ok")) (substring text (1+ nl)))
          (t text))))

(defvar claude-remote-home--detail nil "The data the detail view shows: see `claude-task-detail-insert'.")

(defun claude-remote-home--detail-fetch (data)
  "Ask the gateway for the tracker item of DATA, then draw the detail with it."
  (when-let* ((id (plist-get data :id)))
    (claude-remote-act "api" nil (list "tracker" "show" "id" (number-to-string id))
                       (lambda (res)
                         (when (eq claude-remote-home--view 'detail)
                           (setq claude-remote-home--detail
                                 (plist-put (copy-sequence claude-remote-home--detail) :tracker
                                            (and (plist-get res :ok)
                                                 (ignore-errors
                                                   (claude-task-detail-parse (claude-remote-home-api-body (plist-get res :reply)))))))
                           (claude-remote-home-draw))))))

(defun claude-remote-home-task (task)
  "Show the detail of the glance TASK: its agent run at once, its tracker item when
it arrives.  Opening it marks the task seen."
  (claude-phone-task-mark-seen task)
  (setq claude-remote-home--detail
        (list :id (plist-get task :tracker) :key (claude-phone-task-key task)
              :agent (list :title (plist-get task :title) :kind (plist-get task :kind)
                           :state (plist-get task :state) :last (plist-get task :last)))
        claude-remote-home--view 'detail)
  (claude-remote-home--detail-fetch claude-remote-home--detail)
  (claude-remote-home))

(defun claude-remote-home-swipe-step (delta)
  "Show the detail of the agent DELTA places on in the Board's order (1 next, -1
previous).  Says so at either end and when the agent left the Board."
  (let* ((tasks (append (plist-get claude-phone-glance :tasks) nil))
         (i (seq-position tasks (plist-get claude-remote-home--detail :key)
                          (lambda (tk key) (equal (claude-phone-task-key tk) key))))
         (j (and i (+ i delta))))
    (cond ((not i) (message "That agent is no longer on the Board"))
          ((< j 0) (message "This is the first agent"))
          ((>= j (length tasks)) (message "This is the last agent"))
          (t (claude-remote-home-task (nth j tasks))))))

(defun claude-remote-home-swipe-window-p (window)
  "Non-nil when WINDOW shows the detail view, the only place a swipe is followed."
  (and (eq claude-remote-home--view 'detail)
       (window-live-p window)
       (eq (window-buffer window) (get-buffer claude-remote-home-buffer))))

(defun claude-remote-home-swipe (direction window)
  "A swipe DIRECTION (`left' or `right') on WINDOW: in the detail view, left goes
to the next agent and right to the previous one; elsewhere it does nothing."
  (when (claude-remote-home-swipe-window-p window)
    (claude-remote-home-swipe-step (pcase direction ('left 1) ('right -1)))))

(setq claude-remote-swipe-function #'claude-remote-home-swipe
      claude-remote-swipe-active-function #'claude-remote-home-swipe-window-p)

(defun claude-remote-home--detail-set (state)
  "Set the tracker item of the detail to STATE through the gateway, then read it
again."
  (claude-remote-act "api" nil (list "tracker" "state" "id" (number-to-string (plist-get claude-remote-home--detail :id))
                                     "state" state)
                     (lambda (res)
                       (if (plist-get res :ok)
                           (claude-remote-home--detail-fetch claude-remote-home--detail)
                         (message "tracker: %s" (plist-get res :error))))))

(defun claude-remote-home--detail-draw (buffer)
  "Render the detail into BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (kill-all-local-variables) (erase-buffer)
      (setq-local cursor-type nil mode-line-format nil)
      (claude-task-detail-insert
       claude-remote-home--detail
       (list :back (lambda () (claude-remote-home-view 'board))
             :next (lambda () (claude-remote-home--detail-set "next"))
             :done (lambda () (claude-remote-home--detail-set "done"))
             :drop (lambda ()
                     (claude-phone-confirm (format "Drop #%s?" (plist-get claude-remote-home--detail :id))
                                           (lambda () (claude-remote-home--detail-set "drop")))))
       t)
      (goto-char (point-min)))))

(defun claude-remote-home-draw ()
  "Draw *homun* again, when it exists."
  (when-let* ((buffer (get-buffer claude-remote-home-buffer)))
    (if (eq claude-remote-home--view 'detail)
        (progn (claude-remote-home--detail-draw buffer)
               (claude-remote-home--prepare buffer)
               (force-mode-line-update t))
      (claude-remote-home--draw-view buffer))))

(defun claude-remote-home--draw-view (buffer)
  "Draw the Board, Status or approval view into BUFFER."
  (let ((claude-phone-role claude-remote-home-role)
        (claude-phone-role-function #'claude-remote-home--pick-role)
        (claude-phone-unhandled claude-remote-unhandled)
        (claude-phone-doctor-function #'claude-remote-home-doctor)
        (claude-phone-recreate-function #'claude-remote-home-recreate))
    (claude-phone-show buffer claude-remote-home--view (claude-remote-home--items))
    (claude-remote-home--prepare buffer)
    (when (eq claude-remote-home--view 'services)
      (with-current-buffer buffer
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map (current-local-map))
          (define-key map "g" #'claude-remote-home-doctor)
          (define-key map "q" (lambda () (interactive) (claude-remote-home-view 'status)))
          (use-local-map map))))
    (when (eq claude-remote-home--view 'status)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize (claude-remote-live-status) 'face 'shadow) "\n")
          (claude-phone--button "Reconnect" #'claude-remote-home-reconnect)
          (claude-remote-home--text-row)
          (goto-char (point-min)))))
    (force-mode-line-update t)))

(defun claude-remote-home-doctor-checks (res)
  "The checks of the reply RES of doctor get as plists.
A reply that is missing, empty or an error is one check named doctor get:
unknown with no answer, fail with an error; never an empty list that reads as
ok."
  (let ((data (and (plist-get res :ok) (stringp (plist-get res :reply))
                   (ignore-errors (json-parse-string (claude-remote-home-api-body (plist-get res :reply)) :object-type 'alist)))))
    (if-let* (((listp data)) (checks (append (alist-get 'checks data) nil)))
        (mapcar (lambda (c) (list :id (alist-get 'id c) :name (alist-get 'name c) :area (alist-get 'area c)
                                  :status (alist-get 'status c) :summary (alist-get 'summary c)
                                  :hint (alist-get 'hint c) :open (alist-get 'open c)))
                checks)
      (list (if-let* ((err (plist-get res :error)))
                (list :id "doctor.get" :name "doctor get" :status "fail" :summary (format "%s" err))
              (list :id "doctor.get" :name "doctor get" :status "unknown"
                    :summary "no answer from the gateway"))))))

(defun claude-remote-home-doctor ()
  "Run the doctor on the host; its checks show under DOCTOR on Status."
  (interactive)
  (claude-remote-act "api" nil '("doctor" "get")
                     (lambda (res)
                       (setq claude-phone-doctor (cons (float-time) (claude-remote-home-doctor-checks res)))
                       (claude-remote-home-draw))))

(defun claude-remote-home-recreate ()
  "Ask the host to recreate on the staged image, as the desktop's Recreate does."
  (claude-remote-act "recreate" nil nil
                     (lambda (res)
                       (message "%s" (if (plist-get res :ok) "Recreate requested"
                                       (format "Recreate refused: %s" (plist-get res :error)))))))

(defvar claude-remote-home--timer nil)

(defun claude-remote-home-soon (&rest _)
  "Draw again in a second, once, and only while *homun* is on screen."
  (when (and (not claude-remote-home--timer) (get-buffer-window claude-remote-home-buffer t))
    (setq claude-remote-home--timer
          (run-at-time 1 nil (lambda () (setq claude-remote-home--timer nil)
                               (with-demoted-errors "claude-remote-home: %S" (claude-remote-home-draw)))))))

(add-hook 'homun-stage-shown-hook #'claude-remote-home-soon)

(defun claude-remote-home-view (view)
  "Show VIEW: `talk' is the streamed transcript, the others *homun*."
  (unless (eq view 'approval) (setq claude-phone-view (if (eq view 'services) 'status view)))
  (if (eq view 'talk)
      (claude-remote-home-transcript)
    (setq claude-remote-home--view view)
    (claude-remote-home)))

;;;###autoload
(defun claude-remote-home ()
  "Show the touch home of the remote cockpit."
  (interactive)
  (let ((buffer (get-buffer-create claude-remote-home-buffer))
        (fresh (and (eq system-type 'android) (not (homun-layout-window 'transcript)))))
    (when fresh ; the layout adapts on its own: transcript, compose; the compose window stays the launcher
      (homun-layout-apply)
      (select-window (homun-layout-window (quote transcript))))
    (claude-remote-home--prepare buffer)
    (unless (eq claude-remote-home--view 'approval) (setq claude-phone-view (if (eq claude-remote-home--view 'services) 'status claude-remote-home--view)))
    (unless claude-remote-home--tail
      (setq claude-remote-home--tail
            (claude-bus-tail (claude-bus-path "user" "inbox.jsonl") #'claude-remote-home--alarm)))
    (claude-remote-home-draw)
    ;; *homun* is read and tapped, never typed into: the keyboard goes down
    (when (and (eq system-type 'android) (fboundp 'frame-toggle-on-screen-keyboard))
      (frame-toggle-on-screen-keyboard nil t))
    (unless (and fresh (claude-remote-transcript-file)) (homun-layout-place buffer t))))

(defun claude-remote-home-reconnect ()
  "Close the stream and open it again."
  (interactive)
  (claude-remote-stop)
  (claude-remote-start)
  (claude-remote-home-draw))

(defun claude-remote-home-board ()
  "The board of agents, as the remote cockpit has it."
  (interactive)
  (require 'claude-board)
  (claude-board))

(defun claude-remote-home-transcript ()
  "The manager's transcript as the gateway has streamed it, newest session first."
  (interactive)
  (require 'claude-transcript)
  (setq claude-phone-view 'talk)
  (claude-transcript-open (or (claude-remote-transcript-file) (user-error "No transcript streamed yet"))))

;;; Compose

;; The controls live in the header line, not in the text: a long draft scrolls the text, and
;; on a phone with the keyboard up the window has room for only a few lines.

(defvar claude-remote-home--uploading nil "The file name being uploaded, or nil.")

(defun claude-remote-home--compose-header ()
  "The recipient (tap to change it) and Cancel as secondary buttons, Send primary
at the right edge.
Offline, Send reads Queue: the outbox sends it on the next connect."
  (let ((send (homun-button (if (bound-and-true-p claude-remote-connected) "Send" "Queue")
                            'primary #'claude-remote-home-send t)))
    (concat " " (homun-button (format "To %s ▾" (claude-role-name claude-remote-home-role)) 'secondary
                              #'claude-remote-home-compose-to t)
            "  " (homun-button "Cancel" 'secondary #'claude-remote-home-cancel t)
            "  " (homun-button (if claude-remote-home--uploading "Sending…" "Attach") 'secondary
                               #'claude-remote-home-attach t)
            ;; Send ends one column before the right edge, as the buttons start one after the left
            (propertize " " 'display `(space :align-to (- right ,(1+ (string-width send)))))
            send)))

;;; Attachments

(defun claude-remote-home-attach ()
  "Explain how to attach a file on Android: share or open it with Emacs from any app.
The minibuffer prompt (`claude-remote-home-attach-prompt') is only the fallback."
  (interactive)
  (if (eq system-type 'android)
      (if (y-or-n-p "Open a file from any app (Files, Gallery) with Emacs to attach it.  Browse instead? ")
          (call-interactively #'claude-remote-home-attach-prompt)
        (message "Open a file with Emacs from any app to attach it"))
    (call-interactively #'claude-remote-home-attach-prompt)))

(defun claude-remote-home-attach-prompt (file)
  "Upload FILE (asked for with Emacs's file prompt) and link it in the compose text.
On Android the prompt browses shared storage only once Emacs has the storage permission
(Settings, Apps, Emacs, Permissions); without it the error says so."
  (interactive
   (list (condition-case err
             (read-file-name "Attach: " (if (eq system-type 'android) "/sdcard/" "~/") nil t)
           (error (user-error "Cannot browse files (%s): allow Emacs the storage permission in Android Settings, Apps, Emacs, Permissions"
                              (error-message-string err))))))
  (claude-remote-home--attach-file (expand-file-name file)))

(defun claude-remote-home--attach-file (file &optional on-done)
  "Upload FILE (copied out first when it is an Android content file) and insert a
Markdown link to the saved path into the compose text.  ON-DONE gets non-nil on success.
Every failure is shown with its reason."
  (let ((name (file-name-nondirectory file))
        (tmp nil))
    (cond
     (claude-remote-home--uploading (user-error "Still sending %s" claude-remote-home--uploading))
     ((file-directory-p file) (user-error "%s is a directory" file))
     ((not (file-readable-p file))
      (user-error "Cannot read %s: allow Emacs the storage permission in Android Settings, Apps, Emacs, Permissions" file)))
    (when (string-prefix-p "/content/" file)
      ;; `copy-file' reads content URIs through Android's resolver; the upload then reads a plain file.
      (let ((dir (make-temp-file "homun-share" t)))
        (setq tmp (expand-file-name (if (string-empty-p name) "shared" name) dir))
        (condition-case err
            (copy-file file tmp)
          (error (delete-directory dir t)
                 (user-error "Cannot copy %s out of Android: %s" name (error-message-string err))))))
    (setq claude-remote-home--uploading name)
    (message "Sending %s…" name)
    (claude-remote-home--compose-draw)
    (claude-remote-upload
     (or tmp file)
     (lambda (res)
       (setq claude-remote-home--uploading nil)
       (when tmp (ignore-errors (delete-directory (file-name-directory tmp) t)))
       (if (car res)
           (when-let* ((buf (get-buffer claude-remote-home-compose-buffer)))
             (with-current-buffer buf
               (save-excursion
                 (goto-char (point-max))
                 (unless (or (bobp) (bolp)) (insert "\n"))
                 (insert (format "[%s](%s)\n" name (cdr res)))))
             (message "Attached %s" name))
         (message "Attach failed: %s" (cdr res))
         (display-warning 'claude-remote (format "Attaching %s failed: %s" name (cdr res)) :warning))
       (claude-remote-home--compose-draw)
       (when on-done (funcall on-done (car res)))))))

;; Android's share sheet cannot reach Emacs for files: the manifest registers SEND only for
;; mailto: data.  What Emacs does take is "Open with" (VIEW/EDIT/PICK, file: and content: URIs of
;; any type); EmacsOpenActivity hands emacsclient the real path, or a /content/by-authority/...
;; name for a content URI, and the server visits it.  `server-visit-hook' runs in that buffer.

(defvar claude-remote-home-share-enabled t
  "Non-nil: a file opened with Emacs from another app is attached to compose, not visited.")

(defun claude-remote-home--share-arrived ()
  "In `server-visit-hook': when the cockpit runs on Android, upload the file just
opened from another app, link it in compose, show compose and kill the visiting buffer."
  (when-let* (claude-remote-home-share-enabled
              ((bound-and-true-p claude-remote-device))
              (file buffer-file-name)
              (buf (current-buffer)))
    (let ((done (lambda (_ok) (when (buffer-live-p buf) (kill-buffer buf)))))
      (condition-case err
          (progn
            (claude-remote-home-compose)
            (claude-remote-home--attach-file file done))
        (error
         (message "Share failed: %s" (error-message-string err))
         (display-warning 'claude-remote
                          (format "Attaching shared %s failed: %s" file (error-message-string err))
                          :warning)
         (funcall done nil))))))

(add-hook 'server-visit-hook #'claude-remote-home--share-arrived)

(defun claude-remote-home--roles ()
  "The roles compose can write to: the gateway snapshot's, else the bus's; the
current one first."
  (delete-dups
   (append (list claude-remote-home-role "manager")
           (remove "user" (append (plist-get claude-phone-glance :roles) nil))
           (remove "user" (claude-bus-roles)))))

;;; The recipient dropdown
;; A child frame over the compose window (Emacs 31 Android supports `parent-frame': androidfns.c
;; keeps the frame as a view inside the parent's activity), one 48 dp row per role, anchored under
;; the To button, or above the window when there is no room below.  A tap outside closes it.

(defvar claude-remote-home--dropdown nil "The open recipient dropdown frame, or nil.")

(defun claude-remote-home--dropdown-close ()
  "Close the recipient dropdown, if open."
  (remove-hook 'pre-command-hook #'claude-remote-home--dropdown-outside)
  (when-let* ((frame claude-remote-home--dropdown))
    (setq claude-remote-home--dropdown nil)
    (when (frame-live-p frame) (delete-frame frame))))

(defun claude-remote-home--dropdown-outside ()
  "Close the dropdown when the command at hand was not a tap inside it."
  (let* ((event last-input-event)
         (window (and (consp event) (ignore-errors (posn-window (event-start event))))))
    (unless (and (window-live-p window) (eq (window-frame window) claude-remote-home--dropdown))
      (claude-remote-home--dropdown-close))))

(defun claude-remote-home--choose-role (role)
  "Compose writes to ROLE from now on; close the dropdown and show ROLE's
transcript if one is."
  (claude-remote-home--dropdown-close)
  (setq claude-remote-home-role role)
  (claude-remote-home--show-role-transcript role)
  (claude-remote-home--compose-draw)
  (force-mode-line-update t))

(defun claude-remote-home--show-role-transcript (role)
  "Switch a shown transcript to ROLE's main session (the link follows the
recipient)."
  (when-let* (((claude-remote-home--transcript-shown))
              ((fboundp 'claude-board--role-file))
              (file (ignore-errors (claude-board--role-file (intern role) claude-board-main-dir)))
              ((file-readable-p file)))
    (claude-transcript-open file)))

(defun claude-remote-home--transcript-shown ()
  "Non-nil when a window of the selected frame shows a transcript."
  (seq-some (lambda (w) (with-current-buffer (window-buffer w) (derived-mode-p 'claude-transcript-mode)))
            (window-list)))

;; Every label padded to the widest, so every button is as wide as the list.
(defun claude-remote-home--dropdown-labels ()
  "An alist of (ROLE . LABEL), labels left-aligned and padded to one width."
  (let* ((rows (mapcar (lambda (role)
                         (cons role (concat (if (equal role claude-remote-home-role) "✓ " "  ")
                                            (claude-role-name role))))
                       (claude-remote-home--roles)))
         (width (apply #'max 0 (mapcar (lambda (r) (string-width (cdr r))) rows))))
    (mapcar (lambda (r)
              (cons (car r) (concat (cdr r) (make-string (- width (string-width (cdr r))) ?\s))))
            rows)))

(defun claude-remote-home--dropdown-buffer ()
  "The buffer of the dropdown: one left-aligned pill per role, the current one
marked."
  (let ((buffer (get-buffer-create " *homun roles*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (special-mode)
        (erase-buffer)
        (setq-local touch-screen-display-keyboard nil cursor-type nil mode-line-format nil
                    header-line-format nil tab-line-format nil)
        (dolist (row (claude-remote-home--dropdown-labels))
          (pcase-let ((`(,role . ,label) row))
            (insert (homun-button label
                                (if (equal role claude-remote-home-role) 'chip-selected 'chip)
                                (lambda () (claude-remote-home--choose-role role)) t)
                    "\n")))
        (goto-char (point-min))))
    buffer))

(defun claude-remote-home--dropdown-open ()
  "Open the dropdown child frame under the To button of the selected window."
  (let* ((parent (selected-frame))
         (window (selected-window))
         (edges (window-pixel-edges window))
         (buffer (claude-remote-home--dropdown-buffer))
         (frame (make-frame `((parent-frame . ,parent) (minibuffer . nil) (undecorated . t)
                              (no-accept-focus . t) (no-other-frame . t) (skip-taskbar . t)
                              (child-frame-border-width . 1) (menu-bar-lines . 0)
                              (tool-bar-lines . 0) (tab-bar-lines . 0) (visibility . nil)
                              (left . ,(nth 0 edges)) (top . ,(nth 1 edges))))))
    (setq claude-remote-home--dropdown frame)
    (set-window-buffer (frame-root-window frame) buffer)
    (set-window-dedicated-p (frame-root-window frame) t)
    (fit-frame-to-buffer frame nil nil nil nil)
    ;; under the header line of the window, or above the window when the list does not fit below
    (let* ((below (+ (nth 1 edges) (window-header-line-height window)))
           (top (if (<= (+ below (frame-pixel-height frame)) (frame-pixel-height parent))
                    below
                  (max 0 (- (nth 1 edges) (frame-pixel-height frame))))))
      (set-frame-position frame (nth 0 edges) top))
    (make-frame-visible frame)
    (add-hook 'pre-command-hook #'claude-remote-home--dropdown-outside)
    frame))

(defun claude-remote-home-compose-to ()
  "Open the recipient dropdown under the To button; a tap on a role picks it and
closes it.
A second tap on To closes it again; a tap outside closes it too.  No prompt."
  (interactive)
  (if (frame-live-p claude-remote-home--dropdown)
      (claude-remote-home--dropdown-close)
    (when (fboundp 'frame-toggle-on-screen-keyboard) (frame-toggle-on-screen-keyboard nil t))
    (claude-remote-home--dropdown-open)))

(defvar claude-remote-compose-lines)
(defvar claude-remote-queued)
(defvar homun-layout-compose-lines)

(defvar-local claude-remote-home--placeholder nil "The overlay of the idle launcher's text.")

(defun claude-remote-home--compose-draw (&rest _)
  "The compose window: a one-line launcher while another window is selected, the
action row and `claude-remote-compose-lines' of text while it is."
  (when-let* ((buffer (get-buffer claude-remote-home-compose-buffer)))
    (let* ((window (get-buffer-window buffer))
           (active (and window (eq window (selected-window)))))
      (with-current-buffer buffer
        (setq header-line-format (and active '(:eval (claude-remote-home--compose-header))))
        (move-overlay claude-remote-home--placeholder (point-min) (point-min))
        (overlay-put claude-remote-home--placeholder 'before-string
                     (and (not active) (= (point-min) (point-max))
                          (propertize (format "Message %s… ✎" (claude-role-name claude-remote-home-role)) 'face 'shadow))))
      ;; the tabs hide while the keyboard is up; the strip stays
      (when-let* ((main (homun-layout-window 'transcript (and window (window-frame window)))))
        (set-window-parameter main 'mode-line-format (if active 'none '(:eval (homun-layout-narrow-tabs)))))
      ;; set, not bound: a rescale (the keyboard) fits it again to the same lines
      (setq homun-layout-compose-lines (if active claude-remote-compose-lines 1))
      (when window (homun-layout-fit-compose (window-frame window))))))

(defun claude-remote-home--compose-buffer ()
  "The compose buffer, made once: tapping its text selects it, which opens it."
  (let ((buffer (get-buffer-create claude-remote-home-compose-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'text-mode)
        (text-mode) (visual-line-mode)
        (setq claude-remote-home--placeholder (make-overlay (point-min) (point-min) nil t))
        (add-hook 'window-selection-change-functions #'claude-remote-home--compose-draw nil t)
        (add-hook 'after-change-functions #'claude-remote-home--compose-draw nil t))
      (setq-local touch-screen-display-keyboard t tab-line-format nil))
    buffer))

(defun claude-remote-home-compose-idle ()
  "Show the compose window as the launcher under the main window (the layout's
compose region)."
  (homun-layout-place (claude-remote-home--compose-buffer))
  (claude-remote-home--compose-draw))

;; Compose opened from a role's transcript writes to that role.
(defun claude-remote-home--role-from-transcript ()
  "When the selected window shows a role's transcript, make that role the
recipient."
  (when-let* (((derived-mode-p 'claude-transcript-mode))
              ((require 'claude-compose nil t))
              (route (ignore-errors (claude-compose--route-for-file claude-transcript--file))))
    (setq claude-remote-home-role (symbol-name (claude-compose-route-role route)))))

(defun claude-remote-home-compose ()
  "Open the compose window: the recipient, Send and Cancel in its header line, the
on-screen keyboard up."
  (interactive)
  (claude-remote-home--role-from-transcript)
  (select-window (homun-layout-place (claude-remote-home--compose-buffer)))
  (claude-remote-home--compose-draw)
  (goto-char (point-max))
  (when (fboundp 'frame-toggle-on-screen-keyboard) (frame-toggle-on-screen-keyboard nil nil)))

(defun claude-remote-home-send ()
  "Send the composed text to `claude-remote-home-role', then show the transcript."
  (interactive)
  (with-current-buffer claude-remote-home-compose-buffer
    (let ((text (string-trim (buffer-string))))
      (if (string-empty-p text)
          (message "Nothing to send")
        (claude-bus-user-write claude-remote-home-role text)
        (erase-buffer)
        (message "Queued for %s" claude-remote-home-role)
        (when (fboundp 'frame-toggle-on-screen-keyboard) (frame-toggle-on-screen-keyboard nil t))
        (claude-remote-home-transcript)))))

(defun claude-remote-home-cancel ()
  "Leave the compose window, keeping its text: it goes back to the launcher."
  (interactive)
  (when (fboundp 'frame-toggle-on-screen-keyboard) (frame-toggle-on-screen-keyboard nil t))
  (if-let* ((main (homun-layout-window 'transcript))) (select-window main) (claude-remote-home)))

;;; Menu

(easy-menu-define claude-remote-home-menu global-map "The remote cockpit."
  '("Homun"
    ["Home" claude-remote-home]
    ["Transcript" claude-remote-home-transcript]
    ["Compose" claude-remote-home-compose]
    ["Board" claude-remote-home-board]
    ["Update" homun-update]
    ["Reconnect" claude-remote-home-reconnect]))

(provide 'claude-remote-home)
;;; claude-remote-home.el ends here
