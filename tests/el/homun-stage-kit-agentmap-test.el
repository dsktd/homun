;;; homun-stage-kit-agentmap-test.el --- ERT for the agentmap part -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/homun-stage-kit-agentmap-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'homun-stage-kit-agentmap)

(defconst agentmap-test--fixture
  (expand-file-name "agentmap-fixture.jsonl" (file-name-directory (or load-file-name buffer-file-name))))

(defmacro agentmap-test--with (&rest body)
  (declare (indent 0))
  `(let ((homun-stage-kit--data (make-hash-table :test #'equal))
         (homun-stage-kit-agentmap-min-interval 0)
         (homun-clock-time-function (lambda () 1000.0)))
     (cl-letf (((symbol-function 'homun-stage-kit--wake) #'ignore)
               ((symbol-function 'widgetry-graphic-p) (lambda () t)))
       ,@body)))

(defun agentmap-test--node (file) `((type . "agentmap") (id . "m") (file . ,file) (rows . 6) (width . 40)))

(defun agentmap-test--data (lines)
  (mapcar (lambda (l) (plist-get (cdr (cadr (get-text-property 0 'display l))) :data)) lines))

(defun agentmap-test--poll (node)
  (let ((f (alist-get 'file node)))
    (homun-stage-kit-agentmap--source node (list "agentmap" (expand-file-name f)))))

(ert-deftest homun-stage-kit-agentmap-renders-fixture ()
  (agentmap-test--with
    (let ((node (agentmap-test--node agentmap-test--fixture)))
      (agentmap-test--poll node)
      (let* ((d (homun-stage-kit-get (list "agentmap" agentmap-test--fixture)))
             (m (plist-get d :m)))
        (should (= 2 (hash-table-count (homun-stage-kit-agentmap--m-agents m))))
        (should (= 2 (length (homun-stage-kit-agentmap--m-repos m))))
        (should (= 1 (length (homun-stage-kit-agentmap--m-flashes m))))
        (let ((lines (car (homun-stage-kit--draw (homun-stage-kit--inst-make :type "agentmap" :node node) 0 t))))
          (should (= 6 (length lines)))
          (should (cl-some (lambda (l) (get-text-property 0 'display l)) lines)))))))

(ert-deftest homun-stage-kit-agentmap-new-events-change-it ()
  (agentmap-test--with
    (let* ((tmp (make-temp-file "agentmap" nil ".jsonl")) (node (agentmap-test--node tmp))
           (inst (homun-stage-kit--inst-make :type "agentmap" :node node)))
      (copy-file agentmap-test--fixture tmp t)
      (agentmap-test--poll node)
      (let ((before (agentmap-test--data (car (homun-stage-kit--draw inst 0 t)))))
        (with-temp-buffer
          (insert "{\"t\":1010,\"agent\":\"a3\",\"label\":\"new\",\"kind\":\"edit\",\"path\":\"/r/homun/x.el\",\"repo\":\"/r/homun\",\"ok\":true}\n{\"t\":10")
          (append-to-file nil nil tmp))
        (agentmap-test--poll node)
        (should (= 3 (hash-table-count (homun-stage-kit-agentmap--m-agents (plist-get (homun-stage-kit-get (list "agentmap" (expand-file-name tmp))) :m)))))
        (should-not (equal before (agentmap-test--data (car (homun-stage-kit--draw inst 0 t))))))
      (delete-file tmp))))

(ert-deftest homun-stage-kit-agentmap-no-events-no-redraw ()
  (agentmap-test--with
    (let* ((node (agentmap-test--node agentmap-test--fixture)) (inst (homun-stage-kit--inst-make :type "agentmap" :node node)))
      (agentmap-test--poll node)
      (homun-stage-kit--draw inst 0 t)
      (let ((builds homun-stage-kit-agentmap-builds))
        (dotimes (_ 5) (agentmap-test--poll node) (homun-stage-kit--draw inst 0 t))
        (should (= builds homun-stage-kit-agentmap-builds))))))

(ert-deftest homun-stage-kit-agentmap-missing-stream ()
  (agentmap-test--with
    (let ((node (agentmap-test--node "/nonexistent/events.jsonl")))
      (agentmap-test--poll node)
      (should (string-match-p "no event stream" (homun-stage-kit--text node))))))

(ert-deftest homun-stage-kit-agentmap-clicks ()
  (agentmap-test--with
    (let* ((node (agentmap-test--node agentmap-test--fixture)))
      (agentmap-test--poll node)
      (let* ((m (plist-get (homun-stage-kit-get (list "agentmap" agentmap-test--fixture)) :m))
             (tg (homun-stage-kit-agentmap--targets m 320 96 6)))
        (should (cl-some (lambda (x) (eq (car x) 'agent)) tg))))))

(provide 'homun-stage-kit-agentmap-test)
