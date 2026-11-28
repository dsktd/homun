;;; claude-homun.el --- One menu for Homun's tools -*- coding: utf-8; lexical-binding: t -*-

;; `claude-homun' is a transient with every claude command in one place, bound
;; to SPC o c. The suffixes come from `claude-homun-registry': adding a tool is
;; one entry (group, key, description, command).

(require 'subr-x)
(require 'color)
(require 'transient)
(require 'claude-identity)
(declare-function claude-dashboard--questions "claude-dashboard")
(declare-function claude-dashboard-ask-question "claude-dashboard")
(declare-function homun-stage-bind-start "homun-stage-bind")
(declare-function homun-stage-work-start "homun-stage-work")
(autoload 'claude-update "claude-update" "Show the update state." t)
(autoload 'claude-update-restart "claude-update" "Recreate the containers." t)
(autoload 'claude-todos "claude-todos" "Show the session's todos." t)
(autoload 'claude-events "claude-events" "Show the event log." t)
(autoload 'claude-doctor "claude-doctor" "Show the health of everything Homun runs." t)
(autoload 'claude-pair-phone "claude-pair" "Pair a phone with the cockpit gateway." t)
(autoload 'homun-stage-agent-open "homun-stage-agent" "Show a subagent live on the Stage.")
(autoload 'homun-stage-agent-open-role "homun-stage-agent" "Show a headless role live on the Stage." t)
(autoload 'homun-stage-pulse-start "homun-stage-pulse" "Open the idle pulse on the Stage." t)

(defvar claude-homun-digest-dir (expand-file-name "~/claude/.services/digest/")
  "Where the daily digest files (YYYY-MM-DD.md) are.")
(defvar claude-homun-reports-dir
  (expand-file-name "~/claude/.services/mechanic/reports/")
  "Where the Mechanic's reports are, one file per report, named by time.")
(defvar claude-homun-issues-url "http://127.0.0.1:8080/issues/"
  "The issues service's tracker board, as the host reaches it (the Manager's 8080
proxy relay).")
(defvar claude-homun-tracker-file (expand-file-name "~/claude/context/tracker.org")
  "The tracker's Org file.")

(defun claude-homun--newest (dir regexp)
  "The newest file in DIR matching REGEXP, by name."
  (car (last (and (file-directory-p dir) (directory-files dir t regexp)))))

(defun claude-homun--visit (file what)
  "Open FILE, or say there is no WHAT."
  (if file (find-file file) (user-error "No %s" what)))

(defun claude-homun-open-digest ()
  "Open the newest daily digest."
  (interactive)
  (claude-homun--visit
   (claude-homun--newest claude-homun-digest-dir "\\`[0-9-]+\\.md\\'") "digest"))

(defun claude-homun-open-report ()
  "Open the Mechanic's newest report."
  (interactive)
  (claude-homun--visit
   (claude-homun--newest claude-homun-reports-dir "\\.md\\'") "report"))

(defun claude-homun-open-newest-question ()
  "Open the newest pending question in its answer buffer."
  (interactive)
  (if-let* ((question (car (last (claude-dashboard--questions)))))
      (claude-dashboard-ask-question question)
    (user-error "No pending question")))

(defun claude-homun-open-board ()
  "Open the tracker board of the issues service in the host browser."
  (interactive)
  (claude-browse-url claude-homun-issues-url))

(defun claude-homun-open-tracker ()
  "Open tracker.org."
  (interactive)
  (find-file claude-homun-tracker-file))

(defun claude-homun-list-services ()
  "List the container's services."
  (interactive)
  (shell-command "claude-services list" "*claude-services*"))

(eval-and-compile
  (defconst claude-homun-registry
    '(("Now"
       ("d" "Dashboard" claude-dashboard)
       ("f" "Follow edits" claude-follow)
       ("F" "Toggle auto-follow" claude-follow-toggle-auto)
       ("B" "Agent board" claude-board)
       ("J" "Background tasks" claude-agent-tasks)
       ("q" "Questions" claude-questions-show)
       ("o" "Show focus here" claude-focus-show-here)
       ("k" "Session todos" claude-todos)
       ("l" "Restore layout" homun-layout-restore)
       ("L" "Reset layout to the default" homun-layout-reset)
       ("z" "Focus: transcript and compose only" homun-layout-focus-toggle)
       ("V" "Open or close the collapsed board or stage" homun-layout-expand)
       ("e" "Event log" claude-events))
      ("Ask"
       ("c" (lambda () (format "Compose to %s" claude-agent-name)) claude-compose)
       ("n" "Newest question" claude-homun-open-newest-question)
       ("m" "Question buffer menu" claude-questions-menu)
       ("y" "Submit answers" claude-questions-submit)
       ("x" "Decline" claude-questions-decline))
      ("Work"
       ("t" "Tracker board" claude-homun-open-board)
       ("T" "tracker.org" claude-homun-open-tracker)
       ("w" "Treebundel" treebundel))
      ("Ops"
       ("s" "Status page" claude-status)
       ("a" "Agenda" org-agenda)
       ("r" "Refresh schedules" claude-sched-refresh)
       ("v" "Services" claude-homun-list-services)
       ("D" "Doctor" claude-doctor)
       ("P" "Pair phone" claude-pair-phone)
       ("U" "Update state" claude-update)
       ("R" "Recreate containers" claude-update-restart))
      ("Reports"
       ("g" "Today's digest" claude-homun-open-digest)
       ("b" "Newest Mechanic report" claude-homun-open-report)))
    "The menu of `claude-homun': (GROUP (KEY DESCRIPTION COMMAND)...) per group."))

(defmacro claude-homun--define ()
  "Define the prefix `claude-homun' from `claude-homun-registry'."
  `(transient-define-prefix claude-homun ()
     "Open one of Homun's tools."
     ,@(mapcar (lambda (group) `[,(car group) ,@(cdr group)])
               claude-homun-registry)))

(claude-homun--define)

;;; Transcript speakers

(defvar claude-homun-roles-file
  (seq-find (lambda (f) (and f (file-readable-p f)))
            (list (getenv "ROLES_FILE") "/dev/shm/homun/roles.json"
                  (expand-file-name "../roles.json"
                                    (or (getenv "CLAUDE_EMACS_CONF") "/opt/homun/emacs"))))
  "The wrapper's role registry: name, emoji and colour per role.
Prefers the entrypoint's merged copy (local identities) over the image's neutral
one.")

(defvar claude-homun--roles nil "(STAMP . REGISTRY) of the role registry as last read.")

(defun claude-homun--roles ()
  "The role registry, an alist by role key, or nil without a readable one.
Read again only when the file changed: header lines ask for a role at every
redisplay."
  (when-let* ((attributes (file-attributes claude-homun-roles-file))
              (stamp (list claude-homun-roles-file (file-attribute-size attributes)
                           (file-attribute-modification-time attributes))))
    (unless (equal stamp (car claude-homun--roles))
      (setq claude-homun--roles
            (cons stamp (ignore-errors (json-read-file claude-homun-roles-file)))))
    (cdr claude-homun--roles)))

(defun claude-homun--role-pinned (file)
  "The role whose pinned session (~/.claude/ROLE-session) is FILE, or nil."
  (seq-find (lambda (role)
              (let ((pin (expand-file-name (format "~/.claude/%s-session" role))))
                (and (file-readable-p pin)
                     (equal (string-trim (with-temp-buffer (insert-file-contents pin)
                                                           (buffer-string)))
                            (file-name-base file)))))
            '("manager")))

(defun claude-homun--theme-colour (rgb)
  "The role colour RGB (0-255 list) fitted to the active theme, as #RRGGBB.
It keeps its hue but moves towards the default foreground (more on a light
theme, where pastels vanish), so it reads on the theme's background."
  (let* ((fg (color-name-to-rgb (or (face-foreground 'default nil t) "white")))
         (bg (color-name-to-rgb (or (face-background 'default nil t) "black")))
         (dark (< (apply #'+ bg) 1.5))
         (amount (if dark 0.15 0.45)))
    (apply #'color-rgb-to-hex
           (append (color-blend (mapcar (lambda (v) (/ v 255.0)) rgb) fg (- 1 amount)) '(2)))))

(defun claude-homun--role-style (role)
  "Plist :name :emoji :color of ROLE, an entry of the role registry.
The colour is computed from the registry's accent and the active theme."
  (let ((rgb (append (alist-get 'colour role) nil)))
    (list :name (alist-get 'name role) :emoji (alist-get 'emoji role)
          :color (and (= (length rgb) 3) (claude-homun--theme-colour rgb)))))

(defun claude-homun-role-style (key)
  "The style plist of the role named KEY (a string such as \"manager\"), or nil."
  (when-let* ((role (alist-get (intern key) (claude-homun--roles))))
    (let ((style (claude-homun--role-style role)))
      (if (equal key "manager")
          (plist-put (plist-put style :name claude-agent-name) :emoji claude-agent-emoji)
        style))))

(defun claude-homun-speaker (file)
  "Who speaks in session FILE, for `claude-transcript-speaker-function'.
A role's session gets its name, emoji and colour from the role registry; a
subagent its agent type."
  (let ((meta (concat (file-name-sans-extension file) ".meta.json")))
    (cond
     ((file-readable-p meta)
      (when-let* ((type (alist-get 'agentType (json-read-file meta))))
        (list :name type :emoji "🤖")))
     ((when-let* ((key (or (claude-homun--role-pinned file)
                           ;; Another role's state mounted at /mnt/<role>-claude
                           (and (string-match "\\`/mnt/\\([a-z]+\\)-claude/" file)
                                (match-string 1 file))
                           (and (string-match "--services-\\([a-z]+\\)" file)
                                (match-string 1 file))))
                  (role (alist-get (intern key) (claude-homun--roles))))
        (let ((style (claude-homun--role-style role)))
          (plist-put (if (equal key "manager")
                         (plist-put (plist-put style :name claude-agent-name)
                                    :emoji claude-agent-emoji)
                       style)
                     :role key)))))))

(with-eval-after-load 'claude-transcript
  (setq claude-transcript-speaker-function #'claude-homun-speaker))

;;; Cockpit

(declare-function claude-compose--route-for-file "claude-compose")
(declare-function claude-transcript-open "claude-transcript")

(defconst claude-cockpit-tab-name claude-agent-name "The tab-bar tab the cockpit lives in.")

(defun claude-cockpit--tab ()
  "Select the cockpit's tab, making it when missing, so the user's own layout is
never rebuilt."
  (unless (or noninteractive (not (fboundp 'tab-bar-new-tab)))
    (let ((names (mapcar (lambda (tab) (alist-get 'name tab)) (funcall tab-bar-tabs-function))))
      (cond ((equal (alist-get 'name (tab-bar--current-tab)) claude-cockpit-tab-name))
            ((member claude-cockpit-tab-name names)
             (tab-bar-select-tab-by-name claude-cockpit-tab-name))
            (t (tab-bar-new-tab)
               (tab-bar-rename-tab claude-cockpit-tab-name))))))

;;;###autoload
(defun claude-cockpit (&optional file)
  "Lay out the selected frame for working with the manager: the cockpit layout
\(`homun-layout-apply') in its own tab, showing the transcript of FILE (the main
session by default); an agent's transcript takes no messages, so point stays on
it."
  (interactive)
  (require 'claude-compose)
  (require 'claude-transcript)
  (claude-cockpit--tab)
  (homun-layout-apply)
  (require 'homun-stage-bind)
  (homun-stage-bind-start)
  (require 'homun-stage-work)
  (require 'homun-stage-rows)
  (require 'homun-stage)
  (homun-stage-load-parts)
  (require 'homun-stage-project)
  (homun-stage-work-start)
  (when file
    (claude-transcript-open file)
    (unless (claude-compose--route-for-file file)
      (select-window (homun-layout-window 'transcript)))))

(require 'homun-layout)
(require 'claude-layout)                ; the old names, until their callers are gone
(require 'homun-api)
(require 'homun-compile)
(provide 'claude-homun)
;;; claude-homun.el ends here
