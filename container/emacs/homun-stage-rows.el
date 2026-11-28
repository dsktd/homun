;;; homun-stage-rows.el --- Rows under the `work-map' scene: drill in, hover, drag -*- lexical-binding: t -*-

;; Under the orrery the scene buffer lists one row per item of the map (`homun-stage-work--items'),
;; plus a Done target.  A click or RET opens the row's detail (the tracker item in
;; `claude-task-detail', else the agent run in `claude-run-detail'); hovering shows its latest
;; report line and model (`help-echo', computed on hover from cached reads, no subprocess);
;; dragging a row onto another moves it there, onto the Done target marks it done.  Keys: RET
;; open, M-up and M-down move, d done.  Every action edits the todo org or goes through the
;; tracker, then the map syncs and the rows are drawn again from them: the view holds no state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'homun-stage-store)
(require 'homun-stage-work)
(require 'homun-stage-live)
(declare-function homun-key-hint "claude")
(require 'claude-run-detail)
(require 'claude-task-detail)

(defvar homun-stage-mode-map)

(defvar homun-stage-rows-done-shown 5 "Done rows listed; older ones fold into \"N earlier\".")

(defvar-local homun-stage-rows--shown nil "The rows last drawn in this buffer.")

;;; Rows

(defun homun-stage-rows-list ()
  "The rows of the map, from the same items: plists (:id :label :state :section
:agent)."
  (let ((items (homun-stage-work--items (claude-todos-file) (float-time))))
    (cl-mapcar (lambda (it id)
                 (pcase-let ((`(,_ ,label ,state ,section ,agent) it))
                   (list :id id :label label :state state :section section :agent agent)))
               items (mapcar #'car (homun-stage-work--ids items)))))

(defun homun-stage-rows--task (row)
  "A board-task plist for ROW, for the tracker lookup of `claude-task-detail'."
  (list :id (plist-get row :agent) :desc (plist-get row :label)))

(defun homun-stage-rows--tracker-id (row)
  (claude-task-detail-tracker-id (homun-stage-rows--task row)))

;;; Hover

(defun homun-stage-rows-help (row)
  "The hover text of ROW: its state, latest report line and model.  Reads cached
files only."
  (let ((run (and (plist-get row :agent) (claude-run-detail-data (plist-get row :agent)))))
    (string-join (delq nil (list (plist-get row :state) (plist-get run :latest)
                                 (and (plist-get run :model) (concat "model " (plist-get run :model)))))
                 " · ")))

(defun homun-stage-rows--echo (window _object pos)
  "The `help-echo' function of a row."
  (when-let* ((row (and (window-live-p window)
                        (with-current-buffer (window-buffer window)
                          (get-text-property pos 'homun-row)))))
    (if (eq row 'done) "Drop a row here to mark it done" (homun-stage-rows-help row))))

;;; Drawing

(defun homun-stage-rows-insert (rows)
  "Insert ROWS and the Done target at point."
  (insert "\n" (propertize "Items" 'face 'bold) (propertize (concat (homun-key-hint "  RET open · M-up/M-down move · d done · drag to move or onto Done") "\n") 'face 'shadow))
  (homun-stage-live-work-refresh (mapcar (lambda (r) (list (plist-get r :id) (plist-get r :label) (plist-get r :state))) rows))
  (let ((hidden (max 0 (- (cl-count "done" rows :key (lambda (r) (plist-get r :state)) :test #'equal)
                          homun-stage-rows-done-shown))))
    (when (> hidden 0)
      (insert (propertize (format " %d earlier\n" hidden) 'face 'shadow)))
    (setq rows (seq-remove (lambda (r) (and (equal (plist-get r :state) "done") (> hidden 0)
                                            (cl-decf hidden)))
                           rows)))
  (dolist (row rows)
    (let ((start (homun-stage-live-draw-row
                  (list (plist-get row :id) (plist-get row :label) (plist-get row :state) nil nil))))
      (add-text-properties start (point) (list 'homun-row row 'help-echo #'homun-stage-rows--echo
                                               'mouse-face 'highlight))
      (insert "\n")))
  (homun-stage-live-prune (mapcar (lambda (r) (plist-get r :id)) rows))
  (let ((start (point)))
    (insert (propertize " ✓ Done: drop here" 'face 'shadow))
    (add-text-properties start (point) (list 'homun-row 'done 'help-echo #'homun-stage-rows--echo
                                             'mouse-face 'highlight))
    (insert "\n")))

(defun homun-stage-rows-render (s)
  "Hook of `homun-stage-render-functions': the rows of the work-map S at the end of
the buffer."
  (when (equal (homun-stage-scene-id s) homun-stage-work-id)
    (let ((rows (homun-stage-rows-list)))
      (save-excursion
        (goto-char (point-max))
        (homun-stage-rows-insert rows))
      (setq homun-stage-rows--shown rows))))

(defun homun-stage-rows-redraw ()
  "Draw the work-map again when its rows changed since the last draw."
  (when-let* ((s (gethash homun-stage-work-id homun-stage-scenes))
              (buf (get-buffer (homun-stage-buffer-name homun-stage-work-id)))
              ((not (equal (buffer-local-value 'homun-stage-rows--shown buf) (homun-stage-rows-list)))))
    (homun-stage-render s)))

;;; The todo org: the one place order and done live

(defun homun-stage-rows--bounds (label section)
  "(BEG . END) of the todo subtree LABEL under SECTION in the current buffer, or
nil."
  (let (sec found)
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (cond ((looking-at "\\* \\(.+\\)") (setq sec (match-string 1)))
              ((and (equal sec section)
                    (looking-at (concat "\\*\\* \\(?:TODO\\|STRT\\|WAIT\\|DONE\\|FAILED\\) " (regexp-quote label) "$")))
               (setq found (cons (point) (save-excursion (forward-line 1)
                                                         (if (re-search-forward "^\\*" nil t) (match-beginning 0) (point-max)))))))
        (forward-line 1)))
    found))

(defun homun-stage-rows--edit (fn)
  "Call FN in a copy of the todo file; write it back when FN returned non-nil."
  (let ((file (claude-todos-file)))
    (with-temp-buffer
      (insert-file-contents file)
      (when (funcall fn)
        (write-region (point-min) (point-max) file nil 'silent)
        t))))

(defun homun-stage-rows--reorder (row target after)
  "Move ROW next to TARGET (before it, or AFTER it); both are rows of one section."
  (unless (equal (plist-get row :section) (plist-get target :section))
    (user-error "Rows move inside their own section"))
  (unless (homun-stage-rows--edit
           (lambda ()
             (when-let* ((a (homun-stage-rows--bounds (plist-get row :label) (plist-get row :section)))
                         (text (buffer-substring (car a) (cdr a))))
               (delete-region (car a) (cdr a))
               (when-let* ((b (homun-stage-rows--bounds (plist-get target :label) (plist-get target :section))))
                 (goto-char (if after (cdr b) (car b)))
                 (insert text)
                 t))))
    (user-error "Could not move that row"))
  (homun-stage-rows--refresh))

(defun homun-stage-rows--done-heading (row)
  (homun-stage-rows--edit
   (lambda ()
     (when-let* ((a (homun-stage-rows--bounds (plist-get row :label) (plist-get row :section))))
       (goto-char (car a))
       (when (looking-at "\\*\\* \\(?:TODO\\|STRT\\|WAIT\\|FAILED\\)")
         (replace-match "** DONE")
         t)))))

(defun homun-stage-rows-done (row)
  "Mark ROW done: its tracker item through the tracker, and its todo heading."
  (when-let* ((id (homun-stage-rows--tracker-id row)))
    (claude-task-detail-set-state id "done"))
  (homun-stage-rows--done-heading row)
  (homun-stage-rows--refresh))

(defun homun-stage-rows--refresh ()
  (homun-stage-work-sync)
  (homun-stage-rows-redraw))

;;; Open

(defun homun-stage-rows-open (row)
  "Open ROW's detail: the tracker item, else the agent run, else the bare task
view."
  (cond ((homun-stage-rows--tracker-id row) (claude-task-detail-open (homun-stage-rows--task row)))
        ((plist-get row :agent) (claude-run-detail-open (plist-get row :agent) (plist-get row :label)))
        (t (claude-task-detail-open (homun-stage-rows--task row)))))

;;; Commands

(defun homun-stage-rows--at (&optional pos)
  "The row at POS (default point) of the current buffer, or nil."
  (get-text-property (or pos (point)) 'homun-row))

(defun homun-stage-rows--posn-row (posn)
  "The row under the mouse position POSN."
  (when-let* ((win (posn-window posn)) ((window-live-p win)) (pos (posn-point posn)))
    (with-current-buffer (window-buffer win) (homun-stage-rows--at pos))))

(defun homun-stage-rows--real (row)
  (and (consp row) row))

(defun homun-stage-rows-open-at-point ()
  "Open the detail of the row at point."
  (interactive)
  (homun-stage-rows-open (or (homun-stage-rows--real (homun-stage-rows--at)) (user-error "No item here"))))

(defun homun-stage-rows-click (event)
  "Open the detail of the row clicked in EVENT."
  (interactive "e")
  (when-let* ((row (homun-stage-rows--real (homun-stage-rows--posn-row (event-start event)))))
    (homun-stage-rows-open row)))

(defun homun-stage-rows-press (event)
  "Mouse down on a row: nothing to do yet; the release decides (click, or drag)."
  (interactive "e")
  (ignore event))

(defun homun-stage-rows-drag (event)
  "Finish a drag from one row to another: onto Done marks it done, else the row
moves there."
  (interactive "e")
  (let ((from (homun-stage-rows--real (homun-stage-rows--posn-row (event-start event))))
        (to (homun-stage-rows--posn-row (event-end event))))
    (cond ((or (null from) (null to) (equal from to)) nil)
          ((eq to 'done) (homun-stage-rows-done from))
          (t (let* ((rows (buffer-local-value 'homun-stage-rows--shown
                                              (window-buffer (posn-window (event-start event)))))
                    (after (> (cl-position to rows :test #'equal) (cl-position from rows :test #'equal))))
               (homun-stage-rows--reorder from to after))))))

(defun homun-stage-rows--shift (delta)
  "Move the row at point DELTA places, -1 up and 1 down."
  (let* ((row (or (homun-stage-rows--real (homun-stage-rows--at)) (user-error "No item here")))
         (rows homun-stage-rows--shown)
         (target (nth (+ (cl-position row rows :test #'equal) delta) rows)))
    (unless (and target (>= (+ (cl-position row rows :test #'equal) delta) 0)) (user-error "Already at the end"))
    (homun-stage-rows--reorder row target (> delta 0))
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'homun-row row #'equal)))
      (goto-char (prop-match-beginning m)))))

(defun homun-stage-rows-up () "Move the row at point up." (interactive) (homun-stage-rows--shift -1))
(defun homun-stage-rows-down () "Move the row at point down." (interactive) (homun-stage-rows--shift 1))

(defun homun-stage-rows-done-at-point ()
  "Mark the row at point done."
  (interactive)
  (homun-stage-rows-done (or (homun-stage-rows--real (homun-stage-rows--at)) (user-error "No item here"))))

(with-eval-after-load 'homun-stage-store
  (when (boundp 'homun-stage-mode-map)
    (let ((map homun-stage-mode-map))
      (define-key map (kbd "RET") #'homun-stage-rows-open-at-point)
      (define-key map (kbd "M-<up>") #'homun-stage-rows-up)
      (define-key map (kbd "M-<down>") #'homun-stage-rows-down)
      (define-key map "d" #'homun-stage-rows-done-at-point)
      (define-key map [down-mouse-1] #'homun-stage-rows-press)
      (define-key map [mouse-1] #'homun-stage-rows-click)
      (define-key map [drag-mouse-1] #'homun-stage-rows-drag))))

;; After the live strip (depth 0), so the Items list closes the buffer
(add-hook 'homun-stage-render-functions #'homun-stage-rows-render 90)
;; Drop what an earlier live load hooked in
(advice-remove 'homun-stage-render 'homun-stage-rows--after-render)
(advice-remove 'homun-stage-work-sync 'homun-stage-rows--after-sync)

(provide 'homun-stage-rows)
;;; homun-stage-rows.el ends here
