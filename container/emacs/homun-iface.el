;;; homun-iface.el --- Evil interface navigation by entry -*- lexical-binding: t -*-

;; The evil state `homun-interface' moves over whole entries (a message, a
;; tool block) instead of characters, and is the transcript's initial state.
;; M-j and M-k step entries (j and k stay evil line motions), ]] and [[
;; Cal's turns, ]e ]l ]c errors, links and code blocks; TAB cycles the links, buttons and code blocks of the current
;; entry.  i, a, v, V and C-v leave for evil's normal or visual state on the
;; same text (the transcript is read-only, so i and a give normal, not
;; insert); ESC in normal state comes back, snapped to the entry at point.
;;
;; A view takes part by setting `homun-iface-entries-function' to a function
;; returning its entries as (START END SECTION KIND) in buffer order, so
;; another view (focus) can reuse every motion here.
;; Every key lives on the state's own map or as its auxiliary map of
;; `claude-transcript-mode-map'; nothing global changes.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'magit-section)

(defvar evil-homun-interface-state-map)
(defvar evil-normal-state-map)
(defvar claude-transcript-focus-mode-map)
(declare-function claude-transcript-focus-quit "claude-transcript-focus")
(declare-function claude-transcript-focus-compose "claude-transcript-focus")
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-normal-state "evil-states")
(declare-function evil-homun-interface-state "homun-iface")
(declare-function evil-homun-interface-state-p "homun-iface")
(declare-function evil-visual-char "evil-commands")
(declare-function evil-visual-line "evil-commands")
(declare-function evil-visual-block "evil-commands")
(declare-function evil-scroll-down "evil-commands")
(declare-function evil-scroll-up "evil-commands")
(declare-function claude-transcript-copy "claude-transcript")
(declare-function claude-transcript-copy-block "claude-transcript")
(declare-function claude-transcript-goto-end "claude-transcript")
(declare-function claude-transcript-visit "claude-transcript")
(declare-function claude-transcript--source-only "claude-transcript")
(declare-function claude-transcript--section-text "claude-transcript")
(declare-function claude-compose "claude-compose")
(defvar claude-transcript--results)
(defvar claude-transcript-mode-map)

(defvar-local homun-iface-entries-function nil
  "Function returning this buffer's entries, a list of (START END SECTION KIND)
in buffer order; KIND is `turn' for a turn of Cal's, else the section type.")

(defvar-local homun-iface--query nil
  "The last string `homun-iface-search' looked for.")

;;;; Entries

(defun homun-iface--entries ()
  "This buffer's entries, or nil."
  (and homun-iface-entries-function (funcall homun-iface-entries-function)))

(defun homun-iface-transcript-entries ()
  "The transcript's entries: each turn's prompt, then each section in a turn;
sections outside a turn are entries of their own."
  (when magit-root-section
    (let (out)
      (dolist (top (oref magit-root-section children))
        (let ((children (oref top children)))
          (if (eq (oref top type) 'claude-transcript-turn)
              (progn
                (push (list (oref top start)
                            (if children (oref (car children) start) (oref top end))
                            top 'turn)
                      out)
                (dolist (child children)
                  (push (list (oref child start) (oref child end) child (oref child type))
                        out)))
            (push (list (oref top start) (oref top end) top (oref top type)) out))))
      (nreverse out))))

(defun homun-iface--index (entries &optional pos)
  "Index in ENTRIES of the entry holding POS (default point): the last one that
starts at or before it, else 0."
  (let ((pos (or pos (point))) (index 0) (i 0))
    (dolist (entry entries)
      (when (<= (car entry) pos) (setq index i))
      (setq i (1+ i)))
    index))

(defun homun-iface-current ()
  "The entry at point as (START END SECTION KIND), or nil."
  (when-let* ((entries (homun-iface--entries)))
    (nth (homun-iface--index entries) entries)))

(defun homun-iface--scroll-into-view (start end)
  "Scroll the selected window so START to END shows, START first when it does
not fit; smoothly when `pixel-scroll-precision-interpolate' is there."
  (let* ((window (selected-window))
         (top (window-start window))
         (want (cond ((not (pos-visible-in-window-p start window))
                      (save-excursion (goto-char start) (line-beginning-position)))
                     ((pos-visible-in-window-p (max start (1- end)) window) nil)
                     (t (min start
                             (save-excursion
                               (goto-char (max start (1- end)))
                               (vertical-motion (- 1 (window-body-height window)) window)
                               (point)))))))
    (when (and want (/= want top))
      (if (and (display-graphic-p) (fboundp 'pixel-scroll-precision-interpolate)
               (bound-and-true-p homun-smooth-scroll)
               (< (abs (- want top)) 20000))
          (let ((pixels (cdr (window-text-pixel-size window (min want top) (max want top)))))
            (pixel-scroll-precision-interpolate (if (> want top) (- pixels) pixels) window)
            (goto-char start))
        (set-window-start window want)))))

(defun homun-iface-goto (entry)
  "Put point on ENTRY and bring it into view."
  (goto-char (car entry))
  (when (eq (window-buffer) (current-buffer))
    (homun-iface--scroll-into-view (car entry) (cadr entry))))

(defvar-local homun-iface--before nil
  "Point before the current command, so a snap follows the way point moved.")

(defun homun-iface--snap ()
  "Keep point inside an entry: from a gap, go on the way point moved (the end of
the entry above when it moved up, else the next entry); past the last, stay."
  (when-let* ((entries (homun-iface--entries))
              (entry (nth (homun-iface--index entries) entries)))
    (unless (and (>= (point) (car entry)) (< (point) (max (1+ (car entry)) (cadr entry))))
      ;; Past the last entry (the tail, a stream, a drag) point stays: pulling it
      ;; back to the last entry's start made every other place unreachable.
      ;; Moving up into the gap above an entry must not push point back down.
      (if (and homun-iface--before (< (point) homun-iface--before)
               (>= (point) (car entry)))
          (goto-char (max (car entry) (1- (cadr entry))))
        (when-let* ((next (seq-find (lambda (e) (> (car e) (point))) entries)))
          (goto-char (car next)))))))

(defun homun-iface--pre-command ()
  "Remember point before each command."
  (setq homun-iface--before (point)))

(defun homun-iface--post-command ()
  "After each command in the interface state, snap point."
  (when (and (fboundp 'evil-homun-interface-state-p) (evil-homun-interface-state-p))
    (homun-iface--snap)))

;;;; Motions

(defun homun-iface--step (count pred)
  "Go COUNT entries on (back when negative) among those PRED accepts."
  (let* ((entries (homun-iface--entries))
         (here (point))
         (start (car (nth (homun-iface--index entries) entries)))
         (ahead (if (> count 0)
                    (seq-filter (lambda (e) (and (> (car e) here) (funcall pred e))) entries)
                  (reverse (seq-filter (lambda (e) (and (< (car e) start)
                                                        (funcall pred e)))
                                       entries))))
         (target (or (nth (1- (abs count)) ahead) (car (last ahead)))))
    (if target (homun-iface-goto target) (user-error "No more entries"))))

(defun homun-iface-next (&optional count)
  "Go to the next entry, COUNT times."
  (interactive "p")
  (homun-iface--step (or count 1) #'always))

(defun homun-iface-previous (&optional count)
  "Go to the previous entry, COUNT times."
  (interactive "p")
  (homun-iface--step (- (or count 1)) #'always))

(defun homun-iface--turn-p (entry)
  "Whether ENTRY is a turn of Cal's."
  (eq (nth 3 entry) 'turn))

(defun homun-iface-next-turn (&optional count)
  "Go to Cal's next turn, COUNT times."
  (interactive "p")
  (homun-iface--step (or count 1) #'homun-iface--turn-p))

(defun homun-iface-previous-turn (&optional count)
  "Go to Cal's previous turn, COUNT times."
  (interactive "p")
  (homun-iface--step (- (or count 1)) #'homun-iface--turn-p))

(defun homun-iface--face-at-p (pos faces)
  "Whether the face at POS is one of FACES or a list holding one."
  (let ((face (get-text-property pos 'face)))
    (if (listp face) (seq-some (lambda (f) (memq f faces)) face) (memq face faces))))

(defun homun-iface--error-p (entry)
  "Whether ENTRY failed: a tool call with an error result, or error text."
  (let ((section (nth 2 entry)))
    (or (and section (eq (oref section type) 'claude-transcript-tool)
             (hash-table-p (bound-and-true-p claude-transcript--results))
             (alist-get 'is_error (gethash (oref section value) claude-transcript--results)))
        (homun-iface--starts (car entry) (cadr entry) #'homun-iface--error-at-p))))

(defun homun-iface--error-at-p (pos)
  "Whether POS shows error text."
  (homun-iface--face-at-p pos '(error claude-transcript-error)))

(defun homun-iface-next-error (&optional count)
  "Go to the next entry with an error, COUNT times."
  (interactive "p")
  (homun-iface--step (or count 1) #'homun-iface--error-p))

(defun homun-iface-previous-error (&optional count)
  "Go to the previous entry with an error, COUNT times."
  (interactive "p")
  (homun-iface--step (- (or count 1)) #'homun-iface--error-p))

;;;; Items: links, buttons and code blocks

(defun homun-iface--link-at-p (pos)
  "Whether POS is on a web link."
  (and (<= (point-min) pos (point-max)) (get-text-property pos 'claude-transcript-url)))

(defun homun-iface--code-at-p (pos)
  "Whether POS is in a code block."
  (homun-iface--face-at-p pos '(claude-transcript-code)))

(defun homun-iface--item-at-p (pos)
  "Whether POS is on something to act on: a link, button, widget or code block."
  (or (get-char-property pos 'keymap) (get-char-property pos 'button)
      (homun-iface--code-at-p pos)))

(defun homun-iface--starts (start end pred)
  "Positions from START to END where PRED turns true after a position where it
was false (or at START)."
  (let ((pos start) (was nil) out)
    (while (< pos end)
      (let ((on (and (funcall pred pos) t)))
        (when (and on (not was)) (push pos out))
        (setq was on
              pos (min end (next-char-property-change pos end)))))
    (nreverse out)))

(defun homun-iface--jump (pred count)
  "Go to the COUNTth start of PRED after point (before it when negative)."
  (let* ((starts (homun-iface--starts (point-min) (point-max) pred))
         (here (point))
         (ahead (if (> count 0)
                    (seq-filter (lambda (p) (> p here)) starts)
                  (reverse (seq-filter (lambda (p) (< p here)) starts))))
         (target (nth (1- (abs count)) ahead)))
    (unless target (user-error "None further"))
    (goto-char target)
    (homun-iface--scroll-into-view target (1+ target))))

(defun homun-iface-next-link (&optional count)
  "Go to the next web link, COUNT times."
  (interactive "p")
  (homun-iface--jump #'homun-iface--link-at-p (or count 1)))

(defun homun-iface-previous-link (&optional count)
  "Go to the previous web link, COUNT times."
  (interactive "p")
  (homun-iface--jump #'homun-iface--link-at-p (- (or count 1))))

(defun homun-iface-next-code (&optional count)
  "Go to the next code block, COUNT times."
  (interactive "p")
  (homun-iface--jump #'homun-iface--code-at-p (or count 1)))

(defun homun-iface-previous-code (&optional count)
  "Go to the previous code block, COUNT times."
  (interactive "p")
  (homun-iface--jump #'homun-iface--code-at-p (- (or count 1))))

(defun homun-iface--cycle (direction)
  "Go to the item DIRECTION (1 or -1) away inside the current entry, wrapping."
  (let* ((entry (or (homun-iface-current) (user-error "No entry here")))
         (items (homun-iface--starts (car entry) (cadr entry) #'homun-iface--item-at-p))
         (here (point)))
    (unless items (user-error "Nothing to act on in this entry"))
    (goto-char (if (> direction 0)
                   (or (seq-find (lambda (p) (> p here)) items) (car items))
                 (or (seq-find (lambda (p) (< p here)) (reverse items)) (car (last items)))))))

(defun homun-iface-next-item ()
  "Go to the next link, button or code block of the current entry, wrapping."
  (interactive)
  (homun-iface--cycle 1))

(defun homun-iface-previous-item ()
  "Go to the previous link, button or code block of the current entry, wrapping."
  (interactive)
  (homun-iface--cycle -1))

;;;; Acting on the entry

(defun homun-iface--foldable-p (section)
  "Whether SECTION folds on its own (not a turn, which holds the others)."
  (and section (not (eq (oref section type) 'claude-transcript-turn))
       (or (oref section content) (oref section washer))))

(defun homun-iface-enter ()
  "Act on the entry: the item at point, else expand it, else visit its tool
call, else go to its first item."
  (interactive)
  (let* ((entry (or (homun-iface-current) (user-error "No entry here")))
         (section (nth 2 entry)))
    (cond
     ((homun-iface--item-at-p (point))
      (if (get-char-property (point) 'button) (push-button) (claude-transcript-visit section)))
     ((and (homun-iface--foldable-p section) (oref section hidden))
      (magit-section-show section))
     ((and section (eq (oref section type) 'claude-transcript-tool)) (claude-transcript-visit section))
     (t (homun-iface-next-item)))))

(defun homun-iface-leave ()
  "Collapse the entry when it is open, else go to its start, else up to its turn."
  (interactive)
  (let* ((entry (or (homun-iface-current) (user-error "No entry here")))
         (section (nth 2 entry)))
    (cond
     ((and (homun-iface--foldable-p section) (not (oref section hidden)))
      (magit-section-hide section)
      (homun-iface-goto entry))
     ((/= (point) (car entry)) (homun-iface-goto entry))
     ((when-let* ((parent (and section (oref section parent)))
                  ((eq (oref parent type) 'claude-transcript-turn)))
        (homun-iface-goto (nth (homun-iface--index (homun-iface--entries) (oref parent start))
                               (homun-iface--entries)))
        t))
     (t (user-error "At the top")))))

(defun homun-iface-toggle ()
  "Fold or unfold the entry."
  (interactive)
  (let ((section (nth 2 (or (homun-iface-current) (user-error "No entry here")))))
    (when (homun-iface--foldable-p section) (magit-section-toggle section))
    (homun-iface--snap)))

(defun homun-iface--fold-all (hide)
  "Hide every foldable entry when HIDE, else show them."
  (dolist (entry (homun-iface--entries))
    (let ((section (nth 2 entry)))
      (when (homun-iface--foldable-p section)
        (if hide (magit-section-hide section) (magit-section-show section)))))
  (homun-iface--snap))

(defun homun-iface-fold-all ()
  "Fold every entry that folds."
  (interactive)
  (homun-iface--fold-all t))

(defun homun-iface-unfold-all ()
  "Unfold every entry that folds."
  (interactive)
  (homun-iface--fold-all nil))

(defun homun-iface--text (entry)
  "The text of ENTRY: a turn's prompt alone, else its section with lazy bodies."
  (if (eq (nth 3 entry) 'turn)
      (string-trim (claude-transcript--source-only (car entry) (cadr entry)))
    (string-trim (claude-transcript--section-text (nth 2 entry)))))

(defun homun-iface-copy ()
  "Copy the code block at point, else the entry."
  (interactive)
  (let ((entry (or (homun-iface-current) (user-error "No entry here"))))
    (cond ((homun-iface--code-at-p (point)) (claude-transcript-copy-block))
          ((eq (nth 3 entry) 'turn)
           (kill-new (homun-iface--text entry))
           (message "Copied the prompt"))
          (t (claude-transcript-copy (nth 2 entry))))))

(defun homun-iface-quote ()
  "Quote the entry into the compose box, as Markdown."
  (interactive)
  (let* ((entry (or (homun-iface-current) (user-error "No entry here")))
         (quoted (concat (mapconcat (lambda (line) (string-trim-right (concat "> " line)))
                                    (split-string (homun-iface--text entry) "\n")
                                    "\n")
                         "\n\n"))
         (window (claude-compose)))
    (with-current-buffer (window-buffer (if (windowp window) window (selected-window)))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert quoted))))

(defun homun-iface-open ()
  "Open the web link at point, else the entry's first, on the host."
  (interactive)
  (let* ((entry (or (homun-iface-current) (user-error "No entry here")))
         (pos (if (homun-iface--link-at-p (point)) (point)
                (car (homun-iface--starts (car entry) (cadr entry) #'homun-iface--link-at-p))))
         (url (and pos (get-text-property pos 'claude-transcript-url))))
    (if url (browse-url url) (user-error "No link in this entry"))))

(defun homun-iface-first ()
  "Go to the first entry."
  (interactive)
  (if-let* ((entry (car (homun-iface--entries))))
      (homun-iface-goto entry)
    (goto-char (point-min))))

(defun homun-iface-last ()
  "Go to the last entry and follow new output again."
  (interactive)
  (when (fboundp 'claude-transcript-goto-end) (claude-transcript-goto-end))
  (when-let* ((entry (car (last (homun-iface--entries)))))
    (goto-char (car entry))))

(defun homun-iface-search (query)
  "Go to the next entry whose text holds QUERY; n and N repeat it."
  (interactive (list (read-string "Search entries: " nil nil homun-iface--query)))
  (setq homun-iface--query query)
  (homun-iface--search 1))

(defun homun-iface--search (direction)
  "Go to the next match of the last query in DIRECTION, in a later entry."
  (unless homun-iface--query (user-error "No search yet"))
  (let* ((entry (homun-iface-current))
         (case-fold-search t)
         (found (save-excursion
                  (if (> direction 0)
                      (progn (goto-char (if entry (cadr entry) (point)))
                             (search-forward homun-iface--query nil t))
                    (goto-char (if entry (car entry) (point)))
                    (search-backward homun-iface--query nil t)))))
    (unless found (user-error "No more \"%s\"" homun-iface--query))
    (goto-char (if (> direction 0) (match-beginning 0) found))
    (homun-iface--scroll-into-view (point) (1+ (point)))))

(defun homun-iface-search-next ()
  "Repeat the last entry search forward."
  (interactive)
  (homun-iface--search 1))

(defun homun-iface-search-previous ()
  "Repeat the last entry search backward."
  (interactive)
  (homun-iface--search -1))

(defun homun-iface-half-down ()
  "Scroll half a page down, onto an entry."
  (interactive)
  (evil-scroll-down 0)
  (homun-iface--snap))

(defun homun-iface-half-up ()
  "Scroll half a page up, onto an entry."
  (interactive)
  (evil-scroll-up 0)
  (homun-iface--snap))

;;;; Leaving and coming back

(defun homun-iface-to-normal ()
  "Leave for evil's normal state on the same text.  The transcript is read-only,
so i and a land here rather than in insert state."
  (interactive)
  (evil-normal-state))

(defun homun-iface-to-visual ()
  "Leave for evil's visual state, by character."
  (interactive)
  (evil-normal-state)
  (evil-visual-char))

(defun homun-iface-to-visual-line ()
  "Leave for evil's visual state, by line."
  (interactive)
  (evil-normal-state)
  (evil-visual-line))

(defun homun-iface-to-visual-block ()
  "Leave for evil's visual state, by block."
  (interactive)
  (evil-normal-state)
  (evil-visual-block))

(defun homun-iface-return ()
  "Come back to the interface state, point on the start of the entry holding it
(left alone when that start is off screen)."
  (interactive)
  (evil-homun-interface-state)
  (when-let* ((entry (homun-iface-current)))
    (when (or (not (eq (window-buffer) (current-buffer)))
              (pos-visible-in-window-p (car entry)))
      (goto-char (car entry))))
  (homun-iface--snap))

(defun homun-iface--state-entry ()
  "Snap point to entries in this buffer."
  (when homun-iface-entries-function
    (add-hook 'pre-command-hook #'homun-iface--pre-command nil t)
    (add-hook 'post-command-hook #'homun-iface--post-command nil t)
    (homun-iface--snap)))

(defconst homun-iface-keys
  '(("M-j" . homun-iface-next) ("M-k" . homun-iface-previous)
    ("gg" . homun-iface-first) ("G" . homun-iface-last)
    ("]]" . homun-iface-next-turn) ("[[" . homun-iface-previous-turn)
    ("]e" . homun-iface-next-error) ("[e" . homun-iface-previous-error)
    ("]l" . homun-iface-next-link) ("[l" . homun-iface-previous-link)
    ("]c" . homun-iface-next-code) ("[c" . homun-iface-previous-code)
    ("l" . homun-iface-enter) ("RET" . homun-iface-enter) ("h" . homun-iface-leave)
    ("za" . homun-iface-toggle) ("zM" . homun-iface-fold-all) ("zR" . homun-iface-unfold-all)
    ("TAB" . homun-iface-next-item) ("<backtab>" . homun-iface-previous-item)
    ("y" . homun-iface-copy) ("q" . homun-iface-quote) ("o" . homun-iface-open)
    ("/" . homun-iface-search) ("n" . homun-iface-search-next)
    ("N" . homun-iface-search-previous)
    ("C-d" . homun-iface-half-down) ("C-u" . homun-iface-half-up)
    ("i" . homun-iface-to-normal) ("a" . homun-iface-to-normal)
    ("v" . homun-iface-to-visual) ("V" . homun-iface-to-visual-line)
    ("C-v" . homun-iface-to-visual-block))
  "The keys of the interface state and their commands; j and k are not here.")

(defun homun-iface--setup ()
  "Define the state and its keys; evil is loaded."
  ;; `eval': the macro needs evil, which a cockpit without it never loads
  (eval '(evil-define-state homun-interface
           "Interface state: move over whole entries, act on them; i, a, v leave."
           :tag " <I> "
           :cursor box
           :enable (motion)
           :entry-hook (homun-iface--state-entry)
)
        t)
  ;; Empty the map first, so a reload drops keys no longer in the list
  (let ((parent (keymap-parent evil-homun-interface-state-map)))
    (setcdr evil-homun-interface-state-map nil)
    (set-keymap-parent evil-homun-interface-state-map parent))
  (dolist (key homun-iface-keys)
    (define-key evil-homun-interface-state-map (kbd (car key)) (cdr key)))
  (with-eval-after-load 'claude-transcript
    (evil-define-key* 'normal claude-transcript-mode-map [escape] #'homun-iface-return)
    (evil-set-initial-state 'claude-transcript-mode 'homun-interface))
  (with-eval-after-load 'claude-transcript-focus
    (evil-define-key* 'homun-interface claude-transcript-focus-mode-map
      (kbd "q") #'claude-transcript-focus-quit
      ;; The view is read-only: i and a type in the compose box instead
      (kbd "i") #'claude-transcript-focus-compose (kbd "a") #'claude-transcript-focus-compose)
    (evil-set-initial-state 'claude-transcript-focus-mode 'homun-interface)))

(defun homun-iface-transcript-setup ()
  "Give this transcript buffer its entries."
  (setq homun-iface-entries-function #'homun-iface-transcript-entries))

(add-hook 'claude-transcript-mode-hook #'homun-iface-transcript-setup)

(defun homun-iface-focus-entries ()
  "The focus view's entries: one per drawn message (no section), a turn when it
is one of Cal's."
  (let ((pos (point-min)) out)
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos 'claude-transcript-focus-uuid nil (point-max))))
        (when (get-text-property pos 'claude-transcript-focus-uuid)
          (push (list pos next nil
                      (if (get-text-property pos 'claude-transcript-focus-turn) 'turn 'message))
                out))
        (setq pos next)))
    (nreverse out)))

(defun homun-iface-focus-setup ()
  "Give this focus view its entries, so the interface motions work there."
  (setq homun-iface-entries-function #'homun-iface-focus-entries))

(add-hook 'claude-transcript-focus-mode-hook #'homun-iface-focus-setup)

(with-eval-after-load 'evil (homun-iface--setup))

(provide 'homun-iface)
;;; homun-iface.el ends here
