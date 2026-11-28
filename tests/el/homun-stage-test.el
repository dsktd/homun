;;; homun-stage-test.el --- ERT for homun-stage.el and homun-expr.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-stage-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'json)
(require 'homun-stage)

(defconst homun-stage-test--dir
  (expand-file-name "golden" (file-name-directory (or load-file-name buffer-file-name))))

(defconst homun-stage-test--scene
  "{\"type\":\"col\",\"id\":\"root\",\"children\":[
     {\"type\":\"text\",\"id\":\"t\",\"text\":\"Image build\"},
     {\"type\":\"row\",\"children\":[
        {\"type\":\"stepper\",\"id\":\"s\",\"steps\":[\"pull\",\"build\",\"roll manager\",\"roll others\"],
         \"current\":{\"bind\":\"state.update.phase\"}},
        {\"type\":\"col\",\"children\":[
           {\"type\":\"meter\",\"id\":\"m\",\"label\":\"build\",\"value\":{\"bind\":\"state.update.pct\"}},
           {\"type\":\"meter\",\"id\":\"e\",\"label\":\"expr\",\"value\":{\"expr\":[\"clamp\",[\"*\",\"t\",0.1],0,1]}},
           {\"type\":\"widget\",\"id\":\"w\",\"kind\":\"toggle\",\"label\":\"auto\",\"value\":true}]}]},
     {\"type\":\"md\",\"text\":\"**why**: the roll waits for the gate\"},
     {\"type\":\"table\",\"id\":\"tb\",\"header\":[\"role\",\"image\"],
      \"rows\":[[\"manager\",\"staged\"],[\"mechanic\",\"previous\"]]}]}")

(defun homun-stage-test--parse (s) (json-parse-string s :object-type 'alist :array-type 'list))

(defun homun-stage-test--golden (name)
  (with-temp-buffer
    (insert-file-contents (expand-file-name name homun-stage-test--dir))
    (string-trim-right (buffer-string))))

(ert-deftest homun-stage-text-matches-golden ()
  (let ((homun-stage-bindings (make-hash-table :test #'equal)))
    (puthash "state.update.phase" "build" homun-stage-bindings)
    (puthash "state.update.pct" 0.4 homun-stage-bindings)
    (let ((node (homun-stage-validate (homun-stage-test--parse homun-stage-test--scene))))
      (should (equal (homun-stage-text node '(("t" . 5)))
                     (homun-stage-test--golden "stage-build.txt"))))))

(ert-deftest homun-stage-text-unbound-golden ()
  (let ((homun-stage-bindings (make-hash-table :test #'equal)))
    (should (equal (homun-stage-text (homun-stage-test--parse homun-stage-test--scene) '(("t" . 20)))
                   (homun-stage-test--golden "stage-unbound.txt")))))

(defun homun-stage-test--field (json)
  (condition-case err (progn (homun-stage-validate (homun-stage-test--parse json)) nil)
    (homun-stage-invalid (cadr err))))

(ert-deftest homun-stage-invalid-names-field ()
  (should (equal (homun-stage-test--field "{\"type\":\"blob\"}") "/type"))
  (should (equal (homun-stage-test--field "{\"type\":\"col\",\"children\":[{\"type\":\"text\"}]}")
                 "/children/0/text"))
  (should (equal (homun-stage-test--field
                  "{\"type\":\"col\",\"children\":[{\"type\":\"text\",\"id\":\"a\",\"text\":\"x\"},{\"type\":\"meter\",\"id\":\"a\",\"value\":1}]}")
                 "/children/1/id"))
  (should (equal (homun-stage-test--field "{\"type\":\"meter\",\"value\":{\"expr\":[\"eval\",1]}}") "/value"))
  (should (equal (homun-stage-test--field "{\"type\":\"widget\",\"kind\":\"shell\"}") "/kind"))
  (should (equal (homun-stage-test--field "{\"type\":\"stepper\",\"steps\":[1]}") "/steps")))

(ert-deftest homun-stage-svg-renders ()
  (let ((svg (homun-stage-svg (homun-stage-test--parse homun-stage-test--scene) 400 '(("t" . 1)))))
    (should (eq (car svg) 'svg))
    (should (> (dom-attr svg 'height) 100))))

(ert-deftest homun-stage-steps-preset ()
  (let ((scene (homun-stage-validate
                (homun-stage-steps "Plan" '(("pull" "done") ("build" "now" "slow") ("ask" "you"))))))
    (should (equal (homun-stage-text scene) "Plan\n✓ pull\n▸ build\n    slow\n🔺 ask")))
  (should (equal (homun-stage-text (homun-stage-steps nil '(("a" "done") ("b" "failed")) t))
                 "✓ a  →  ✗ b"))
  (should (equal (homun-stage-test--field
                  "{\"type\":\"stepper\",\"steps\":[\"a\"],\"states\":[\"late\"]}")
                 "/states"))
  (should (equal (homun-stage-test--field "{\"type\":\"text\",\"text\":\"a\",\"face\":\"pink\"}")
                 "/face")))

(ert-deftest homun-stage-button-calls-its-action ()
  (let ((homun-stage-actions (make-hash-table :test #'equal)) (pressed nil))
    (puthash "go" (lambda () (setq pressed t)) homun-stage-actions)
    (funcall (homun-stage--press "go"))
    (should pressed)
    (with-temp-buffer
      (homun-stage-insert '((type . "row") (children ((type . "widget") (kind . "button") (id . "go")
                                                      (label . "Go")))) 400)
      (should (string-match-p "Go" (buffer-string))))))

(ert-deftest homun-expr-closed ()
  (should (= (homun-expr-eval '("lerp" 0 10 "x") '(("x" . 0.5))) 5.0))
  (should (= (homun-expr-eval '("ease" 1) nil) 1.0))
  (should (= (homun-expr-eval '("/" 1 0) nil) 0.0))
  (should-error (homun-expr-eval '("shell-command" "ls") nil))
  (should (homun-expr-check '("eval" 1)))
  (should (homun-expr-check (make-list 3000 1)))
  (should-not (homun-expr-check '("+" "t" ("sin" "i")))))

(ert-deftest homun-stage-event-command-carries-attributes ()
  (let ((homun-stage-event-program '("cal" "send")))
    (should (equal (homun-stage-event-command "s" "go" "click" "t")
                   '("cal" "send" "meta" "origin=stage" "scene=s" "node=go" "kind=click" "value=t")))))

(ert-deftest homun-stage-ask-answers-one-at-a-time ()
  (let* ((sent nil)
         (scene (homun-stage-ask '(("q1" "A?" "choice" ("x" "y")) ("q2" "B?" "many" ("p" "q"))
                                   ("q3" "C?" "text" nil)))))
    (should (= 6 (length (alist-get 'children scene))))
    (cl-letf (((symbol-function 'homun-stage-event)
               (lambda (scene node kind _v &optional text) (push (list scene node kind text) sent))))
      (funcall (gethash "ask:q1:2" homun-stage-actions))
      (should (= 1 (length sent)))
      (should (equal (cl-subseq (car sent) 1 3) '("q1" "answer")))
      (should (equal (alist-get 'choices (json-parse-string (nth 3 (car sent)) :object-type 'alist))
                     ["y"])))))

(ert-deftest homun-stage-ask-press-sends-one-event ()
  (let ((sent nil) (scene (homun-stage-ask '(("q1" "A?" "choice" ("x"))))))
    (should scene)
    (cl-letf (((symbol-function 'homun-stage-event) (lambda (&rest a) (push a sent))))
      (funcall (homun-stage--press "ask:q1:1"))
      (should (= 1 (length sent))))))

(ert-deftest homun-stage-diffview-colours-its-lines ()
  (let ((text (homun-stage-text '((type . "diffview") (diff . "f\n-old\n+new")))))
    (should (equal (substring-no-properties text) "f\n-old\n+new"))
    (should (eq (get-text-property 3 'face text) 'diff-removed))
    (should (eq (get-text-property 8 'face text) 'diff-added))
    (should-error (homun-stage-validate '((type . "diffview"))))))

(ert-deftest homun-stage-tall-svg-is-sliced-and-clicks-resolve ()
  "A tall SVG goes in as several one-line slices; every slice carries its node."
  (let* ((rows (cl-loop for i below 30
                        collect `((type . "text") (id . ,(format "r%d" i)) (text . ,(format "row %d" i)))))
         (node `((type . "box") (id . "tall") (children . ,rows))))
    (cl-letf (((symbol-function 'widgetry-graphic-p) (lambda () t))
              ((symbol-function 'homun-stage--text-only-p) (lambda (_) nil))
              ((symbol-function 'frame-char-height) (lambda (&rest _) 20))
              ((symbol-function 'homun-stage-svg) (lambda (&rest _) (svg-create 300 200)))
              ((symbol-function 'svg-image) (lambda (&rest _) (list 'image :type 'svg))))
      (with-temp-buffer
        (homun-stage-insert node 300 nil)
        (let (slices)
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (when-let* ((d (get-text-property (point) 'display))) (push d slices))
              (forward-char)))
          (should (> (length slices) 5))
          (goto-char (- (point-max) 3))
          (should (equal (get-text-property (point) 'homun-stage-node) "tall")))))))

(ert-deftest homun-stage-no-tall-lines ()
  "No line of a rendered scene holds an unsliced image, a tall space or a line-height."
  (let ((node `((type . "box") (id . "tall")
                (children . ,(cl-loop for i below 12
                                      collect `((type . "text") (id . ,(format "r%d" i)) (text . "x")))))))
    (cl-letf (((symbol-function 'widgetry-graphic-p) (lambda () t))
              ((symbol-function 'homun-stage--text-only-p) (lambda (_) nil))
              ((symbol-function 'frame-char-height) (lambda (&rest _) 20))
              ((symbol-function 'homun-stage-svg) (lambda (&rest _) (svg-create 300 200)))
              ((symbol-function 'svg-image) (lambda (&rest _) (list 'image :type 'svg))))
      (with-temp-buffer
        (homun-stage-insert node 300 nil)
        (dotimes (i (buffer-size))
          (let ((d (get-text-property (1+ i) 'display)))
            (when (and (consp d) (symbolp (car d)))
              (should-not (eq (car d) 'image))
              (should-not (and (eq (car d) 'space) (plist-get (cdr d) :height))))
            (should-not (numberp (get-text-property (1+ i) 'line-height)))))))))

(ert-deftest homun-stage-validates-every-kit-scene ()
  "Every scene the kit can produce validates, and a session that loaded only
`homun-stage' (the phone's) knows the kit's node types."
  (require 'homun-stage-project)
  (dolist (scene homun-stage-project-scenes)
    (let ((spec (homun-stage-project-spec (car scene))))
      (should (equal spec (homun-stage-validate spec)))))
  (with-temp-buffer
    (let ((status (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                "--batch" "-L" "container/emacs" "-L" "container/emacs/widgetry"
                                "-l" "homun-stage" "--eval"
                                "(homun-stage-validate '((type . \"col\") (children ((type . \"layout\") (rows . 7)))))")))
      (should (zerop status)))))
