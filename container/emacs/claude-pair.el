;;; claude-pair.el --- Pair a phone with the cockpit gateway -*- lexical-binding: t -*-

;; "Pair phone" (design 3.6b): one step on each side.  `claude-pair-phone' writes a pairing,
;; pair/<id>.json in the cockpit-gateway service (the device name, no extra permissions, the
;; SHA-256 of a secret, an expiry `claude-pair-ttl' ahead), enables and starts the gateway, and
;; shows the line for the phone as text and as a QR code.  The line holds
;; homun-pair:HOST:PORT/ID/SECRET/SHA256 (the proxy's root certificate) and, evaluated in the
;; phone's *scratch*, writes the bootstrap block (homun-init.el) into init.el and runs it: the
;; block trades the code for a device key (once), fetches the cockpit's files from the gateway
;; with the CA pinned, and starts them, at every start.
;;
;; A code works once and for ten minutes; pairing a name that has a key replaces that key.  The
;; QR code opens the gateway's pairing page (/cockpit-gateway/p/<id>, only while the code is
;; live), whose button copies the line.  Pairing again replaces the block, which is also the
;; repair.  A test device (a name starting with emulator) gets its line returned only, never
;; shown to the user.

(require 'homun-dir)
(require 'subr-x)
(require 'widgetry-buttons nil t)

(defvar claude-pair-gateway-dir (expand-file-name "~/claude/.services/cockpit-gateway/")
  "The cockpit-gateway service directory.")

(defvar claude-pair-proxy-dir (expand-file-name "~/claude/.services/proxy/")
  "The proxy service directory: hosts (the names its certificate covers) and
root.crt.")

(defvar claude-pair-port 8443 "The proxy's TLS port as the phone reaches it.")

(defvar claude-pair-ttl 600 "Seconds a pairing code stays valid.")

(defvar claude-pair-qrencode '("nix" "shell" "nixpkgs#qrencode" "-c" "qrencode")
  "The qrencode command, for the QR code.")

(defconst claude-pair-buffer "*homun pair*")

(defun claude-pair--random (bytes)
  "BYTES random bytes from the kernel, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (call-process "head" "/dev/urandom" t nil "-c" (number-to-string bytes))
    (mapconcat (lambda (b) (format "%02x" b)) (buffer-string) "")))

(defun claude-pair--host ()
  (or (with-temp-buffer
        (ignore-errors (insert-file-contents (expand-file-name "hosts" claude-pair-proxy-dir)))
        (when (re-search-forward "^[A-Za-z0-9._-]+$" nil t)
          (let ((h (match-string 0))) (unless (member h '("127.0.0.1" "localhost")) h))))
      (user-error "No host for the phone: put its name or IP in %shosts" claude-pair-proxy-dir)))

(defun claude-pair--pin ()
  "The SHA-256 of the proxy's root certificate (DER)."
  (let ((file (expand-file-name "root.crt" claude-pair-proxy-dir)))
    (unless (file-readable-p file) (user-error "No %s yet: start the proxy first" file))
    (with-temp-buffer
      (insert-file-contents file)
      (secure-hash 'sha256 (base64-decode-string
                            (replace-regexp-in-string "-----[^-]+-----\\|\n\\|\r" "" (buffer-string)))))))

(defvar claude-pair--device "phone" "The device name of the pairing being made.")

(defun claude-pair--block (pair)
  "The bootstrap block (homun-init.el) with the configuration of PAIR in place of
its empty one."
  (let* ((parts (split-string (string-remove-prefix "homun-pair:" pair) "/"))
         (conf (list :url (format "https://%s/cockpit-gateway/" (car parts)) :code (concat (nth 1 parts) "." (nth 2 parts))
                     :pin (nth 3 parts) :device claude-pair--device)))
    (with-temp-buffer
      (insert-file-contents (expand-file-name "homun-init.el" homun-cockpit-dir))
      (search-forward "(setq homun-conf nil)")
      (replace-match (format "(setq homun-conf '%S)" conf) t t)
      (buffer-string))))

(defun claude-pair-line (pair)
  "The text for the phone's *scratch* that writes the bootstrap block into init.el
and runs it.
The block (homun-init.el) pairs, fetches the cockpit and starts it; pairing
again replaces it."
  (concat
   ";;; -*- lexical-binding: t -*-\n"
   (let ((print-quoted t) (print-escape-newlines t))
     (prin1-to-string
      `(let ((b ,(claude-pair--block pair)) (init (or user-init-file (locate-user-emacs-file "init.el"))))
         (with-temp-buffer
           (when (file-exists-p init) (insert-file-contents init))
           (when (re-search-forward "^;; homun begin" nil t)
             (delete-region (match-beginning 0) (if (re-search-forward "^;; homun end\n?" nil t) (point) (point-max))))
           (goto-char (point-max))
           (when (zerop (buffer-size)) (insert ";;; -*- lexical-binding: t -*-\n"))
           (unless (bolp) (insert "\n"))
           (insert b)
           (write-region nil nil init nil 'silent))
         (eval (read (concat "(progn " b "\n)")) t))))))

(defun claude-pair--write (name)
  "Write a pairing for the device NAME; return its homun-pair: string."
  (let* ((id (claude-pair--random 8)) (secret (claude-pair--random 16))
         (dir (expand-file-name "pair/" claude-pair-gateway-dir))
         (file (expand-file-name (concat id ".json") dir))
         (now (floor (float-time))))
    (make-directory dir t)
    (set-file-modes dir #o700)
    (with-temp-file (concat file ".tmp")
      (insert (json-serialize (list :name name :sha256 (secure-hash 'sha256 secret) :created now
                                    :expires (+ now claude-pair-ttl) :secrets :false :approve :false
                                    :readonly :false :alarms :false))))
    (set-file-modes (concat file ".tmp") #o600)
    (rename-file (concat file ".tmp") file t)
    (format "homun-pair:%s:%d/%s/%s/%s" (claude-pair--host) claude-pair-port id secret (claude-pair--pin))))

(defun claude-pair--start-gateway ()
  "Enable the gateway and start it (it runs in this container)."
  (ignore-errors (delete-file (expand-file-name "disabled" claude-pair-gateway-dir)))
  (when (executable-find "claude-services")
    (start-process "claude-pair-gateway" nil "claude-services" "start" "cockpit-gateway")))

(defun claude-pair--qr (text)
  "A PNG image of TEXT as a QR code, or nil when qrencode fails."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (when (eql 0 (apply #'call-process (car claude-pair-qrencode) nil '(t nil) nil
                        (append (cdr claude-pair-qrencode) (list "-t" "PNG" "-s" "4" "-l" "L" "-o" "-" text))))
      (create-image (buffer-string) 'png t))))

(defun claude-pair--draw (name line url expires)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "Pair %s" name) 'face '(:weight bold :height 1.3)) "\n"
            (propertize (format-time-string "One use, until %H:%M.  " expires) 'face 'shadow)
            (propertize "Scan the code on the phone: its page copies the line for Emacs and says what to tap."
                        'face 'shadow)
            "\n\n")
    (if-let* ((image (claude-pair--qr url))) (insert-image image "[QR]") (insert "(no qrencode: open the address)"))
    (insert "\n" url)
    (insert "\n\n")
    (if (fboundp 'widgetry-buttons)
        (widget-create 'widgetry-buttons
                       :buttons (list (list :label "Copy line" :notify (lambda (&rest _) (kill-new line) (message "Copied")))
                                      (list :label "New code" :notify (lambda (&rest _) (claude-pair-phone name)))))
      (insert-text-button "Copy line" 'action (lambda (_) (kill-new line) (message "Copied"))))
    (insert "\n\n" line "\n")
    (when (fboundp 'widget-setup) (widget-setup))
    (goto-char (point-min))))

(defun claude-pair--test-p (name)
  "Non-nil for a test device's NAME (emulator...): its pairing is returned, never
shown."
  (string-prefix-p "emulator" name))

(defun claude-pair--page (pair line)
  "Leave LINE for the gateway's pairing page of PAIR; return the page's URL."
  (let* ((parts (split-string (string-remove-prefix "homun-pair:" pair) "/"))
         (file (expand-file-name (concat (nth 1 parts) ".line") (expand-file-name "pair/" claude-pair-gateway-dir))))
    (with-temp-file (concat file ".tmp") (insert line))
    (set-file-modes (concat file ".tmp") #o600)
    (rename-file (concat file ".tmp") file t)
    (format "https://%s/cockpit-gateway/p/%s" (car parts) (nth 1 parts))))

;;;###autoload
(defun claude-pair-phone (&optional name)
  "Make a pairing code for the device NAME (default phone): show its page's QR code
and the line.
A test device (`claude-pair--test-p') gets the line returned only, so it never
shows to the user."
  (interactive (list (read-string "Device name (phone): " nil nil "phone")))
  (let ((name (if (string-empty-p (or name "")) "phone" name)))
    (unless (and (string-match-p "\\`[a-z0-9][a-z0-9-]\\{0,31\\}\\'" name) (not (equal name "host")))
      (user-error "A device name is [a-z0-9-], at most 32, and not host"))
    (let* ((claude-pair--device name) (pair (claude-pair--write name)) (line (claude-pair-line pair))
           (url (claude-pair--page pair line)))
      (claude-pair--start-gateway)
      (unless (claude-pair--test-p name)
        (let ((buffer (get-buffer-create claude-pair-buffer)))
          (with-current-buffer buffer
            (special-mode)
            (when (fboundp 'widgetry-mode) (widgetry-mode 1))
            (setq-local homun-stage-tab "pair")
            (claude-pair--draw name line url (+ (float-time) claude-pair-ttl)))
          (pop-to-buffer buffer)))
      line)))

(provide 'claude-pair)
;;; claude-pair.el ends here
