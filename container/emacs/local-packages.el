;; -*- no-byte-compile: t; -*-
;;; local-packages.el --- the container's package declarations, loaded last by Cal's packages.el

;; Cal's packages.el declares treebundel from the fork's `transient' branch; the
;; build needs a pin, so this later declaration, which Doom merges over the
;; first (a repeated `package!' keeps the earlier keys it does not set), adds
;; it. Bump the pin with the fork.
(package! treebundel :recipe (:host github :repo "purplg/treebundel" :branch "transient")
  :pin "a49ba149c0d5b7bb5b7216dd51f79db01147ddae")

;; goggles' face is what claude-follow flashes a followed file with
(package! goggles)
