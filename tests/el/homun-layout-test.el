;;; homun-layout-test.el --- ERT for the lock of homun-layout.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-layout-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'homun-layout)

(defmacro homun-layout-test--with (lock &rest body)
  "Run BODY in a frame split into the four slots, `homun-layout-lock' being LOCK.
`slot' gives the window of a slot."
  (declare (indent 1))
  `(let ((homun-layout-lock ,lock)
         (homun-layout-narrow-columns 1) (homun-layout-orientation 'wide)
         (homun-layout-compose-lines 4)
         (config (current-window-configuration)))
     (unwind-protect
         (cl-flet ((slot (name) (homun-layout-window name)))
           (homun-layout--build)
           ,@body)
       (let ((ignore-window-parameters t)
             (homun-layout-lock nil))
         (homun-layout-lock-apply)
         (set-window-configuration config)))))

(ert-deftest homun-layout-lock-dedicates-the-slots ()
  (homun-layout-test--with t
    (should (equal '(t t t side)
                   (mapcar (lambda (name) (window-dedicated-p (slot name)))
                           '(main board compose slate))))
    (dolist (name '(main board compose slate))
      (should (eq #'homun-layout--keep (window-parameter (slot name) 'delete-window))))
    ;; Window movement (C-x o, evil's C-w hjkl) reaches every slot
    (dolist (name '(main board compose slate))
      (should-not (window-parameter (slot name) 'no-other-window)))
    ;; No mode line under the compose box, the buffer's own on the board, one without key maps elsewhere
    (should-not (window-parameter (slot 'board) 'mode-line-format))
    (should (eq 'none (window-parameter (slot 'compose) 'mode-line-format)))
    (should (eq 'none (window-parameter (slot 'transcript) 'mode-line-format)))
    (should-not (flatten-tree (mapcar (lambda (part) (and (stringp part) (text-properties-at 0 part)))
                                      (flatten-tree homun-layout-lock-mode-line))))))

(ert-deftest homun-layout-lock-refuses-switches-but-not-the-cockpit ()
  (homun-layout-test--with t
    (let ((board (slot 'board))
          (other (get-buffer-create " *homun-layout-test*")))
      (unwind-protect
          (progn
            ;; What C-x b and a click on the mode line come down to
            (with-selected-window board
              (should-error (switch-to-buffer other nil t))
              (should-error (switch-to-prev-buffer board)))
            (should-error (set-window-buffer board other))
            (should (equal "*claude-layout*" (buffer-name (window-buffer board))))
            ;; Deleting it leaves it, alone or with the others
            (delete-window board)
            (should (window-live-p board))
            (with-selected-window (slot 'transcript) (delete-other-windows))
            (should (= 4 (length (homun-layout--windows))))
            ;; The cockpit's own switch works, and the window stays locked
            (homun-layout-show other board)
            (should (eq other (window-buffer board)))
            (should (eq t (window-dedicated-p board))))
        (kill-buffer other)))))

(ert-deftest homun-layout-lock-comes-off-and-on-live ()
  (homun-layout-test--with t
    (let ((board (slot 'board))
          (other (get-buffer-create " *homun-layout-test*")))
      (unwind-protect
          (progn
            (setq homun-layout-lock nil)
            (should (eq 'side (window-dedicated-p board)))
            (should-not (window-dedicated-p (slot 'transcript)))
            (dolist (parameter '(delete-window mode-line-format))
              (should-not (window-parameter board parameter)))
            (set-window-buffer board other)
            (should (eq other (window-buffer board)))
            (setq homun-layout-lock t)
            (should (eq t (window-dedicated-p board)))
            (should-not (window-parameter board 'no-other-window)))
        (kill-buffer other)))))

;; The window API the rest of the cockpit uses instead of window-* calls

(ert-deftest homun-layout-place-routes-to-regions ()
  (homun-layout-test--with t
    (let ((stage (get-buffer-create "*stage test*"))
          (other (get-buffer-create " *homun-layout-test*")))
      (unwind-protect
          (progn
            (should (eq (slot 'stage) (homun-layout-place stage)))
            (should (eq (slot 'stage) (homun-layout-side other)))
            (should (eq other (window-buffer (slot 'stage))))
            ;; Closing a region window blanks it; the window stays
            (homun-layout-close (slot 'stage))
            (should (window-live-p (slot 'stage)))
            (should (equal "*claude-layout*" (buffer-name (window-buffer (slot 'stage))))))
        (kill-buffer stage) (kill-buffer other)))))

(ert-deftest homun-layout-side-without-the-layout ()
  (let ((config (current-window-configuration))
        (buffer (get-buffer-create " *homun-layout-side*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (let ((window (homun-layout-side buffer)))
            (should (eq 'right (window-parameter window 'window-side)))
            (homun-layout-close window)
            (should-not (window-live-p window))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(provide 'homun-layout-test)
;;; homun-layout-test.el ends here

(ert-deftest homun-layout-pop-shows-any-transcript-in-the-locked-main-window ()
  (homun-layout-test--with t
    (let ((one (get-buffer-create "*transcript: one*"))
          (two (get-buffer-create "*transcript: two*"))
          (plain (get-buffer-create " *homun-layout-test*")))
      (unwind-protect
          (let ((main (slot 'transcript)))
            (homun-layout-pop one)
            (homun-layout-pop two)
            (should (eq two (window-buffer main)))
            (should (eq main (selected-window)))
            (should (eq t (window-dedicated-p main)))
            ;; A mode-line click (a plain switch) still refuses what is not the cockpit's
            (should-error (set-window-buffer main plain)))
        (mapc #'kill-buffer (list one two plain))))))

(ert-deftest homun-layout-pick-follows-the-frame-shape ()
  (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 140))
            ((symbol-function 'frame-pixel-width) (lambda (&optional _) 1000))
            ((symbol-function 'frame-pixel-height) (lambda (&optional _) 1800)))
    (let ((homun-layout-orientation 'auto))
      (should (eq 'portrait (homun-layout--pick)))
      (setq homun-layout-orientation 'wide)
      (should (eq 'wide (homun-layout--pick)))
      (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 80)))
        (setq homun-layout-orientation 'portrait)
        (should (eq 'narrow (homun-layout--pick)))))
    (cl-letf (((symbol-function 'frame-pixel-height) (lambda (&optional _) 600)))
      (let ((homun-layout-orientation 'auto))
        (should (eq 'wide (homun-layout--pick)))))))

(ert-deftest homun-layout-portrait-stacks-the-slots ()
  (let ((homun-layout-orientation 'portrait) (homun-layout-narrow-columns 1)
        (homun-layout-compose-lines 4) (config (current-window-configuration)))
    (unwind-protect
        (progn (homun-layout--build)
               (let ((tops (mapcar (lambda (n) (nth 1 (window-edges (cdr (assq n (homun-layout--windows))))))
                                   '(transcript compose stage board))))
                 (should (equal tops (sort (copy-sequence tops) #'<)))
                 (should (eq 'portrait (homun-layout--shape)))))
      (let ((ignore-window-parameters t) (homun-layout-lock nil))
        (homun-layout-lock-apply)
        (set-window-configuration config)))))

;; Portrait frame 120x200 forced: every slot exists, in vertical order, board with real height.
(ert-deftest homun-layout-portrait-apply-creates-all-four-slots ()
  (let ((homun-layout-orientation 'portrait) (homun-layout-narrow-columns 1)
        (homun-layout-compose-lines 4) (config (current-window-configuration)))
    (unwind-protect
        (progn (homun-layout--build)
               (let ((wins (mapcar #'homun-layout-window '(transcript compose stage board))))
                 (should (cl-every #'window-live-p wins))
                 (let ((tops (mapcar (lambda (w) (nth 1 (window-edges w))) wins)))
                   (should (equal tops (sort (copy-sequence tops) #'<)))
                   (should (= 4 (length (delete-dups (copy-sequence tops))))))
                 (should (>= (window-total-height (nth 3 wins)) 4))))
      (let ((ignore-window-parameters t) (homun-layout-lock nil))
        (homun-layout-lock-apply)
        (set-window-configuration config)))))

(defmacro homun-layout-test--frame (columns width height &rest body)
  "Run BODY as if the frame had COLUMNS columns and WIDTH x HEIGHT pixels."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'frame-width) (lambda (&optional _) ,columns))
             ((symbol-function 'frame-pixel-width) (lambda (&optional _) ,width))
             ((symbol-function 'frame-pixel-height) (lambda (&optional _) ,height)))
     ,@body))

(ert-deftest homun-layout-pick-holds-the-shape-near-the-column-threshold ()
  (let ((homun-layout-orientation 'wide) (homun-layout-narrow-columns 100)
        (homun-layout-narrow-margin 8))
    (homun-layout-test--frame 95 900 500
      (should (eq 'wide (homun-layout--pick nil 'wide)))
      (should (eq 'narrow (homun-layout--pick nil 'narrow)))
      (should (eq 'narrow (homun-layout--pick))))
    (homun-layout-test--frame 91 900 500
      (should (eq 'narrow (homun-layout--pick nil 'wide))))
    (homun-layout-test--frame 108 900 500
      (should (eq 'narrow (homun-layout--pick nil 'narrow))))
    (homun-layout-test--frame 109 900 500
      (should (eq 'wide (homun-layout--pick nil 'narrow))))))

(ert-deftest homun-layout-pick-holds-the-shape-near-square ()
  (let ((homun-layout-orientation 'auto) (homun-layout-portrait-enter 1.15)
        (homun-layout-portrait-leave 0.95))
    (homun-layout-test--frame 140 1000 1050
      (should (eq 'wide (homun-layout--pick nil 'wide)))
      (should (eq 'portrait (homun-layout--pick nil 'portrait)))
      (should (eq 'portrait (homun-layout--pick))))
    (homun-layout-test--frame 140 1000 1200
      (should (eq 'portrait (homun-layout--pick nil 'wide))))
    (homun-layout-test--frame 140 1000 940
      (should (eq 'wide (homun-layout--pick nil 'portrait))))))

(defun homun-layout-test--names (map)
  "The region names of MAP, in order."
  (let ((pos 0) names)
    (while (string-match "\\([a-z]+\\)@" map pos)
      (push (list nil (match-string 1 map)) names)
      (setq pos (match-end 0)))
    (nreverse names)))

(ert-deftest homun-layout-sweep-maps-regions-per-shape ()
  "Design §11: a sweep of frame shapes, each with its region map."
  (let ((homun-layout-compose-lines 4) (homun-layout-narrow-columns 60)
        (homun-layout-orientation 'auto) (config (current-window-configuration)))
    (unwind-protect
        (dolist (case '((70 1600 1000 wide "transcript" "stage" "board" "compose")
                        (70 1000 1600 portrait "transcript" "compose" "stage" "board")
                        (40 400 900 narrow "stage" "transcript" "compose")))
          (pcase-let ((`(,cols ,w ,h ,shape . ,order) case))
            (homun-layout-test--frame cols w h
              (homun-layout--build)
              (let ((map (homun-layout-map)))
                (should (string-prefix-p (format "%s " shape) map))
                ;; top-to-bottom, left-to-right order of the regions
                (should (equal order (mapcar (lambda (m) (cadr m))
                                             (homun-layout-test--names map))))
                (pcase shape
                  ('wide (should (> (window-total-height (homun-layout-window 'stage))
                                    (window-total-height (homun-layout-window 'board)))))
                  ('portrait (should (> (window-total-height (homun-layout-window 'board))
                                       (* 0.2 (window-total-height (frame-root-window))))))
                  ('narrow (should (= 1 (window-body-height (homun-layout-window 'stage))))))))))
      (let ((ignore-window-parameters t) (homun-layout-lock nil))
        (homun-layout-lock-apply)
        (set-window-configuration config)))))

(ert-deftest homun-layout-old-names-still-work ()
  (require 'claude-layout)
  (should (eq (indirect-function 'claude-layout-focus-toggle) (indirect-function 'homun-layout-focus-toggle)))
  (let ((homun-layout-narrow-columns 1))
    (should (= 101 (let ((claude-layout-narrow-columns 101)) homun-layout-narrow-columns))))
  (homun-layout-test--with t
    (should (eq (slot 'main) (cdr (assq 'main (claude-layout--windows)))))
    (should (eq (slot 'slate) (homun-layout-window 'stage)))))

;;; Arrangements that stay

(defmacro homun-layout-test--saved (&rest body)
  `(let ((homun-layout-saved-file (make-temp-file "layout-saved")))
     (unwind-protect (homun-layout-test--with nil ,@body)
       (delete-file homun-layout-saved-file))))

(ert-deftest homun-layout-persist-round-trip ()
  (homun-layout-test--saved
   (window-resize (homun-layout-window 'compose) 2)
   (let ((h (window-total-height (homun-layout-window 'compose))))
     (homun-layout--persist)
     (should (assq 'wide (homun-layout--saved)))
     (homun-layout-apply t)
     (should-not (= h (window-total-height (homun-layout-window 'compose))))
     (homun-layout-apply)
     (should (= h (window-total-height (homun-layout-window 'compose)))))))

(ert-deftest homun-layout-persist-skips-popups-and-reset-forgets ()
  (homun-layout-test--saved
   (let ((popup (split-window (homun-layout-window 'transcript))))
     (set-window-parameter popup 'homun-region nil)
     (homun-layout--persist)
     (should-not (homun-layout--saved))
     (delete-window popup))
   (homun-layout--persist)
   (should (homun-layout--saved))
   (homun-layout-reset)
   (should-not (homun-layout--saved))))

(ert-deftest homun-layout-bad-saved-state-falls-back ()
  (homun-layout-test--saved
   (with-temp-file homun-layout-saved-file (prin1 '((wide . (garbage))) (current-buffer)))
   (let ((regions (homun-layout--regions-of-frame)))
     (homun-layout-apply)
     (should (equal regions (homun-layout--regions-of-frame))))))

(ert-deftest homun-layout-refuses-a-layout-with-a-non-region-window ()
  (homun-layout-test--with nil
    (should (homun-layout--plain-p))
    (let ((homun-layout--state nil))
      (set-window-buffer (split-window (slot 'transcript) nil 'below) (get-buffer-create "*Messages*"))
      (should-not (homun-layout--plain-p))
      (homun-layout--save)
      (should-not homun-layout--state))))

(ert-deftest homun-layout-restore-drops-a-state-with-a-non-region-window ()
  (homun-layout-test--with nil
    (set-window-buffer (split-window (slot 'transcript) nil 'below) (get-buffer-create "*Messages*"))
    (let ((homun-layout--state (window-state-get (frame-root-window) t)))
      (homun-layout-restore)
      (should (homun-layout--plain-p))
      (should-not (get-buffer-window "*Messages*")))))

;;; No work strip: the work-map scene is a stage scene again

(ert-deftest homun-layout-has-no-work-region ()
  (dolist (shape '(wide portrait))
    (let ((homun-layout-orientation shape))
      (homun-layout-test--with nil
        (should-not (slot 'work))
        (should (equal '(board compose stage transcript) (homun-layout--regions-of-frame)))))))

(ert-deftest homun-layout-work-scene-goes-to-the-stage ()
  (homun-layout-test--with nil
    (let ((buf (generate-new-buffer "*stage work-map*")))
      (unwind-protect
          (progn
            (should (eq 'stage (homun-layout-region buf)))
            (should (eq (slot 'stage) (homun-layout-place buf))))
        (kill-buffer buf)))))

(ert-deftest homun-layout-saved-layout-is-used ()
  (homun-layout-test--saved
   (homun-layout--build)
   (with-temp-file homun-layout-saved-file
     (prin1 `((wide . ,(window-state-get (frame-root-window) t))) (current-buffer)))
   (homun-layout--build)
   (homun-layout--use-saved)
   (should (equal '(board compose stage transcript) (homun-layout--regions-of-frame)))))

(ert-deftest homun-layout-saved-layout-with-a-work-strip-is-refused ()
  "A layout saved while the strip existed has a region that is built no more: the default stays."
  (homun-layout-test--saved
   (homun-layout--build)
   (let ((ignore-window-parameters t))
     (homun-layout--mark (split-window (slot 'compose) -3 'below) 'work 'wide))
   (with-temp-file homun-layout-saved-file
     (prin1 `((wide . ,(window-state-get (frame-root-window) t))) (current-buffer)))
   (homun-layout--build)
   (homun-layout--use-saved)
   (should (equal '(board compose stage transcript) (homun-layout--regions-of-frame)))))

(ert-deftest homun-layout-apply-and-restore-drop-an-old-work-strip ()
  (homun-layout-test--with nil
    (let ((ignore-window-parameters t))
      (homun-layout--mark (split-window (slot 'compose) -3 'below) 'work 'wide))
    (should (slot 'work))
    (let ((homun-layout--state (window-state-get (frame-root-window) t)))
      (homun-layout-restore))
    (should-not (slot 'work))
    (should (equal '(board compose stage transcript) (homun-layout--regions-of-frame)))))

(ert-deftest homun-layout-placeholder-is-read-only-with-a-hint ()
  (let ((buf (homun-layout--placeholder)))
    (with-current-buffer buf
      (should buffer-read-only)
      (should (> (buffer-size) 0))
      (should-error (insert "x") :type 'buffer-read-only))))

(defun homun-layout-test--tail-window (lines)
  "A window over a buffer of LINES lines, ready for `homun-layout-tail'."
  (let ((buf (generate-new-buffer " *tail*")))
    (with-current-buffer buf (dotimes (i lines) (insert (format "line %d\n" i))))
    (set-window-buffer (selected-window) buf)
    (selected-window)))

(ert-deftest homun-layout-tail-leaves-a-visible-end-alone ()
  (let ((config (current-window-configuration)))
    (unwind-protect
        (let ((w (homun-layout-test--tail-window 3)))
          (set-window-start w 1)
          (set-window-vscroll w 0)
          (homun-layout-tail w)
          (should (= (window-start w) 1))
          (should (= (window-vscroll w) 0)))
      (set-window-configuration config))))

(ert-deftest homun-layout-tail-shows-an-offscreen-end ()
  (let ((config (current-window-configuration)))
    (unwind-protect
        (let ((w (homun-layout-test--tail-window 500)))
          (set-window-start w 1)
          (should-not (pos-visible-in-window-p (point-max) w t))
          (homun-layout-tail w)
          ;; batch has no redisplay: the end fits when the start is within a window height of it
          (should (<= (with-current-buffer (window-buffer w)
                        (count-screen-lines (window-start w) (point-max) nil w))
                      (window-body-height w))))
      (set-window-configuration config))))
