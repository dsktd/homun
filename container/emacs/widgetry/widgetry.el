;;; widgetry.el --- Widgets for interactive Emacs buffers -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: widgets

;;; Commentary:

;; A growing set of `widget' types for interactive buffers, each a coloured
;; tag and a value block operated directly by keys and mouse (all can be
;; dragged).  `widgetry-slider' (and -x, -y, -z), a number changed by
;; dragging or typing, was extracted from brp-watch.el in brp-emacs.
;; `widgetry-toggle', `widgetry-chips', `widgetry-selector', `widgetry-vector' and
;; `widgetry-button', `widgetry-buttons' and
;; `widgetry-link', `widgetry-secret', `widgetry-text', `widgetry-meter' and
;; `widgetry-activity' follow.
;; Use `widgetry-mode' in the buffer.

;;; Code:

(require 'widgetry-core)
(require 'widgetry-slider)
(require 'widgetry-toggle)
(require 'widgetry-chips)
(require 'widgetry-selection)
(require 'widgetry-buttons)
(require 'widgetry-selector)
(require 'widgetry-vector)
(require 'widgetry-button)
(require 'widgetry-link)
(require 'widgetry-secret)
(require 'widgetry-text)
(require 'widgetry-meter)
(require 'widgetry-activity)

(widgetry-theme-apply)

(provide 'widgetry)
;;; widgetry.el ends here
