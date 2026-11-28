;; homun begin -*- lexical-binding: t -*-: the phone's start-up block.  Written into init.el by the pairing line, which also
;; replaces it when you pair again.  It needs only Emacs: it fetches the cockpit's files from the
;; gateway (pinned CA, one request) into ~/.emacs.d/homun/, loads them and starts.  M-x homun-update refetches
;; and reloads; M-x homun-repair wipes the files first.  Delete this block to unpair.
(require 'url)
(require 'url-http)
(require 'gnutls)
(require 'nsm)
(defvar homun-conf)
(defvar url-http-response-status)
(setq homun-conf nil)
(defvar homun-version nil "Short hash of the manifest last fetched.")
(defvar homun-dir (locate-user-emacs-file "homun/"))

(defun homun--text (body) (decode-coding-string body 'utf-8))

(defun homun--get (path &optional headers insecure data)
  "PATH of the gateway, as the raw body.  Trusts the pinned CA only; INSECURE: any,
for the pin check."
  (let* ((key (plist-get homun-conf :key))
         (gnutls-trustfiles (and (not insecure) (list (expand-file-name "ca.pem" homun-dir))))
         (gnutls-verify-error (not insecure)) (network-security-level (if insecure 'low 'high))
         (nsm-settings-file (make-temp-file "nsm")) (url-http-attempt-keepalives nil)
         (url-request-method (if data "POST" "GET")) (url-request-data data)
         (url-request-extra-headers (append headers (and key `(("X-Homun-Key" . ,key))) (and data '(("Content-Type" . "application/json")))))
         (buf (condition-case e (url-retrieve-synchronously (concat (plist-get homun-conf :url) path) t t 30)
                (error (error "can't reach the gateway: %s" (error-message-string e))))))
    (unless buf (error "can't reach the gateway (down, offline, or a certificate that is not the pinned one)"))
    (with-current-buffer buf
      (unwind-protect
          (let ((code url-http-response-status))
            (goto-char (point-min))
            (re-search-forward "\r?\n\r?\n" nil t)
            (unless (eql code 200) (user-error "gateway answered %s: %s" code (string-trim (homun--text (buffer-substring (point) (point-max))))))
            (buffer-substring (point) (point-max)))
        (when-let* ((p (get-buffer-process buf))) (set-process-query-on-exit-flag p nil) (delete-process p))
        (kill-buffer buf)))))

(defun homun--write (file body)
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'binary)) (write-region body nil file nil 'silent)))

(defun homun--sha (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (secure-hash 'sha256 (current-buffer))))

(defun homun--save ()
  "Keep `homun-conf' in init.el."
  (let ((init (or user-init-file (locate-user-emacs-file "init.el"))))
    (with-temp-buffer
      (insert-file-contents init)
      (when (re-search-forward "^(setq homun-conf .*$" nil t)
        (replace-match (format "(setq homun-conf '%S)" homun-conf) t t)
        (write-region nil nil init nil 'silent)))))

(defun homun--pem-pin (pem)
  (secure-hash 'sha256 (base64-decode-string (replace-regexp-in-string "-----[^-]+-----\\|\n\\|\r" "" pem))))

(defun homun--ca ()
  "Fetch the gateway's root certificate into ca.pem, if it is the pinned one."
  (let* ((code (plist-get homun-conf :code))
         (pem (homun--text (homun--get "ca.crt" (and code `(("X-Homun-Pair" . ,(car (split-string code "\\."))))) t))))
    (unless (equal (plist-get homun-conf :pin) (homun--pem-pin pem))
      (user-error "the gateway's certificate is not the pinned one"))
    (homun--write (expand-file-name "ca.pem" homun-dir) pem)))

(defun homun--pair ()
  "Trade the pairing code in `homun-conf' for a device key, once."
  (let ((key (plist-get (json-parse-string
                         (homun--text (homun--get "pair" nil nil (json-serialize (list :code (plist-get homun-conf :code)))))
                         :object-type 'plist)
                        :key)))
    (setq homun-conf (list :url (plist-get homun-conf :url) :key key :pin (plist-get homun-conf :pin)
                           :device (plist-get homun-conf :device)))
    (homun--save)))

(defun homun-sync ()
  "Fetch the gateway's files (one request) and write those that differ from the
cache; the names written."
  (let ((all (homun--get "client")) (pos 0) names written)
    (while (and (< pos (length all))
                (eq pos (string-match "\\([0-9a-f]\\{64\\}\\) \\([A-Za-z0-9._-]+\\.el\\) \\([0-9]+\\)\n" all pos)))
      (let* ((sum (match-string 1 all)) (name (match-string 2 all)) (start (match-end 0))
             (end (+ start (string-to-number (match-string 3 all))))
             (body (substring all start end)) (file (expand-file-name name homun-dir)))
        (unless (equal sum (secure-hash 'sha256 body)) (error "%s does not match its hash" name))
        (push name names)
        (unless (and (file-readable-p file) (equal sum (homun--sha file)))
          (homun--write file body)
          (push name written))
        (setq pos (1+ end))))
    (unless names (error "the gateway sent no files"))
    (dolist (f (directory-files homun-dir nil "\\.elc?\\'"))
      (unless (member f names) (delete-file (expand-file-name f homun-dir))))
    (setq homun-version (substring (secure-hash 'sha256 all) 0 8))
    written))

(defun homun--wipe ()
  (dolist (f (directory-files homun-dir t "\\.elc?\\'")) (delete-file f)))

(defun homun-update ()
  "Fetch what changed and load it in this Emacs."
  (interactive)
  (let ((fetched (homun-sync)))
    (dolist (f fetched) (load (expand-file-name f homun-dir) nil t))
    (message "homun %s: %d file%s updated" homun-version (length fetched) (if (= 1 (length fetched)) "" "s"))))

(defun homun-repair ()
  "Throw the fetched files away, fetch them all again and reconnect."
  (interactive)
  (homun--wipe)
  (if (not (featurep 'claude-remote)) (homun-start t)
    (homun-update)
    (claude-remote-stop)
    (claude-remote-start)))

(defun homun-start (&optional wiped)
  "Pair when there is a code, fetch, load and start.  A cache that fails to load is
wiped and fetched once more; any other failure is a message and a retry in a
minute."
  (condition-case err
      (progn
        (make-directory homun-dir t)
        (let ((ca (expand-file-name "ca.pem" homun-dir)))
          (when (and (file-readable-p ca) (not (equal (plist-get homun-conf :pin) (homun--pem-pin (with-temp-buffer (insert-file-contents ca) (buffer-string))))))
            (delete-file ca))
          (unless (file-readable-p ca) (homun--ca)))
        (when (plist-get homun-conf :code) (homun--pair))
        (condition-case fetch
            (homun-sync)
          (error (unless (file-readable-p (expand-file-name "claude-remote.el" homun-dir)) (signal (car fetch) (cdr fetch)))
                 (message "homun: not fetched (%s); using the cache" (error-message-string fetch))))
        (add-to-list 'load-path homun-dir)
        (require 'claude-remote)
        (setq claude-remote-url (plist-get homun-conf :url) claude-remote-key (plist-get homun-conf :key)
              claude-remote-device (plist-get homun-conf :device) claude-remote-ca-file (expand-file-name "ca.pem" homun-dir))
        (homun-remote-start))
    (user-error (message "homun: %s" (error-message-string err)))
    (error (message "homun: %s; M-x homun-repair fetches everything again" (error-message-string err))
           (if wiped (run-at-time 60 nil #'homun-start t)
             (homun--wipe)
             (homun-start t)))))

(homun-start)
;; homun end
