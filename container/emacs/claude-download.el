;;; claude-download.el --- homun:download/NAME links -*- lexical-binding: t -*-

;; A transcript link `homun:download/NAME' names a file the cockpit's gateway serves from
;; ~/claude/.services/downloads/files/.  On the desktop it opens that file; on Android it fetches
;; it through the gateway (progress in the echo area), saves it in Download and asks Android to
;; open it (an .apk brings up the package installer).

(require 'claude-remote)

(defcustom claude-download-dir "/sdcard/Download/"
  "Where the phone saves downloads."
  :type 'directory :group 'claude)

(defcustom claude-download-local-dir "~/claude/.services/downloads/files/"
  "Where the desktop finds the files `homun:download' links name."
  :type 'directory :group 'claude)

(defconst claude-download--name-regexp "\\`[A-Za-z0-9_][A-Za-z0-9._-]\\{0,99\\}\\'"
  "What a download name may look like: a plain file name, as the gateway takes.")

(defvar claude-download--timer nil "The progress timer of the running download.")

(declare-function android-browse-url "android-win")

(defun claude-download--done (name ok text)
  "Report the end of the download NAME: OK, TEXT is the saved path, else the reason."
  (when (timerp claude-download--timer) (cancel-timer claude-download--timer))
  (setq claude-download--timer nil)
  (if ok
      (condition-case err
          (progn (android-browse-url (concat "file://" text))
                 (message "Downloaded %s, opening it" name))
        (error (message "Downloaded %s to %s, but Android cannot open it: %s"
                        name text (error-message-string err))))
    (message "Download of %s failed: %s" name text)
    (display-warning 'claude-remote (format "Download of %s failed: %s" name text) :warning)))

(defun claude-download--phone (name)
  "Fetch NAME through the gateway into `claude-download-dir', then open it."
  (let ((dir (file-name-as-directory claude-download-dir)))
    (unless (and (file-directory-p dir) (file-writable-p dir))
      (user-error "Cannot save to %s: allow Emacs the storage permission in Android Settings, Apps, Emacs, Permissions" dir))
    (when claude-download--timer (user-error "Still downloading"))
    (message "Downloading %s…" name)
    (let ((buffer (claude-remote-download name (expand-file-name name dir)
                                          (lambda (res) (claude-download--done name (car res) (cdr res))))))
      (when (and (buffer-live-p buffer) (null claude-download--timer))
        (setq claude-download--timer
              (run-with-timer 0.5 0.5
                              (lambda ()
                                (if (buffer-live-p buffer)
                                    (message "Downloading %s… %d KB" name (/ (buffer-size buffer) 1024))
                                  (cancel-timer claude-download--timer)))))))))

;;;###autoload
(defun claude-download-open (name)
  "Open the download NAME: fetched and handed to Android on the phone, the local file on the desktop."
  (interactive "sDownload: ")
  (unless (string-match-p claude-download--name-regexp name)
    (user-error "Not a download name: %s" name))
  (if (eq system-type 'android)
      (claude-download--phone name)
    (let ((file (expand-file-name name claude-download-local-dir)))
      (unless (file-regular-p file) (user-error "No such download: %s" file))
      (find-file file))))

(provide 'claude-download)
;;; claude-download.el ends here
