;;; claude-compose-test.el --- ERT for the claude-compose queue -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-compose-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-compose)


(defmacro claude-compose-test--queue (&rest body)
  `(let* ((dir (make-temp-file "cal" t))
          (claude-compose-queue-dir (expand-file-name "queue" dir))
          (claude-compose--outbox nil)
          (claude-compose--info nil)
          (claude-compose--process nil)
          (claude-compose-outbox-functions nil))
     (make-directory claude-compose-queue-dir t)
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(defun claude-compose-test--wait ()
  (while (process-live-p claude-compose--process) (accept-process-output nil 0.05)))

(defun claude-compose-test--states ()
  (mapcar (lambda (m) (plist-get m :state)) claude-compose--outbox))

(ert-deftest claude-compose-queue-waits-while-homun-works ()
  (claude-compose-test--queue
   (let ((claude-compose--info '(:start 0)))
     (claude-compose--enqueue "one")
     (claude-compose--enqueue "two")
     (should (equal '(pending pending) (claude-compose-test--states)))
     (should (equal '("one" "two")
                    (mapcar (lambda (id) (claude-compose--file-text (claude-compose--queue-path id)))
                            (claude-compose--queue-names)))))))

(ert-deftest claude-compose-pump-sends-in-order ()
  (claude-compose-test--queue
   (let* ((log (expand-file-name "got" claude-compose-queue-dir))
          (claude-compose-program (list "sh" "-c" (format "cat >> %s; echo >> %s" log log))))
     (let ((claude-compose--info '(:start 0)))
       (claude-compose--enqueue "one")
       (claude-compose--enqueue "two"))
     (claude-compose--pump) (claude-compose-test--wait) (claude-compose-test--wait)
     (should (equal '(sent sent) (claude-compose-test--states)))
     (should (equal "one\ntwo\n" (claude-compose--file-text log)))
     (should-not (claude-compose--queue-names))
     (should-not (claude-compose--queue-names "sending")))))

(ert-deftest claude-compose-failure-holds-the-rest ()
  (claude-compose-test--queue
   (let ((claude-compose-program (list "sh" "-c" "echo 'claude-cal: not listening' >&2; exit 1")))
     (let ((claude-compose--info '(:start 0)))
       (claude-compose--enqueue "one")
       (claude-compose--enqueue "two"))
     (claude-compose--pump) (claude-compose-test--wait)
     (should (equal '(failed pending) (claude-compose-test--states)))
     (should (equal "not listening" (plist-get (claude-compose--failed) :error)))
     (should (file-exists-p (claude-compose--queue-path "paused")))
     (should (= 1 (length (claude-compose--queue-names "failed"))))
     (claude-compose--pump)
     (should-not claude-compose--process)
     (let ((claude-compose--info '(:start 0))) (claude-compose-retry))
     (should (equal '(pending pending) (claude-compose-test--states)))
     (should-not (file-exists-p (claude-compose--queue-path "paused")))
     (should (= 2 (length (claude-compose--queue-names))))
     (claude-compose--pump) (claude-compose-test--wait)
     (claude-compose-drop)
     (claude-compose-test--wait)
     (should (equal '(failed) (claude-compose-test--states)))
     (should (= 1 (length (claude-compose--queue-names "failed")))))))

(ert-deftest claude-compose-sync-marks-what-the-hook-took ()
  (claude-compose-test--queue
   (let ((claude-compose--info '(:start 0)))
     (claude-compose--enqueue "taken")
     (claude-compose--enqueue "lost")
     (with-temp-file (expand-file-name "log.jsonl" (file-name-directory claude-compose-queue-dir))
       (insert (format "{\"sha256\":\"%s\"}\n" (claude-compose--sha "taken"))))
     (mapc (lambda (id) (delete-file (claude-compose--queue-path id))) (claude-compose--queue-names))
     (claude-compose--sync)
     (should (equal '(sent failed) (claude-compose-test--states)))
     (should (claude-compose-seen "taken\n"))
     (should (equal '(failed) (claude-compose-test--states))))))

(ert-deftest claude-compose-recover-interrupted ()
  (claude-compose-test--queue
   (make-directory (expand-file-name "sending" claude-compose-queue-dir))
   (with-temp-file (claude-compose--queue-path "1000" "sending") (insert "half"))
   (claude-compose--recover)
   (should (equal '(failed) (claude-compose-test--states)))
   (should (claude-compose--queue-names "failed"))))

(ert-deftest claude-compose-tail-reads-only-new-lines ()
  (let* ((file (make-temp-file "t" nil ".jsonl"))
         (claude-compose--tail nil))
    (cl-letf (((symbol-function 'claude-compose--main-file) (lambda () file)))
      (with-temp-file file
        (insert "{\"type\":\"user\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"message\":{\"content\":\"hi\"}}\n"
                "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}\n"))
      (should (equal "Bash" (alist-get 'name (plist-get (claude-compose--info-read) :call))))
      (let ((offset (plist-get claude-compose--tail :offset)))
        (should (= offset (file-attribute-size (file-attributes file))))
        (append-to-file "{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":[]}}\n{\"type\":\"user\"" nil file)
        (should-not (claude-compose--info-read))
        (should (< (plist-get claude-compose--tail :offset) (file-attribute-size (file-attributes file))))))
    (delete-file file)))

(ert-deftest claude-compose-notice-is-not-work ()
  (should (claude-compose--notice-p
           '((type . "user") (message . ((content . "<task-notification>x"))))))
  (should-not (claude-compose--notice-p
               '((type . "user") (message . ((content . "hello")))))))

(ert-deftest claude-compose-who-parse ()
  (let ((who (claude-compose--who-parse "{\"role\":\"manager\",\"name\":\"Example\",\"emoji\":\"🗂️\"}\n" 0)))
    (should (equal "Example" (plist-get who :name)))
    (should (equal "manager" (plist-get who :role))))
  (should (equal "not listening" (plist-get (claude-compose--who-parse "claude-cal: not listening\n" 1) :error)))
  (should (plist-get (claude-compose--who-parse "garbage" 0) :error)))

(ert-deftest claude-compose-routes ()
  (let ((m (claude-compose-route 'manager)) (b (claude-compose-route 'mechanic))
        (claude-role-names '(("mechanic" . "Mechanic"))))
    (setq b (claude-compose-route 'mechanic))
    (should (equal "*claude-compose*" (claude-compose-route-buffer m)))
    (should (equal "*claude-compose: Mechanic*" (claude-compose-route-buffer b)))
    (should (equal '("cal" "-") (last (claude-compose-route-send b) 2)))
    (should (equal "who" (car (last (claude-compose-route-who b)))))
    (should (equal "who" (car (last (claude-compose-route-who m)))))))

(ert-deftest claude-compose-offline-header-names-the-role ()
  (let ((claude-compose--who (claude-compose--who-parse
                              "{\"role\":\"mechanic\",\"name\":\"Mechanic\",\"emoji\":\"X\",\"online\":false,\"reason\":\"r\"}" 1)))
    (should (string-match-p "Mechanic (offline)" (claude-compose--header)))
    (should (plist-get claude-compose--who :error)))
  (let ((claude-compose--who (claude-compose--who-parse
                              "{\"role\":\"mechanic\",\"name\":\"Mechanic\",\"online\":true}" 0)))
    (should (string-match-p "→ Mechanic +Send" (substring-no-properties (claude-compose--header))))))

(ert-deftest claude-compose-box-per-role-in-the-side-window ()
  (let ((claude-compose-history-file (make-temp-file "hist"))
        (claude-role-names (quote (("mechanic" . "Mechanic")))))
    (cl-letf (((symbol-function 'claude-compose--who-refresh) #'ignore))
      (save-window-excursion
        (select-window (window-main-window))
        (delete-other-windows)
        (switch-to-buffer (get-buffer-create "*claude-compose-test-main*"))
        (let ((main (selected-window)))
          (claude-compose--show (claude-compose-route 'manager))
          (claude-compose--show (claude-compose-route 'mechanic))
          (let ((w (get-buffer-window "*claude-compose: Mechanic*")))
            (should (window-parameter w 'window-side))
            (should-not (get-buffer-window "*claude-compose*")))
          (claude-compose--show (claude-compose-route 'manager))
          (should (window-parameter (get-buffer-window "*claude-compose*") 'window-side))
          (should-not (window-parameter main 'window-side))
          (should-not (eq main (get-buffer-window "*claude-compose*"))))))
    (kill-buffer "*claude-compose*") (kill-buffer "*claude-compose: Mechanic*")))

(ert-deftest claude-compose-hook-context-counts-as-seen ()
  (claude-compose-test--queue
   (let ((claude-compose--info '(:start 0)))
     (claude-compose--enqueue "mid turn")
     (claude-compose--entry-seen
      '((type . "attachment")
        (attachment . ((type . "hook_additional_context")
                       (content . ["<channel source=\"cal\" ts=\"1\">mid turn</channel>\n"])))))
     (should-not claude-compose--outbox))))

(ert-deftest claude-compose-queue-operation-not-seen ()
  "A queue-operation only notes that a message waits: the outbox keeps it until
the entry the transcript draws comes, so it never vanishes and comes back."
  (claude-compose-test--queue
   (let ((claude-compose--info '(:start 0))
         (text "<channel source=\"cal\" ts=\"1\">waits</channel>"))
     (claude-compose--enqueue "waits")
     (claude-compose--entry-seen `((type . "queue-operation") (operation . "enqueue")
                                   (content . ,text)))
     (should claude-compose--outbox)
     (claude-compose--entry-seen
      `((type . "attachment")
        (attachment . ((type . "queued_command") (prompt . [((type . "text") (text . ,text))])))))
     (should-not claude-compose--outbox))))

(ert-deftest claude-compose-drop-pending-asks ()
  (claude-compose-test--queue
   (let ((claude-compose--info '(:start 0)))
     (claude-compose--enqueue "later")
     (cl-letf (((symbol-function 'claude-confirm) (lambda (&rest _) nil)))
       (claude-compose-drop))
     (should claude-compose--outbox)
     (cl-letf (((symbol-function 'claude-confirm) (lambda (&rest _) t)))
       (claude-compose-drop))
     (should-not claude-compose--outbox))))

(ert-deftest claude-compose-waits-while-homun-starts ()
  (claude-compose-test--queue
   (let* ((claude-compose-manager-dir (expand-file-name "manager" dir))
          (claude-compose-retry-interval 100)
          (claude-compose-program (list "sh" "-c" "echo 'claude-cal: the Manager is not listening' >&2; exit 1")))
     (make-directory claude-compose-manager-dir t)
     (write-region "" nil (expand-file-name "boot" claude-compose-manager-dir) nil 'silent)
     (claude-compose--enqueue "one")
     (claude-compose-test--wait)
     (should (equal '(pending) (claude-compose-test--states)))
     (should (string-match-p "starting" (plist-get (car claude-compose--outbox) :error)))
     (should (= 1 (length (claude-compose--queue-names))))
     (should-not (claude-compose--queue-names "failed"))
     (should-not (file-exists-p (claude-compose--queue-path "paused")))
     ;; past the grace time it fails as before
     (let ((claude-compose-start-grace 0) (claude-compose--hold-until 0.0))
       (claude-compose--pump) (claude-compose-test--wait)
       (should (equal '(failed) (claude-compose-test--states)))))))

(ert-deftest claude-compose-box-follows-its-transcript ()
  (require 'claude-transcript)
  (let* ((claude-compose-auto-open t)
         (manager (claude-compose-route 'manager))
         (agent (get-buffer-create "*transcript: agent*"))
         (main (get-buffer-create "*transcript: main*"))
         (box (get-buffer-create (claude-compose-route-buffer manager))))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-compose--route-for-file)
                   (lambda (file) (and (equal file "main") manager)))
                  ((symbol-function 'claude-compose--show)
                   (lambda (&optional _route)
                     (set-window-buffer (split-window (frame-root-window) nil 'below) box))))
          (with-current-buffer agent
            (setq major-mode 'claude-transcript-mode) (setq-local claude-transcript--file "agent"))
          (with-current-buffer main
            (setq major-mode 'claude-transcript-mode) (setq-local claude-transcript--file "main"))
          (with-current-buffer box
            (claude-compose-mode 1) (setq claude-compose--route manager))
          (delete-other-windows)
          (set-frame-parameter nil 'claude-compose-boxes nil)
          ;; An agent's transcript with the Manager's box: the box goes
          (set-window-buffer (selected-window) agent)
          (set-window-buffer (split-window nil nil 'below) box)
          (claude-compose--pair-frame (selected-frame))
          (should-not (get-buffer-window box))
          ;; The main transcript appears: its box comes back, once
          (set-window-buffer (selected-window) main)
          (claude-compose--pair-frame (selected-frame))
          (should (get-buffer-window box))
          ;; Closed by hand while the transcript stays: it stays closed
          (delete-window (get-buffer-window box))
          (claude-compose--pair-frame (selected-frame))
          (should-not (get-buffer-window box)))
      (delete-other-windows)
      (mapc #'kill-buffer (list agent main box)))))

(ert-deftest claude-compose-ref-chips-serialize ()
  (with-temp-buffer
    (insert "why ")
    (insert (propertize "[stage:roll/pin]" 'homun-ref '("stage" . "roll/pin")))
    (insert " and ")
    (insert (propertize "[file:/a.el:3]" 'homun-ref '("file" . "/a.el:3")))
    (should (equal '("stage:roll/pin" "file:/a.el:3") (claude-compose--refs)))
    (let ((m (json-parse-string (claude-compose--wire (buffer-string) (claude-compose--refs))
                                :object-type 'alist)))
      (should (equal "stage:roll/pin,file:/a.el:3" (alist-get 'ref (alist-get 'meta m))))
      (should (string-prefix-p "why " (alist-get 'text m)))))
  (should (equal "plain" (claude-compose--wire "plain" nil))))

(ert-deftest claude-compose-ref-here-reads-node-and-file ()
  (with-temp-buffer
    (insert (propertize "node" 'homun-node "roll/pin"))
    (goto-char (point-min))
    (should (equal '("stage" . "roll/pin") (claude-compose--ref-here))))
  (with-temp-buffer
    (setq buffer-file-name "/x/y.el")
    (should (equal '("file" . "/x/y.el:1") (claude-compose--ref-here)))))

(ert-deftest claude-compose-send-sticks-transcript-to-end ()
  (require 'claude-transcript)
  (with-temp-buffer
    (claude-transcript-mode)
    (setq claude-transcript--file "/x/t.jsonl")
    (let ((inhibit-read-only t)) (dotimes (_ 200) (insert "line\n")))
    (let ((window (selected-window)) (old (window-buffer (selected-window))))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (set-window-point window (point-min))
            (cl-letf (((symbol-function 'claude-compose--route) (lambda () 'r))
                      ((symbol-function 'claude-compose--route-for-file) (lambda (_) 'r)))
              (claude-compose--stick-transcripts))
            (should (= (window-point window) (point-max)))
            (should (claude-transcript--at-end-p window)))
        (set-window-buffer window old)))))

(ert-deftest claude-compose-stream-turn-reaches-the-fifo ()
  (let* ((dir (make-temp-file "stream" t))
         (fifo (expand-file-name "in" dir)))
    (unwind-protect
        (progn
          (call-process "mkfifo" nil nil nil fifo)
          (let ((result 'none)
                (reader (make-process :name "r" :command (list "cat" fifo)
                                      :buffer (generate-new-buffer " r" t) :noquery t)))
            (claude-agent-stream-send
             dir (claude-agent-stream-user-turn (claude-compose--stream-turn "hi")) (lambda (e) (setq result e)))
            (while (or (eq result 'none) (process-live-p reader)) (accept-process-output nil 0.05))
            (let ((turn (json-parse-string (car (split-string (with-current-buffer (process-buffer reader) (buffer-string)) "\n"))
                                           :object-type 'alist)))
              (should (null result))
              (should (equal "user" (alist-get 'type turn)))
              (should (string-match-p "source=\"cal\".*>hi</channel>"
                                      (alist-get 'text (aref (alist-get 'content (alist-get 'message turn)) 0)))))))
      (delete-directory dir t))))

(ert-deftest claude-compose-headless-manager-goes-to-its-stream ()
  "A headless Manager has no outbox reader: compose must route it to the stream like any role."
  (let* ((home (make-temp-file "home" t))
         (base (expand-file-name "claude/.services/manager" home))
         (default-directory temporary-file-directory)
         (process-environment (cons (concat "HOME=" home) process-environment)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "stream" base) t)
          (call-process "mkfifo" nil nil nil (expand-file-name "stream/in" base))
          (cl-letf (((symbol-function 'claude-compose--route)
                     (lambda () (claude-compose-route 'manager))))
            (should-not (claude-compose--stream-dir))
            (with-temp-file (expand-file-name "session-mode" base) (insert "headless\n"))
            (should (equal (expand-file-name "stream" base) (claude-compose--stream-dir)))))
      (delete-directory home t))))

(ert-deftest claude-compose-headless-role-header-names-it ()
  "A headless role's header names it from its stream, not `nobody listening'."
  (let* ((home (make-temp-file "home" t))
         (base (expand-file-name "claude/.services/mechanic" home))
         (default-directory temporary-file-directory)
         (process-environment (cons (concat "HOME=" home) process-environment))
         (claude-compose--who nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "stream" base) t)
          (call-process "mkfifo" nil nil nil (expand-file-name "stream/in" base))
          (with-temp-file (expand-file-name "session-mode" base) (insert "headless\n"))
          (cl-letf (((symbol-function 'claude-compose--route)
                     (lambda () (claude-compose-route 'mechanic)))
                    ((symbol-function 'claude-compose-route-who)
                     (lambda (_) '("claude-cal" "who"))))
            (claude-compose--who-refresh)
            (should-not (plist-get claude-compose--who :error))
            (should-not (string-match-p "nobody" (claude-compose--header-who)))
            (should (string-match-p "→" (claude-compose--header-who)))))
      (delete-directory home t))))

(defvar claude-remote-home-role)

(ert-deftest claude-compose-to-points-the-phone-at-the-role ()
  (let ((claude-remote-home-role "manager"))
    (cl-letf (((symbol-function 'claude-compose--show) #'ignore))
      (claude-compose-to 'mechanic))
    (should (equal "mechanic" claude-remote-home-role))))

(ert-deftest claude-compose-has-no-preview ()
  (should-not (fboundp 'claude-compose-preview-toggle))
  (should-not (lookup-key claude-compose-mode-map (kbd "C-c C-v")))
  (with-temp-buffer
    (let ((claude-compose--who (list :role "mechanic" :name "M")))
      (should-not (string-match-p "Preview" (claude-compose--header))))))

(ert-deftest claude-compose-headers-are-scaled ()
  (skip-unless (fboundp 'gfm-mode))
  (let ((buffer (claude-compose--buffer (claude-compose-route 'manager))))
    (unwind-protect
        (with-current-buffer buffer
          (insert "# Title\n")
          (font-lock-ensure)
          (let ((face (get-text-property 3 'face)))
            (should (memq 'markdown-header-face-1 (if (listp face) face (list face))))
            (should (> (plist-get (cadr (assq 'markdown-header-face-1 face-remapping-alist))
                                  :height)
                       1.0))))
      (kill-buffer buffer))))

(ert-deftest claude-role-name-display ()
  (let ((claude-role-names '(("zed" . "Placeholder"))))
    (should (equal "Placeholder" (claude-role-name 'zed)))
    (should (equal "Placeholder" (claude-role-name "zed")))
    (should (equal "nameless" (claude-role-name "nameless")))
    (should (equal "*claude-compose: Placeholder*"
                   (claude-compose-route-buffer (claude-compose-route 'zed))))))

(ert-deftest claude-compose-to-switches-only-transcript-windows ()
  (let* ((other (generate-new-buffer " other"))
         (tr (generate-new-buffer " tr"))
         (target (generate-new-buffer " target")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer tr (setq major-mode 'claude-transcript-mode))
          (defvar claude-board-main-dir)
          (delete-other-windows)
          (let ((w1 (selected-window)) (w2 (split-window)))
            (set-window-buffer w1 tr) (set-window-buffer w2 other)
            (cl-letf (((symbol-function 'claude-board--role-file) (lambda (&rest _) "/etc/hostname"))
                      ((symbol-function 'claude-transcript-buffer) (lambda (_) target)))
              (claude-compose--follow-transcript 'mechanic))
            (should (eq target (window-buffer w1)))
            (should (eq other (window-buffer w2)))))
      (mapc #'kill-buffer (list other tr target)))))
