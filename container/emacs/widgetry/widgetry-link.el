;;; widgetry-link.el --- A pill that opens a URL -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widgetry-button' that opens a URL with `browse-url': the tag is an
;; arrow, the label the title, and the full URL shows as the help-echo.
;; One press opens it (RET, SPC or a click); there is no hold, since
;; opening a page is neither a vote nor destructive.
;;
;;   (widget-create 'widgetry-link :value " Dashboard "
;;                  :url "https://example.org/")

;;; Code:

(require 'widgetry-button)
(require 'browse-url)

(defun widgetry-link--open (widget &rest _)
  "Open the :url of the link WIDGET."
  (when-let* ((url (widget-get widget :url)))
    (browse-url url)))

(defun widgetry-link--create (widget)
  "Insert WIDGET like a button, its help-echo the URL."
  (widgetry-button--create widget)
  (when-let* ((overlay (widget-get widget :widgetry-overlay)))
    (overlay-put overlay 'help-echo
                 (lambda (&rest _)
                   (widgetry-hover-enter widget)
                   (widgetry-button--hover widget)
                   (widget-get widget :url)))))

(define-widget 'widgetry-link 'widgetry-button
  "A pill that opens :url in the browser."
  :url nil
  :tag " ↗ "
  :value " Link "
  :notify #'widgetry-link--open
  :value-create #'widgetry-link--create)

(provide 'widgetry-link)
;;; widgetry-link.el ends here
