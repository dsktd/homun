;;; homun-stage-project.el --- Project scenes of the stage: yakvc, panels, undertow -*- lexical-binding: t -*-

;; Three scenes composed from the stage scene kit (`homun-stage-kit', `homun-stage-kit-parts').
;; `M-x homun-stage-project-show' picks one.  The yakvc scene has no map of the players: the
;; test server logs counts of sessions and matches, no names and no positions.

;;; Code:

(require 'cl-lib)
(require 'homun-stage-store)
(require 'homun-stage-kit)
(require 'homun-stage-kit-parts)

(defvar homun-stage-project-root (expand-file-name "~/claude/") "The workspace root the scenes read.")

(defun homun-stage-project--p (rel) (expand-file-name rel homun-stage-project-root))

(defun homun-stage-project--yakvc ()
  `((type . "col")
    (children
     ((type . "text") (text . "yakvc") (face . "title"))
     ((type . "prs") (id . "prs") (repo . "desocketed/yakvc") (numbers . (216 228 229 230)) (width . 72))
     ((type . "text") (text . "test server") (face . "dim"))
     ((type . "players") (id . "players") (width . 72)
      (file . ,(homun-stage-project--p ".services/buildlog/yakvc-server/server.log")))
     ((type . "log") (id . "log") (width . 72) (lines . 6) (skip . "periodic_stun")
      (file . ,(homun-stage-project--p ".services/buildlog/yakvc-server/server.log"))))))

(defun homun-stage-project--panels ()
  (let ((dir (homun-stage-project--p "gpui-panels/panels")) (bl (homun-stage-project--p ".services/buildlog/panels")))
    `((type . "col")
      (children
       ((type . "text") (text . "panels") (face . "title"))
       ((type . "text") (text . "layout of the join test fixture") (face . "dim"))
       ((type . "layout") (id . "layout") (width . 48) (rows . 7)
        (open . ,(concat dir "/src/layout.rs")) (line . 536)
        (ron . "Split(axis:Horizontal,ratio:0.5,first:Split(axis:Vertical,ratio:0.5,first:Area(1),second:Area(3)),second:Split(axis:Vertical,ratio:0.5,first:Area(2),second:Area(4)))"))
       ((type . "buildstat") (id . "build") (latest . ,bl) (width . 72))
       ((type . "tests") (id . "tests") (latest . ,bl))
       ((type . "checklist") (id . "milestones") (label . "milestones") (width . 48)
        (file . ,(concat dir "/MILESTONES.md")))
       ((type . "commits") (id . "commits") (dir . ,dir) (base . "HEAD~8") (width . 72))))))

(defun homun-stage-project--undertow ()
  (let ((doc (homun-stage-project--p "design/mc-social/DESIGN.md")))
    `((type . "col")
      (children
       ((type . "text") (text . "Undertow") (face . "title"))
       ((type . "cycle") (id . "cycle") (width . 60) (rows . 9)
        (steps . (((label . "day") (sub . "gather, build, explore") (open . ,doc) (line . 13))
                  ((label . "dusk: Ledger") (sub . "vote, exile") (open . ,doc) (line . 13))
                  ((label . "night: tide") (sub . "takes a ring of blocks") (open . ,doc) (line . 13)))))
       ((type . "text") (text . "open questions") (face . "dim"))
       ((type . "section") (id . "questions") (file . ,doc) (heading . "^## 5\\.") (max . 6) (width . 72))))))

(defconst homun-stage-project-scenes
  '(("yakvc" "yakvc" homun-stage-project--yakvc)
    ("panels" "panels" homun-stage-project--panels)
    ("undertow" "Undertow" homun-stage-project--undertow))
  "Scene id, title and the function that builds its spec.")

(defun homun-stage-project-spec (id)
  (funcall (nth 2 (assoc id homun-stage-project-scenes))))

;;;###autoload
(defun homun-stage-project-show (id)
  "Show the project scene ID (yakvc, panels or undertow)."
  (interactive (list (completing-read "Project scene: " (mapcar #'car homun-stage-project-scenes) nil t)))
  (homun-stage-show "manager" id (nth 1 (assoc id homun-stage-project-scenes))
                    (homun-stage-project-spec id) "pinned")
  (unless noninteractive (homun-stage-display id)))

(provide 'homun-stage-project)
;;; homun-stage-project.el ends here
