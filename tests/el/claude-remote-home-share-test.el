;;; claude-remote-home-share-test.el --- ERT for files shared to Emacs -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-remote-home-share-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-remote-home)

(defmacro claude-remote-home-share-test--run (result &rest body)
  "Simulate a file arriving through `server-visit-hook'; the upload answers RESULT."
  `(let* ((dir (make-temp-file "share" t))
          (file (expand-file-name "pic.png" dir))
          (claude-remote-home--uploading nil)
          (claude-remote-home-compose-buffer " *share-compose*")
          (uploaded nil) (shown nil))
     (write-region "x" nil file)
     (get-buffer-create claude-remote-home-compose-buffer)
     (cl-letf (((symbol-function 'claude-remote-upload)
                (lambda (f cb) (push f uploaded) (funcall cb ,result)))
               ((symbol-function 'claude-remote-home-compose) (lambda () (setq shown t)))
               ((symbol-function 'claude-remote-home--compose-draw) #'ignore))
       (let ((visit (find-file-noselect file)))
         (with-current-buffer visit (run-hooks 'server-visit-hook))
         ,@body))
     (kill-buffer claude-remote-home-compose-buffer)))

(ert-deftest claude-remote-home-share-uploads-links-and-kills-the-buffer ()
  (claude-remote-home-share-test--run (cons t "/up/pic.png")
    (should shown)
    (should (equal uploaded (list file)))
    (should (equal (with-current-buffer claude-remote-home-compose-buffer (buffer-string))
                   "[pic.png](/up/pic.png)\n"))
    (should-not (get-file-buffer file))))

(ert-deftest claude-remote-home-share-failure-shows-the-reason ()
  (let (warned)
    (cl-letf (((symbol-function 'display-warning) (lambda (_ msg &rest _) (setq warned msg))))
      (claude-remote-home-share-test--run (cons nil "413 too big")
        (should (string-match-p "too big" warned))
        (should (equal (with-current-buffer claude-remote-home-compose-buffer (buffer-string)) ""))
        (should-not (get-file-buffer file))))))
