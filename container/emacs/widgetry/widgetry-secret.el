;;; widgetry-secret.el --- A pill that reads a secret -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widgetry-button' that asks for a secret with `read-passwd' (masked,
;; never echoed) and hands it to `:accept', a function of the secret and
;; the widget that returns non-nil when it kept it.  The secret is never
;; stored in the widget, the kill ring, the minibuffer history or the undo
;; list, and the string is wiped with `clear-string' once `:accept'
;; returns.  On success the pill shows `:saved-tag' and is disabled.
;;
;; A second, touching segment " Paste " saves the clipboard instead (the
;; keyboard: "p" on the pill).  It reads the selection directly, so the
;; kill ring is untouched, asks first with only the length of the text,
;; never the text, hands it to `:accept' like a typed secret, and then
;; empties the clipboard unless `widgetry-secret-clear-clipboard' is nil.
;;
;;   (widget-create 'widgetry-secret :value " Token " :prompt "Enter token: "
;;                  :accept (lambda (secret _widget) (my-store secret) t))

;;; Code:

(require 'widgetry-button)

(defcustom widgetry-secret-clear-clipboard t
  "Whether pasting a secret empties the clipboard afterwards."
  :type 'boolean
  :group 'widgetry)

(defvar widgetry-secret-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widgetry-button-map)
    (define-key map [down-mouse-1] #'widgetry-secret-drag)
    (define-key map (kbd "p") #'widgetry-secret-paste)
    map)
  "Keymap for secret pills.")

(define-widget 'widgetry-secret 'widgetry-button
  "A pill that reads a secret and hands it to :accept."
  :tag " 🔒 "
  :value " Secret "
  :prompt "Enter secret: "
  :accept nil
  ;; What the secret is called, for the paste question; nil for the label.
  :name nil
  :paste-tag " Paste "
  :parts #'widgetry-secret--parts
  :keymap widgetry-secret-map
  :saved-tag " ✓ "
  :notify #'widgetry-secret--ask)

(defun widgetry-secret--parts (widget)
  "The parts of WIDGET: the pill, then the touching Paste segment."
  (append (widgetry-button--parts widget)
          (list (list (widget-get widget :paste-tag)
                      (if (widget-get widget :disabled)
                          'widgetry-button-disabled
                        'widgetry-button-value)))))

(defun widgetry-secret--paste-start (widget)
  "Offset into WIDGET's text where its Paste segment begins."
  (- (length (mapconcat #'car (widgetry-secret--parts widget) ""))
     (length (widget-get widget :paste-tag))))

(defun widgetry-secret--on-paste-p (widget event)
  "Non-nil when the mouse EVENT is on the Paste segment of WIDGET."
  (and (mouse-event-p event)
       (>= (widgetry-click-offset widget event) (widgetry-secret--paste-start widget))))

(defun widgetry-secret-drag (event)
  "Press the secret under the mouse EVENT; on Paste, paste when released."
  (interactive "e")
  (let ((widget (widgetry-widget-at event 'button)))
    (if (widgetry-secret--on-paste-p widget event)
        (progn (track-mouse (while (eq (car-safe (widgetry-read-event)) 'mouse-movement)))
               (widgetry-secret--paste widget))
      (widgetry-button-drag event widget))))

(defun widgetry-secret-paste (&optional event)
  "Save the clipboard as the secret of the pill at point, or under EVENT."
  (interactive (list last-nonmenu-event))
  (widgetry-secret--paste (widgetry-widget-at event 'button)))

(defun widgetry-secret--clipboard ()
  "The clipboard as a fresh string, or nil; the kill ring is not touched."
  ;; Not `gui-selection-value' first: it answers nil for a clipboard it has
  ;; returned before, so a second paste of the same text found nothing.  An
  ;; `interprogram-paste-function' of the session's own (wl-paste, say) is the
  ;; clipboard where the selection calls reach none.
  (let ((text (or (ignore-errors (gui-get-selection 'CLIPBOARD))
                  (and (functionp interprogram-paste-function)
                       (not (eq interprogram-paste-function #'gui-selection-value))
                       (ignore-errors (funcall interprogram-paste-function)))
                  (ignore-errors (gui-selection-value)))))
    (when (consp text) (setq text (car text)))
    (and (stringp text) (not (string-empty-p text)) (substring-no-properties text))))

(defun widgetry-secret--clear-clipboard ()
  "Empty the clipboard, the way this session writes it."
  (ignore-errors (gui-set-selection 'CLIPBOARD ""))
  (when (and (functionp interprogram-cut-function)
             (not (eq interprogram-cut-function #'gui-select-text)))
    (ignore-errors (funcall interprogram-cut-function ""))))

(defun widgetry-secret--paste (widget)
  "Save the clipboard through the :accept of WIDGET after asking, then wipe it."
  (unless (widget-get widget :disabled)
    (let ((secret (widgetry-secret--clipboard))
          (accept (widget-get widget :accept)))
      (unwind-protect
          (cond ((null secret) (message "The clipboard is empty"))
                ((and accept
                      (y-or-n-p (format "Save %d characters from the clipboard as %s? "
                                        (length secret)
                                        (or (widget-get widget :name)
                                            (string-trim (widget-value widget)))))
                      (funcall accept secret widget))
                 (when widgetry-secret-clear-clipboard
                   (widgetry-secret--clear-clipboard))
                 (widget-put widget :tag (widget-get widget :saved-tag))
                 (widget-put widget :status 'done)
                 (widget-put widget :disabled t)
                 (widget-value-set widget (widget-value widget))))
        (when secret (clear-string secret))))))

(defun widgetry-secret--read (prompt)
  "Read a secret with PROMPT, leaving no trace in the kill ring or undo."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (interprogram-cut-function nil)
        (interprogram-paste-function nil)
        (minibuffer-setup-hook
         (cons #'buffer-disable-undo minibuffer-setup-hook)))
    (read-passwd prompt)))

(defun widgetry-secret--ask (widget &rest _)
  "Read a secret for WIDGET, give it to its :accept, then wipe it."
  (let ((accept (widget-get widget :accept))
        (secret (widgetry-secret--read (widget-get widget :prompt))))
    (unwind-protect
        (when (and accept (not (string-empty-p secret))
                   (funcall accept secret widget))
          (widget-put widget :tag (widget-get widget :saved-tag))
          (widget-put widget :status 'done)
          (widget-put widget :disabled t)
          (widget-value-set widget (widget-value widget)))
      (clear-string secret))))

(provide 'widgetry-secret)
;;; widgetry-secret.el ends here
