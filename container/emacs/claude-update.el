;;; claude-update.el --- Update state and Recreate from the user's Emacs -*- coding: utf-8; lexical-binding: t -*-

;; New launcher code comes with a home-manager switch on the host: the host service (homun-host)
;; follows the pin, builds the image (`claude:staged') and rolls the containers onto it, and this file only shows
;; how far that is: update/stage-state (`building <start> <step>/<total>', `ready <end> <image>',
;; `failed <end>'), update/state and stage.log.  The one request from here is a recreate of the
;; containers on the current image (`claude-update-restart', the Recreate button): Emacs writes a
;; `recreate' request into the cockpit's part of the host service's spool,
;; host/requests/cockpit/<id>.json; that directory is rw in this container alone (run.nu
;; `host-inbox'), and the host service (bin/homun-host) runs bin/claude-update-on-request for a
;; fresh one and answers in host/results/<id>.json.  It builds nothing; an image a switch built
;; while work was running is taken then.  Nothing else may write the request: no homun-api entry.
;; A host whose service has never run has no spool: there the request is the line
;; `<epoch> restart [force]' in update/emacs-request/request, answered in update/emacs-result.

(require 'homun-proc)
(require 'subr-x)
(require 'claude)
(require 'homun-layout)
(require 'homun-clock)
(require 'homun-version)
(require 'homun-stage-store)

(defconst claude-update-dir (expand-file-name "claude/.services/update" "~"))
(defconst claude-update-request (expand-file-name "emacs-request/request" claude-update-dir))
(defconst claude-update-host-dir (expand-file-name "claude/.services/host" "~"))

(defvar claude-update--sent nil "Epoch seconds of the last request sent to the host service's spool.")

(defun claude-update--spool ()
  "The cockpit's part of the host service's spool, or nil where there is none."
  (let ((dir (expand-file-name "requests/cockpit" claude-update-host-dir)))
    (and (file-directory-p dir) dir)))

(defun claude-update--host-result (stamp)
  "The host service's answer to the request sent at STAMP as an alist, or nil."
  (let ((file (expand-file-name (format "results/cockpit-%d.json" stamp) claude-update-host-dir)))
    (when (file-readable-p file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (json-parse-buffer :object-type 'alist :null-object nil :false-object nil))))))

(defun claude-update--read (name)
  "The trimmed contents of NAME in `claude-update-dir', or nil."
  (let ((file (expand-file-name name claude-update-dir)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (string-trim (buffer-string))))))

(defun claude-update--request-time ()
  "Epoch seconds of the last request, or nil."
  (or claude-update--sent
      (let ((text (claude-update--read "emacs-request/request")))
        (and text (string-match-p "\\`[0-9]+ " text) (string-to-number text)))))

(defun claude-update--state ()
  "(WORD . EPOCH) from update/state (running, done, failed), or nil."
  (let ((text (claude-update--read "state")))
    (when (and text (string-match "\\`\\([a-z]+\\) \\([0-9]+\\)" text))
      (cons (match-string 1 text) (string-to-number (match-string 2 text))))))

(defun claude-update--role-note ()
  "What the last roll did to one role, e.g. \"manager rolled back\", or nil.
update/state then reads `failed|done <epoch> <role> <outcome>' (lib/roll.nu)."
  (let ((text (claude-update--read "state")))
    (when (and text (string-match
                     "\\`[a-z]+ [0-9]+ \\([a-z][a-z0-9-]*\\) \\([a-z-]+\\)\\'" text))
      (let ((role (match-string 1 text)))
        (pcase (match-string 2 text)
          ("rolled-back" (format "%s rolled back to its previous image" role))
          ("stopped" (format "update stopped at %s · repair requested" role))
          ("gave-up" (format "%s is down · automatic repair gave up" role))
          ("untouched" nil)
          (_ (format "%s failed its health gate" role)))))))

(defun claude-update--result (stamp)
  "The host's answer to request STAMP (\"ok\" or the refusal), or nil.
A request the host service has taken and not finished counts as \"ok\"."
  (if-let* ((row (and stamp (claude-update--host-result stamp))))
      (if (or (equal (alist-get 'state row) "running") (alist-get 'ok row))
          "ok"
        (or (alist-get 'text row) "refused"))
    (let ((text (claude-update--read "emacs-result")))
      (when (and text stamp (string-prefix-p (format "%d " stamp) text))
        (substring text (1+ (length (format "%d" stamp))))))))

(defun claude-update--stage ()
  "(WORD EPOCH DETAIL) from update/stage-state, or nil.  DETAIL is the step as
\"n/m\" or the image."
  (let ((text (claude-update--read "stage-state")))
    (when (and text (string-match "\\`\\([a-z]+\\) \\([0-9]+\\)\\(?: \\(.*\\)\\)?\\'" text))
      (list (match-string 1 text) (string-to-number (match-string 2 text)) (match-string 3 text)))))

(defun claude-update-building-p ()
  "Non-nil while the host is building the image (a state older than 30 minutes is
stale)."
  (let ((stage (claude-update--stage)))
    (and (equal (car stage) "building") (< (- (float-time) (cadr stage)) 1800))))

(defun claude-update-staged-p ()
  "Non-nil when an image is staged and not yet applied."
  (file-readable-p (expand-file-name "staged.json" claude-update-dir)))

(defun claude-update--progress ()
  "The build progress row, e.g. \"Building image · step 14/31 · 2m10s\", or nil."
  (when (claude-update-building-p)
    (let* ((stage (claude-update--stage))
           (secs (max 0 (floor (- (float-time) (cadr stage)))))
           (step (and (caddr stage) (not (equal (caddr stage) "0/0")) (caddr stage))))
      (format "Building image%s · %dm%02ds" (if step (format " · step %s" step) "")
              (/ secs 60) (% secs 60)))))

(defun claude-update-pending-p ()
  "Non-nil while a request is waiting or a restart is running."
  (let* ((stamp (claude-update--request-time))
         (state (claude-update--state)))
    (or (equal (car state) "running")
        (and stamp (< (- (float-time) stamp) 60)
             (let ((result (claude-update--result stamp)))
               (or (null result) (equal result "ok")))))))

(defun claude-update-status ()
  "A short state of the update for the board's header, or nil when idle."
  (let* ((stamp (claude-update--request-time))
         (state (claude-update--state))
         (result (claude-update--result stamp))
         (stage (claude-update--stage))
         (now (float-time)))
    (cond
     ((equal (car state) "running") "recreating")
     ((claude-update--progress))
     ((and stamp (< (- now stamp) 8) (null result)) "recreate requested")
     ((and stamp (< (- now stamp) 600) (null result)
           (not (and state (>= (cdr state) stamp))))
      "Recreate requested · waiting for the host (is homun-host running? homun host show)")
     ((and stamp (< (- now stamp) 600) result (not (equal result "ok"))
           (not (and state (>= (cdr state) stamp))))
      (format "recreate refused: %s" (car (split-string result "\n"))))
     ((and (equal (car stage) "failed") (< (- now (cadr stage)) 600)) "update failed")
     ((and state (member (car state) '("done" "failed")) (< (- now (cdr state)) 86400)
           (claude-update--role-note)))
     ((claude-update-staged-p) "Update built · Recreate applies it")
     ((and state (equal (car state) "done") (< (- now (cdr state)) 600)) "recreated")
     ((and state (equal (car state) "failed") (< (- now (cdr state)) 600)) "recreate failed"))))

(defvar claude-update--timer nil "Redraw tick while an image builds.")

(defun claude-update--tick ()
  (claude-update--spin-start)
  (when (or (claude-update-building-p) (claude-update--request-time))
    (force-mode-line-update t)))

(unless claude-update--timer
  (setq claude-update--timer (run-with-timer 5 5 #'claude-update--tick)))

;; The Recreate button spins while an image builds: a `homun-clock' client that exists only then and
;; redraws just that button group (`claude-update--group', set by the board), never the board.
(defconst claude-update--spinner ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])
(defvar claude-update--spin-frame 0)
(defvar-local claude-update--group nil "The board's Recreate button group, if drawn.")

(defun claude-update--spinning-p ()
  "Non-nil while an image builds or the manager compacts: the board spins then."
  (or (claude-update-building-p)
      (and (fboundp 'claude-board--compacting-p) (claude-board--compacting-p))))

(defun claude-update--spin (&optional _snap)
  "Advance the spinner.  Return non-nil while the build goes on, so `homun-clock'
stops by itself."
  (setq claude-update--spin-frame (1+ claude-update--spin-frame))
  (let ((building (claude-update--spinning-p)) (any nil))
    (dolist (buffer (buffer-list))
      (when-let* (((buffer-live-p buffer))
                  (group (buffer-local-value 'claude-update--group buffer))
                  (overlay (widget-get group :widgetry-overlay))
                  ((overlay-buffer overlay)))
        (setq any t)
        (ignore-errors (widgetry-redraw group))))
    (unless building (setq claude-update--spin-frame 0))
    (and building any)))

(defun claude-update--spin-start ()
  "Run the spinner on `homun-clock' while a build runs."
  (when (and (not (assq 'claude-update-spin homun-clock--clients)) (claude-update--spinning-p))
    (homun-clock-register 'claude-update-spin #'claude-update--spin 0.12)))

(defvar claude-update-busy-file (expand-file-name "~/claude/.services/manager/busy.txt")
  "The Manager's copy of the `claude-busy' lines (this container has no
claude-busy).")

(defun claude-update--busy ()
  "The lines of `claude-busy' an update would kill, or `unknown' when the Manager's
file is missing or older than two minutes."
  (let ((mtime (file-attribute-modification-time (file-attributes claude-update-busy-file))))
    (if (and mtime (< (float-time (time-since mtime)) 120))
        (with-temp-buffer
          (insert-file-contents claude-update-busy-file)
          (split-string (buffer-string) "\n" t))
      'unknown)))

;;;; What the checkout is ahead by

(defconst claude-update-repo (expand-file-name "claude/_tools/homun" "~"))

(defun claude-update--rev (name)
  "The commit recorded in update/NAME (a file or the `rev' of a json one), or nil."
  (when-let* ((text (claude-update--read name)))
    (if (string-suffix-p ".json" name)
        (ignore-errors (alist-get 'rev (json-parse-string text :object-type 'alist)))
      (and (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" text) text))))

(defvar claude-update--ahead-cache nil "(TIME BASE . RESULT) of the last `claude-update--ahead'.")

(defun claude-update--ahead ()
  "Commits of the wrapper checkout not in the staged image, or the running one:
a list of subjects, or `unknown' when no revision is
recorded (update/running-rev is written when an update is applied)."
  (let ((base (or (and (claude-update-staged-p) (claude-update--rev "staged.json"))
                  (claude-update--rev "running-rev"))))
    (if (null base) 'unknown
      (if (and claude-update--ahead-cache (equal (cadr claude-update--ahead-cache) base)
               (< (- (float-time) (car claude-update--ahead-cache)) 20))
          (cddr claude-update--ahead-cache)
        ;; Read in the background; until it is in, the last answer for this base (or unknown)
        (homun-proc-async "update ahead" "git"
                          (list "-C" claude-update-repo "-c" "safe.directory=*" "log"
                                "--format=%h %s" (concat base "..HEAD"))
                          (lambda (status out)
                            (setq claude-update--ahead-cache
                                  (cons (float-time)
                                        (cons base (if (eql 0 status) (split-string out "\n" t)
                                                     'unknown))))))
        (if (equal (cadr claude-update--ahead-cache) base) (cddr claude-update--ahead-cache)
          'unknown)))))

;;;; Emacs itself (the `emacs' service's Nix profile)

;; Emacs runs in the claude-emacs container (the `editor' role), whose `emacs' service installs
;; container/emacs/flake.nix into /nix/var/nix/profiles/emacs once.  That container shares /nix, so
;; the build happens right here: `claude-update-emacs' builds into a GC-rooted link (new-profile),
;; logging to update.log, and `claude-update-emacs-restart' switches the profile and restarts the
;; service, with the frame layout saved first (`homun-layout-save-to-file').  It builds the
;; flavour the profile holds: the flake's doom package from the host's Doom directory
;; ($HOMUN_COCKPIT_CONFIG) when that is a Doom build, its default package otherwise; a change
;; of flavour is the service's to make (container/services/emacs/run).  What the profile was
;; built from is a hash of flake.nix, flake.lock, doom/local.el, doom/local-packages.el and,
;; for Doom, the .el files of the host's directory (the files Nix takes), kept in
;; profile-inputs when applied and in built-inputs when built: no Nix evaluation to ask
;; whether something changed.  Nothing restarts by itself.

(defconst claude-update-emacs-conf (or (getenv "CLAUDE_EMACS_CONF") "/opt/homun/emacs"))
(defconst claude-update-emacs-files '("flake.nix" "flake.lock" "doom/local.el" "doom/local-packages.el"))
(defvar claude-update-emacs-dir (expand-file-name "claude/.services/emacs/" "~"))
(defvar claude-update-emacs-profile "/nix/var/nix/profiles/emacs")

(defun claude-update-emacs--doom-p ()
  "Non-nil when the profile holds the Doom flavour."
  (file-executable-p (expand-file-name "bin/doom-emacs" claude-update-emacs-profile)))

(defun claude-update-emacs--installable ()
  "The shell words that name the flake package of the profile's flavour."
  (let ((flake (concat "path:" claude-update-emacs-conf)))
    (cond ((not (claude-update-emacs--doom-p)) (shell-quote-argument flake))
          ((getenv "HOMUN_COCKPIT_CONFIG")
           (concat "--impure " (shell-quote-argument (concat flake "#doom"))))
          (t (user-error "This Doom build has no source: set cockpit.config in the host config")))))

(defun claude-update-emacs--path (name) (expand-file-name name claude-update-emacs-dir))

(defun claude-update-emacs--file (name)
  "The trimmed contents of NAME under `claude-update-emacs-dir', or nil."
  (let ((file (claude-update-emacs--path name)))
    (when (file-readable-p file)
      (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string))))))

(defvar claude-update-emacs--hash-cache nil "(STAMPS . HASH) of the last `claude-update-emacs--inputs'.")

(defun claude-update-emacs--inputs ()
  "Hash of the Emacs flake's input files; recomputed only when one of them changed."
  (let* ((files (append (mapcar (lambda (f) (expand-file-name f claude-update-emacs-conf))
                                claude-update-emacs-files)
                        (when-let* (((claude-update-emacs--doom-p))
                                    (dir (getenv "HOMUN_COCKPIT_CONFIG"))
                                    ((file-directory-p dir)))
                          (directory-files dir t "\\.el\\'"))))
         (stamps (mapcar (lambda (f) (file-attribute-modification-time (file-attributes f))) files)))
    (if (equal (car claude-update-emacs--hash-cache) stamps)
        (cdr claude-update-emacs--hash-cache)
      (let ((hash (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (dolist (f files) (when (file-readable-p f) (insert-file-contents-literally f)
                                        (goto-char (point-max))))
                    (secure-hash 'sha1 (current-buffer)))))
        (setq claude-update-emacs--hash-cache (cons stamps hash))
        hash))))

(defun claude-update-emacs--build-alive-p ()
  "Non-nil when update.pid names a live process of this container that is the
build's shell.
The build runs here, so a pid that is gone, or reused by another program after a
recreate, means it ended without writing its result."
  (when-let* ((pid (string-to-number (or (claude-update-emacs--file "update.pid") "")))
              ((> pid 0))
              (attrs (process-attributes pid))
              (args (alist-get 'args attrs)))
    (string-match-p "update-state" args)))

(defvar claude-update-emacs--interrupted-noted nil "The update-state text already reported.")

(defun claude-update-emacs--interrupted (run)
  "Mark the build record RUN as interrupted in update-state; warn once per record."
  (let ((text (format "failed %d interrupted (%s)" (floor (float-time)) run)))
    (ignore-errors
      (with-temp-file (claude-update-emacs--path "update-state") (insert text "\n"))
      (delete-file (claude-update-emacs--path "update.pid")))
    (unless (equal claude-update-emacs--interrupted-noted run)
      (setq claude-update-emacs--interrupted-noted run)
      (display-warning 'claude-update
                       (format "The Emacs build of %s ended without a result (killed by a restart?); press Update Emacs to build again"
                               (format-time-string "%F %R" (string-to-number (cadr (split-string run)))))
                       :error))))

(defun claude-update-emacs-state ()
  "One of `building', `failed', `ready' (built from the current inputs),
`changed' (inputs differ from the profile's), `unknown' (no record of what the
profile was built from) or `current'. A `building' record whose build process is
gone is turned into `failed', with a warning."
  (let* ((run (claude-update-emacs--file "update-state"))
         (now (claude-update-emacs--inputs))
         (applied (claude-update-emacs--file "profile-inputs")))
    (when (and run (string-prefix-p "building" run) (not (claude-update-emacs--build-alive-p)))
      (claude-update-emacs--interrupted run)
      (setq run (claude-update-emacs--file "update-state")))
    (cond ((and run (string-prefix-p "building" run)) 'building)
          ((equal applied now) 'current)
          ((equal (claude-update-emacs--file "built-inputs") now) 'ready)
          ((and run (string-prefix-p "failed" run)) 'failed)
          ((null applied) 'unknown)
          (t 'changed))))

(defun claude-update-emacs-label ()
  (pcase (claude-update-emacs-state)
    ('building "building") ('failed "build failed") ('ready "built, restart applies it")
    ('changed "inputs changed since the running build")
    ('unknown "no record of the running build (Update Emacs records it)")
    (_ "up to date")))

(defun claude-update-emacs--script (hash)
  (let ((dir claude-update-emacs-dir))
    (format "cd %s || exit; echo $$ >update.pid; : >update.log
echo \"building $(date +%%s)\" >update-state
if nix build --max-jobs 8 --print-build-logs --out-link new-profile %s >>update.log 2>&1; then
  echo %s >built-inputs; echo \"built $(date +%%s)\" >update-state
else echo \"failed $(date +%%s)\" >update-state; fi
rm -f update.pid\n"
            (shell-quote-argument dir) (claude-update-emacs--installable)
            (shell-quote-argument hash))))

;;;###autoload
(defun claude-update-emacs ()
  "Build the next Emacs profile in the background; progress is in update.log."
  (interactive)
  (if (eq (claude-update-emacs-state) 'building)
      (message "Emacs is already building")
    (make-directory claude-update-emacs-dir t)
    (start-process "claude-emacs-build" nil "setsid" "sh" "-c"
                   (claude-update-emacs--script (claude-update-emacs--inputs)))
    (message "Building Emacs; progress in update.log")))

(defun claude-update-emacs-restart-script ()
  "The shell text that switches the profile and restarts the service, detached."
  (format "sleep 1; cd %s || exit
flock /nix/var/claude-nix-profile.lock sh -c 'nix profile remove --profile \"$0\" --all && { nix profile install --profile \"$0\" \"$@\" || { nix profile rollback --profile \"$0\"; exit 1; }; }' %s %s >>update.log 2>&1 \\
  && cp built-inputs profile-inputs && echo \"restarting $(date +%%s)\" >>update.log \\
  && claude-services restart emacs >>update.log 2>&1\n"
          (shell-quote-argument claude-update-emacs-dir)
          (shell-quote-argument claude-update-emacs-profile)
          (claude-update-emacs--installable)))

;;;###autoload
(defun claude-update-emacs-restart ()
  "Switch to the built profile and restart the daemon; the frame layout comes back.
Only after `claude-update-emacs' has built the current inputs."
  (interactive)
  (unless (eq (claude-update-emacs-state) 'ready)
    (user-error "No Emacs build ready for the current inputs: press Update Emacs"))
  (homun-layout-save-to-file)
  (call-process "setsid" nil 0 nil "-f" "sh" "-c" (claude-update-emacs-restart-script))
  (message "Restarting Emacs..."))

(defun claude-update-emacs-buttons ()
  "Button specs for `widgetry-buttons': Update Emacs (a press) and Restart Emacs (a
hold)."
  (let ((state (claude-update-emacs-state)))
    (list (list :label "Update Emacs" :confirm nil :disabled (and (memq state '(building current)) t)
                :help "Build the Emacs profile from the flake in the background"
                :notify (lambda (&rest _) (claude-update-emacs)))
          (list :label "Restart Emacs" :confirm 'hold :disabled (and (not (eq state 'ready)) t)
                :help (if (eq state 'ready) "Switch the profile and restart the daemon (frames come back)"
                        "Nothing built for the current inputs: press Update Emacs")
                :notify (lambda (&rest _) (claude-update-emacs-restart))))))

;;;; Commit counters (Pending and Recreate)

(defconst claude-update-launcher-dir (expand-file-name "claude/_tools/homun" "~")
  "The launcher checkout whose commits the counters count.")

(defvar claude-update--counts nil "The last `claude-update-counts' as (TIME KEY . COUNTS).")

(defconst claude-update-run-dir "/opt/homun"
  "The launcher clone that runs; its commits are the published ones when it is a
git checkout.")

(defun claude-update--git (&rest args)
  "Output lines of git ARGS in the launcher checkout, or nil on failure."
  (claude-update--git-in claude-update-launcher-dir args))

(defun claude-update--git-in (dir args)
  "Output lines of git ARGS run in DIR, or nil on failure."
  (let ((default-directory dir))
    (let ((r (homun-proc-sync "git" args)))
      (when (eq 0 (car r)) (split-string (cdr r) "\n" t)))))

(defvar claude-update--sources (make-hash-table :test #'equal)
  "Published rev to the sha of the local commit it was made from.")

(defun claude-update--source (rev)
  "The local commit REV (a running or staged rev, maybe a published squash) comes
from, or nil.
A `Source-Rev: <sha>' trailer names it when that commit exists in the dev
checkout; else the newest local commit with the same tree does."
  (or (gethash rev claude-update--sources)
      (let* ((dirs (delete-dups
                    (append (and (file-directory-p (expand-file-name ".git" claude-update-run-dir))
                                 (list claude-update-run-dir))
                            (list claude-update-launcher-dir))))
             (body (seq-some (lambda (dir)
                               (claude-update--git-in dir (list "log" "-1" "--format=%B" rev)))
                             dirs))
             (trailer (seq-some (lambda (line)
                                  (and (string-match "\\`Source-Rev: *\\([0-9a-f]\\{7,40\\}\\)" line)
                                       (match-string 1 line)))
                                body))
             (sha (or (and trailer
                           (car (claude-update--git "rev-parse" "--verify" "--quiet"
                                                    (concat trailer "^{commit}"))))
                      (when-let* ((tree (seq-some (lambda (dir)
                                                    (car (claude-update--git-in
                                                          dir (list "rev-parse" (concat rev "^{tree}")))))
                                                  dirs)))
                        (car (seq-some (lambda (line)
                                         (and (string-suffix-p (concat " " tree) line)
                                              (split-string line)))
                                       (claude-update--git "log" "--format=%H %T" "-1000" "HEAD")))))))
        (when sha (puthash rev sha claude-update--sources))
        sha)))

(defun claude-update--staged-rev ()
  "The rev of the staged image record, or nil."
  (when-let* ((text (claude-update--read "staged.json"))
              ((string-match "\"rev\": *\"\\([0-9a-f]+\\)\"" text)))
    (match-string 1 text)))

(defun claude-update--between (from to)
  "The subjects of the commits in FROM..TO (revs of the dev checkout), newest
first; `unknown' when either end cannot be resolved to a local commit."
  (let ((from (and from (claude-update--source from)))
        (to (if (equal to "HEAD") "HEAD" (and to (claude-update--source to)))))
    (cond ((not (and from to)) 'unknown)
          ((equal from to) nil)
          (t (claude-update--git "log" "--format=%s" (format "%s..%s" from to))))))

(defun claude-update-counts ()
  "The commit counters as (:pending SUBJECTS :recreate SUBJECTS), cached for ten
seconds.
Each is a list of subjects, or `unknown' when a rev cannot be traced to a local
commit.  Recreate is the commits built and staged but not running (running rev
to staged rev); Pending is those not yet built into an image (newest built rev
to HEAD)."
  (let* ((running (claude-update--read "running-rev"))
         (staged (or (claude-update--staged-rev) running))
         (key (list running staged (claude-update--read "stage-state"))))
    (if (and claude-update--counts
             (< (- (float-time) (car claude-update--counts)) 10)
             (equal key (cadr claude-update--counts)))
        (cddr claude-update--counts)
      (let ((counts (list :pending (claude-update--between staged "HEAD")
                          :recreate (claude-update--between running staged))))
        (setq claude-update--counts (cons (float-time) (cons key counts)))
        counts))))

(defun claude-update--subjects-help (title subjects)
  "TITLE with the commit SUBJECTS under it, at most 15."
  (concat title ":\n"
          (mapconcat (lambda (line) (concat "  " line)) (seq-take subjects 15) "\n")
          (if (> (length subjects) 15) (format "\n  ... and %d more" (- (length subjects) 15)) "")))

(defun claude-update-pending-label ()
  "\"N to build\" (launcher commits not yet built into an image) with its help, or
nil at 0.
The text carries the commit subjects as its `help-echo'."
  (let ((subjects (plist-get (claude-update-counts) :pending)))
    (cond ((eq subjects 'unknown)
           (propertize "? to build" 'face 'shadow
                       'help-echo "The built image's rev matches no commit here (no Source-Rev trailer, no identical tree)"))
          (subjects
           (propertize (format "%d to build" (length subjects)) 'face 'shadow
                       'help-echo (claude-update--subjects-help "Not yet built into an image" subjects))))))

;;;; The buttons (board and update buffer)

(defvar claude-update-boot-file (expand-file-name "~/claude/.services/manager/boot")
  "The record the Manager's container writes when it starts.")

(defun claude-update--starting-p ()
  "Non-nil while the Manager's container started under five minutes ago."
  (when-let* ((attrs (file-attributes claude-update-boot-file)))
    (< (- (float-time) (float-time (file-attribute-modification-time attrs))) 300)))

(defun claude-update--restart-block ()
  "Why Recreate is disabled, as (SHORT . LONG), or nil when it may be pressed.
SHORT is a few words to show next to the button, LONG the full help text."
  (let ((busy (claude-update--busy))
        (stage (claude-update--stage)))
    (cond ((claude-update-pending-p)
           '("recreate already requested"
             . "A recreate is already requested or running"))
          ((claude-update-building-p)
           (let ((step (and (caddr stage) (not (equal (caddr stage) "0/0")) (caddr stage))))
             (cons (concat "update in progress" (if step (format " · step %s" step) ""))
                   "An image is being built: the host applies it when it is ready")))
          ((claude-update--starting-p)
           '("container still starting"
             . "The Manager's container started under five minutes ago"))
          ((eq busy 'unknown)
           '("busy state unknown"
             . "Busy state unknown (the Manager's busy list is missing or stale)"))
          (busy (cons (format "%d running: %s%s" (length busy)
                              (truncate-string-to-width (string-trim (car busy)) 40 nil nil t)
                              (if (cdr busy) "…" ""))
                      (format "Running now:\n%s"
                              (mapconcat (lambda (l) (concat "  " l)) busy "\n")))))))

(defun claude-update-restart-reason ()
  "\"Recreate off: WHY\" while Recreate is disabled, else nil."
  (when-let* ((block (claude-update--restart-block)))
    (concat "Recreate off: " (car block))))

(defun claude-update-emacs-restart-reason ()
  "\"Restart Emacs off: WHY\" while Restart Emacs is disabled, else nil."
  (unless (eq (claude-update-emacs-state) 'ready)
    (concat "Restart Emacs off: " (claude-update-emacs-label))))

(defun claude-update-buttons ()
  "Button specs for `widgetry-buttons': Recreate, a hold, disabled while work runs,
the busy state is unknown or an image builds (it spins then)."
  (let* ((block (claude-update--restart-block))
         (staged (let ((c (plist-get (claude-update-counts) :recreate))) (and (consp c) c))))
    (list (list :label (cond (staged (format "Recreate %d" (length staged)))
                             ((claude-update-staged-p) "Recreate · ready")
                             (t "Recreate"))
                :shown (lambda (widget)
                         (if (claude-update-building-p)
                             (format " %s %s " (aref claude-update--spinner
                                                     (% claude-update--spin-frame 10))
                                     (string-trim (widget-value widget)))
                           (widget-value widget)))
                :confirm 'hold :disabled (and block t)
                :help (concat (or (cdr block) "Recreate claude-manager (and the side roles) on the current image; new code comes with a home-manager switch")
                              (and staged (concat "\n" (claude-update--subjects-help
                                                        "Built, not running" staged))))
                :notify (lambda (&rest _) (claude-update-restart))))))

(defun claude-update-help-echo (group)
  "Make the segments of GROUP show their :help on hover, and all of it for
`display-local-help' (C-h .), which the keyboard reaches."
  (when-let* ((overlay (widget-get group :widgetry-overlay))
              (inner (overlay-get overlay 'help-echo)))
    (overlay-put overlay 'kbd-help
                 (mapconcat (lambda (segment)
                              (format "%s: %s" (string-trim (widget-value segment))
                                      (or (widget-get segment :help) "")))
                            (widget-get group :segments) "\n"))
    (overlay-put overlay 'help-echo
                 (lambda (&rest args)
                   (apply inner args)
                   (when-let* ((segment (ignore-errors (widgetry-buttons--pointer-segment group))))
                     (widget-get segment :help))))))

;;;; Requests

(defun claude-update--send (text)
  "Ask the host for TEXT (\"restart\" or \"restart force\"); return the request's
epoch."
  (let ((stamp (floor (float-time))))
    (if-let* ((spool (claude-update--spool)))
        (let ((id (format "cockpit-%d" stamp)))
          (write-region
           (json-serialize `((id . ,id) (kind . "recreate") (from . "cockpit") (ts . ,stamp)
                             (args . ((force . ,(if (string-suffix-p " force" text) t :false))))))
           nil (expand-file-name (format ".%s.tmp" id) spool) nil 'silent)
          (rename-file (expand-file-name (format ".%s.tmp" id) spool)
                       (expand-file-name (format "%s.json" id) spool) t)
          (setq claude-update--sent stamp))
      (write-region (format "%d %s\n" stamp text) nil claude-update-request))
    stamp))

(defun claude-update--report (stamp what)
  "Message the host's answer to STAMP; a refusal says why."
  (let ((result (claude-update--result stamp)))
    (cond ((null result) (message "%s requested; the host has not answered yet (is homun-host running? homun host show)" what))
          ((equal result "ok") (message "%s: accepted" what))
          (t (message "%s refused: %s" what result)))))

;;;###autoload
(defun claude-update ()
  "Show the update state (`claude-update-open').  Nothing updates from here: a
home-manager switch on the host does, and `claude-update-restart' recreates on
the current image."
  (interactive)
  (claude-update-open))

;;;###autoload
(defun claude-update-restart (&optional force)
  "Recreate the containers on the current image; an image a switch left staged is
taken first.
Refuses while work runs or the busy state is unknown.  With a prefix argument
FORCE, lists what will be killed and asks twice (`claude-confirm'), then
recreates anyway."
  (interactive "P")
  (cond
   ((claude-update-pending-p)
    (message "A recreate is already %s" (or (claude-update-status) "pending")))
   (t
    (let ((block (cdr (claude-update--restart-block))))
      (when (and block (not force))
        (user-error "Recreate blocked: %s (C-u M-x claude-update-restart forces)" block))
      (when (and force
                 (not (and (claude-confirm (format "FORCE recreate, killing:\n%s\nContinue? "
                                                   (or block "nothing is running")))
                           (claude-confirm "Really kill it all and recreate claude-manager? "))))
        (user-error "Not recreated"))
      (let ((stamp (claude-update--send (if force "restart force" "restart"))))
        (message "Recreate requested...")
        (run-at-time 6 nil #'claude-update--report stamp "Recreate"))))))

(define-obsolete-function-alias 'claude-restart #'claude-update-restart "2026-11-22")

;;;; The update buffer

(require 'widgetry-meter)
(require 'widgetry-buttons)
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-normal-state "evil-states")

(defconst claude-update-buffer "*claude-update*")
(defconst claude-update-log-height 12 "Lines of stage.log shown: a fixed-height box, the tail.")
(defconst claude-update--log-time "\\`\\(?:[0-9-]+[T ]\\)?[0-9]+:[0-9]+:[0-9.]+Z? "
  "A leading timestamp of a log line.")

(defun claude-update--tail (file lines)
  "The last LINES lines of FILE as a list (only its last 60 kB is read), or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil (max 0 (- (file-attribute-size (file-attributes file)) 60000)))
      (last (split-string (buffer-string) "[\n\r]+" t) lines))))

(defun claude-update--insert-log (title file lines)
  "Insert TITLE and a box of exactly LINES lines: the tail of FILE, timestamps
dimmed, errors red.
Lines are cut at the window edge, never wrapped."
  (let ((rows (claude-update--tail file lines)))
    (insert (propertize (concat "  " title "\n") 'face 'shadow))
    (dotimes (_ (- lines (length rows))) (insert "\n"))
    (dolist (row rows)
      (let ((at (if (string-match claude-update--log-time row) (match-end 0) 0)))
        (insert "  " (propertize (substring row 0 at) 'face 'shadow)
                (let ((text (substring row at)))
                  (if (string-match-p "\\<\\(?:error\\|failed\\|fatal\\)\\>" text)
                      (propertize text 'face 'error)
                    text))
                "\n")))))

(defvar claude-update-card-steps)

(defun claude-update--summary ()
  "Insert the current step with its elapsed time, the step line and the one meter."
  (if-let* ((info (claude-update-card--current))
            (phase (plist-get info :phase)))
      (progn
        (insert "  " (propertize (claude-update-card--title phase) 'face 'bold) "   "
                (propertize (claude-update-card--info info (float-time)) 'face 'shadow) "\n  "
                (mapconcat (lambda (pair)
                             (format "%s %s" (pcase (cdr pair) ('done "✓") ('now "▸") ('failed "✗") (_ "·"))
                                     (alist-get (car pair) claude-update-card-steps)))
                           (claude-update-card-step-states phase) "  ")
                "\n")
        (when (eq phase 'building)
          (insert "  " (widgetry-meter-string (claude-update-card--fraction info) 30) "\n")))
    (insert (propertize (concat "  " (or (claude-update--progress) (claude-update-status) "Up to date") "\n")
                        'face 'bold))))

;; The view lives as long as the update does.  The state files say whether it does
;; (`claude-update-card--current': building, staged, recreating); nothing else is kept
;; but the epoch the user dismissed it at.

(defvar claude-update--dismissed 0 "Epoch the user closed the view at.")
(defvar claude-update--auto nil "Non-nil when the view was opened by `claude-update-keep'.")

(defun claude-update--insert-blockers ()
  "While an image is staged, list the work that keeps it from being applied."
  (when (eq (plist-get (claude-update-card--current) :phase) 'staged)
    (let ((busy (claude-update--busy)))
      (insert (propertize "  Waiting for idle work" 'face 'bold) "\n")
      (if (eq busy 'unknown)
          (insert (propertize "    busy list unknown\n" 'face 'shadow))
        (dolist (line (or busy '("nothing running: the host applies it next")))
          (insert "    " (string-trim line) "\n")))
      (insert "\n"))))

(defun claude-update-dismiss ()
  "Close the update view for good until a newer phase starts."
  (interactive)
  (setq claude-update--dismissed (float-time))
  (when-let* ((buffer (get-buffer claude-update-buffer)))
    (if-let* ((window (get-buffer-window buffer t)))
        (quit-window t window)
      (kill-buffer buffer))))

(defun claude-update-keep ()
  "Make the view follow the update: show it in its region while a phase is
pending (unless dismissed since it began), kill it once the update is over."
  (let ((info (claude-update-card--current)))
    (cond
     ((and info (memq (plist-get info :phase) '(building staged recreating)))
      ;; The card shows the update; this only keeps the log buffer alive.  It never
      ;; puts it in a window: that swapped the stage window on every tick.
      (when (and (> (plist-get info :since) claude-update--dismissed)
                 (not (get-buffer claude-update-buffer)))
        (setq claude-update--auto t)
        (with-current-buffer (get-buffer-create claude-update-buffer)
          (unless (derived-mode-p 'claude-update-mode) (claude-update-mode))
          (claude-update--draw))
        (claude-update--ensure-timer)))
     ((and claude-update--auto (get-buffer claude-update-buffer))
      (setq claude-update--auto nil)
      (kill-buffer claude-update-buffer)))))

(defun claude-update--waiting-p ()
  (let ((status (claude-update-status)))
    (and status (string-match-p "waiting for the host" status))))

(defun claude-update--header ()
  "The header line: state and the keys, always visible."
  (let ((status (cond ((claude-update--progress)) ((claude-update-status)) (t "up to date"))))
    (concat " " (propertize "Update" 'face 'bold) " · "
            (propertize status 'face (if (string-match-p "fail\\|refused" status) 'error 'bold))
            (propertize (homun-key-hint "   SPC m r recreate · gr redraw · q close") 'face 'shadow))))

(defun claude-update--draw ()
  "Redraw `claude-update-buffer', keeping point and the window's scroll where they
were."
  (when-let* ((buffer (get-buffer claude-update-buffer)))
    (with-current-buffer buffer
      (let* ((window (get-buffer-window buffer t))
             (line (line-number-at-pos (if window (window-point window) (point))))
             (top (and window (line-number-at-pos (window-start window))))
             (inhibit-read-only t)
             (ahead (claude-update--ahead)))
        (setq widget-field-list nil widget-field-new nil)
        (erase-buffer)
        (insert "  ")
        (claude-update-help-echo (widget-create 'widgetry-buttons :buttons (claude-update-buttons)))
        (insert "\n")
        (when-let* ((reason (claude-update-restart-reason)))
          (insert (propertize (concat "  " reason "\n") 'face 'shadow)))
        (insert "\n")
        (claude-update--summary)
        (insert "\n")
        (cond ((eq ahead 'unknown)
               (insert (propertize "  Commits ahead: unknown (no running revision recorded yet)\n\n" 'face 'shadow)))
              (ahead
               (insert (propertize (format "  %d commit%s not in the image\n" (length ahead)
                                           (if (cdr ahead) "s" ""))
                                   'face 'bold))
               (dolist (l (seq-take ahead 8)) (insert "    " l "\n"))
               (insert "\n")))
        (claude-update--insert-blockers)
        (insert (propertize "  Emacs" 'face 'bold) " · " (claude-update-emacs-label) "\n  ")
        (claude-update-help-echo (widget-create 'widgetry-buttons :buttons (claude-update-emacs-buttons)))
        (insert "\n")
        (when-let* ((reason (claude-update-emacs-restart-reason)))
          (insert (propertize (concat "  " reason "\n") 'face 'shadow)))
        (insert "\n")
        (claude-update--insert-log "stage.log" (expand-file-name "stage.log" claude-update-dir)
                                   claude-update-log-height)
        (insert "\n")
        (claude-update--insert-log "emacs update.log" (claude-update-emacs--path "update.log") 5)
        (goto-char (point-min)) (forward-line (1- line))
        (when window
          (homun-layout-point window (point) (save-excursion (goto-char (point-min))
                                                   (forward-line (1- top)) (point))
                            t))
        (claude-touch)))))

(defvar claude-update-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (homun-bind-common map (lambda () (interactive) (claude-update--draw)))
    (define-key map (kbd "q") #'claude-update-dismiss)
    map))

(with-eval-after-load 'evil
  (evil-set-initial-state 'claude-update-mode 'normal)
  (evil-define-key* 'normal claude-update-mode-map (kbd "q") #'claude-update-dismiss)
  (homun-bind-leader 'claude-update-mode 'claude-update-mode-map
                     '(("r" . claude-update-restart))))

(define-derived-mode claude-update-mode nil "Update"
  "The update state: progress, the Recreate button and the live build log.
\\{claude-update-mode-map}"
  (widgetry-mode 1)
  (when (bound-and-true-p evil-local-mode) (evil-normal-state))
  (setq-local revert-buffer-function (lambda (&rest _) (claude-update--draw)))
  (setq truncate-lines t)
  (setq-local header-line-format
              '(:eval (claude-update--header))))

(defvar claude-update--redraw-timer nil)

(defun claude-update--ensure-timer ()
  "Redraw the view every 3 s while it is shown."
  (unless claude-update--redraw-timer
    (setq claude-update--redraw-timer
          (run-with-timer 3 3 (lambda ()
                                (if-let* ((b (get-buffer claude-update-buffer)))
                                    (when (get-buffer-window b t) (claude-update--draw))
                                  (cancel-timer claude-update--redraw-timer)
                                  (setq claude-update--redraw-timer nil)))))))

;;;###autoload
(defun claude-update-open ()
  "Show the update buffer in the stage region."
  (interactive)
  (with-current-buffer (get-buffer-create claude-update-buffer)
    (unless (derived-mode-p 'claude-update-mode) (claude-update-mode))
    (claude-update--draw))
  (claude-update--ensure-timer)
  (pop-to-buffer claude-update-buffer))

;;;; The update card: a system scene of the Stage while an update runs

;; While an image builds, waits to be applied or is being recreated, the scene `update' (the
;; `homun-stage-build' preset) shows in the stage region without taking focus: title and
;; launcher rev, a phase stepper, a build meter with elapsed time and ETA, and buttons
;; (Recreate now, Show log, Dismiss).  When the update is over the scene closes; a failure
;; stays until dismissed.

(defvar claude-update-card-done-for 30 "Seconds a finished update stays on the card.")
(defvar claude-update-card--dismissed 0 "Epoch of the failure the user dismissed.")
(defvar claude-update-card--timer nil)
(defconst claude-update-card-scene "update" "The id of the card's scene.")

(defun claude-update-card-phase (stage state staged now &optional _pending)
  "The phase of the update as a plist (:phase :since :step :total :failed), or nil
when idle.
STAGE is (WORD EPOCH DETAIL) of stage-state, STATE (WORD . EPOCH) of
update/state, STAGED non-nil with a staged image (it stays staged until the
image is applied).  PENDING is unused, kept for callers."
  (let ((word (car stage)) (at (cadr stage)) (detail (caddr stage)))
    (cond
     ((equal (car state) "running") (list :phase 'recreating :since (cdr state)))
     ((and (equal word "building") (< (- now at) 1800))
      (let ((n (and detail (string-match "\\`\\([0-9]+\\)/\\([0-9]+\\)\\'" detail)
                    (> (string-to-number (match-string 2 detail)) 0)
                    (cons (string-to-number (match-string 1 detail))
                          (string-to-number (match-string 2 detail))))))
        (list :phase 'building :since at :step (car n) :total (cdr n))))
     ((and (equal word "failed") (> at claude-update-card--dismissed))
      (list :phase 'failed :since at :failed t))
     ((and (equal (car state) "failed") (> (cdr state) claude-update-card--dismissed))
      (list :phase 'failed :since (cdr state) :failed t))
     (staged (list :phase 'staged :since (or at now)))
     ((and (equal (car state) "done") (< (- now (cdr state)) claude-update-card-done-for))
      (list :phase 'done :since (cdr state))))))

(defun claude-update-card--current ()
  (claude-update-card-phase (claude-update--stage) (claude-update--state) (claude-update-staged-p)
                            (float-time) (claude-update-pending-p)))

(defun claude-update-card--rev ()
  (let ((rev (or (claude-update--rev "staged.json") (claude-update--rev "running-rev"))))
    (and rev (substring rev 0 (min 8 (length rev))))))

(defconst claude-update-card-steps
  '((build . "Build") (stage . "Stage") (manager . "Recreate manager")
    (mechanic . "Recreate mechanic") (done . "Done"))
  "The steps of an update, in order.")

(defun claude-update-card-step-states (phase)
  "Each step of `claude-update-card-steps' with its state for PHASE: done, now,
next or failed.
While recreating, both recreate steps are now: the state does not say which role
rolls."
  (let ((now (pcase phase
               ('building '(build)) ('staged '(stage))
               ('recreating '(manager mechanic)) ('done nil) ('failed '(build))))
        (seen nil))
    (mapcar (lambda (step)
              (let ((key (car step)))
                (cons key
                      (cond ((eq phase 'done) 'done)
                            ((memq key now) (setq seen t) (if (eq phase 'failed) 'failed 'now))
                            (seen 'next)
                            (t 'done)))))
            claude-update-card-steps)))

(defun claude-update-card-eta (step total elapsed)
  "Seconds left at build STEP of TOTAL after ELAPSED seconds, by the pace so far,
or nil."
  (and step total (> step 0) (> total step) (> elapsed 0)
       (* (/ (float elapsed) step) (- total step))))

(defun claude-update-card--title (phase)
  (pcase phase
    ('building "Building the image") ('staged "Image staged · waits for idle work")
    ('recreating "Recreating the containers") ('done "Update done") ('failed "Update failed")))

(defun claude-update-card--mark (phase)
  "The mark of PHASE as a text node."
  (pcase phase
    ('done '((type . "text") (face . "ok") (text . "✓")))
    ('failed '((type . "text") (face . "err") (text . "✗")))
    (_ `((type . "text") (face . "now")
         (text . ,(aref claude-update--spinner (% claude-update--spin-frame 10)))))))

(defun claude-update-card--buttons (phase)
  "The buttons for PHASE: Recreate now while staged and nothing blocks it, Show
log, Dismiss."
  (delq nil
        (list (and (eq phase 'staged) (not (claude-update--restart-block))
                   '("update-recreate" "Recreate now" " ⟳ " "ok" "hold"))
              '("update-log" "Show log" " ≡ " nil nil)
              (and (eq phase 'failed) '("update-dismiss" "Dismiss" " ✗ " "err" nil)))))

(dolist (action '(("update-recreate" . claude-update-restart)
                  ("update-log" . claude-update-open)
                  ("update-dismiss" . claude-update-card-dismiss)))
  (puthash (car action) (cdr action) homun-stage-actions))

(defun claude-update-card--fraction (info)
  "The build progress of INFO, 0.0 before the first step."
  (let ((step (plist-get info :step)) (total (plist-get info :total)))
    (if step (/ (float step) total) 0.0)))

(defun claude-update-card--info (info now)
  "\"step 14/31 · 2m10s · ~2m left\" for INFO at NOW."
  (let* ((step (plist-get info :step)) (total (plist-get info :total))
         (elapsed (max 0 (- now (plist-get info :since))))
         (eta (claude-update-card-eta step total elapsed)))
    (string-join (delq nil (list (and step (format "step %d/%d" step total))
                                 (homun-stage-age elapsed)
                                 (and eta (concat "~" (homun-stage-age eta) " left"))))
                 " · ")))

(defun claude-update-card-scene (info now)
  "The card for INFO at NOW, a `homun-stage-build' scene."
  (let ((phase (plist-get info :phase)))
    (homun-stage-build
     (list (claude-update-card--mark phase)
           `((type . "text") (face . "title") (text . ,(claude-update-card--title phase)))
           `((type . "text") (face . "dim")
             (text . ,(format "  launcher %s" (or (claude-update-card--rev) "?")))))
     (mapcar (lambda (pair) (list (alist-get (car pair) claude-update-card-steps)
                                  (symbol-name (cdr pair))))
             (claude-update-card-step-states phase))
     :meter (and (eq phase 'building) (claude-update-card--fraction info))
     :info (claude-update-card--info info now)
     :note (and (eq phase 'failed) (claude-update--role-note))
     :buttons (claude-update-card--buttons phase))))

(defun claude-update-card-dismiss ()
  "Dismiss a failed update's card."
  (interactive)
  (setq claude-update-card--dismissed (float-time))
  (claude-update-card--tick))

(defun claude-update-card--tick ()
  "Show, refresh or close the card by the update's phase; keep the view with it."
  (ignore-errors (claude-update-keep))
  (ignore-errors
    (let ((open (gethash claude-update-card-scene homun-stage-scenes)))
      (if-let* ((info (claude-update-card--current)))
          (let ((root (claude-update-card-scene info (float-time))))
            (unless (and open (equal root (homun-stage-scene-root open)))
              (homun-stage-show "update" claude-update-card-scene "update" root "system"))
            (unless open (homun-stage-display claude-update-card-scene)))
        (when open (homun-stage-close "update" claude-update-card-scene))))))

(unless claude-update-card--timer
  (setq claude-update-card--timer (run-with-timer 3 3 #'claude-update-card--tick)))

(provide 'claude-update)
;;; claude-update.el ends here
