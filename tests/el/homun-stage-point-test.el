;;; homun-stage-point-test.el --- ERT for pulses, anchors, chips and the patch log -*- lexical-binding: t -*-

(require 'ert)
(require 'homun-api)
(require 'homun-stage-point)

(defmacro homun-stage-point-test--with (&rest body)
  `(let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-api-log-file (make-temp-file "api-log")))
     (unwind-protect (progn ,@body)
       (homun-stage--unmark)
       (dolist (b (buffer-list))
         (when (string-match-p "\\`\\*stage " (buffer-name b)) (kill-buffer b)))
       (delete-directory homun-stage-dir t))))

(defconst homun-stage-point-test--root
  "{\"type\":\"col\",\"id\":\"root\",\"children\":[{\"type\":\"text\",\"id\":\"t\",\"text\":\"Roll\"}]}")

(defun homun-stage-point-test--show ()
  (homun-api-call (list "stage" "show" "id" "roll" "title" "Roll" "root" homun-stage-point-test--root)))

(defun homun-stage-point-test--set (text)
  (homun-api-call (list "stage" "patch" "id" "roll"
                        "ops" (format "[{\"path\":\"/t/text\",\"set\":\"%s\"}]" text))))

(ert-deftest homun-stage-point-focus-file-keeps-point ()
  (homun-stage-point-test--with
   (let ((file (make-temp-file "pulse")))
     (with-temp-file file (insert "a\nb\nc\nd\n"))
     (with-current-buffer (find-file-noselect file)
       (goto-char 3)
       (let ((win (selected-window)) (cur (current-buffer)))
         (should (equal (homun-api-call (list "stage" "focus" "target" (concat "file:" file ":2-3")))
                        "ok\n{\"ok\":true,\"shown\":true}"))
         (should (= (point) 3))
         (should (eq (selected-window) win))
         (should (eq (current-buffer) cur))
         (should (= (length homun-stage--marks) 1))
         (should (equal (buffer-substring (overlay-start (car homun-stage--marks))
                                          (overlay-end (car homun-stage--marks)))
                        "b\nc\n")))
       (kill-buffer)))))

(ert-deftest homun-stage-point-hover-sync ()
  (homun-stage-point-test--with
   (homun-stage-point-test--show)
   (with-temp-buffer
     (insert (homun-stage-anchors-in "see [the text](homun:stage/roll/t) here"))
     (let ((sb (get-buffer "*stage roll*")))
       (should (get-text-property 5 'homun-stage-anchor))
       (with-current-buffer sb
         (should (equal (get-text-property (point-min) 'homun-node) "roll/t")))
       ;; node side hovered: the prose is highlighted
       (homun-stage-hover nil sb (with-current-buffer sb (point-min)))
       (should (cl-some (lambda (o) (eq (overlay-buffer o) (current-buffer))) homun-stage--marks))
       (should (cl-some (lambda (o) (eq (overlay-buffer o) sb)) homun-stage--marks))
       ;; prose side hovered: the node is highlighted
       (homun-stage--unmark)
       (homun-stage-hover nil (current-buffer) 5)
       (should (cl-some (lambda (o) (eq (overlay-buffer o) sb)) homun-stage--marks))))))

(ert-deftest homun-stage-point-closed-chip ()
  (homun-stage-point-test--with
   (homun-stage-point-test--show)
   (homun-api-call (list "stage" "close" "id" "roll"))
   (let ((s (homun-stage-anchors-in "[done](homun:stage/roll)")))
     (should (eq (get-text-property 0 'homun-button-role s) 'chip))
     (with-temp-buffer
       (insert s) (goto-char 1)
       (save-window-excursion (homun-stage-anchor-activate))
       (should (get-buffer "*stage snapshot roll*"))
       (kill-buffer "*stage snapshot roll*")))))

(ert-deftest homun-stage-point-patch-log-scrub ()
  (homun-stage-point-test--with
   (homun-stage-point-test--show)
   (homun-stage-point-test--set "one")
   (homun-stage-point-test--set "two")
   (with-current-buffer (get-buffer "*stage roll*")
     (should (string-match-p "two" (buffer-string)))
     (homun-stage-scrub-back)
     (should (string-match-p "one" (buffer-string)))
     (homun-stage-scrub-back)
     (should (string-match-p "Roll" (buffer-string)))
     (homun-stage-scrub-forward) (homun-stage-scrub-forward)
     (should-not homun-stage--scrub)
     (should (string-match-p "two" (buffer-string))))))

(ert-deftest homun-stage-point-log-trim-keeps-base ()
  (homun-stage-point-test--with
   (homun-stage-point-test--show)
   (let ((homun-stage-max-log 3))
     (dotimes (i 5) (homun-stage-patch "manager" "roll" (homun-stage-parse (format "[{\"path\":\"/t/text\",\"set\":\"n%d\"}]" i))))
     (let ((s (homun-stage-scene "roll")))
       (should (= (length (homun-stage-scene-patches s)) 3))
       (should (alist-get 'root (car (homun-stage-scene-patches s))))
       (should (equal (alist-get 'text (car (homun-stage--find (homun-stage-root-at s 4) "t"))) "n2"))))))
