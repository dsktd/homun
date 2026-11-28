;;; homun-iface-test.el --- ERT for homun-iface.el -*- lexical-binding: t; -*-
;; emacs --batch -L container/emacs -L <evil> -l tests/el/homun-iface-test.el -f ert-run-tests-batch-and-exit
;; (skipped without evil on the `load-path')

;;; Code:

(require 'ert)
(require 'claude)
(require 'claude-transcript)
(require 'homun-iface)
(require 'evil nil t)

(defconst homun-iface-tests--fixture
  (expand-file-name "claude-transcript-fixture.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro homun-iface-tests--with-session (&rest body)
  "Run BODY in a transcript of the fixture, in the interface state."
  (declare (indent defun))
  `(progn
     (skip-unless (featurep 'evil))
     (let* ((dir (make-temp-file "homun-iface" t))
            (file (expand-file-name "session.jsonl" dir))
            (claude-transcript-projects-directory dir))
       (copy-file homun-iface-tests--fixture file)
       (with-temp-buffer
         (claude-transcript-mode)
         (setq claude-transcript--file file)
         (claude-transcript--render claude-transcript-tail-turns)
         (evil-local-mode 1)
         (evil-homun-interface-state)
         (goto-char (point-min))
         (unwind-protect (progn ,@body)
           (delete-directory dir t))))))

(defun homun-iface-tests--key (keys)
  "The command KEYS run in the current state."
  (key-binding (kbd keys)))

(ert-deftest homun-iface-initial-state ()
  (skip-unless (featurep 'evil))
  (should (eq (evil-initial-state 'claude-transcript-mode) 'homun-interface)))

(ert-deftest homun-iface-jk-move-by-entry ()
  (homun-iface-tests--with-session
    (should (eq (homun-iface-tests--key "M-j") #'homun-iface-next))
    (should-not (memq (homun-iface-tests--key "j") (list #'homun-iface-next)))
    (should (eq (homun-iface-tests--key "M-k") #'homun-iface-previous))
    (homun-iface-first)
    (let ((entries (homun-iface--entries)))
      (should (> (length entries) 4))
      (homun-iface-next)
      (should (= (point) (car (nth 1 entries))))
      (homun-iface-next 2)
      (should (= (point) (car (nth 3 entries))))
      (homun-iface-previous)
      (should (= (point) (car (nth 2 entries)))))))

(ert-deftest homun-iface-turns ()
  (homun-iface-tests--with-session
    (should (eq (homun-iface-tests--key "[[") #'homun-iface-previous-turn))
    (homun-iface-first)
    (homun-iface-next-turn)
    (should (eq (nth 3 (homun-iface-current)) 'turn))
    (should (string-search "You" (buffer-substring (point) (line-end-position))))
    (homun-iface-next)
    (homun-iface-previous-turn)
    (should (eq (nth 3 (homun-iface-current)) 'turn))))

(ert-deftest homun-iface-i-normal-esc-snaps ()
  (homun-iface-tests--with-session
    (should (eq (homun-iface-tests--key "i") #'homun-iface-to-normal))
    (homun-iface-first)
    (homun-iface-next)
    (let ((start (point)))
      (homun-iface-to-normal)
      (should (evil-normal-state-p))
      (should (eq (homun-iface-tests--key "<escape>") #'homun-iface-return))
      (forward-char 3)
      (homun-iface-return)
      (should (evil-homun-interface-state-p))
      (should (= (point) start)))))


(ert-deftest homun-iface-step-builds-entries-once ()
  "A step, back or forward, asks for the entries once, not once per entry."
  (let* ((calls 0)
         (homun-iface-entries-function
          (lambda () (setq calls (1+ calls))
            (mapcar (lambda (n) (list (* n 10) (+ (* n 10) 5) nil 'text)) (number-sequence 0 50)))))
    (with-temp-buffer
      (insert (make-string 600 ?x))
      (cl-letf (((symbol-function 'homun-iface-goto) #'ignore))
        (goto-char 300)
        (setq calls 0)
        (homun-iface-previous)
        (should (= calls 1))
        (setq calls 0)
        (homun-iface-next)
        (should (= calls 1))))))

(ert-deftest homun-iface-snap-past-last-entry-stays ()
  "Point past the last entry stays there; a gap before an entry goes forward."
  (let ((homun-iface-entries-function
         (lambda () (list (list 0 5 nil 'text) (list 10 15 nil 'text)))))
    (with-temp-buffer
      (insert (make-string 40 ?x))
      (progn
        (goto-char 30)
        (homun-iface--snap)
        (should (= (point) 30))
        (goto-char 7)
        (homun-iface--snap)
        (should (= (point) 10))))))

;; Cal could not move point above the last message: a line up from an entry's
;; first line lands in the blank gap above it, and the snap pushed it back down.
(ert-deftest homun-iface-snap-up-into-gap-goes-up ()
  "A gap reached by moving up goes to the end of the entry above it."
  (let ((homun-iface-entries-function
         (lambda () (list (list 1 5 nil 'text) (list 10 15 nil 'text)))))
    (with-temp-buffer
      (insert (make-string 40 ?x))
      (progn
        (goto-char 10)
        (homun-iface--pre-command)
        (goto-char 7)
        (homun-iface--snap)
        (should (= (point) 4))
        (homun-iface--pre-command)
        (goto-char 2)
        (homun-iface--snap)
        (should (= (point) 2))))))

(provide 'homun-iface-test)
;;; homun-iface-test.el ends here
