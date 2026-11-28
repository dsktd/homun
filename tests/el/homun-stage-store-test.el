;;; homun-stage-store-test.el --- ERT for the Stage store and its API entries -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-stage-store-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'homun-api)
(require 'homun-stage-store)

(defconst homun-stage-store-test--root
  "{\"type\":\"col\",\"id\":\"root\",\"children\":[
     {\"type\":\"text\",\"id\":\"t\",\"text\":\"Roll\"},
     {\"type\":\"stepper\",\"id\":\"s\",\"steps\":[\"pull\",\"build\"],\"current\":0},
     {\"type\":\"table\",\"id\":\"tb\",\"rows\":[]}]}")

(defmacro homun-stage-store-test--with (&rest body)
  `(let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-api-log-file (make-temp-file "api-log")))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (string-prefix-p "*stage " (buffer-name b)) (kill-buffer b)))
       (delete-directory homun-stage-dir t))))

(defun homun-stage-store-test--call (&rest argv) (homun-api-call argv))

(defun homun-stage-store-test--show (&optional id caller)
  (homun-stage-store-test--call "stage" "show" "id" (or id "roll") "title" "Roll"
                                "root" homun-stage-store-test--root "caller" (or caller "manager")))

(defun homun-stage-store-test--patch (ops &rest more)
  (apply #'homun-stage-store-test--call "stage" "patch" "id" "roll" "ops" ops more))

(defun homun-stage-store-test--err (reply)
  (should (string-prefix-p "err invalid\n" reply))
  (json-parse-string (substring reply 12) :object-type 'alist))

(ert-deftest homun-stage-store-build-and-patch ()
  (homun-stage-store-test--with
   (should (equal (homun-stage-store-test--show) "ok\n{\"ok\":true,\"version\":1}"))
   (should (equal (homun-stage-store-test--patch
                   "[{\"path\":\"/s/steps\",\"set\":[\"pull\",\"build\",\"roll\"]},
                     {\"path\":\"/s/current\",\"animate\":{\"to\":2,\"ms\":400}},
                     {\"path\":\"/root/children/-\",\"insert\":{\"type\":\"md\",\"id\":\"why\",\"text\":\"gate\"}},
                     {\"path\":\"/root/children/t\",\"remove\":true},
                     {\"path\":\"/tb/rows\",\"set\":[[\"a\",\"b\"]]}]")
                  "ok\n{\"ok\":true,\"version\":2}"))
   (should (equal (homun-stage-text (homun-stage-scene-root (homun-stage-scene "roll")))
                  "✓ pull\n✓ build\n▸ roll\na │ b\ngate"))
   (should (string-match-p "▸ roll" (with-current-buffer "*stage roll*" (buffer-string))))))

(ert-deftest homun-stage-store-all-or-nothing ()
  (homun-stage-store-test--with
   (homun-stage-store-test--show)
   (let ((e (homun-stage-store-test--err
             (homun-stage-store-test--patch
              "[{\"path\":\"/s/current\",\"set\":1},{\"path\":\"/s/nope/x\",\"set\":1}]"))))
     (should (equal (alist-get 'field e) "/s/nope")))
   (should (= 1 (homun-stage-scene-version (homun-stage-scene "roll"))))
   (should (equal (alist-get 'current (car (homun-stage--find (homun-stage-scene-root (homun-stage-scene "roll")) "s"))) 0))
   ;; a patch that leaves an invalid tree names the field and changes nothing
   (let ((e (homun-stage-store-test--err (homun-stage-store-test--patch "[{\"path\":\"/s/type\",\"set\":\"blob\"}]"))))
     (should (string-match-p "type" (alist-get 'field e))))
   (should (equal (alist-get 'field (homun-stage-store-test--err (homun-stage-store-test--patch "[{\"path\":\"/zz/a\",\"set\":1}]")))
                  "/zz"))))

(ert-deftest homun-stage-store-owner-version-limits ()
  (homun-stage-store-test--with
   (homun-stage-store-test--show)
   (should (equal (alist-get 'error (homun-stage-store-test--err
                                     (homun-stage-store-test--patch "[{\"path\":\"/s/current\",\"set\":1}]" "caller" "mechanic")))
                  "not owner"))
   (should (equal (alist-get 'error (homun-stage-store-test--err (homun-stage-store-test--show "roll" "mechanic")))
                  "not owner"))
   (should (equal (alist-get 'field (homun-stage-store-test--err
                                     (homun-stage-store-test--patch "[{\"path\":\"/s/current\",\"set\":1}]" "if_version" "7")))
                  "if_version"))
   (let ((many (concat "[" (mapconcat #'identity (make-list 65 "{\"path\":\"/s/current\",\"set\":1}") ",") "]")))
     (should (equal (alist-get 'limit (homun-stage-store-test--err (homun-stage-store-test--patch many))) "max_ops")))
   (dotimes (_ 20) (homun-stage-store-test--patch "[{\"path\":\"/s/current\",\"set\":1}]"))
   (should (equal (alist-get 'limit (homun-stage-store-test--err
                                     (homun-stage-store-test--patch "[{\"path\":\"/s/current\",\"set\":1}]")))
                  "patch_rate"))
   (let ((big (format "{\"type\":\"text\",\"text\":\"%s\"}" (make-string (* 300 1024) ?x))))
     (should (equal (alist-get 'limit (homun-stage-store-test--err
                                       (homun-stage-store-test--call "stage" "show" "id" "big" "title" "b" "root" big)))
                    "max_bytes")))
   (should (equal (alist-get 'field (homun-stage-store-test--err
                                     (homun-stage-store-test--call "stage" "show" "id" "bad" "title" "b" "root" "{\"type\":\"blob\"}")))
                  "root/type"))))

(ert-deftest homun-stage-store-close-list-persist-tabs ()
  (homun-stage-store-test--with
   (homun-stage-store-test--show)
   (should (file-exists-p (expand-file-name "roll.json" homun-stage-dir)))
   (homun-stage-load)
   (should (= 1 (homun-stage-scene-version (homun-stage-scene "roll"))))
   (homun-stage-pin "manager" "roll")
   (dotimes (i 6) (homun-stage-store-test--show (format "s%d" i)))
   (should (= 6 (hash-table-count homun-stage-scenes)))
   (should (gethash "roll" homun-stage-scenes))
   (should-not (gethash "s0" homun-stage-scenes))
   (should (equal (alist-get 'error (homun-stage-store-test--err
                                     (homun-stage-store-test--call "stage" "close" "id" "roll" "caller" "mechanic")))
                  "not owner"))
   (should (string-prefix-p "ok" (homun-stage-store-test--call "stage" "close" "id" "s5" "caller" "cal")))
   (should (file-exists-p (expand-file-name "closed/s5.json" homun-stage-dir)))
   (should-not (file-exists-p (expand-file-name "s5.json" homun-stage-dir)))
   (should (= 5 (length (json-parse-string (substring (homun-stage-store-test--call "stage" "list") 3)))))
   (let ((got (json-parse-string (substring (homun-stage-store-test--call "stage" "get" "id" "roll") 3) :object-type 'alist)))
     (should (equal (alist-get 'lifetime got) "pinned"))
     (should (string-match-p "▸ pull" (alist-get 'text got))))))

(ert-deftest homun-stage-store-schema-hides-caller ()
  (let* ((schema (json-parse-string (substring (homun-api-call '("api" "schema" "object" "stage")) 3)
                                    :object-type 'alist :array-type 'list))
         (show (seq-find (lambda (e) (equal (alist-get 'name e) "stage show")) schema)))
    (should (eq (alist-get 'caller show) t))
    (should-not (seq-find (lambda (a) (equal (alist-get 'key a) "caller")) (alist-get 'args show)))
    (should (= 8 (length schema)))))

(ert-deftest homun-stage-default-buffer-resumes-last-shown-scene ()
  "After a restart (scenes loaded, no buffers) the stage shows the scene used last."
  (homun-stage-store-test--with
   (homun-stage-show "x" "old" "Old" (json-parse-string homun-stage-store-test--root :object-type 'alist :array-type 'list) "pinned")
   (homun-stage-show "x" "new" "New" (json-parse-string homun-stage-store-test--root :object-type 'alist :array-type 'list) "pinned")
   (setf (homun-stage-scene-used (gethash "old" homun-stage-scenes)) (+ (float-time) 10))
   (dolist (b (buffer-list))
     (when (string-prefix-p "*stage " (buffer-name b)) (kill-buffer b)))
   (should (equal "*stage old*" (buffer-name (homun-stage-default-buffer))))))

(ert-deftest homun-stage-default-buffer-placeholder-only-without-scenes ()
  (homun-stage-store-test--with
   (should (equal "*claude-layout*" (buffer-name (homun-stage-default-buffer))))))

;;; The homund backend (skipped without a `homund' on PATH)

(defmacro homun-stage-store-test--homund (&rest body)
  `(progn
     (skip-unless (executable-find "homund"))
     (homun-stage-store-test--with
      (let ((homun-stage-backend 'homund)) ,@body))))

(ert-deftest homun-stage-store-homund-survives-restart ()
  (homun-stage-store-test--homund
   (should (equal (homun-stage-store-test--show) "ok\n{\"ok\":true,\"version\":1}"))
   (homun-stage-store-test--patch "[{\"path\":\"/t/text\",\"set\":\"Rolled\"}]")
   ;; an Emacs restart: the in-memory store is gone, the files homund wrote are not
   (clrhash homun-stage-scenes)
   (homun-stage-load)
   (let ((s (homun-stage-scene "roll")))
     (should (= 2 (homun-stage-scene-version s)))
     (should (equal "Rolled" (alist-get 'text (cadr (assq 'children (homun-stage-scene-root s)))))))
   (should (equal "manager" (homun-stage-scene-owner (homun-stage-scene "roll"))))))

(ert-deftest homun-stage-store-homund-refuses-whole ()
  (homun-stage-store-test--homund
   (homun-stage-store-test--show)
   (let ((e (homun-stage-store-test--err
             (homun-stage-store-test--patch "[{\"path\":\"/t/text\",\"set\":\"x\"},{\"path\":\"/zz/a\",\"set\":1}]"))))
     (should (equal (alist-get 'error e) "no such node")))
   (should (= 1 (homun-stage-scene-version (homun-stage-scene "roll"))))))

(ert-deftest homun-stage-store-homund-subscription-mirrors-others ()
  (homun-stage-store-test--homund
   (homun-stage-load)
   (should (process-live-p homun-stage--subscription))
   (unwind-protect
       (progn
         ;; another writer (the CLI) shows a scene: the subscription brings it in
         (let ((process-environment (cons (concat "HOMUN_STAGE=" (directory-file-name homun-stage-dir))
                                          process-environment)))
           (with-temp-buffer
             (insert homun-stage-store-test--root)
             (call-process-region (point-min) (point-max) "homund" nil nil nil
                                  "stage" "store" "manager" "other" "Other" "turn")))
         (with-timeout (5 (ert-fail "no event"))
           (while (not (gethash "other" homun-stage-scenes)) (accept-process-output nil 0.1)))
         (should (equal "Other" (homun-stage-scene-title (homun-stage-scene "other")))))
     (delete-process homun-stage--subscription))))
