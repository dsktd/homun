;;; claude-download-test.el --- ERT for homun:download links -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-download-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-transcript)
(require 'claude-download)

(ert-deftest claude-download-link-parse ()
  (let ((spec (claude-transcript--link-parse "homun:download/app-1.2.apk" "Install")))
    (should (eq 'download (plist-get spec :type)))
    (should (equal "app-1.2.apk" (plist-get spec :id))))
  (should-not (claude-transcript--link-parse "homun:download/../x" "x"))
  (should-not (claude-transcript--link-parse "homun:download" "x")))

(defun claude-download-test--serve (handler)
  "A fake gateway on localhost: HANDLER gets the request text, returns the full response."
  (make-network-process
   :name "fake-gateway" :server t :host "127.0.0.1" :service t :family 'ipv4 :noquery t
   :filter (lambda (proc text) (process-send-string proc (funcall handler text)) (delete-process proc))))

(defmacro claude-download-test--with-gateway (handler &rest body)
  (declare (indent 1))
  `(let* ((server (claude-download-test--serve ,handler))
          (claude-remote-url (format "http://127.0.0.1:%d/" (process-contact server :service)))
          (claude-remote-key "k") (done nil))
     (unwind-protect (progn ,@body) (delete-process server))))

(defun claude-download-test--wait (get)
  (let ((end (+ (float-time) 5))) (while (and (not (funcall get)) (< (float-time) end)) (accept-process-output nil 0.05))))

(ert-deftest claude-download-fetch-saves-binary-with-key ()
  (let ((seen nil) (file (make-temp-file "dl")))
    (claude-download-test--with-gateway
        (lambda (req) (setq seen req)
          "HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\n\r\nPK\0\377\200")
      (claude-remote-download "a.apk" file (lambda (res) (setq done res)))
      (claude-download-test--wait (lambda () done))
      (should (equal (cons t file) done))
      (should (string-match-p "GET /download\\?name=a\\.apk" seen))
      (should (string-match-p "X-Homun-Key: k" seen))
      (should (equal "PK\0\377\200" (with-temp-buffer (set-buffer-multibyte nil)
                                                       (insert-file-contents-literally file) (buffer-string)))))))

(ert-deftest claude-download-fetch-failure-shows-reason ()
  (let ((file (make-temp-file "dl")))
    (claude-download-test--with-gateway
        (lambda (_) "HTTP/1.0 404 Not Found\r\n\r\ndownload: no such file\n")
      (claude-remote-download "x" file (lambda (res) (setq done res)))
      (claude-download-test--wait (lambda () done))
      (should-not (car done))
      (should (string-match-p "404 download: no such file" (cdr done))))))

(ert-deftest claude-download-done-hands-file-to-android ()
  (let (opened)
    (cl-letf (((symbol-function 'android-browse-url) (lambda (url &rest _) (setq opened url))))
      (claude-download--done "a.apk" t "/sdcard/Download/a.apk")
      (should (equal "file:///sdcard/Download/a.apk" opened)))))

(ert-deftest claude-download-phone-denied-says-permission ()
  (let ((claude-download-dir "/nonexistent-dir/") (system-type 'android))
    (let ((err (should-error (claude-download-open "a.apk") :type 'user-error)))
      (should (string-match-p "storage permission" (cadr err))))))

(ert-deftest claude-download-desktop-opens-local-file ()
  (let* ((dir (make-temp-file "dl" t)) (claude-download-local-dir dir) opened)
    (write-region "x" nil (expand-file-name "n.txt" dir))
    (cl-letf (((symbol-function 'find-file) (lambda (f) (setq opened f))))
      (claude-download-open "n.txt"))
    (should (equal (expand-file-name "n.txt" dir) opened))
    (should-error (claude-download-open "../n.txt") :type 'user-error)))
