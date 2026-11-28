;;; claude-remote-test.el --- ERT for the remote cockpit's transport -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-remote-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-remote)

(ert-deftest claude-remote-parse-events ()
  (let ((r (claude-remote--parse-events "id: 1-2\nevent: bus\ndata: {}\n\n: beat\n\nid: 1-3\nev")))
    (should (equal (car r) '(((data . "{}") (event . "bus") (id . "1-2")))))
    (should (equal (cdr r) "id: 1-3\nev"))))

(ert-deftest claude-remote-record-once ()
  (let* ((claude-remote--seen nil)
         (claude-bus-dir (make-temp-file "bus" t)) (got nil)
         (claude-remote--tails nil)
         (claude-bus-transport claude-remote-transport)
         (rec (list :kind "bus" :source "user" :data (list :id "a" :msg "hi"))))
    (claude-bus-tail (claude-bus-path "user" "inbox.jsonl") (lambda (m) (push (plist-get m :msg) got)))
    (claude-remote--handle (list :kind "bus" :source "user" :data (list :id "old")) t)
    (claude-remote--handle rec)
    (claude-remote--handle rec)
    (claude-remote--handle (list :kind "bus" :source "user" :data (list :id "old" :msg "again")))
    (should (equal got '("hi")))))

(ert-deftest claude-remote-approval-is-the-desktop-scene ()
  (let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
         (homun-stage-scenes (make-hash-table :test #'equal))
         (homun-stage-actions (make-hash-table :test #'equal))
         (claude-approve-guard 0) (claude-approve--pending nil)
         (claude-approve--shown (make-hash-table :test 'equal))
         (claude-approve-answer-function #'claude-remote--approve-answer) (sent nil)
         (fresh `((id . "1-1") (tool . "Bash") (summary . "ls") (since . ,(floor (float-time)))))
         (root (claude-approve-scene (list fresh '((id . "2-2") (tool . "Bash") (since . 1000))) 0)))
    (cl-letf (((symbol-function 'claude-remote-act) (lambda (kind args &rest _) (push (cons kind args) sent)))
              ((symbol-function 'homun-stage-display) #'ignore)
              ((symbol-function 'homun-stage-render) #'ignore))
      (claude-remote--handle
       (list :kind "scene" :source "approve.json"
             :data (list :id "approve" :title "Permissions (2)" :root (json-parse-string (homun-stage-encode root) :object-type 'plist))))
      ;; The expired request has no card here either
      (should (equal (mapcar (lambda (r) (alist-get 'id r)) claude-approve--pending) '("1-1")))
      (funcall (gethash "approve-1-1-deny" homun-stage-actions))
      (should (equal sent '(("approve" :id "1-1" :answer "deny"))))
      (should-not (gethash "approve" homun-stage-scenes)))))

(ert-deftest claude-remote-stale-action-asks ()
  (let* ((claude-remote-dir (file-name-as-directory (make-temp-file "remote" t)))
         (claude-remote--sending nil) (claude-remote--asking nil) (asked nil) (posted nil))
    (cl-letf (((symbol-function 'claude-remote--request) (lambda (&rest args) (push args posted)))
              ((symbol-function 'claude-phone-confirm) (lambda (_p _yes no) (setq asked no))))
      (claude-bus--write-atomic (expand-file-name "phone-1.eld" (claude-remote--path "outbox"))
                                (prin1-to-string (list :id "phone-1" :ts 1 :kind "alarm" :args nil)))
      (claude-remote-flush)
      (should asked)
      (should-not posted)
      (claude-remote-flush) ; still open: not asked twice
      (funcall asked)       ; the No pill
      (should-not (claude-remote--outbox)))))

(ert-deftest claude-remote-hung-send-is-resent ()
  "A send that never answers (a connection the phone's sleep cut) is given up after the timeout
and sent again, so the messages queued behind it do not wait; the bottom line counts them."
  (let* ((claude-remote-dir (file-name-as-directory (make-temp-file "remote" t)))
         (claude-remote--sending nil) (claude-remote--send-timer nil) (claude-remote-queued 0)
         (claude-remote-device "phone") (posted nil) (timers nil))
    (cl-letf (((symbol-function 'claude-remote--request) (lambda (&rest args) (push args posted) nil))
              ((symbol-function 'run-at-time) (lambda (secs _r f) (push (cons secs f) timers) 'timer))
              ((symbol-function 'timerp) (lambda (x) (eq x 'timer)))
              ((symbol-function 'cancel-timer) #'ignore))
      (claude-remote-act "alarm" nil)
      (claude-remote-act "alarm" nil)
      (should (= 2 claude-remote-queued))
      (should (string-match-p "queued 2" (progn (require 'claude-remote-home) (claude-remote-home--queued))))
      (should (= 1 (length posted)))      ; one at a time; the first hangs
      (should (= claude-remote-send-timeout (car (car timers))))
      (funcall (cdr (car timers)))        ; the timeout: given up, sent again
      (should (= 2 (length posted)))
      (let ((late (nth 3 (car (last posted)))) (now (nth 3 (car posted))))
        (funcall late '(200 :ok t))       ; the hung first reply, late: ignored
        (should (= 2 claude-remote-queued))
        (funcall now '(200 :ok t)))       ; the resend's: done, the next goes
      (should (= 1 claude-remote-queued))
      (should (= 3 (length posted))))))

(ert-deftest claude-remote-notify-when-active ()
  (let* ((claude-remote-dir (file-name-as-directory (make-temp-file "remote" t)))
         (claude-remote--device nil) (shown nil))
    (cl-letf (((symbol-function 'android-notifications-notify) (lambda (&rest args) (push args shown))))
      (claude-remote--notify (list :from "manager" :alarm "done" :msg "x"))
      (should-not shown)                ; never acted from here, no alarms permission
      (claude-bus--write-atomic (claude-remote--path "sent" "last") "1")
      (claude-remote--notify (list :from "manager" :alarm "done" :msg "x"))
      (should (equal (plist-get (car shown) :title) "manager: done")))))

(ert-deftest claude-remote-transcript-is-a-local-file ()
  (let* ((claude-remote-dir (file-name-as-directory (make-temp-file "remote" t)))
         (claude-remote--seen nil)
         (rec (list :kind "transcript" :source "s1" :data (list :type "user" :uuid "u1"))))
    (claude-remote--handle rec t)
    (claude-remote--handle rec t)
    (claude-remote--handle (list :kind "transcript" :source "s1" :data (list :truncated t)) t)
    (let ((file (expand-file-name "s1.jsonl" (claude-remote--path "transcript"))))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "{\"type\":\"user\",\"uuid\":\"u1\"}\n")))))

(ert-deftest claude-remote-connect-survives-a-failed-handshake ()
  "open-network-stream returns nil on a refused TLS handshake: retry, never signal."
  (let ((claude-remote-url "https://127.0.0.1:1/x/") (claude-remote--process nil)
        (claude-remote--timer nil) (claude-remote--retry 2) (claude-remote-key "k"))
    (cl-letf (((symbol-function 'open-network-stream) (lambda (&rest _) nil)))
      (claude-remote--connect)
      (claude-remote--connect)
      (should (timerp claude-remote--timer))
      (should-not claude-remote--process)
      (cancel-timer claude-remote--timer))))

(defvar homun-test-var 1)

(ert-deftest claude-remote-start-loads-the-saved-settings ()
  "The phone never runs cockpit.el, so its start path loads what was saved."
  (require 'claude-settings)
  (let ((claude-settings-file (make-temp-file "settings" nil ".eld")))
    (with-temp-file claude-settings-file (prin1 '((homun-test-var . 7)) (current-buffer)))
    (cl-letf (((symbol-function 'claude-remote-start) #'ignore)
              ((symbol-function 'claude-remote-report-start) #'ignore))
      (homun-remote-start))
    (should (= 7 (default-value 'homun-test-var)))))

(ert-deftest claude-remote-compose-window-fits-buttons-and-text ()
  "On a phone layout the compose window, with a long draft and squeezed as the on-screen
keyboard does, keeps Send and Cancel in its header line and its text lines in view."
  (require 'claude-remote-home)
  (let ((homun-layout-phone t) (homun-layout-narrow-columns most-positive-fixnum)
        (homun-layout-compose-lines claude-remote-compose-lines)
        (config (current-window-configuration)))
    (unwind-protect
        (cl-letf (((symbol-function 'frame-toggle-on-screen-keyboard) #'ignore))
          (homun-layout--build)
          (claude-remote-home-compose)
          (insert (mapconcat (lambda (i) (format "Line %d of a long draft" i)) (number-sequence 1 40) "\n"))
          (let ((window (homun-layout-window 'compose)))
            ;; the keyboard shrinks the frame: Emacs takes the lines from every window
            (window-resize window (- 2 (window-total-height window)) nil t)
            (homun-layout--rescale (selected-frame))
            (should (>= (window-body-height window) claude-remote-compose-lines))
            (should-not (window-parameter window 'tab-line-format))
            (should (eq 'none (window-parameter (homun-layout-window 'transcript) 'mode-line-format)))
            (should (equal (buffer-local-value (quote header-line-format) (window-buffer window))
                           (quote (:eval (claude-remote-home--compose-header)))))
            (should (string-match-p "To manager ▾.*Cancel.*Queue" (claude-remote-home--compose-header)))
            (let ((claude-remote-connected t))
              (should (string-match-p "Cancel.*Send *\\'" (claude-remote-home--compose-header))))
            (should-not (string-match-p "Send" (with-current-buffer (window-buffer window) (buffer-string))))))
      (when-let* ((b (get-buffer claude-remote-home-compose-buffer))) (kill-buffer b))
      (let ((ignore-window-parameters t)) (set-window-configuration config)))))

(ert-deftest claude-remote-compose-idle-is-a-launcher ()
  "Not selected, the compose window is one line with a placeholder and no action row;
selected, it has the row and its text lines (the design's Transcript and Compose)."
  (require 'claude-remote-home)
  (let ((homun-layout-phone t) (homun-layout-narrow-columns most-positive-fixnum)
        (homun-layout-compose-lines claude-remote-compose-lines)
        (config (current-window-configuration)))
    (unwind-protect
        (cl-letf (((symbol-function 'frame-toggle-on-screen-keyboard) #'ignore))
          (homun-layout--build)
          (select-window (homun-layout-window 'transcript))
          (claude-remote-home-compose-idle)
          (let ((window (homun-layout-window 'compose)))
            (with-current-buffer (window-buffer window)
              (should-not header-line-format)
              (should (string-match-p "Message manager"
                                      (overlay-get claude-remote-home--placeholder 'before-string))))
            (should (= 1 (window-body-height window)))
            ;; idle: the tabs are the main window's mode line, just above the launcher
            (should (equal '(:eval (homun-layout-narrow-tabs))
                           (window-parameter (homun-layout-window 'transcript) 'mode-line-format)))
            (should-not (window-parameter (homun-layout-window 'transcript) 'tab-line-format))
            (claude-remote-home-compose)
            (with-current-buffer (window-buffer window)
              (should header-line-format)
              (should-not (overlay-get claude-remote-home--placeholder 'before-string)))
            (should (eq 'none (window-parameter (homun-layout-window 'transcript) 'mode-line-format)))
            (should (= homun-layout-compose-lines claude-remote-compose-lines))
            (should (> (window-body-height window) 1))))
      (when-let* ((b (get-buffer claude-remote-home-compose-buffer))) (kill-buffer b))
      (let ((ignore-window-parameters t)) (set-window-configuration config)))))

(defvar touch-screen-current-tool)

;; synthetic touch-screen-scroll events, 10 px each 16 ms: 625 px/s
(defun claude-remote-test--drag (t0 n)
  (dotimes (i n) (claude-remote--glide-note (list 'touchscreen-scroll (selected-window) 0 10) (+ t0 (* i 0.016)))))

(ert-deftest claude-remote-glide-velocity-from-timestamps ()
  (let ((claude-remote--glide-samples nil) (claude-remote--glide-timer t))
    (claude-remote-test--drag 100.0 10)
    ;; only the last 80 ms count, and a slow start does not drag the speed down
    (push (cons 99.0 1) (cdr (last claude-remote--glide-samples)))
    (should (< (abs (- (claude-remote--glide-velocity claude-remote--glide-samples) 625.0)) 1.0))
    (should-not (claude-remote--glide-velocity (list (cons 1.0 10))))))

(ert-deftest claude-remote-glide-decay-curve ()
  (let ((claude-remote-glide-friction 2.0) (claude-remote-glide-stop 20.0))
    (should (< (abs (- (claude-remote--glide-decay 1000.0 0.5) (* 1000 (exp -1.0)))) 1e-9))
    ;; steps compose: two halves are one whole
    (should (< (abs (- (claude-remote--glide-decay (claude-remote--glide-decay 1000.0 0.25) 0.25)
                       (claude-remote--glide-decay 1000.0 0.5)))
               1e-9))
    (should (= 0.0 (claude-remote--glide-decay 21.0 0.1)))
    (should (< (claude-remote--glide-decay -1000.0 0.1) 0))))

(ert-deftest claude-remote-glide-steps-and-stops ()
  (let ((claude-remote--glide-samples nil) (claude-remote--glide-timer t) (claude-remote--glide-speed 0.0)
        (claude-remote--glide-carry 0.0) (claude-remote--glide-rest 0.0) (moved 0)
        (touch-screen-current-tool nil))
    (cl-letf (((symbol-function 'pixel-scroll-precision-scroll-down-page) (lambda (n) (cl-incf moved n)))
              ((symbol-function 'cancel-timer) #'ignore))
      (claude-remote-test--drag 0.0 10)
      (should (claude-remote--glide-tick 0.15))  ; lift
      (should (< (abs (- claude-remote--glide-speed 625.0)) 1.0))
      (let ((now 0.15)) (while (claude-remote--glide-tick (cl-incf now 0.008))))
      ;; integral of v0 e^-kt down to the stop speed
      (should (< (abs (- moved (/ (- 625.0 20.0) claude-remote-glide-friction))) 5))
      (should (null claude-remote--glide-timer))
      ;; a finger catches a glide and a flick the same way adds to it
      (setq claude-remote--glide-timer t)
      (claude-remote-test--drag 1.0 10)
      (claude-remote--glide-tick 1.15)
      (setq touch-screen-current-tool '(1))
      (claude-remote--glide-tick 1.16)
      (should (zerop claude-remote--glide-speed))
      (setq touch-screen-current-tool nil)
      (claude-remote-test--drag 1.2 10)
      (claude-remote--glide-tick 1.35)
      (should (> claude-remote--glide-speed 1200)))))

(ert-deftest claude-remote-mirrors-any-homund-scene ()
  "A scene record of the gateway that is not an approval is shown, patched and closed here."
  (let ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
        (homun-stage-scenes (make-hash-table :test #'equal))
        (rec (lambda (text)
               (list :kind "scene" :source "roll.json"
                     :data (list :id "roll" :owner_role "manager" :title "Roll" :lifetime "turn"
                                 :root (list :type "text" :id "t" :text text))))))
    (cl-letf (((symbol-function 'homun-stage-render) #'ignore))
      (claude-remote--handle (funcall rec "one"))
      (should (equal "one" (alist-get 'text (homun-stage-scene-root (homun-stage-scene "roll")))))
      (should (equal "manager" (homun-stage-scene-owner (homun-stage-scene "roll"))))
      (claude-remote--handle (list :kind "closed" :source "roll.json" :data (list :id "roll")))
      (should-not (gethash "roll" homun-stage-scenes)))))


;;; Recovery: a stream the phone's sleep cut, a gateway that drops it, a request that signals

(defmacro claude-remote-test--gateway (accepts beat &rest body)
  "Run BODY with a local plain gateway that answers each stream with 200 and, when BEAT,
one beat, then goes silent; ACCEPTS (a symbol) holds its connections, newest first."
  (declare (indent 2))
  `(let* ((,accepts nil)
          (server (make-network-process
                   :name "gw" :server t :host "127.0.0.1" :service t :family 'ipv4
                   :log (lambda (_s conn _m)
                          (push conn ,accepts)
                          (process-send-string conn (concat "HTTP/1.0 200 OK\r\n\r\n" (if ,beat ": beat\n\n" ""))))))
          (claude-remote-url (format "http://127.0.0.1:%d/x/" (process-contact server :service)))
          (claude-remote-key "k") (claude-remote-dir (file-name-as-directory (make-temp-file "remote" t)))
          (claude-remote-state-file nil) (claude-remote--cursor "c")
          (claude-remote--process nil) (claude-remote--timer nil) (claude-remote--watchdog nil)
          (claude-remote--lost nil) (claude-remote--retry 2) (claude-remote-connected nil)
          (claude-remote--sending nil) (claude-remote-connected-hook nil)
          (inhibit-message t))
     (unwind-protect (progn ,@body)
       (claude-remote-stop)
       (dolist (c ,accepts) (delete-process c))
       (delete-process server))))

(defun claude-remote-test--until (pred)
  (let ((end (+ (float-time) 5)))
    (while (and (not (funcall pred)) (< (float-time) end)) (accept-process-output nil 0.05))
    (funcall pred)))

(defun claude-remote-test--logged (re)
  (with-current-buffer (messages-buffer)
    (save-excursion (goto-char (point-min)) (re-search-forward re nil t))))

(ert-deftest claude-remote-silent-stream-reconnects ()
  "A stream that hears no beat for `claude-remote-stream-idle' (the phone slept, the connection
was cut without a FIN) is dropped, logged and opened again; the recovery is logged too."
  (claude-remote-test--gateway accepts t
    (claude-remote--connect)
    (should (claude-remote-test--until (lambda () claude-remote-connected)))
    (should (timerp claude-remote--watchdog))
    (let ((old claude-remote--process))
      (claude-remote--watch)                    ; heard just now: kept
      (should (eq old claude-remote--process))
      (process-put old 'heard (- (float-time) 300))
      (claude-remote--watch)
      (should-not (process-live-p old))
      (should-not claude-remote-connected)
      (should claude-remote--lost)
      (should (timerp claude-remote--timer))
      (should (claude-remote-test--logged "stream lost (silent for 3[0-9][0-9] s), reconnecting in 2 s"))
      (claude-remote--connect)                  ; the reconnect timer
      (should (claude-remote-test--until (lambda () claude-remote-connected)))
      (should-not claude-remote--lost)
      (should (= 2 (length accepts)))
      (should (claude-remote-test--logged "stream back after [0-9]+ s, 1 tries")))))

(ert-deftest claude-remote-cut-stream-reconnects-and-resends ()
  "The gateway ends the stream mid-way (a restart, a TLS abort): the sentinel logs why and
reconnects with backoff; a send in flight across the cut is resent when the stream is back."
  (claude-remote-test--gateway accepts nil
    (claude-remote--connect)
    (should (claude-remote-test--until (lambda () claude-remote-connected)))
    (delete-process (car accepts))
    (should (claude-remote-test--until (lambda () claude-remote--lost)))
    (should (claude-remote-test--logged "stream lost (.+), reconnecting in 2 s"))
    (should (= 4 claude-remote--retry))         ; backoff doubles
    (let ((posted nil))
      (setq claude-remote--sending (list (expand-file-name "a1.eld" claude-remote-dir)))
      (cl-letf (((symbol-function 'claude-remote-flush) (lambda () (push 'flush posted))))
        (claude-remote--connect)
        (should (claude-remote-test--until (lambda () claude-remote-connected))))
      (should-not claude-remote--sending)       ; given up, the flush on connect resends it
      (should (memq 'flush posted))
      (should (claude-remote-test--logged "send a1 in flight across the reconnect, resending")))))

(ert-deftest claude-remote-signalling-send-retries-soon ()
  "url.el signals before it has a connection (GnuTLS -110 in the handshake): the send is
logged and tried again in 5 s, not left in flight."
  (let* ((claude-remote-dir (file-name-as-directory (make-temp-file "remote" t)))
         (claude-remote--sending nil) (claude-remote--send-timer nil) (claude-remote-queued 0)
         (claude-remote-device "phone") (timers nil) (inhibit-message t))
    (cl-letf (((symbol-function 'claude-remote--request)
               (lambda (&rest _) (signal 'gnutls-error '("GnuTLS error: #<process x>, -110"))))
              ((symbol-function 'run-at-time) (lambda (secs _r f) (push (cons secs f) timers) 'timer))
              ((symbol-function 'timerp) (lambda (x) (eq x 'timer)))
              ((symbol-function 'cancel-timer) #'ignore))
      (claude-remote-act "alarm" nil)
      (should-not claude-remote--sending)
      (should (= 5 (car (car timers))))
      (should (= 1 claude-remote-queued))
      (should (claude-remote-test--logged "send phone-[0-9]+ failed: .*-110")))))

(ert-deftest claude-remote-signalling-snapshot-reconnects ()
  (let ((claude-remote--timer nil) (claude-remote--retry 2) (inhibit-message t))
    (cl-letf (((symbol-function 'claude-remote--request) (lambda (&rest _) (error "boom"))))
      (claude-remote--snapshot t)
      (should (timerp claude-remote--timer))
      (cancel-timer claude-remote--timer)
      (should (claude-remote-test--logged "snapshot failed: boom")))))

(ert-deftest claude-remote-lost-stream-drops-url-pool ()
  "url.el pools every answered connection, keep-alive or not: a lost stream empties the pool."
  (let* ((proc (make-pipe-process :name "pooled" :noquery t))
         (url-http-open-connections (make-hash-table :test #'equal)))
    (puthash '("h" 1) (list proc) url-http-open-connections)
    (claude-remote--drop-pool)
    (should-not (process-live-p proc))
    (should (zerop (hash-table-count url-http-open-connections)))))

(ert-deftest claude-remote-dropdown-rows-equal-width ()
  (require 'claude-remote-home)
  (let ((claude-remote-home-role "tally"))
    (cl-letf (((symbol-function 'claude-remote-home--roles) (lambda () '("tally" "bolt" "dispatcher")))
              ((symbol-function 'claude-role-name) (lambda (r) (if (equal r "bolt") "Bo" r))))
      (let ((widths (mapcar (lambda (r) (string-width (cdr r))) (claude-remote-home--dropdown-labels))))
        (should (= 3 (length widths)))
        (should (apply #'= widths))))))

(ert-deftest claude-remote-seen-is-bounded-and-newest-first ()
  (let ((claude-remote--seen nil) (claude-remote--seen-max 4))
    (should-not (claude-remote--seen-p "a"))
    (should (claude-remote--seen-p "a"))
    (dolist (k '("b" "c" "d" "e")) (claude-remote--seen-p k))
    (should (equal claude-remote--seen '("e" "d" "c" "b")))
    (should-not (claude-remote--seen-p "a"))))

(ert-deftest claude-remote-seen-adopts-old-hash-table-on-reload ()
  "Loading the file over the old table-shaped state keeps its keys as the new list."
  (let ((claude-remote--seen (make-hash-table :test #'equal)))
    (puthash "old" t claude-remote--seen) (puthash "newer" t claude-remote--seen)
    (load (locate-library "claude-remote") nil t)
    (should (equal claude-remote--seen '("newer" "old")))
    (should (claude-remote--seen-p "old"))))

(ert-deftest claude-remote-upload-link-opens-in-emacs ()
  (let* ((path (expand-file-name "~/claude/.services/uploads/phone/1-a.png"))
         (s (claude-transcript--fmt-web-links (format "see [a.png](%s) ok" path))))
    (should (equal (get-text-property 6 'claude-transcript-url s) (concat "file://" path)))
    (should (null (get-text-property 1 'claude-transcript-url
                                     (claude-transcript--fmt-web-links "see [x](/etc/passwd)"))))))

(ert-deftest claude-remote-scroll-guard-survives-dead-marker ()
  "A page scroll that dies with a marker error is dropped and the window reset; end-of-buffer passes."
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (should-not (claude-remote--scroll-guard
                 (lambda (_) (error "Marker does not point anywhere")) 10))
    (should (eq (window-buffer) (current-buffer)))
    (should-error (claude-remote--scroll-guard (lambda (_) (signal 'end-of-buffer nil)) 10)
                  :type 'end-of-buffer)))
