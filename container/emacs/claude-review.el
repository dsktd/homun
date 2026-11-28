;;; claude-review.el --- Review a branch diff beside an Org notes file -*- lexical-binding: t -*-

;; `claude-review' shows `git diff BASE...HEAD' of a repository (diff-mode) next
;; to an Org notes buffer.  C-c C-n on a hunk adds a heading "file:line" with
;; the hunk quoted and puts point under it to write the note.  C-c C-c in
;; either buffer returns the notes as JSON in answers/ID:
;;   {"status": "ok", "notes": [{"file", "line", "hunk", "text"}...]}
;; C-c C-k declines (answers/ID.declined).  Returns at once, like `claude-ask'.

(require 'homun-layout)
(require 'diff-mode)
(require 'json)
(require 'org)
(require 'subr-x)
(require 'claude)

(defvar claude-review-hunk-lines 40
  "Longest quoted hunk, in lines; the rest is cut.")

(defvar-local claude-review-id nil "The review this buffer belongs to.")
(defvar-local claude-review-notes nil "In a diff buffer: its notes buffer.")

(defvar claude-review-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'claude-review-add)
    (define-key map (kbd "C-c C-c") #'claude-review-submit)
    (define-key map (kbd "C-c C-k") #'claude-review-decline)
    map)
  "Keys of `claude-review-mode', in the diff and the notes buffer.")

(define-minor-mode claude-review-mode
  "C-c C-n note the hunk at point, C-c C-c submit the notes, C-c C-k decline."
  :lighter " Review" :keymap claude-review-map)

;;; Notes

(defun claude-review--hunk-info ()
  "(FILE LINE TEXT) of the diff hunk at point: new-file line, hunk cut to a limit."
  (save-excursion
    (diff-beginning-of-hunk t)
    (let* ((start (point))
           (file (or (diff-find-file-name nil t) "?"))
           (line (if (looking-at "@@ -[0-9,]+ \\+\\([0-9]+\\)")
                     (string-to-number (match-string 1))
                   1))
           (end (progn (diff-end-of-hunk) (point)))
           (lines (split-string (buffer-substring-no-properties start end) "\n" t)))
      (list file line (string-join (seq-take lines claude-review-hunk-lines) "\n")))))

(defun claude-review-add ()
  "Add a note for the hunk at point to the notes buffer and go there."
  (interactive)
  (pcase-let ((`(,file ,line ,text) (claude-review--hunk-info))
              (notes (or claude-review-notes (current-buffer))))
    (with-current-buffer notes
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* %s:%d\n#+begin_src diff\n%s\n#+end_src\n\n" file line text)))
    (pop-to-buffer notes)
    (goto-char (point-max))))

(defun claude-review--collect ()
  "The notes of the current Org buffer as a list of plists."
  (let (notes)
    (org-map-entries
     (lambda ()
       (let* ((title (org-get-heading t t t t))
              (body (buffer-substring-no-properties
                     (save-excursion (org-end-of-meta-data t) (point))
                     (org-entry-end-position)))
              (hunk (and (string-match "#\\+begin_src diff\n\\(\\(?:.*\n\\)*?\\)#\\+end_src" body)
                         (match-string 1 body)))
              (text (string-trim (replace-regexp-in-string
                                  "#\\+begin_src diff\n\\(?:.*\n\\)*?#\\+end_src" "" body))))
         (when (string-match "\\`\\(.*\\):\\([0-9]+\\)\\'" title)
           (push (list :file (match-string 1 title)
                       :line (string-to-number (match-string 2 title))
                       :hunk (string-trim-right (or hunk ""))
                       :text text)
                 notes))))
     nil nil)
    (vconcat (nreverse notes))))

(defun claude-review--finish (suffix json)
  "Write JSON to answers/<id>SUFFIX atomically and close both buffers."
  (let* ((id (or claude-review-id (user-error "Not a review buffer")))
         (file (expand-file-name (concat id suffix) claude-answers-dir))
         (tmp (concat file ".tmp")))
    (make-directory claude-answers-dir t)
    (write-region json nil tmp nil 'silent)
    (rename-file tmp file t)
    (dolist (b (list (get-buffer (format "*claude review notes %s*" id))
                     (get-buffer (format "*claude review diff %s*" id))))
      (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))

(defun claude-review-submit ()
  "Send the notes to Claude."
  (interactive)
  (let ((notes-buffer (get-buffer (format "*claude review notes %s*" claude-review-id))))
    (claude-review--finish
     ""
     (json-serialize
      (list :status "ok"
            :notes (with-current-buffer notes-buffer (claude-review--collect)))))))

(defun claude-review-decline ()
  "Tell Claude there are no notes."
  (interactive)
  (unless (claude-confirm "Decline this review? ") (user-error "Not declined"))
  (claude-review--finish ".declined" ""))

;;; Showing

(defun claude-review--buffers (id dir base)
  "The diff and notes buffers of review ID for DIR against BASE: (DIFF . NOTES)."
  (let ((default-directory (file-name-as-directory dir))
        (diff (get-buffer-create (format "*claude review diff %s*" id)))
        (notes (get-buffer-create (format "*claude review notes %s*" id))))
    (with-current-buffer diff
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (zerop (call-process "git" nil t nil "diff" (concat base "...HEAD")))
          (insert "git diff failed\n")))
      (diff-mode)
      (setq default-directory (file-name-as-directory dir))
      (goto-char (point-min)))
    (with-current-buffer notes
      (erase-buffer)
      (org-mode)
      (insert (format "#+title: Review of %s against %s\n\n" dir base)))
    (dolist (b (list diff notes))
      (with-current-buffer b
        (setq claude-review-id id)
        (claude-review-mode 1)))
    (with-current-buffer diff (setq claude-review-notes notes))
    (cons diff notes)))

(defun claude-review (id dir base)
  "Show DIR's diff against BASE beside Org notes; the answer goes to answers/ID."
  (pcase-let ((`(,diff . ,notes) (claude-review--buffers id dir base)))
    (claude--with-frame
      (homun-layout-alone diff notes)))
  (claude--notify "Claude asks" (format "Review %s against %s" dir base))
  id)

(provide 'claude-review)
;;; claude-review.el ends here
