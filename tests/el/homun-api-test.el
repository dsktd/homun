;;; homun-api-test.el --- ERT for homun-api.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-api-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'homun-api)

(defmacro homun-api-test--with (&rest body)
  `(let ((homun-api--entries nil)
         (homun-api-log-file (make-temp-file "homun-api-log"))
         (homun-api-timeout 1))
     (homun-api-define "t add" "Add." ((a int :required t) (b int :default 10)) (+ a b))
     (homun-api-define "t mode" "Mode." ((m enum :required t :choices ("x" "y")) (on bool)) (list m on))
     (homun-api-define "t slow" "Slow." () (sleep-for 5) 'late)
     (homun-api-define "t big" "Big." () (make-string 9000 ?a))
     (homun-api-define "t boom" "Boom." () (error "bang"))
     (homun-api-define "t data" "Data." ((d data :required t)) d)
     ,@body))

(ert-deftest homun-api-ok-and-default ()
  (homun-api-test--with
   (should (equal (homun-api-call '("t" "add" "a" "5")) "ok\n15"))
   (should (equal (homun-api-call '("t" "add" "b" "1" "a" "2")) "ok\n3"))))

(ert-deftest homun-api-validation ()
  (homun-api-test--with
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "add"))))
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "add" "a" "x"))))
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "add" "a" "1" "c" "2"))))
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "add" "a"))))
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "mode" "m" "z"))))
   (should (equal (homun-api-call '("t" "mode" "m" "x" "on" "yes")) "ok\n(\"x\" t)"))
   (should (string-prefix-p "err unknown" (homun-api-call '("t" "nope"))))))

(ert-deftest homun-api-data-is-never-evaluated ()
  (homun-api-test--with
   (should (equal (homun-api-call '("t" "data" "d" "(1 \"a\" :k)")) "ok\n(1 \"a\" :k)"))
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "data" "d" "#.(kill-emacs)"))))
   (should (string-prefix-p "err invalid" (homun-api-call '("t" "data" "d" "#1=(a . #1#)"))))))

(ert-deftest homun-api-timeout-cap-failure ()
  (homun-api-test--with
   (should (string-prefix-p "err timeout" (homun-api-call '("t" "slow"))))
   (let ((r (homun-api-call '("t" "big"))))
     (should (< (length r) (+ homun-api-result-max 100)))
     (should (string-match-p "cut:" r)))
   (should (equal (homun-api-call '("t" "boom")) "err failed\nbang"))))

(ert-deftest homun-api-rpc-reads-args-left ()
  (homun-api-test--with
   (let ((server-eval-args-left (list "t" "add" "a" "1")))
     (should (equal (homun-rpc) "ok\n11"))
     (should (null server-eval-args-left)))))

(ert-deftest homun-api-logs-one-line-per-call ()
  (homun-api-test--with
   (homun-api-call '("t" "add" "a" "1"))
   (homun-api-call '("t" "nope"))
   (should (= 2 (length (split-string (with-temp-buffer (insert-file-contents homun-api-log-file)
                                                       (buffer-string))
                                      "\n" t))))))

(ert-deftest homun-api-load-only-allowed-roots ()
  (should-error (homun-api--allowed-file "/etc/passwd") :type 'homun-api-error)
  (should (homun-api--allowed-file (locate-library "homun-api.el"))))

(ert-deftest homun-api-real-entries-registered ()
  (dolist (n '("daemon get" "load file" "transcript refresh" "board get" "compose get"
               "stage show" "stage list" "page open" "face get" "face set"
               "buffer get" "window get" "window set" "variable set" "approve demo"))
    (should (assoc n homun-api--entries))))

(ert-deftest homun-api-schema-is-whole-json ()
  (let* ((homun-api-log-file (make-temp-file "homun-api-log"))
         (reply (homun-api-call '("api" "schema")))
         (entries (json-parse-string (substring reply 3) :object-type 'alist :array-type 'list))
         (set (seq-find (lambda (e) (equal (alist-get 'name e) "window set")) entries))
         (slot (seq-find (lambda (a) (equal (alist-get 'key a) "slot")) (alist-get 'args set))))
    (should (> (length reply) homun-api-result-max))
    (should (< (length entries) (length homun-api--entries)))
    (should (equal (alist-get 'type slot) "enum"))
    (should (member "slate" (alist-get 'choices slot)))))

(ert-deftest homun-api-json-rows-fit-the-cap ()
  (let* ((homun-api-result-max 300)
         (text (homun-api--json-rows (make-list 40 (make-string 20 ?a)) :k 1))
         (data (json-parse-string text :object-type 'alist)))
    (should (<= (length text) 300))
    (should (= 40 (+ (length (alist-get 'rows data)) (alist-get 'cut data))))))

(ert-deftest homun-api-typed-entries ()
  (let ((homun-api-log-file (make-temp-file "homun-api-log")))
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (should (string-prefix-p "err invalid" (homun-api-call '("variable" "get" "name" "load-path"))))
    (should (string-prefix-p "err invalid" (homun-api-call '("variable" "get" "name" "claude-api-token"))))
    (should (string-match-p "\"value\":\"5\"" (homun-api-call '("variable" "get" "name" "homun-api-timeout"))))
    (should (string-prefix-p "err invalid" (homun-api-call '("mode" "set" "mode" "homun-nope-mode" "state" "on"))))
    (should (string-prefix-p "err invalid" (homun-api-call '("window" "set" "buffer" "*scratch*"))))
    (should (string-prefix-p "ok" (homun-api-call '("window" "set" "buffer" "*scratch*"
                                                     "showing" "*scratch*"))))))

(ert-deftest homun-api-var-reset-takes-the-definition ()
  (let* ((dir (make-temp-file "homun-api" t))
         (file (expand-file-name "claude-reset-probe.el" dir))
         (homun-api-load-roots (list dir))
         (homun-api-log-file (make-temp-file "homun-api-log")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "(defvar claude-reset-probe (+ 1 1) \"Doc.\")\n"))
          (load file nil t t)
          (setq claude-reset-probe 9)
          (should (string-match-p "\"value\":\"2\"" (homun-api-call (quote ("variable" "set" "name" "claude-reset-probe" "reset" "yes")))))
          (should (= 2 (symbol-value 'claude-reset-probe)))
          ;; Only the cockpit's own variables
          (should (string-prefix-p "err invalid" (homun-api-call (quote ("variable" "set" "name" "fill-column" "reset" "yes"))))))
      (delete-directory dir t))))

(ert-deftest homun-api-variable-get-display-vars ()
  (let ((homun-api-log-file (make-temp-file "homun-api-log")))
    (with-current-buffer (get-buffer-create "*homun-api-hl*")
      (setq-local header-line-format '(" probe " "x")))
    (unwind-protect
        (let ((r (homun-api-call '("variable" "get" "name" "header-line-format" "buffer" "*homun-api-hl*"))))
          (should (string-prefix-p "ok" r))
          (should (string-match-p "probe" r))
          (should (string-match-p "\"local\":true" r))
          ;; other non-scalar variables stay closed
          (should (string-prefix-p "err invalid" (homun-api-call '("variable" "get" "name" "load-path")))))
      (kill-buffer "*homun-api-hl*"))))

(ert-deftest homun-api-buffer-props ()
  (let ((homun-api-log-file (make-temp-file "homun-api-log")))
    (with-current-buffer (get-buffer-create "*homun-api-props*")
      (erase-buffer)
      (insert "plain " (propertize "bold" 'face 'bold 'help-echo "tip") " tail")
      (overlay-put (make-overlay 7 11) 'homun-probe t))
    (unwind-protect
        (let* ((r (homun-api-call '("buffer" "props" "name" "*homun-api-props*" "match" "bold" "chars" "6")))
               (j (json-parse-string (substring r 3) :object-type 'plist)))
          (should (string-prefix-p "ok" r))
          (should (= 7 (plist-get j :start)))
          (should (equal "bold" (plist-get (aref (plist-get j :runs) 0) :text)))
          (should (string-match-p "help-echo" (plist-get (aref (plist-get j :runs) 0) :props)))
          (should (= 2 (length (plist-get j :runs))))
          (should (string-match-p "homun-probe" (plist-get (aref (plist-get j :overlays) 0) :props)))
          (should (string-prefix-p "ok" (homun-api-call '("buffer" "props" "name" "*homun-api-props*" "pos" "1"))))
          (should (string-prefix-p "err invalid" (homun-api-call '("buffer" "props" "name" "*homun-api-props*"))))
          (should (string-prefix-p "err invalid" (homun-api-call '("buffer" "props" "name" "*homun-api-props*" "pos" "999"))))
          (should (string-prefix-p "err invalid" (homun-api-call '("buffer" "props" "name" "*homun-api-props*" "match" "nope")))))
      (kill-buffer "*homun-api-props*"))))

(define-derived-mode homun-api-probe-mode special-mode "Probe")

(ert-deftest homun-api-view-refresh ()
  (let ((homun-api-log-file (make-temp-file "homun-api-log")) (drawn 0))
    (with-current-buffer (get-buffer-create "*homun-api-view*")
      (homun-api-probe-mode)
      (setq-local revert-buffer-function (lambda (&rest _) (cl-incf drawn))))
    (with-current-buffer (get-buffer-create "*homun-api-file*") (fundamental-mode))
    (unwind-protect
        (progn
          (should (string-match-p "\"refreshed\":\\[\"\\*homun-api-view\\*\"\\]"
                                  (homun-api-call '("view" "refresh" "buffer" "*homun-api-view*"))))
          (should (= 1 drawn))
          ;; a buffer that is no cockpit view is refused, and none shown means nothing drawn
          (should (string-prefix-p "err invalid" (homun-api-call '("view" "refresh" "buffer" "*homun-api-file*"))))
          (should (string-prefix-p "ok" (homun-api-call '("view" "refresh"))))
          (should (= 1 drawn)))
      (kill-buffer "*homun-api-view*")
      (kill-buffer "*homun-api-file*"))))

(ert-deftest homun-api-reload-keeps-other-files-entries ()
  (let ((homun-api--entries nil))
    (homun-api-define "t other" "From a second file." () 'kept)
    (load (locate-library "homun-api.el") nil t)
    (should (assoc "t other" homun-api--entries))))

(ert-deftest homun-api-files-register-and-survive-reloads ()
  "Every file that registers entries keeps them, in any load order, loaded twice."
  (let* ((dir (file-name-directory (locate-library "homun-api.el")))
         (files (seq-filter
                 (lambda (f)
                   (with-temp-buffer
                     (insert-file-contents f)
                     (re-search-forward "(homun-api-\\(?:define\\|register\\) \"" nil t)))
                 (directory-files dir t "\\.el\\'")))
         (names (apply #'append
                       (mapcar (lambda (f)
                                 (with-temp-buffer
                                   (insert-file-contents f)
                                   (let (acc)
                                     (while (re-search-forward
                                             "^\\s-*(homun-api-\\(?:define\\|register\\) \"\\([^\"]+\\)\"" nil t)
                                       (push (match-string 1) acc))
                                     acc)))
                               files)))
         (order (sort (append files files) (lambda (_a _b) (zerop (random 2))))))
    (should (member "compile start" names))
    (dolist (f order) (load f nil t))
    (dolist (n names) (should (assoc n homun-api--entries)))))
