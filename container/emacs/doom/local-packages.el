;; -*- no-byte-compile: t; -*-
;;; local-packages.el --- the container's package declarations, loaded last by the user's packages.el

;; The user's packages.el declares treebundel from the fork's `transient' branch; the
;; build needs a pin, so this later declaration, which Doom merges over the
;; first (a repeated `package!' keeps the earlier keys it does not set, so the
;; fork and branch stay the user's), adds the pin. Bump the pin with the fork.
(package! treebundel
  :pin "a49ba149c0d5b7bb5b7216dd51f79db01147ddae")

;; goggles' face is what claude-follow flashes a followed file with
(package! goggles)

;; The user's config.el turns on share-path, their unpublished package: the stand-in
;; in share-path.el (flake.nix's emacsPackageOverrides), or config.el stops
;; before it loads local.el
(package! share-path)

;; prettier Org in the manager's question, dashboard and task buffers (claude-org-modern)
(package! org-modern)
