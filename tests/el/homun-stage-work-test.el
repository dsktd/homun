;;; homun-stage-work-test.el --- ERT for the live work-map -*- lexical-binding: t -*-
(require 'ert)
(require 'homun-stage-work)

(defconst homun-stage-work-test--org "* Agents
** STRT Build
:PROPERTIES:
:AGENT: [[homun-agent:aaa]]
:END:
** TODO Later one
** DONE Old
:PROPERTIES:
:AGENT: [[homun-agent:old]]
:END:
** DONE Fresh
:PROPERTIES:
:AGENT: [[homun-agent:new]]
:END:
")

(defvar homun-stage-work-test--live nil "Running agent plists the stub returns.")

(defmacro homun-stage-work-test--with (&rest body)
  `(let* ((file (make-temp-file "work" nil ".org" homun-stage-work-test--org))
          (now (float-time))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-stage-anim--tweens nil)
          (rows (make-hash-table :test #'equal)))
     (puthash "aaa" '((status . "running")) rows)
     (puthash "old" `((status . "done") (end . ,(- now 999999))) rows)
     (puthash "new" `((status . "done") (end . ,(- now 10))) rows)
     (cl-letf (((symbol-function 'homun-stage-work-running) (lambda () homun-stage-work-test--live))
               ((symbol-function 'homun-stage-work--budget) (lambda () '(6 49)))
               ((symbol-function 'claude-links-row) (lambda (a) (gethash a rows)))
               ((symbol-function 'claude-todos-file) (lambda () file))
               ((symbol-function 'homun-stage-render) #'ignore)
               ((symbol-function 'homun-stage--write) #'ignore))
       (unwind-protect (progn ,@body) (delete-file file)))))

(ert-deftest homun-stage-work-items-from-org-and-store ()
  (homun-stage-work-test--with
   (should (equal (mapcar (lambda (it) (seq-take (cddr it) 2)) (homun-stage-work--items file (float-time)))
                  '(("running" "Agents") ("todo" "Agents") ("done" "Agents"))))))

(ert-deftest homun-stage-work-sync-shows-then-patches ()
  (homun-stage-work-test--with
   (homun-stage-work-sync)
   (let ((s (gethash "work-map" homun-stage-scenes)))
     (should s)
     (should (= 1 (homun-stage-scene-version s)))
     (homun-stage-work-sync)
     (should (= 1 (homun-stage-scene-version s)))
     (puthash "aaa" '((status . "failed")) rows)
     (homun-stage-work-sync)
     (should (= 2 (homun-stage-scene-version s)))
     (should (homun-stage-anim-active-p "work-map"))
     (with-temp-file file (insert homun-stage-work-test--org "** DONE Extra\n:PROPERTIES:\n:AGENT: [[homun-agent:new]]\n:END:\n"))
     (homun-stage-work-sync)
     (should (= 4 (cl-count-if (lambda (n) (string-prefix-p "p" (car n)))
                                (homun-stage-work--nodes (homun-stage-scene-root (gethash "work-map" homun-stage-scenes)))))))))

(ert-deftest homun-stage-work-planets-by-urgency ()
  (let* ((root (homun-stage-work--root '(("a" "Build it now please" "running" "A") ("b" "wait one" "wait" "A")
                                         ("c" "later" "todo" "A") ("d" "done one" "done" "A"))))
         (nodes (homun-stage-work--nodes root))
         (dist (lambda (id) (let ((n (alist-get id nodes nil nil #'equal)))
                              (round (sqrt (+ (expt (- (alist-get 'x n) 200) 2) (expt (- (alist-get 'y n) 170) 2))))))))
    (let ((ids (mapcar #'car nodes)))
      (should (= 4 (cl-count-if (lambda (i) (string-prefix-p "p" i)) ids)))
      (should (= 3 (cl-count-if (lambda (i) (string-prefix-p "l" i)) ids))))
    (let ((orbits (cl-loop for (id . n) in nodes when (string-prefix-p "p" id) collect (funcall dist id))))
      (should (equal (sort orbits #'<) '(60 110 155 155))))
    (should (equal (alist-get 'label (alist-get "m" nodes nil nil #'equal)) "today 1 of 4"))))

(ert-deftest homun-stage-work-ops-tween-moves-only ()
  (let* ((a (homun-stage-work--root '(("a" "Build" "todo" "A"))))
         (b (homun-stage-work--root '(("a" "Build" "running" "A"))))
         (ops (homun-stage-work--ops a b)))
    (should ops)
    (should (cl-every (lambda (o) (if (string-match-p "/[xy]\\'" (alist-get 'path o)) (assq 'animate o) (assq 'set o))) ops))
    (should-not (homun-stage-work--ops a a))))

(ert-deftest homun-stage-work-every-running-agent-shows ()
  (homun-stage-work-test--with
   ;; aaa: linked to a heading; old: resumed (its row says done); zzz: no heading, tracker task
   (puthash "old" `((status . "done") (end . ,(- now 10))) rows)
   (let ((homun-stage-work-test--live
          '((:id "aaa" :desc "Build" :kind agent) (:id "old" :desc "Old" :kind agent)
            (:id "zzz" :desc "Headless one" :kind agent :task "12"))))
     (let ((items (homun-stage-work--items file (float-time))))
       (should (equal (mapcar #'cadr (seq-filter (lambda (it) (equal (nth 2 it) "running")) items))
                      '("Build" "Old" "Headless one")))
       (should (= 1 (cl-count "zzz" items :key (lambda (it) (nth 4 it)) :test #'equal)))))))

(ert-deftest homun-stage-work-cap-keeps-running ()
  (homun-stage-work-test--with
   (let ((homun-stage-work-max 3)
         (homun-stage-work-test--live '((:id "r1" :desc "R1" :kind agent) (:id "r2" :desc "R2" :kind agent))))
     (should (equal (mapcar #'caddr (homun-stage-work--items file (float-time)))
                    '("running" "running" "running"))))))
