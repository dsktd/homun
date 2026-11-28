;;; claude-questions-test.el --- ERT for the question buffers -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-questions-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(defvar claude-service-dir nil)
(require 'claude-questions)
;; Set, not defvar'd: another test file loaded first may already have bound it
(setq claude-service-dir (file-name-as-directory (make-temp-file "svc" t)))
(setq claude-answers-dir (expand-file-name "answers/" claude-service-dir))

(defconst claude-questions-test-org "\
* Which database?
:PROPERTIES:
:ID: db
:END:
- [ ] sqlite
- [ ] postgres
- [ ] Other:
- [ ] Skip / wrong question

* Which pool size?
:PROPERTIES:
:ID: pool
:WHEN: db=postgres
:END:
- [ ] 10
- [ ] 50

* Pool timeout?
:PROPERTIES:
:ID: timeout
:WHEN: pool=50 !db=sqlite
:END:
- [ ] 5s
- [ ] 30s

* Anything else?
:PROPERTIES:
:ID: else
:END:
#+begin_note
#+end_note
")

(defmacro claude-questions-test--with (id &rest body)
  "Run BODY in a fresh question buffer of ID, never displayed."
  (declare (indent 1))
  `(let* ((file (make-temp-file "q" nil ".org" claude-questions-test-org))
          (buffer (claude-questions-open file ,id)))
     (unwind-protect (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (let ((kill-buffer-hook nil)) (kill-buffer buffer))))))

(defun claude-questions-test--tick (text)
  "Tick the item TEXT and run the checkbox hook as C-c C-c would."
  (goto-char (point-min))
  (search-forward (concat "[ ] " text))
  (replace-match (concat "[X] " text) t t)
  (run-hooks 'org-checkbox-statistics-hook))

(defun claude-questions-test--state (id)
  (alist-get 'state (seq-find (lambda (q) (equal (alist-get 'id q) id))
                              (claude-questions--all))))

(defun claude-questions-test--answers (name)
  (json-parse-string (with-temp-buffer
                       (insert-file-contents (expand-file-name name claude-answers-dir))
                       (buffer-string))
                     :object-type 'alist :array-type 'list))

(ert-deftest claude-questions-when-parses ()
  (should (equal (claude-questions--parse-when "db=postgres !x=\"two words\"")
                 '((nil "db" . "postgres") (t "x" . "two words"))))
  (should-not (claude-questions--parse-when nil))
  (should-error (claude-questions--parse-when "db") :type 'user-error)
  (should-error (claude-questions--parse-when "db=a junk") :type 'user-error))

(ert-deftest claude-questions-conditions-chain ()
  (claude-questions-test--with "c1"
    (should (equal (claude-questions-test--state "pool") "N/A"))
    (should (equal (claude-questions-test--state "timeout") "N/A"))
    (claude-questions-test--tick "postgres")
    (should (equal (claude-questions-test--state "pool") "OPEN"))
    (should (equal (claude-questions-test--state "timeout") "N/A"))
    (claude-questions-test--tick "50")
    (should (equal (claude-questions-test--state "timeout") "OPEN"))))

(ert-deftest claude-questions-save-stages-answered ()
  (claude-questions-test--with "c2"
    (claude-questions-test--tick "sqlite")
    (save-buffer)
    (should (equal (claude-questions-test--state "db") "STAGED"))
    (should (equal (claude-questions-test--state "else") "OPEN"))))

(ert-deftest claude-questions-write-in-and-skip ()
  (claude-questions-test--with "c3"
    (goto-char (point-min))
    (search-forward "[ ] Other:")
    (replace-match "[X] Other: mysql" t t)
    (should (equal (alist-get 'choices (car (claude-questions--all))) '("mysql")))
    (claude-questions-test--tick "Skip / wrong question")
    (let ((db (car (claude-questions--all))))
      (should (alist-get 'skipped db))
      (should-not (alist-get 'choices db)))))

(ert-deftest claude-questions-partial-then-final-submit ()
  (claude-questions-test--with "c4"
    (claude-questions-test--tick "sqlite")
    (claude-questions-submit)
    (let ((part (claude-questions-test--answers "c4.part-1")))
      (should (equal (mapcar (lambda (a) (alist-get 'id a)) part) '("db")))
      (should (equal (alist-get 'choices (car part)) '("sqlite"))))
    (should (equal (claude-questions-test--state "db") "DONE"))
    (should (buffer-live-p (current-buffer)))
    (goto-char (point-min))
    (search-forward "#+begin_note\n")
    (insert "ship it\n")
    (claude-questions-submit)
    (let ((final (claude-questions-test--answers "c4")))
      (should (equal (mapcar (lambda (a) (alist-get 'id a)) final) '("else" "pool" "timeout")))
      (should (equal (alist-get 'text (car final)) "ship it"))
      (should (equal (alist-get 'status (cadr final)) "na")))))

(ert-deftest claude-questions-ask-and-reply ()
  (let ((claude-questions-events (make-temp-file "events")))
    (claude-questions-test--with "c5"
      (goto-char (point-max))
      (insert "#+begin_ask\nwhy this one?\n#+end_ask\n")
      (claude-questions-ask)
      (let ((event (json-parse-string
                    (with-temp-buffer (insert-file-contents claude-questions-events) (buffer-string))
                    :object-type 'alist)))
        (should (equal (alist-get 'alarm event) "dashboard"))
        (should (string-match-p "ask on question else in c5" (alist-get 'msg event)))
        (should (string-match-p "why this one" (alist-get 'msg event))))
      (should-error (claude-questions-ask) :type 'user-error)
      (let ((here (point)))
        (claude-questions-reply "c5" "else" "because")
        (should (= here (point))))
      (should (string-match-p "\\*\\*\\* Manager\nbecause\n" (buffer-string)))
      (should (equal (alist-get 'text (car (last (claude-questions--all)))) "")))))

(ert-deftest claude-questions-push-back-ticks-skip ()
  (claude-questions-test--with "c6"
    (goto-char (point-min))
    (claude-questions-push-back)
    (insert "wrong premise")
    (let ((db (car (claude-questions--all))))
      (should (alist-get 'skipped db))
      (should (equal (alist-get 'notes db) "wrong premise"))
      (should (claude-questions--answered-p db)))))

;;;; Chaining

(defconst claude-questions-test-one "* Pick\n:PROPERTIES:\n:ID: pick\n:END:\n- [ ] yes\n- [ ] no\n")

(defmacro claude-questions-test--chain (ids &rest body)
  "Open one question buffer per ID in IDS, registered, as BUFFERS; run BODY."
  (declare (indent 1))
  `(let* ((claude-questions--waiting nil)
          (buffers (mapcar (lambda (id)
                             (let* ((file (make-temp-file "q" nil ".org" claude-questions-test-one))
                                    (buffer (claude-questions-open file id)))
                               (claude-questions--register id file)
                               buffer))
                           ,ids)))
     (unwind-protect (progn ,@body)
       (dolist (b buffers)
         (when (buffer-live-p b)
           (with-current-buffer b (set-buffer-modified-p nil))
           (let ((kill-buffer-hook nil)) (kill-buffer b)))))))

(ert-deftest claude-questions-chain-shows-next-then-closes ()
  (claude-questions-test--chain '("m1" "m2")
    (let ((window (selected-window)))
      (set-window-buffer window (car buffers))
      (claude-questions--count-more)
      (should (= 1 (buffer-local-value 'claude-questions--more (car buffers))))
      (with-current-buffer (car buffers)
        (claude-questions-test--tick "yes")
        (claude-questions-submit))
      (should-not (buffer-live-p (car buffers)))
      (should (eq (window-buffer window) (cadr buffers)))
      (should (= 0 (buffer-local-value 'claude-questions--more (cadr buffers))))
      (should (file-exists-p (expand-file-name "m1" claude-answers-dir)))
      (with-current-buffer (cadr buffers)
        (claude-questions-test--tick "no")
        (claude-questions-submit))
      (should-not (buffer-live-p (cadr buffers)))
      (should (file-exists-p (expand-file-name "m2" claude-answers-dir)))
      (should-not claude-questions--waiting))))

(ert-deftest claude-questions-chain-decline-moves-on-and-skips-stale ()
  (claude-questions-test--chain '("s1" "s2" "s3")
    ;; s2's caller timed out: skipped
    (with-current-buffer (cadr buffers) (setq claude-ask-timed-out t))
    (set-window-buffer (selected-window) (car buffers))
    (with-current-buffer (car buffers) (claude-questions-decline))
    (should (file-exists-p (expand-file-name "s1.declined" claude-answers-dir)))
    (should (eq (window-buffer (selected-window)) (nth 2 buffers)))
    (should (equal (mapcar #'car claude-questions--waiting) '("s2" "s3")))))

(ert-deftest claude-questions-chain-stale-registry-entry ()
  (claude-questions-test--chain '("r1")
    (claude-questions--register "gone" "/nonexistent.org")
    (should (equal (claude-questions--pending) buffers))
    (with-current-buffer (car buffers)
      (should (= 0 (progn (claude-questions--count-more) claude-questions--more))))))

;;;; Notes at three levels

(defconst claude-questions-test-notes "\
#+begin_note
buffer note
#+end_note

* Pick
:PROPERTIES:
:ID: pick
:END:
- [ ] yes
  #+begin_note
  why not
  #+end_note
- [X] no
- [ ] Other: ___

#+begin_note
question note
#+end_note
")

(defmacro claude-questions-test--with-notes (&rest body)
  `(let* ((file (make-temp-file "q" nil ".org" claude-questions-test-notes))
          (buffer (claude-questions-open file "n1")))
     (unwind-protect (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (let ((kill-buffer-hook nil)) (kill-buffer buffer))))))

(ert-deftest claude-questions-notes-three-levels ()
  (claude-questions-test--with-notes
    (should (equal (claude-questions--buffer-notes) '("buffer note")))
    (let ((q (car (claude-questions--all))))
      (should (equal (alist-get 'notes q) "question note"))
      (should (equal (alist-get 'choice-notes q) '((yes . "why not"))))
      (should (equal (alist-get 'choices q) '("no"))))))

(ert-deftest claude-questions-notes-survive-staging-and-submit ()
  (claude-questions-test--with-notes
    (claude-questions-submit)
    (let* ((json (claude-questions-test--answers "n1"))
           (buffer-entry (car json))
           (pick (cadr json)))
      (should (equal (alist-get 'id buffer-entry) "_buffer"))
      (should (equal (alist-get 'blocks buffer-entry) '("buffer note")))
      (should (equal (alist-get 'choice_notes pick) '((yes . "why not"))))
      (should (equal (alist-get 'notes pick) "question note")))))

(ert-deftest claude-questions-staging-keeps-item-note-text ()
  (claude-questions-test--with-notes
    (claude-questions-refresh t)
    (should (string-match-p "why not" (buffer-string)))
    (should (equal (alist-get 'choice-notes (car (claude-questions--all))) '((yes . "why not"))))))

(ert-deftest claude-questions-add-notes-from-menu ()
  (claude-questions-test--with-notes
    (goto-char (point-min))
    (search-forward "- [X] no")
    (claude-questions-add-choice-note)
    (insert "because")
    (should (equal (alist-get 'choice-notes (car (claude-questions--all)))
                   '((yes . "why not") (no . "because"))))
    (claude-questions-add-note)
    (insert "second")
    (should (equal (alist-get 'notes (car (claude-questions--all)))
                   "question note\n\nsecond"))))
