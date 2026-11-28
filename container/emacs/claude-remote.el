;;; claude-remote.el --- The cockpit in another Emacs, through the cockpit gateway -*- lexical-binding: t -*-

;; The `remote' flavour of the cockpit (design 3.6b): the same Elisp in an Emacs off the host,
;; Android Emacs first, reading one authenticated event stream instead of the host's files.
;;
;; The gateway (container/cockpit-gateway, at /cockpit-gateway/ behind the proxy) serves
;; /snapshot, /stream (server-sent events, resumable by cursor) and /act (one typed action).
;; `claude-remote-start' points `claude-bus-dir' and `homun-stage-dir' at a local cache and
;; sets `claude-bus-transport', so the code that tails inboxes, sends alarms and queues the
;; user's words works unchanged:
;;
;;   bus records       to the handlers of `claude-bus-tail' for bus/<to>/inbox.jsonl
;;   scene records     the approval queue is rebuilt from the requests it carries (`claude-approve-scene');
;;                     a `closed' record closes it; a press sends an approve action
;;   other records     to `claude-remote-record-functions' (KIND SOURCE DATA)
;;   compose, alarms   compose and alarm actions; the gateway files them as this device
;;   offline           actions wait in <cache>/outbox/ and go out with their own time when the
;;                     stream is back; the buffers keep what they drew meanwhile
;;
;; Each record is handed on once: its bus id (or kind and seq) is remembered, and the cursor
;; and those ids are kept in `claude-remote-state-file', so a restart or a gateway reset does
;; not announce old alarms again.  Raw eval never crosses: the gateway takes typed actions only.
;;
;; Setup: "Pair phone" in the desktop cockpit (`claude-pair-phone') shows a QR code of a page
;; whose line writes the bootstrap block (homun-init.el) into init.el.  The block pairs once,
;; fetches this code from the gateway (client.go) with the CA pinned, and starts it.  The
;; gateway checks every request itself (the proxy's login is not asked for on /cockpit-gateway/).

(defvar claude-agent-name)
(require 'cl-lib)
(require 'filenotify)
(require 'gnutls)
(require 'json)
(require 'map)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'claude-bus)
(require 'claude-approve)
(require 'claude-phone)
(require 'homun-clock)
(defvar claude-approve-answer-function)
(defvar homun-stage-dir)
(defvar homun-stage-scenes)
(declare-function claude-remote-home "claude-remote-home")
(declare-function claude-remote-home-draw "claude-remote-home")
(declare-function claude-remote-report-start "claude-remote-report")
(declare-function claude-remote-swipe-setup "claude-remote-swipe")

(defgroup claude-remote nil "The cockpit through the cockpit gateway." :group 'applications)

(defcustom claude-remote-url nil
  "The gateway's base URL, ending in /cockpit-gateway/."
  :type '(choice (const nil) string))

(defcustom claude-remote-key nil
  "This device's key, printed once by `homun cockpit device add'."
  :type '(choice (const nil) string))

(defcustom claude-remote-device "phone"
  "This device's name on the host (the one given to `homun cockpit device add')."
  :type 'string)

(defcustom claude-remote-ca-file nil
  "The proxy's root certificate (Caddy's internal CA), added to
`gnutls-trustfiles'."
  :type '(choice (const nil) file))

(defcustom claude-remote-dir (locate-user-emacs-file "homun-remote/")
  "Where the remote cockpit keeps its cache: bus, approve, state."
  :type 'directory)

(defvar claude-remote-record-functions nil
  "Called with KIND SOURCE DATA for each record that is neither bus nor approve.")

(defvar claude-remote-state-file nil "The cursor and seen ids; set by `claude-remote-start'.")

(defvar claude-remote-unhandled nil "Alist (KIND . COUNT) of records no handler knows, shown on Status.")
(defvar claude-remote--cursor nil "The stream cursor of the last record handled.")
(defvar claude-remote--seen nil "The last `claude-remote--seen-max' record keys handed on, newest first.")
;; Live reload over a running Emacs keeps the old value: adopt the old hash table's keys.
(when (hash-table-p claude-remote--seen)
  (let (keys)
    (maphash (lambda (k _) (push k keys)) claude-remote--seen)
    (setq claude-remote--seen keys)))
(defvar claude-remote--tails nil "Alist (FILE . HANDLER) of the inboxes followed.")
(defvar claude-remote--process nil "The stream's network process.")
(defvar claude-remote--retry 2 "Seconds before the next reconnect.")
(defvar claude-remote--timer nil "The reconnect timer.")
(defvar claude-remote--watchdog nil "Checks every few seconds that the open stream still hears from the gateway.")
(defvar claude-remote--lost nil "When the stream went down (a float time) and how many tries since: (TIME .
TRIES).")
(defvar claude-remote--device nil "This device's record from the snapshot (its permissions).")
(defvar claude-remote--roles nil "The bus's recipients from the snapshot, for `claude-bus-roles'.")
(defvar claude-remote-connected nil "Non-nil while the stream is open.")
(defvar claude-remote-connected-hook nil "Run each time the stream comes up.")
(defvar claude-remote-disconnected-hook nil "Run each time the stream goes down.")

(defconst claude-remote--seen-max 2000)

;;; Helpers

(defun claude-remote--path (&rest parts)
  (let ((path (file-name-as-directory (expand-file-name claude-remote-dir))))
    (dolist (part parts path) (setq path (expand-file-name part (file-name-as-directory path))))))

(defun claude-remote--url (path)
  (concat (file-name-as-directory claude-remote-url) path))

(defun claude-remote--headers ()
  (list (cons "X-Homun-Key" claude-remote-key)))

(defun claude-remote--json (text)
  (json-parse-string text :object-type 'plist :null-object nil :false-object nil))

(require 'nsm)
(require 'gnutls)
(declare-function claude-remote-home-text-restore "claude-remote-home")
(declare-function claude-settings-load "claude-settings")
(declare-function set-fontset-font "fontset")

;; A keep-alive connection outlives its response buffer, and killing that buffer
;; then asks whether to kill the process: every gateway request is one-shot.
(setq url-http-attempt-keepalives nil)

(defmacro claude-remote--strict (&rest body)
  "Run BODY trusting the pinned CA only: no system roots, no saved exceptions, no
prompts."
  `(let ((gnutls-trustfiles (and claude-remote-ca-file (list (expand-file-name claude-remote-ca-file))))
         (gnutls-verify-error t) (network-security-level 'high)
         (nsm-settings-file (make-temp-file "nsm")))
     ,@body))

(defun claude-remote--kill-response ()
  "Kill the current url response buffer and any keep-alive connection on it,
without a prompt."
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (set-process-query-on-exit-flag proc nil)
    (delete-process proc))
  (kill-buffer))

(defun claude-remote--json-ascii (body)
  "BODY as JSON text with every non-ASCII character escaped: url-http refuses a
request that mixes raw UTF-8 bytes with a multibyte header (a key read from a
file), so the body stays plain."
  (replace-regexp-in-string
   "[^\0-\177]"
   (lambda (m)
     (let ((c (aref m 0)))
       (if (< c #x10000) (format "\\u%04x" c)
         (let ((c (- c #x10000)))
           (format "\\u%04x\\u%04x" (+ #xd800 (ash c -10)) (+ #xdc00 (logand c #x3ff)))))))
   (decode-coding-string (json-serialize body) 'utf-8) t t))

(defun claude-remote--request (method path body callback)
  "METHOD PATH on the gateway with the JSON BODY (a plist or nil); CALLBACK
gets (STATUS . DATA)."
  (let ((url-request-method method)
        (url-request-extra-headers (append (claude-remote--headers)
                                           (and body '(("Content-Type" . "application/json")))))
        (url-request-data (and body (claude-remote--json-ascii body))))
    (claude-remote--strict
     (url-retrieve (claude-remote--url path)
                  (lambda (_status)
                    (let ((code (bound-and-true-p url-http-response-status))
                          (data (progn (goto-char (point-min))
                                       (when (re-search-forward "\r?\n\r?\n" nil t)
                                         (ignore-errors
                                           (claude-remote--json
                                            (decode-coding-string
                                             (buffer-substring (point) (point-max)) 'utf-8)))))))
                      (claude-remote--kill-response)
                      (funcall callback (cons code data))))
                  nil t t))))

;;; Records

(defun claude-remote--seen-p (key)
  "Non-nil when KEY was handed on before; else remember it, forgetting the oldest
past the bound."
  (or (member key claude-remote--seen)
      (progn (push key claude-remote--seen)
             (when (> (length claude-remote--seen) claude-remote--seen-max)
               (setcdr (nthcdr (1- claude-remote--seen-max) claude-remote--seen) nil))
             nil)))

(defun claude-remote--key (rec)
  (let ((data (plist-get rec :data)))
    (if (and (equal (plist-get rec :kind) "bus") (plist-get data :id))
        (concat "bus:" (plist-get data :id))
      ;; The approval queue is one scene id that changes: its records are told apart by content
      (format "%s:%s:%s" (plist-get rec :kind) (plist-get rec :source)
              (or (and (not (member (plist-get rec :kind) '("scene" "closed"))) (plist-get data :id))
                  (sxhash-equal data))))))

(defun claude-remote--transcript (session data)
  "Append the transcript entry DATA of SESSION to its local file, the one the
viewer follows."
  (unless (plist-get data :truncated)
    (let ((file (expand-file-name (concat session ".jsonl") (claude-remote--path "transcript"))))
      (make-directory (file-name-directory file) t)
      (write-region (concat (json-serialize data) "\n") nil file t 'quiet))))

;; An answer another device gave to a transcript widget: kept, then drawn in the open transcript
(defun claude-remote--widget (data)
  "Keep the widget answer DATA (:text) and draw it."
  (when (and (stringp (plist-get data :text)) (fboundp 'claude-transcript--widget-record))
    (claude-transcript--widget-record (plist-get data :text))
    (claude-transcript--widget-apply)))

;; Every record kind has one handler here; a kind with none is counted as unhandled, nowhere else.
(defun claude-remote--on-bus (_kind source data)
  "Hand the bus record DATA of SOURCE to the tail that watches that inbox."
  (let ((file (expand-file-name (claude-bus-path source "inbox.jsonl"))))
    (dolist (tail claude-remote--tails)
      (when (equal (car tail) file)
        (with-demoted-errors "claude-remote: %S" (funcall (cdr tail) data))))))

(defun claude-remote--on-transcript (_kind source data)
  "Write the transcript record DATA of SOURCE to its file, and refresh the Home
view."
  (claude-remote--transcript source data)
  (when (fboundp 'claude-remote-home-soon) (claude-remote-home-soon)))

(defun claude-remote--on-hook (kind source data)
  "Hand a KIND record of SOURCE and DATA to the hooks of
`claude-remote-record-functions'."
  (run-hook-with-args 'claude-remote-record-functions kind source data))

(defconst claude-remote--handlers
  `(("bus" . claude-remote--on-bus)
    ("scene" . ,(lambda (_kind source data)
                  (claude-remote--approve-scene (file-name-sans-extension source)
                                                (homun-stage-parse (json-serialize data)))))
    ("closed" . ,(lambda (_kind source _data)
                   (claude-remote--approve-closed (file-name-sans-extension source))))
    ("widget" . ,(lambda (_kind _source data) (claude-remote--widget data)))
    ("transcript" . claude-remote--on-transcript)
    ("live" . ,(lambda (_kind _source data)
                 (require 'claude-transcript-stream) (claude-transcript-stream-set data)))
    ("glance" . claude-remote--on-hook)
    ("reload" . claude-remote--on-hook)
    ("device" . claude-remote--on-hook))
  "Alist (KIND . HANDLER); a handler is called with KIND SOURCE DATA.
A kind the phone deliberately ignores gets `ignore' with a comment saying why.")

(defun claude-remote--dispatch (kind source data)
  "Call the handler of KIND with SOURCE and DATA; with none, count KIND as
unhandled.
Unknown kinds still reach the record hooks, for add-ons that know them."
  (if-let* ((handler (alist-get kind claude-remote--handlers nil nil #'equal)))
      (funcall handler kind source data)
    (cl-incf (alist-get kind claude-remote-unhandled 0 nil #'equal))
    (claude-remote--on-hook kind source data)))

(defun claude-remote--handle (rec &optional quiet)
  "Hand the record REC on, once.  QUIET only remembers it (a first snapshot is
history)."
  (unless (claude-remote--seen-p (claude-remote--key rec))
    (let ((kind (plist-get rec :kind)))
      ;; Transcript records are history too: the file is the view.
      (when (or (not quiet) (equal kind "transcript"))
        (claude-remote--dispatch kind (plist-get rec :source) (plist-get rec :data))))))

(defun claude-remote-transcript-file ()
  "The newest transcript the gateway streamed, or nil."
  (let ((dir (claude-remote--path "transcript")))
    (and (file-directory-p dir)
         (car (sort (directory-files dir t "\\.jsonl\\'") #'file-newer-than-file-p)))))

;;; Approve: the scene the desktop draws, answered through the gateway

(declare-function homun-layout-window "homun-layout")
(declare-function homun-layout-marquee-toggle "homun-layout")

(defun claude-remote--stage-open (open)
  "Open the narrow layout's stage marquee when OPEN, else close it, if it is not so
already."
  (when-let* ((window (homun-layout-window 'stage)))
    (when (eq (and open t) (<= (window-body-height window) 1))
      (ignore-errors (homun-layout-marquee-toggle)))
    (unless open (when-let* ((main (homun-layout-window 'transcript))) (select-window main)))))

(defun claude-remote--approve-scene (scene data)
  "Show the approval queue SCENE (DATA is the record's) rebuilt here from the
requests it carries, so the card guard runs on this clock; mirror other scenes."
  (if (not (equal scene claude-approve-scene-id))
      (claude-remote--mirror-scene scene data)
    (claude-remote--approve-from (alist-get 'root data))
    (unless homun-layout-phone ; on the phone the approval card shows it
      (when (gethash scene homun-stage-scenes)
        (homun-stage-display scene)
        (claude-remote--stage-open t)))))

(defun claude-remote--approve-from (root)
  "Draw the queue from the scene ROOT the desktop drew: its requests still in their
window."
  (claude-approve-render
   (cl-remove-if #'claude-approve--stale-p (append (alist-get 'requests root) nil))
   (eq t (alist-get 'waiting root))
   (let ((ticker (alist-get 'ticker root))) (and (stringp ticker) (not (string-empty-p ticker)) ticker))))

(defun claude-remote--mirror-scene (scene data)
  "Show the desktop's scene SCENE, as the homund store keeps it in DATA, in the
local store."
  (when-let* ((root (alist-get 'root data)))
    (homun-stage-show (or (alist-get 'owner_role data) "cal") scene (alist-get 'title data) root
                      (or (alist-get 'lifetime data) "turn") (alist-get 'stale_ms data))))

(defun claude-remote--approve-closed (scene)
  "The desktop closed SCENE: close it here."
  (if (equal scene claude-approve-scene-id)
      (claude-approve-render nil)
    (when (gethash scene homun-stage-scenes)
      (homun-stage-close "cal" scene)))
  (unless (gethash claude-approve-scene-id homun-stage-scenes)
    (claude-remote--stage-open nil))
  (when (fboundp 'claude-remote-home-soon) (claude-remote-home-soon)))

(defun claude-remote--arm-loaded ()
  "Draw the queue read back from the cache again: its actions and guard live in
memory only."
  (when-let* ((s (gethash claude-approve-scene-id homun-stage-scenes)))
    (claude-remote--approve-from (homun-stage-scene-root s))))

(defun claude-remote--approve-answer (id verdict)
  "Send the answer VERDICT of request ID to the gateway (`claude-approve-answer'
then drops its card)."
  (claude-remote-act "approve"
                     (if (string-prefix-p "{\"behavior\":\"deny\"" verdict)
                         (list :id id :answer "deny"
                               :reason (gethash "message" (json-parse-string verdict)))
                       (list :id id :answer verdict)))
  (when (fboundp 'claude-remote-home-soon) (claude-remote-home-soon)))

;;; Actions: an outbox that survives a lost connection

;; Each action is first written to <cache>/outbox/<id>.eld, then sent, one at a time and oldest
;; first, with the time the user acted.  A reply removes it; no reply (offline, the gateway
;; down) keeps it for the next connect; a refusal drops it with a message.  One older than
;; `claude-remote-stale' asks before it goes.  The gateway answers a resent id with its first
;; result, so an action whose reply was lost is never done twice.

(defcustom claude-remote-stale 600
  "Seconds after which a queued action asks before it is sent."
  :type 'integer)

(defcustom claude-remote-send-timeout 20
  "Seconds a send may stay unanswered before it is given up and sent again (the
gateway answers a resent id with its first result).  url.el has no timeout of
its own: a request on a connection the phone's sleep cut can hang for minutes,
and the whole outbox behind it."
  :type 'integer)

(defvar claude-remote--sending nil "The send in flight, (FILE), or nil.")
(defvar claude-remote--send-buffer nil "The url buffer of the send in flight.")
(defvar claude-remote--send-timer nil "Gives up the send in flight, or retries a failed one.")
(defvar claude-remote--callbacks (make-hash-table :test #'equal) "Action id -> callback.")
(defvar claude-remote-queued 0 "Actions waiting in the outbox; the phone's bottom line shows them.")

(defun claude-remote--outbox ()
  (let ((dir (claude-remote--path "outbox")))
    (and (file-directory-p dir) (directory-files dir t "\\.eld\\'"))))

(defun claude-remote--count ()
  "Count the outbox again for the indicator."
  (setq claude-remote-queued (length (claude-remote--outbox)))
  (force-mode-line-update t))

(defun claude-remote--abandon-send (why)
  "Give up the send in flight, logging WHY, and kill its connection; it is resent
by the next flush."
  (when claude-remote--sending
    (message "claude-remote: send %s %s, resending" (file-name-base (car claude-remote--sending)) why)
    (when (buffer-live-p claude-remote--send-buffer)
      (let ((proc (get-buffer-process claude-remote--send-buffer)))
        (when proc (set-process-sentinel proc #'ignore) (delete-process proc)))
      (kill-buffer claude-remote--send-buffer))
    (setq claude-remote--sending nil)))

(defun claude-remote--retry-send (seconds)
  "Flush again in SECONDS, dropping a send still in flight then (it is resent)."
  (when (timerp claude-remote--send-timer) (cancel-timer claude-remote--send-timer))
  (setq claude-remote--send-timer
        (run-at-time seconds nil
                     (lambda ()
                       (setq claude-remote--send-timer nil)
                       (claude-remote--abandon-send (format "unanswered after %d s" seconds))
                       (claude-remote-flush)))))

(defun claude-remote--compose-file (action)
  "The local queued copy of a compose ACTION in `claude-bus-user-dir', or nil."
  (when-let* ((name (plist-get action :local)))
    (expand-file-name name (claude-bus-user-dir (plist-get (plist-get action :args) :role)))))

(defun claude-remote--done (file action)
  (ignore-errors (delete-file file))
  (when-let* ((local (claude-remote--compose-file action))) (ignore-errors (delete-file local)))
  (setq claude-remote--sending nil)
  (claude-remote--count))

(defvar claude-remote--asking nil "The queued action whose stale question is open.")

(defun claude-remote--stale-no (file action)
  "True when the stale ACTION in FILE is not to be sent now: asked with Yes and No
pills, the answer flushes again.  A question already open is not asked twice."
  (unless (equal claude-remote--asking file)
    (setq claude-remote--asking file)
    (claude-phone-confirm
     (format "Send the %s from %s anyway?" (plist-get action :kind)
             (format-time-string "%H:%M" (plist-get action :ts)))
     (lambda () (setq claude-remote--asking nil)
       (let ((claude-remote-stale most-positive-fixnum)) (claude-remote-flush)))
     (lambda () (setq claude-remote--asking nil) (claude-remote--done file action) (claude-remote-flush))))
  t)

(defun claude-remote--try (failed &rest args)
  "`claude-remote--request' with ARGS; when it signals, FAILED gets the error's
text and nil returns."
  (condition-case err (apply #'claude-remote--request args)
    (error (funcall failed (error-message-string err)) nil)))

(defun claude-remote-flush ()
  "Send the oldest queued action, then the next, until the outbox is empty or a
send fails."
  (interactive)
  (unless claude-remote--sending
    (when-let* ((file (car (claude-remote--outbox)))
                (action (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))
      (if (and (> (- (float-time) (plist-get action :ts)) claude-remote-stale)
               (claude-remote--stale-no file action))
          nil
        (let ((token (list file))) ; this send, not a resend of the same file
          (setq claude-remote--sending token)
          (claude-remote--retry-send claude-remote-send-timeout)
          (setq claude-remote--send-buffer
                (claude-remote--try
                 (lambda (err)
                   ;; url.el can signal before it has a connection (a TLS handshake cut, -110)
                   (message "claude-remote: send %s failed: %s" (file-name-base file) err)
                   (setq claude-remote--sending nil)
                   (claude-remote--retry-send 5))
                 "POST" "act" (map-delete (copy-sequence action) :local)
                 (lambda (reply)
                   (let ((code (car reply)) (res (cdr reply))
                         (callback (gethash (plist-get action :id) claude-remote--callbacks)))
                     (cond
                      ((not (eq claude-remote--sending token))) ; given up: its resend answers
                      ((or (null code) (>= code 500))
                       ;; offline: kept, tried again soon and on the next connect
                       (setq claude-remote--sending nil)
                       (claude-remote--retry-send 5))
                      (t
                       (when (timerp claude-remote--send-timer) (cancel-timer claude-remote--send-timer))
                       (unless (plist-get res :ok)
                         (message "claude-remote: %s refused: %s" (plist-get action :kind)
                                  (or (plist-get res :error) code)))
                       (remhash (plist-get action :id) claude-remote--callbacks)
                       (claude-remote--done file action)
                       (when callback (funcall callback res))
                       (claude-remote-flush))))))))))))

(defun claude-remote-upload (file callback)
  "Upload FILE to the gateway; CALLBACK gets (OK . PATH-OR-ERROR-TEXT).
The gateway saves it under the device's uploads directory and answers the path."
  (let ((url-request-method "POST")
        (url-request-extra-headers (append (claude-remote--headers)
                                           '(("Content-Type" . "application/octet-stream"))))
        (url-request-data (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (insert-file-contents-literally file)
                            (buffer-string))))
    (claude-remote--strict
     (url-retrieve
      (claude-remote--url (concat "upload?name=" (url-hexify-string (file-name-nondirectory file))))
      (lambda (_status)
        (let* ((code (bound-and-true-p url-http-response-status))
               (body (progn (goto-char (point-min))
                            (when (re-search-forward "\r?\n\r?\n" nil t)
                              (decode-coding-string (buffer-substring (point) (point-max)) 'utf-8))))
               (res (and (eql code 200) (ignore-errors (claude-remote--json body)))))
          (claude-remote--kill-response)
          (funcall callback
                   (if (plist-get res :path)
                       (cons t (plist-get res :path))
                     (cons nil (cond ((null code) "the gateway cannot be reached")
                                     ((eql code 413) (format "too big: %s" (string-trim (or body ""))))
                                     (t (format "%s %s" code (string-trim (or body ""))))))))))
      nil t t))))

(defun claude-remote-download (name file callback)
  "Fetch NAME from the gateway's downloads into FILE; CALLBACK gets (OK . FILE-OR-ERROR-TEXT).
Returns the response buffer, whose size is the bytes received so far."
  (let ((url-request-extra-headers (claude-remote--headers)))
    (claude-remote--strict
     (url-retrieve
      (claude-remote--url (concat "download?name=" (url-hexify-string name)))
      (lambda (_status)
        (let* ((code (bound-and-true-p url-http-response-status))
               (start (progn (goto-char (point-min))
                             (and (re-search-forward "\r?\n\r?\n" nil t) (point))))
               (result
                (cond ((null code) (cons nil "the gateway cannot be reached"))
                      ((not (eql code 200))
                       (cons nil (format "%s %s" code (string-trim (decode-coding-string
                                                                    (buffer-substring (or start (point-max)) (point-max))
                                                                    'utf-8)))))
                      (t (condition-case err
                             (let ((coding-system-for-write 'binary))
                               (write-region start (point-max) file nil 'silent)
                               (cons t file))
                           (error (cons nil (format "cannot save %s: %s" file (error-message-string err)))))))))
          (claude-remote--kill-response)
          (funcall callback result)))
      nil t t))))

(defun claude-remote-act (kind args &optional argv callback local)
  "Queue the action KIND with ARGS (a plist of strings), or the API words ARGV for
kind api, and send it when the gateway can be reached.  CALLBACK gets the
gateway's result plist. LOCAL names the queued compose file kept in the user
directory until it is sent."
  (let* ((id (format "%s-%s" claude-remote-device (format-time-string "%s%N")))
         (action (list :id id :ts (floor (float-time)) :kind kind
                       :args (or args (make-hash-table)) :argv (vconcat argv) :local local)))
    (when callback (puthash id callback claude-remote--callbacks))
    ;; The user's last action from here: alarms follow the device last active
    (claude-bus--write-atomic (expand-file-name "last" (claude-bus--mkdir (claude-remote--path "sent")))
                              (number-to-string (floor (float-time))))
    (claude-bus--write-atomic (expand-file-name (concat id ".eld") (claude-remote--path "outbox"))
                              (prin1-to-string action))
    (claude-remote--count)
    (claude-remote-flush)
    id))

;;; The stream

(defun claude-remote--state-save ()
  (when claude-remote-state-file
    (claude-bus--write-atomic claude-remote-state-file
                              (prin1-to-string (list :cursor claude-remote--cursor :device claude-remote--device
                                                     :seen (seq-take claude-remote--seen 1000))))))

(defun claude-remote--state-load ()
  (when-let* ((file claude-remote-state-file)
              ((file-readable-p file))
              (state (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))
    (setq claude-remote--cursor (plist-get state :cursor)
          claude-remote--device (plist-get state :device))
    (setq claude-remote--seen nil)
    (dolist (k (reverse (plist-get state :seen))) (claude-remote--seen-p k))))

(defun claude-remote--event (event)
  "Act on one server-sent EVENT (an alist of id, event, data)."
  (let ((id (alist-get 'id event)) (kind (alist-get 'event event)))
    (pcase kind
      ("reset" (claude-remote--snapshot nil))
      ("hello" nil)
      (_ (when-let* ((rec (ignore-errors (claude-remote--json (alist-get 'data event)))))
           (claude-remote--handle rec))))
    (when id (setq claude-remote--cursor id))))

(defun claude-remote--parse-events (text)
  "The complete events in TEXT and the rest: (EVENTS . REST)."
  (let ((events nil) (start 0))
    (while (string-match "\r?\n\r?\n" text start)
      (let ((block (substring text start (match-beginning 0))) (event nil))
        (setq start (match-end 0))
        (dolist (line (split-string block "\r?\n" t))
          (when (string-match "\\`\\([a-z]+\\): ?\\(.*\\)\\'" line)
            (push (cons (intern (match-string 1 line)) (match-string 2 line)) event)))
        (when event (push event events))))
    (cons (nreverse events) (substring text start))))

(defun claude-remote--filter (proc chunk)
  (process-put proc 'heard (float-time))
  (let ((text (concat (process-get proc 'pending) (decode-coding-string chunk 'utf-8))))
    (unless (process-get proc 'body)
      (if (not (string-match "\r?\n\r?\n" text))
          (setq text (progn (process-put proc 'pending text) nil))
        (let ((head (substring text 0 (match-beginning 0))))
          (setq text (substring text (match-end 0)))
          (if (string-match "\\`HTTP/[0-9.]+ 200" head)
              (progn (process-put proc 'body t)
                     (setq claude-remote-connected t claude-remote--retry 2)
                     (claude-remote--back)
                     (force-mode-line-update t)
                     (claude-remote-flush)
                     (run-hooks 'claude-remote-connected-hook))
            (message "claude-remote: the gateway answered %s" (car (split-string head "\r?\n")))
            ;; A wrong or deleted key waits long; a gateway that is down (502) is tried again soon
            (process-put proc 'refused (string-match-p "\\`HTTP/[0-9.]+ 40[13]" head))
            (process-put proc 'reason (car (split-string head "\r?\n")))
            (delete-process proc)
            (setq text nil)))))
    (when text
      (let ((parsed (claude-remote--parse-events text)))
        (process-put proc 'pending (cdr parsed))
        (when (car parsed)
          (dolist (event (car parsed)) (claude-remote--event event))
          (claude-remote--state-save))))))

(defcustom claude-remote-stream-idle 70
  "Seconds the open stream may stay silent before it is taken for dead and opened
again.
The gateway sends a beat every 25 s; a connection the phone's sleep cut gets no
FIN and no error, so without this it would stay \"connected\" and hear nothing
until a restart."
  :type 'integer)

(defun claude-remote--drop-pool ()
  "Delete the connections url.el keeps for reuse: it pools every answered one,
keep-alive or not, and one the network cut while the phone slept fails the next
request on it."
  (when (boundp 'url-http-open-connections)
    (maphash (lambda (_k procs)
               (dolist (p procs) (when (processp p) (set-process-sentinel p #'ignore) (delete-process p))))
             url-http-open-connections)
    (clrhash url-http-open-connections)))

(defun claude-remote--down (proc reason)
  "The stream PROC ended for REASON: log it, drop what rode on the old network, try
again."
  (setq claude-remote-connected nil)
  (force-mode-line-update t)
  (run-hooks 'claude-remote-disconnected-hook)
  (when (eq proc claude-remote--process)
    (setq claude-remote--process nil)
    (unless claude-remote--lost (setq claude-remote--lost (cons (float-time) 0)))
    (claude-remote--drop-pool)
    (let ((delay (claude-remote--reconnect (process-get proc 'refused))))
      (message "claude-remote: stream lost (%s), reconnecting in %d s" reason delay))))

(defun claude-remote--sentinel (proc what)
  (unless (process-live-p proc)
    (claude-remote--down proc (or (process-get proc 'reason) (string-trim what)))))

(defun claude-remote--watch ()
  "Drop the open stream when it heard nothing for `claude-remote-stream-idle'
seconds."
  (let ((proc claude-remote--process))
    (if (not (process-live-p proc))
        (when (timerp claude-remote--watchdog)
          (cancel-timer claude-remote--watchdog)
          (setq claude-remote--watchdog nil))
      (let ((quiet (- (float-time) (or (process-get proc 'heard) 0))))
        (when (> quiet claude-remote-stream-idle)
          (set-process-sentinel proc #'ignore)
          (delete-process proc)
          (claude-remote--down proc (format "silent for %d s" quiet)))))))

(defun claude-remote--back ()
  "The stream answered 200: log a recovery, and resend at once a send that rode on
the old connection."
  (when-let* ((lost claude-remote--lost))
    (setq claude-remote--lost nil)
    (message "claude-remote: stream back after %d s, %d tries" (- (float-time) (car lost)) (cdr lost))
    (claude-remote--abandon-send "in flight across the reconnect")))

(defun claude-remote--reconnect (&optional slow)
  "Try the stream again after a pause that grows to a minute (five with SLOW, a
refusal).
Return the pause."
  (when (timerp claude-remote--timer) (cancel-timer claude-remote--timer))
  (let ((delay (if slow 300 claude-remote--retry)))
    (setq claude-remote--timer (run-at-time delay nil #'claude-remote--connect)
          claude-remote--retry (min 60 (* 2 claude-remote--retry)))
    delay))

(defun claude-remote--connect ()
  "Open the stream from `claude-remote--cursor'.  HTTP/1.0, so the body is not
chunked."
  (unless (process-live-p claude-remote--process)
    (when claude-remote--lost (cl-incf (cdr claude-remote--lost)))
    (let* ((u (url-generic-parse-url claude-remote-url))
           (tls (equal (url-type u) "https"))
           (path (concat (file-name-as-directory (url-filename u)) "stream?since="
                         (url-hexify-string (or claude-remote--cursor "")))))
      (condition-case err
          (let ((proc (or (claude-remote--strict
                           (open-network-stream "claude-remote" nil (url-host u) (url-port u)
                                                :type (if tls 'tls 'plain) :coding 'binary))
                          ;; a TLS handshake that fails verification (a changed CA) returns nil
                          (error "TLS handshake failed: the proxy's certificate does not match the pinned CA; pair again"))))
            (set-process-filter proc #'claude-remote--filter)
            (set-process-sentinel proc #'claude-remote--sentinel)
            (set-process-query-on-exit-flag proc nil)
            (setq claude-remote--process proc)
            (process-put proc 'heard (float-time))
            (unless (timerp claude-remote--watchdog)
              (setq claude-remote--watchdog (run-at-time 10 10 #'claude-remote--watch)))
            (process-send-string
             proc (concat "GET " path " HTTP/1.0\r\nHost: " (url-host u) "\r\nAccept: text/event-stream\r\n"
                          (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) (claude-remote--headers) "")
                          "\r\n")))
        (error (message "claude-remote: cannot reach the gateway: %s" (error-message-string err))
               (claude-remote--reconnect))))))

(defun claude-remote--role-names (names)
  "The snapshot's NAMES plist (:role \"Name\") as an alist keyed by role string."
  (cl-loop for (k v) on names by #'cddr
           collect (cons (substring (symbol-name k) 1) v)))

(defun claude-remote--snapshot (first)
  "Draw from /snapshot: hand on the records not seen (FIRST: only remember them),
then stream."
  (claude-remote--try
   (lambda (err) (message "claude-remote: snapshot failed: %s" err) (claude-remote--reconnect))
   "GET" "snapshot" nil
   (lambda (reply)
     (let ((snap (cdr reply)))
       (if (not (eql (car reply) 200))
           (progn (message "claude-remote: snapshot failed (%s)" (car reply)) (claude-remote--reconnect))
         (seq-do (lambda (rec) (claude-remote--handle rec first)) (plist-get snap :records))
         ;; The answers to widgets, history for a phone that joins late, are state, not events
         (seq-do (lambda (rec) (claude-remote--widget (plist-get rec :data))) (plist-get snap :widgets))
         (setq claude-remote--cursor (plist-get snap :cursor)
               claude-remote--device (plist-get snap :device)
               claude-remote--roles (append (plist-get snap :roles) nil)
               claude-role-names (claude-remote--role-names (plist-get snap :names)))
         ;; The assistant's display name comes from the host; `claude-agent-name' stays the fallback
         (when-let* ((name (plist-get (plist-get snap :agent) :name))
                     ((stringp name)) ((not (string-empty-p name))))
           (setq claude-agent-name name))
         (claude-remote--state-save)
         ;; not lost but replaced: no reconnect from its sentinel
         (let ((old claude-remote--process))
           (setq claude-remote--process nil)
           (when (process-live-p old) (delete-process old)))
         (claude-remote--connect))))))

;;; Android

;; On Android Emacs (`system-type' android) the cockpit always takes the narrow layout (one
;; main window with a tab line to the board, stage and todos), the cockpit's buffers are drawn at
;; `claude-remote-text-scale', and alarms to the user become Android notifications when this
;; device gets them: it was given the alarms permission, or the user acted from it lately.
;; Touch needs nothing of its own: a tap is mouse-1 on a button, which is a widget click.

(defcustom claude-remote-text-scale 1
  "The `text-scale-mode' step of the cockpit's buffers on a phone."
  :type 'integer)

(defcustom claude-remote-active-window 1800
  "Seconds after this device's last action during which alarms to the user notify
here."
  :type 'integer)

(defvar claude-remote--alarm-tail nil)
(defvar homun-layout-narrow-columns)
(defvar homun-layout-narrow-views)
(defvar homun-layout-transcript-function)
(defvar homun-layout-compose-function)
(declare-function claude-remote-home-compose-idle "claude-remote-home")
(declare-function claude-remote-home-soon "claude-remote-home")
(defvar widgetry-svg)
(defvar widgetry-touch-scale)
(defvar homun-layout-phone)
(defvar claude-transcript-phone)
(defvar homun-layout-compose-lines)
(defvar homun-layout-tabs-function)
(defvar homun-layout-phone-header)
(declare-function claude-remote-home-tabs "claude-remote-home")
(declare-function claude-remote-home-strip "claude-remote-home")

(defconst claude-remote--mode-hooks
  '(claude-transcript-mode-hook claude-board-mode-hook claude-events-mode-hook
    homun-stage-mode-hook claude-todos-view-mode-hook claude-agent-mode-hook))

(defun claude-remote--scale ()
  (text-scale-set claude-remote-text-scale))

(defun claude-remote--active-p ()
  "Non-nil when alarms to the user should notify on this device."
  (or (plist-get claude-remote--device :alarms)
      (when-let* ((attrs (file-attributes (claude-remote--path "sent" "last"))))
        (< (- (float-time) (float-time (file-attribute-modification-time attrs)))
           claude-remote-active-window))))

(defun claude-remote--notify (m)
  (when (and (fboundp 'android-notifications-notify) (claude-remote--active-p))
    (android-notifications-notify
     :title (format "%s: %s" (or (plist-get m :from) "homun") (or (plist-get m :alarm) "alarm"))
     :body (or (plist-get m :msg) "") :group "homun" :replaces-id 0)))

(defconst claude-remote--no-python
  '("sh" "-c" "cat >/dev/null; echo 'Not available on the phone: it has no python3 (use Compose)' >&2; exit 1")
  "Stands in for the cockpit's python3 helpers on a remote cockpit, which has none.")

(defvar claude-compose-program)
(defvar claude-transcript-widget-sender)
(defvar claude-compose-mechanic-program)
(defvar claude-transcript-reply-program)
(defvar claude-links-command)

(defconst claude-remote-compose-lines 5
  "Text lines of the phone's compose window, below its header line with Send.")

;;; Momentum scrolling
;; touch-screen.el scrolls while the finger moves and stops with it; it has no momentum (Emacs
;; 31.1; pixel-scroll's own momentum only follows touchpad scroll-end events).  The drag goes
;; through `touch-screen-handle-scroll', which calls `pixel-scroll-precision-scroll-down-page'
;; (or -up-page) with the event's pixels; the glide steps through the same call at the display
;; rate on a timer of its own that ends with it.  Its speed comes from the timed finger deltas
;; of the last `claude-remote-glide-window' seconds and decays exponentially like Android's fling.

(defvar claude-remote-glide-friction 1.2
  "Glide decay rate per second: the speed is multiplied by exp(-friction * dt).
Lower glides longer.")
(defvar claude-remote-glide-gain 1.0 "How much of the finger's speed at the lift the glide starts with.")
(defvar claude-remote-glide-window 0.08 "Seconds of finger movement before the lift the speed is taken from.")
(defvar claude-remote-glide-stop 20.0 "Speed in px/s below which the glide stops.")
(defvar claude-remote-glide-step 0.008 "Seconds between glide steps (about the display rate).")

(defvar claude-remote--glide-samples nil "Finger deltas as (TIME . DY), newest first.")
(defvar claude-remote--glide-speed 0.0 "Glide speed in px/s (negative: up).")
(defvar claude-remote--glide-carry 0.0
  "Glide speed left when a finger caught it; a flick the same way adds it back.")
(defvar claude-remote--glide-rest 0.0 "Sub-pixel remainder of the glide not scrolled yet.")
(defvar claude-remote--glide-last nil "Time of the last glide step.")
(defvar claude-remote--glide-window nil "Window the glide scrolls.")
(defvar claude-remote--glide-timer nil "The glide's step timer while it runs.")
(defvar touch-screen-current-tool)
(defvar touch-screen-precision-scroll)

(defun claude-remote--glide-velocity (samples)
  "Finger speed in px/s from SAMPLES, (TIME . DY) newest first, over the glide
window.
The oldest delta in the window only marks its start time.  Nil without two timed
samples."
  (let* ((now (caar samples))
         (recent (seq-take-while (lambda (s) (<= (- now (car s)) claude-remote-glide-window)) samples))
         (span (and (cdr recent) (- now (car (car (last recent)))))))
    (when (and span (> span 0.001))
      (/ (apply #'+ (mapcar #'cdr (butlast recent))) span))))

(defun claude-remote--glide-decay (speed dt)
  "SPEED after DT seconds of friction, or 0.0 once below
`claude-remote-glide-stop'."
  (let ((v (* speed (exp (- (* claude-remote-glide-friction dt))))))
    (if (< (abs v) claude-remote-glide-stop) 0.0 v)))

(defun claude-remote--glide-end ()
  "Stop the glide and its timer."
  (when claude-remote--glide-timer (cancel-timer claude-remote--glide-timer))
  (setq claude-remote--glide-timer nil claude-remote--glide-speed 0.0
        claude-remote--glide-carry 0.0 claude-remote--glide-rest 0.0
        claude-remote--glide-samples nil))

(defun claude-remote--glide-lift (now)
  "The finger lifted at NOW: start the glide from its speed, adding a caught one
the same way."
  (let ((v (if (> (- now (caar claude-remote--glide-samples)) claude-remote-glide-window) 0.0 ; held still
             (* claude-remote-glide-gain (or (claude-remote--glide-velocity claude-remote--glide-samples) 0.0)))))
    (when (> (* v claude-remote--glide-carry) 0) (setq v (+ v claude-remote--glide-carry)))
    (setq claude-remote--glide-speed v claude-remote--glide-carry 0.0
          claude-remote--glide-rest 0.0 claude-remote--glide-samples nil
          claude-remote--glide-last now)))

(defun claude-remote--glide-tick (&optional now)
  "One glide step at NOW (default the current time).  Return non-nil while the
glide goes on."
  (let ((now (or now (float-time))))
    (cond
     (touch-screen-current-tool                ; finger down: the touch scrolls, keep the speed
      (unless (zerop claude-remote--glide-speed)
        (setq claude-remote--glide-carry claude-remote--glide-speed
              claude-remote--glide-speed 0.0))
      t)
     (claude-remote--glide-samples (claude-remote--glide-lift now) t)
     ((or (zerop claude-remote--glide-speed) (not (window-live-p claude-remote--glide-window)))
      (claude-remote--glide-end)
      nil)
     (t (let* ((dt (min 0.05 (- now claude-remote--glide-last)))
               (v (claude-remote--glide-decay claude-remote--glide-speed dt))
               (px (+ claude-remote--glide-rest (* 0.5 (+ v claude-remote--glide-speed) dt)))
               (dy (truncate px)))
          (setq claude-remote--glide-rest (- px dy)
                claude-remote--glide-speed v
                claude-remote--glide-last now)
          (unless (zerop dy)
            (with-selected-window claude-remote--glide-window
              (condition-case nil
                  (if (> dy 0) (pixel-scroll-precision-scroll-down-page dy)
                    (pixel-scroll-precision-scroll-up-page (- dy)))
                ((beginning-of-buffer end-of-buffer) (setq claude-remote--glide-speed 0.0)))))
          t)))))

(defun claude-remote--glide-run ()
  "Timer function: step the glide, ending the timer with it."
  (unless (claude-remote--glide-tick) (claude-remote--glide-end)))

(defun claude-remote--glide-note (event &optional time)
  "Advice for `touch-screen-scroll': record EVENT's delta at TIME for the glide."
  (setq claude-remote--glide-window (nth 1 event))
  (push (cons (or time (float-time)) (nth 3 event)) claude-remote--glide-samples)
  (when (nthcdr 16 claude-remote--glide-samples) (setcdr (nthcdr 15 claude-remote--glide-samples) nil))
  (unless claude-remote--glide-timer
    (setq claude-remote--glide-timer
          (run-at-time claude-remote-glide-step claude-remote-glide-step #'claude-remote--glide-run))))

(defun claude-remote--countdown-tick (&optional _snap)
  "Redraw the mode lines while disconnected (the retry countdown).  Always non-nil."
  (unless claude-remote-connected (force-mode-line-update t))
  t)

(defun claude-remote--scroll-guard (fn &rest args)
  "Around advice for the pixel scroll page commands on the phone: a window whose
markers died (error \"Marker does not point anywhere\" from `pos-visible-in-window-p',
seen in the compose box after a redraw) is shown its buffer again, which makes new
ones, and the scroll is dropped; the end-of-buffer signals still pass."
  (condition-case err (apply fn args)
    ((beginning-of-buffer end-of-buffer) (signal (car err) (cdr err)))
    (error (set-window-buffer nil (current-buffer))
           (message "scroll: %s, window reset" (error-message-string err))
           nil)))

(defun claude-remote-momentum-setup ()
  "Pixel-wise touch scrolling that keeps gliding after the finger lifts."
  (setq touch-screen-precision-scroll t)
  (pixel-scroll-precision-mode 1)
  (dolist (f '(pixel-scroll-precision-scroll-down-page pixel-scroll-precision-scroll-up-page))
    (advice-add f :around #'claude-remote--scroll-guard))
  (advice-add 'touch-screen-scroll :before #'claude-remote--glide-note)
  (require 'claude-remote-swipe)
  (claude-remote-swipe-setup))

(defun claude-remote-android-setup ()
  "Narrow layout, text scale, and notifications for alarms to the user."
  (setq widgetry-touch-scale 1 ; every text widget a thumb-sized target
        homun-layout-phone t claude-transcript-phone t
        homun-layout-compose-lines claude-remote-compose-lines
        homun-layout-narrow-columns most-positive-fixnum
        ;; Android's SVG renderer draws no text: widgets as text
        widgetry-svg nil)
  ;; the transcript is the streamed file; one tab strip, no window commands needed
  (require 'claude-transcript)
  (setq homun-layout-transcript-function
        (lambda () (claude-transcript-open (or (claude-remote-transcript-file) (user-error "No transcript streamed yet"))))
        homun-layout-compose-function #'claude-remote-home-compose-idle
        homun-layout-narrow-views
        (append (seq-remove (lambda (v) (member (car v) '("Todos" "Stage" "Home" "Close"))) homun-layout-narrow-views)
                '(("Home" . claude-remote-home) ("Close" . (lambda () (claude-remote--stage-open nil))))))
  (setq-default mode-line-format nil)
  ;; the strip on top of the main window and the Talk, Board and Status tabs under it
  (setq homun-layout-tabs-function #'claude-remote-home-tabs
        homun-layout-phone-header '(:eval (claude-remote-home-strip)))
  (homun-clock-register 'claude-remote-countdown #'claude-remote--countdown-tick 1) ; retry countdown
  (claude-remote-momentum-setup)
  ;; The helpers that shell out to python3 do not exist here: a clear message instead of
  ;; `file-missing: Searching for program: python3'
  (setq claude-transcript-widget-sender #'claude-remote--widget-send
        claude-compose-program claude-remote--no-python
        claude-compose-mechanic-program claude-remote--no-python
        claude-transcript-reply-program claude-remote--no-python
        claude-links-command claude-remote--no-python)
  (with-eval-after-load 'claude-errwatch
    (advice-add 'claude-errwatch--send-mechanic :override
                (lambda (&rest _) (message "Not available on the phone: no mechanic requests from here"))))
  (dolist (hook claude-remote--mode-hooks) (add-hook hook #'claude-remote--scale))
  (unless claude-remote--alarm-tail
    (setq claude-remote--alarm-tail
          (claude-bus-tail (claude-bus-path "user" "inbox.jsonl") #'claude-remote--notify))))

;;; The transport

(defun claude-remote--user-write (role text)
  "Queue TEXT for ROLE: a local copy in the user directory shows it queued until it
is sent."
  (let ((id (format-time-string "%s%N")))
    (claude-bus--write-atomic (expand-file-name id (claude-bus-user-dir role)) text)
    (claude-remote-act "compose" (list :role (format "%s" role) :text text) nil
                       (lambda (res) (when (plist-get res :ok) (message "Delivered to %s" role)))
                       id)
    id))

(defun claude-remote--widget-send (text done failed _attrs)
  "Send a transcript widget's TEXT to the manager through the gateway, as Compose
does.
The text already names the widget and its value; DONE when queued, FAILED when
it cannot be."
  (condition-case err
      (progn (claude-remote--user-write (or (bound-and-true-p claude-remote-home-role) "manager") text)
             (message "Sent")
             (funcall done))
    (error (message "Not sent: %s" (error-message-string err))
           (when failed (funcall failed)))))

(defconst claude-remote-transport
  (list :tail (lambda (file handler)
                (let ((cell (cons file handler))) (push cell claude-remote--tails) cell))
        :untail (lambda (cell) (setq claude-remote--tails (delq cell claude-remote--tails)))
        :send (lambda (to alarm msg) (claude-remote-act "alarm" (list :to to :alarm alarm :msg msg)) "sent")
        :user-write #'claude-remote--user-write
        :reader-ok (lambda (_role) t)
        :roles (lambda () claude-remote--roles))
  "The `claude-bus-transport' of a remote cockpit.")

;;;###autoload
(defun claude-remote-start ()
  "Run this Emacs's cockpit through the gateway at `claude-remote-url'."
  (interactive)
  (unless (and claude-remote-url claude-remote-key)
    (user-error "Not paired: Pair phone in the desktop cockpit, then its init.el line"))
  (setq claude-bus-dir (claude-remote--path "bus")
        claude-bus-device claude-remote-device
        claude-bus-transport claude-remote-transport
        homun-stage-dir (claude-remote--path "stage")
        claude-approve-answer-function #'claude-remote--approve-answer
        claude-remote-state-file (claude-remote--path "state.eld"))
  (claude-bus--mkdir claude-bus-dir)
  (homun-stage-load)
  (claude-remote--arm-loaded)
  (claude-remote--state-load)
  (when (eq system-type 'android) (claude-remote-android-setup))
  (if claude-remote--cursor (claude-remote--connect) (claude-remote--snapshot t)))

;;; Fonts

;; The desktop cockpit's mono face and a symbols fallback, fetched from GET /fonts into the
;; directory Emacs on Android scans for user fonts (~/fonts) when their sha256 differs.

(defconst claude-remote-font-family "JetBrains Mono" "The desktop cockpit's default face.")
(defconst claude-remote-font-symbols '("Symbols Nerd Font Mono" "Noto Sans Symbols" "Noto Sans Symbols 2")
  "Fallback families for symbols, most wanted first.")

(defun claude-remote--font-frames (body)
  "The (SHA NAME . BYTES) frames of the unibyte BODY of GET /fonts."
  (let ((pos 0) out)
    (while (string-match "\\([0-9a-f]\\{64\\}\\) \\([^ \n/]+\\) \\([0-9]+\\)\n" body pos)
      (let* ((start (match-end 0)) (len (string-to-number (match-string 3 body))))
        (push (cons (match-string 1 body) (cons (match-string 2 body) (substring body start (+ start len)))) out)
        (setq pos (+ start len 1))))
    (nreverse out)))

(defun claude-remote--font-install (frames dir)
  "Write the FRAMES whose file in DIR is missing or differs; the names written."
  (let (written)
    (dolist (f frames (nreverse written))
      (let ((file (expand-file-name (cadr f) dir)))
        (unless (and (file-exists-p file)
                     (equal (car f) (with-temp-buffer
                                      (set-buffer-multibyte nil)
                                      (insert-file-contents-literally file)
                                      (secure-hash 'sha256 (current-buffer)))))
          (make-directory dir t)
          (let ((coding-system-for-write 'binary)) (write-region (cddr f) nil file nil 'silent))
          (push (cadr f) written))))))

;; The phone's fonts do not all carry every symbol (Android Emacs may not see the fetched ones).
;; A display-table entry per missing glyph shows a covered look-alike, on the phone only.
(defconst claude-remote-glyph-map
  '((?↺ . ?→) (?⏺ . ?●) (?☐ . ?□) (?☑ . ?■) (?☰ . ?≡) (?⚙ . ?*) (?✎ . ?») (?➤ . ?▶))
  "Glyphs the phone's fonts lack, each with the one drawn instead.")

(defconst claude-remote-glyph-ok
  "·—…‹›←→↓↔↗−∴⋯⌘⏻─│┆┊┼▅█▉▊▋▌▍▎▏░■▪▲▶▾◀◆◈◌●✓✗⚠⠇⠋⠏⠙⠦⠧⠴⠸⠹⠼📱🔒🖥🧮□≡»*"
  "Every other non-ASCII glyph the phone UI uses: drawn by JetBrains Mono, Noto
Symbols or Noto Color Emoji.")

;; Emacs on Android draws only outline (glyf) fonts: sfnt.c reads no CBDT or COLR tables, so Noto
;; Color Emoji cannot be drawn.  The four marker emoji get a coloured text look-alike instead.
(defface claude-remote-marker-red '((t :inherit error)) "Marker 🔺." :group 'claude)
(defface claude-remote-marker-orange '((t :inherit warning)) "Marker 🔸." :group 'claude)
(defface claude-remote-marker-blue '((t :inherit font-lock-function-name-face)) "Marker 🔹." :group 'claude)
(defface claude-remote-marker-green '((t :inherit success)) "Marker 🐢." :group 'claude)

(defconst claude-remote-marker-map
  '((?🔺 ?▲ claude-remote-marker-red) (?🔸 ?◆ claude-remote-marker-orange)
    (?🔹 ?▪ claude-remote-marker-blue) (?🐢 ?✓ claude-remote-marker-green))
  "The marker emoji, each with the glyph and face drawn instead.")

(defconst claude-remote-emoji-fonts '("Noto Sans Symbols 2" "Noto Sans Symbols")
  "Monochrome outline families for emoji and symbol ranges, most wanted first.")

(defun claude-remote-glyphs-install ()
  "Show the look-alikes of `claude-remote-glyph-map' in place of the glyphs the
phone lacks."
  (unless standard-display-table (setq standard-display-table (make-display-table)))
  (pcase-dolist (`(,from ,to ,face) claude-remote-marker-map)
    (aset standard-display-table from (vector (make-glyph-code to face))))
  (pcase-dolist (`(,from . ,to) claude-remote-glyph-map)
    (aset standard-display-table from (vector to))))

(defun claude-remote--font-apply ()
  "Use the desktop's family and symbol fallbacks, those Emacs can see; non-nil when
the family is there."
  (claude-remote-glyphs-install)
  (let ((families (font-family-list)))
    (dolist (fam (reverse claude-remote-font-symbols))
      (when (member fam families)
        (set-fontset-font t 'symbol (font-spec :family fam) nil 'prepend)
        (set-fontset-font t 'unicode (font-spec :family fam) nil 'append)))
    (dolist (fam (reverse claude-remote-emoji-fonts))
      (when (member fam families)
        (dolist (target '(emoji symbol (#x1F300 . #x1FAFF) (#x2600 . #x27BF)))
          (set-fontset-font t target (font-spec :family fam) nil 'append))))
    (when (member claude-remote-font-family families)
      (set-face-attribute 'default nil :family claude-remote-font-family)
      t)))

(defun claude-remote-fonts ()
  "Fetch the desktop's fonts into ~/fonts when they changed, then apply them."
  (interactive)
  (let ((dir (expand-file-name "~/fonts/")) (url-request-extra-headers (claude-remote--headers)))
    (claude-remote--font-apply)
    (claude-remote--strict
     (url-retrieve
      (claude-remote--url "fonts")
      (lambda (_status)
        (let ((code (bound-and-true-p url-http-response-status)) written)
          (when (eql code 200)
            (goto-char (point-min))
            (when (re-search-forward "\r?\n\r?\n" nil t)
              (setq written (claude-remote--font-install
                             (claude-remote--font-frames (buffer-substring-no-properties (point) (point-max))) dir))))
          (claude-remote--kill-response)
          (when written
            (message (if (claude-remote--font-apply) "fonts installed" "fonts installed: restart Emacs")))))
      nil t t))))

;;; Start

;; The bootstrap block in init.el (homun-init.el) fetches this code, sets the `claude-remote-'
;; url, key, device and CA variables and calls this; it also owns the update and repair commands.

;;;###autoload
(defun homun-remote-start ()
  "Start the remote cockpit with the variables the bootstrap block set."
  (interactive)
  ;; cockpit.el is not sent here: load the saved settings the way it does (file under ~/claude/.services/emacs, which `homun-repair' leaves alone)
  (require 'claude-settings)
  (claude-settings-load)
  ;; the desktop cockpit's theme (its init.el is not sent here either)
  (load-theme 'modus-vivendi t)
  (menu-bar-mode -1)
  (tool-bar-mode -1) ; the phone's screen is for the cockpit
  ;; first, so that errors of the start itself wait in the queue for the stream
  (require 'claude-remote-report)
  (claude-remote-report-start)
  (claude-remote-start)
  ;; a phone has no keyboard: the touch home opens by itself
  (when (eq system-type 'android)
    (ignore-errors (claude-remote-fonts))
    (require 'claude-remote-home)
    (claude-remote-home-text-restore)
    (add-hook 'claude-remote-connected-hook #'claude-remote-home-draw)
    ;; from init.el: after the startup screen would have been drawn, instead of it
    (if after-init-time (claude-remote-home)
      (setq inhibit-startup-screen t)
      (add-hook 'emacs-startup-hook #'claude-remote-home 90))))

(defun claude-remote-stop ()
  "Close the stream; the bus goes back to local files."
  (interactive)
  (when (timerp claude-remote--timer) (cancel-timer claude-remote--timer))
  (when (timerp claude-remote--watchdog) (cancel-timer claude-remote--watchdog))
  (setq claude-remote--watchdog nil claude-remote--lost nil)
  (let ((proc claude-remote--process))
    (setq claude-remote--process nil)
    (when (process-live-p proc) (delete-process proc)))
  (setq claude-bus-transport nil claude-remote-connected nil
        claude-approve-answer-function nil))

(provide 'claude-remote)
;;; claude-remote.el ends here
