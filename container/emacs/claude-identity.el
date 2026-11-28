;;; claude-identity.el --- The agent's name and emoji, from agent.json -*- coding: utf-8; lexical-binding: t -*-

;; The one agent identity (name, emoji) every label reads, loaded from
;; $CLAUDE_AGENT_FILE, /run/claude-agent.json, ~/.config/claude/agent.json or
;; ~/claude/.services/identities/agent.json (local only) or
;; the repo's container/agent.json, else "Manager".

;;; Code:

(require 'cl-lib)
(require 'json)

(defun claude-identity--field (key default)
  "KEY of the agent.json that applies, or DEFAULT."
  (or (ignore-errors
        (cl-loop for f in (list (getenv "CLAUDE_AGENT_FILE") "/run/claude-agent.json"
                                "~/.config/claude/agent.json"
                                "~/claude/.services/identities/agent.json"
                                (expand-file-name "../agent.json"
                                                  (or (getenv "CLAUDE_EMACS_CONF")
                                                      "/opt/homun/emacs")))
                 when (and f (file-readable-p f))
                 return (let ((v (alist-get key (json-read-file (expand-file-name f)))))
                          (and (stringp v) (not (string-empty-p v)) v))))
      default))

(defcustom claude-agent-name (claude-identity--field 'name "Manager")
  "The agent's name, as the cockpit's labels and messages say it."
  :type 'string :group 'tools)

(defcustom claude-agent-emoji (claude-identity--field 'emoji "🗂️")
  "The agent's emoji."
  :type 'string :group 'tools)

;; ERT must not hardcode a name: role names come from the role registry, or, on the phone, from
;; the gateway's snapshot (`claude-role-names'); the role key stays the fallback and the routing id.
(defvar claude-role-names nil "Alist of (ROLE-KEY . NAME) the phone got from the gateway snapshot.")

(declare-function claude-homun-role-style "claude-homun")

(defun claude-role-name (role)
  "The display name of ROLE (a key, string or symbol), else the key itself."
  (let ((key (if (symbolp role) (symbol-name role) role)))
    (or (cdr (assoc key claude-role-names))
        (and (fboundp 'claude-homun-role-style)
             (let ((n (plist-get (claude-homun-role-style key) :name)))
               (and (stringp n) (not (string-empty-p n)) n)))
        key)))

(provide 'claude-identity)
;;; claude-identity.el ends here
