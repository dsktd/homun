;;; widgetry-text.el --- A pill holding a line of text -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widgetry-button' that shows a line of text, its value, in a field of
;; `:width' columns (ellipsized when longer, `:placeholder' when empty).
;; Pressing it (RET, SPC or a click) edits the text in place: the pill
;; turns into plain editable text in `widgetry-text-editing', even in a
;; read-only buffer, with point inside.  RET commits (a changed text
;; notifies); C-g cancels (ESC too, but under evil it commits, like leaving insert state; i a I A on the pill start editing there) and restores the old text.  Leaving the
;; text, by moving point out of it or switching window or buffer, also
;; cancels, so a stray click never changes a value.  Nothing is recorded
;; for undo and the buffer stays unmodified.  The text is `widget-value'.
;;
;;   (widget-create 'widgetry-text :value "main" :placeholder "branch"
;;                  :notify (lambda (widget &rest _)
;;                            (message "%s" (widget-value widget))))

;;; Code:

(require 'widgetry-button)

(defvar evil-state)
(defvar evil-local-mode)

(defun widgetry-text--evil-filter (command)
  "COMMAND when evil is on in normal or motion state, else nil."
  (and (bound-and-true-p evil-local-mode) (memq evil-state '(normal motion)) command))

(defun widgetry-text--insert-command (key)
  "A command editing the text at point, point per the evil insert KEY."
  (let ((name (intern (concat "widgetry-text-insert-" key))))
    (defalias name
      (lambda () (interactive) (widgetry-text-edit nil (if (member key '("a" "A")) 'end 'start))))
    name))

(defun widgetry-text-yank ()
  "Insert the latest kill at point as one line."
  (interactive)
  (insert (replace-regexp-in-string "[\n\r]+" " " (string-trim (current-kill 0 t)))))

(defun widgetry-text--paste-command (key)
  "A command editing the text at point with the kill pasted: p at the end, P at the
start."
  (let ((name (intern (concat "widgetry-text-paste-" key))))
    (defalias name
      (lambda ()
        (interactive)
        (widgetry-text-edit nil (if (equal key "p") 'end 'start))
        (let ((pos (point)))
          (widgetry-text-yank)
          (when (equal key "P") (goto-char pos)))))
    name))

(define-widget 'widgetry-text 'widgetry-button
  "A pill with an editable line of text."
  :tag " ✎ "
  :value ""
  :placeholder ""
  :width 24
  :reflow t
  :prompt "Text: "
  :shown #'widgetry-text--shown
  :notify #'ignore
  :keymap (let ((map (make-sparse-keymap)))
            (set-keymap-parent map widgetry-button-map)
            (define-key map [down-mouse-1] #'widgetry-text-edit)
            (define-key map (kbd "RET") #'widgetry-text-edit)
            (define-key map (kbd "SPC") #'widgetry-text-edit)
            ;; Under evil, i a I A on the pill start editing in insert state
            (dolist (key '("i" "a" "I" "A"))
              (define-key map key
                `(menu-item "" ,(widgetry-text--insert-command key)
                            :filter widgetry-text--evil-filter)))
            ;; Under evil, p appends the kill to the text, P prepends it
            (dolist (key '("p" "P"))
              (define-key map key
                `(menu-item "" ,(widgetry-text--paste-command key)
                            :filter widgetry-text--evil-filter)))
            map))

(defun widgetry-text--shown (widget)
  "The text of WIDGET, or its placeholder, as wide as its :width."
  (let* ((text (widget-value widget))
         (text (if (string-empty-p text) (or (widget-get widget :placeholder) "") text))
         (text (replace-regexp-in-string "[\n\t]" " " text)))
    (concat " " (truncate-string-to-width text (widgetry-fit-cells widget (widget-get widget :width) 4) nil ?\s "…") " ")))

(defface widgetry-text-editing
  '((t (:inherit widgetry-button-value :box (:line-width -1))))
  "Face of the text of a `widgetry-text' pill while it is edited in place."
  :group 'widgetry)

(declare-function evil-insert-state "evil-states")
(declare-function evil-emacs-state "evil-states")
(declare-function evil-change-state "evil-core")
(declare-function evil-make-intercept-map "evil-core")
(declare-function evil-normalize-keymaps "evil-core")

(defvar widgetry-text-edit-map
  (let ((map (make-keymap)))
    (define-key map (kbd "RET") #'widgetry-text-commit)
    (define-key map (kbd "C-m") #'widgetry-text-commit)
    (define-key map (kbd "C-g") #'widgetry-text-cancel)
    (define-key map [escape] #'widgetry-text-escape)
    (define-key map [down-mouse-1] #'ignore)
    (define-key map (kbd "C-y") #'widgetry-text-yank)
    ;; Read-only modes bind letters to `undefined'; typing must still insert
    (define-key map [remap self-insert-command] #'self-insert-command)
    (define-key map [remap undefined] #'self-insert-command)
    (set-char-table-range (nth 1 map) (cons 32 126) #'self-insert-command)
    (set-char-table-range (nth 1 map) (cons 160 (max-char)) #'self-insert-command)
    map)
  "Keymap of the text of a `widgetry-text' pill while it is edited.")

(define-minor-mode widgetry-text-editing-mode
  "Buffer-local mode active while a `widgetry-text' pill is edited.
Its keymap wins over evil states and read-only major modes."
  :keymap widgetry-text-edit-map
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps))
  ;; On a touch screen the keyboard is up while a text is edited, and only then
  (when (and (eq system-type 'android) (fboundp 'frame-toggle-on-screen-keyboard))
    (setq-local touch-screen-display-keyboard widgetry-text-editing-mode)
    (frame-toggle-on-screen-keyboard nil (not widgetry-text-editing-mode))))

(with-eval-after-load 'evil
  (evil-make-intercept-map widgetry-text-edit-map))

(defvar touch-screen-display-keyboard)
(declare-function magit-section-post-command-hook "magit-section")
(defvar-local widgetry-text--editing nil
  "The edit in this buffer: a plist, nil when none.")

(defun widgetry-text--replace (overlay text)
  "Make the buffer text under OVERLAY TEXT, keeping the overlay alive."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (buffer-undo-list t)
        (start (overlay-start overlay))
        (end (overlay-end overlay)))
    (save-excursion
      (overlay-put overlay 'evaporate nil)
      (goto-char end)
      (insert text)
      (delete-region start end)
      (move-overlay overlay start (+ start (length text)))
      (overlay-put overlay 'evaporate t))))

(defun widgetry-text--guard (beg end)
  "Refuse a change from BEG to END outside the text being edited."
  (when-let* ((edit widgetry-text--editing)
              (overlay (plist-get edit :overlay)))
    (unless (and (>= beg (1+ (overlay-start overlay)))
                 (<= end (1- (overlay-end overlay))))
      (user-error "Only the text can be edited"))))

(defun widgetry-text--check ()
  "Cancel the edit once point or the window has left the text."
  (when-let* ((edit widgetry-text--editing))
    (let* ((overlay (plist-get edit :overlay))
           (start (1+ (overlay-start overlay)))
           (end (1- (overlay-end overlay))))
      (cond ((or (not (eq (current-buffer) (overlay-buffer overlay)))
                 (not (eq (selected-window) (plist-get edit :window))))
             (widgetry-text--finish nil))
            ;; The release of the click that began it lands on the text
            ((and (mouse-event-p last-command-event) (or (< (point) start) (> (point) end)))
             (goto-char (max start (min end (point)))))
            ((or (< (point) start) (> (point) end))
             (widgetry-text--finish nil))))))

(defun widgetry-text--finish (commit)
  "End the edit in the current buffer, keeping the text if COMMIT."
  (when-let* ((edit widgetry-text--editing))
    (let* ((widget (plist-get edit :widget))
           (overlay (plist-get edit :overlay))
           (old (widget-value widget))
           (new (and commit
                     (replace-regexp-in-string
                      "[\n\t]" " "
                      (buffer-substring-no-properties
                       (1+ (overlay-start overlay)) (1- (overlay-end overlay)))))))
      (setq widgetry-text--editing nil)
      (widget-put widget :editing nil)
      (when (plist-get edit :magit)
        (add-hook 'post-command-hook #'magit-section-post-command-hook nil t))
      (remove-hook 'before-change-functions #'widgetry-text--guard t)
      (remove-hook 'post-command-hook #'widgetry-text--check t)
      (when (plist-get edit :widget-hooks)
        (add-hook 'before-change-functions #'widget-before-change nil t)
        (add-hook 'after-change-functions #'widget-after-change nil t))
      (overlay-put overlay 'keymap (plist-get edit :keymap))
      (widgetry-text--replace overlay (plist-get edit :text))
      (setq buffer-undo-list (plist-get edit :undo)
            buffer-read-only (plist-get edit :read-only))
      (set-buffer-modified-p (plist-get edit :modified))
      (widget-put widget :value old)
      (goto-char (overlay-start overlay))
      (widgetry-text-editing-mode -1)
      (when (and (plist-get edit :evil) (fboundp 'evil-change-state))
        (evil-change-state (or (plist-get edit :evil) 'normal)))
      (if (and new (not (equal new old)))
          (widgetry-notify widget new)
        (widgetry-redraw widget)))))

(defun widgetry-text-commit ()
  "Keep the text being edited, and notify if it changed."
  (interactive)
  (widgetry-text--finish t))

(defun widgetry-text--place (overlay where)
  "Where point goes in the edited text of OVERLAY: `start' or else the end."
  (if (eq where 'start) (1+ (overlay-start overlay)) (1- (overlay-end overlay))))

(defun widgetry-text-escape ()
  "Leave the text: commit under evil, as leaving insert state does, else cancel."
  (interactive)
  (widgetry-text--finish (bound-and-true-p evil-local-mode)))

(defun widgetry-text-cancel ()
  "Drop the text being edited and restore the old one."
  (interactive)
  (widgetry-text--finish nil))

(defun widgetry-text-edit (&optional event where)
  "Edit the text of the widget at point, or under the mouse EVENT, in place.
Point goes to the `end' of the text, or to its `start' if WHERE is that."
  (interactive (list last-nonmenu-event))
  (let* ((widget (widgetry-widget-at event 'button))
         (buffer (overlay-buffer (widget-get widget :widgetry-overlay))))
    (with-current-buffer buffer
      (when widgetry-text--editing (widgetry-text--finish nil))
      (let* ((overlay (widget-get widget :widgetry-overlay))
             (face 'widgetry-text-editing)
             (edit (list :widget widget :overlay overlay
                         :text (buffer-substring (overlay-start overlay) (overlay-end overlay))
                         :keymap (overlay-get overlay 'keymap)
                         :undo buffer-undo-list :read-only buffer-read-only
                         :modified (buffer-modified-p)
                         ;; The widget library refuses changes outside its fields
                         :widget-hooks (memq #'widget-before-change before-change-functions)
                         :window (get-buffer-window buffer)
                         :evil (and (bound-and-true-p evil-local-mode) (or evil-state 'normal))))
             (value (widget-value widget)))
        (setq widgetry-text--editing edit)
        (widget-put widget :editing t)
        ;; magit-section's hook errors with point outside any section
        (when (memq #'magit-section-post-command-hook post-command-hook)
          (plist-put edit :magit t)
          (remove-hook 'post-command-hook #'magit-section-post-command-hook t))
        (overlay-put overlay 'display nil)
        (overlay-put overlay 'keymap widgetry-text-edit-map)
        (widgetry-text--replace
         overlay (propertize (concat " " value " ") 'face face 'read-only nil))
        (setq buffer-read-only nil
              buffer-undo-list t)
        (set-buffer-modified-p (plist-get edit :modified))
        (remove-hook 'before-change-functions #'widget-before-change t)
        (remove-hook 'after-change-functions #'widget-after-change t)
        (add-hook 'before-change-functions #'widgetry-text--guard nil t)
        (add-hook 'post-command-hook #'widgetry-text--check nil t)
        (when-let* ((window (get-buffer-window buffer)))
          (set-window-point window (widgetry-text--place overlay where)))
        (goto-char (widgetry-text--place overlay where))
        (when (plist-get edit :evil)
          (evil-insert-state))
        (widgetry-text-editing-mode 1)
        (message "RET commits, C-g cancels")))))

(provide 'widgetry-text)
;;; widgetry-text.el ends here
