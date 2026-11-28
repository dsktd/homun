;;; claude-phone-test.el --- ERT for the phone's Now screen -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/claude-phone-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'claude-remote)
(require 'claude-remote-home)

(defmacro claude-phone-test--queue (&rest body)
  "BODY with a scratch Stage and queue state, the card guard off."
  `(let ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
         (homun-stage-scenes (make-hash-table :test #'equal))
         (homun-stage-actions (make-hash-table :test #'equal))
         (claude-approve-guard 0) (claude-approve--pending nil) (claude-approve--open nil)
         (claude-approve--shown (make-hash-table :test 'equal))
         (claude-approve--selection (widgetry-selection-create nil #'ignore)))
     (cl-letf (((symbol-function 'homun-stage-display) #'ignore)
               ((symbol-function 'homun-stage-render) #'ignore))
       ,@body)))

(ert-deftest claude-phone-request-becomes-waiting-item ()
  (claude-phone-test--queue
   (claude-approve-render '(((id . "1-1") (tool . "Bash") (summary . "ls") (risk . "read-only"))))
   (let ((item (car (claude-remote-home--items))))
     (should (equal (plist-get item :kind) "approval"))
     (should (equal (mapcar #'car (plist-get item :answers)) '("Allow" "Deny…")))
     (should (string-match-p "ls" (plist-get item :body)))
     (should (= 1 (claude-remote-home--waiting))))))

(ert-deftest claude-phone-question-choices-are-answers ()
  (claude-phone-test--queue
   (claude-approve-render
    '(((id . "1-2") (tool . "AskUserQuestion")
       (input . ((questions . [((question . "Which?") (options . [((label . "A")) ((label . "B"))]))]))))))
   (let ((item (car (claude-remote-home--items))))
     (should (equal (plist-get item :kind) "question"))
     (should (equal (mapcar #'car (plist-get item :answers)) '("A" "B" "Decline"))))))

(ert-deftest claude-phone-strip-states ()
  "The design's Top strip states: link word, 5h meter and percent, the chip hidden at 0."
  (let ((s (claude-phone-strip '(live) 0.42 3)))
    (should (string-match-p "● +live +5h .* 42%" s))
    (should (string-match-p "▲ 3 waiting" s)))
  (should-not (string-match-p "waiting" (claude-phone-strip '(live) 0.42 0)))
  (should (string-match-p "retry 7s" (claude-phone-strip '(retry . 7) nil 1)))
  (should (string-match-p "offline · 2" (claude-phone-strip '(offline . 2) 0.5 1)))
  (should (eq (get-text-property 1 'face (claude-phone-strip '(live) nil 0)) 'success))
  (should (eq (get-text-property 1 'face (claude-phone-strip '(offline . 0) nil 0)) 'error)))

(ert-deftest claude-phone-strip-taps ()
  "Tap 5h: Status; tap the chip: the approval card; tap the link word: reconnect."
  (let* (seen (claude-phone-view-function (lambda (v) (push v seen)))
         (claude-phone-reconnect-function (lambda () (push 'reconnect seen)))
         (s (claude-phone-strip '(live) 0.42 3)))
    (dolist (word '("live" "5h" "waiting"))
      (let ((map (get-text-property (string-match word s) 'keymap s)))
        (funcall (lookup-key map [header-line mouse-1]))))
    (should (equal (nreverse seen) '(reconnect status approval)))))

(ert-deftest claude-phone-tabs ()
  (let ((s (claude-phone-tabs 'board)))
    (should (string-match-p "Talk.*Board.*Status" s))
    (should (eq (get-text-property (string-match "Board" s) 'homun-button-role s) 'tab-active))
    (should (eq (get-text-property (string-match "Talk" s) 'homun-button-role s) 'tab))))

(defconst claude-phone-test--glance
  '(:usage (:five 40.0 :seven 10.0) :tasks [(:kind "subagent" :title "fix it" :age "3m")]
    :doctor (:ok nil :problem "bus stale") :roles ["manager" "mechanic"]
    :attn [(:level "nudge" :step "desk" :text "look")]))

(ert-deftest claude-phone-board-and-status-are-text ()
  (let ((claude-phone-glance claude-phone-test--glance)
        (claude-phone-role "manager") (claude-phone-unhandled '(("weird" . 2))))
    (with-current-buffer (claude-phone-show " *phone-test*" 'board nil)
      (should (string-match-p "◌  fix it" (buffer-string)))
      (should (string-match-p "running · subagent · 3m" (buffer-string))))
    (with-current-buffer (claude-phone-show " *phone-test*" 'status nil)
      (let ((text (buffer-string)))
        (should (string-match-p "5h .* 40%" text))
        (should (string-match-p "▲0 ✗1" text)) ; the problem counts as a fail, no text
        (should (string-match-p "nudge +look" text))
        (should (string-match-p "weird +2" text))
        (should (string-match-p "manager  ✎" text))
        (should (string-match-p "mechanic" text))
        (should (string-match-p "Run doctor" text))))))

(ert-deftest claude-phone-status-roles-and-doctor ()
  "Role rows take their state from the doctor's session checks; other failed checks list under DOCTOR."
  (let ((claude-phone-doctor nil)
        (claude-phone-glance '(:roles ["mechanic"] :doctor (:ok :false :problem nil)
                               :checks [(:id "mechanic.heartbeat" :name "Mechanic" :status "fail" :summary "14m")
                                        (:id "gateway.cert" :name "gateway cert" :status "warn" :summary "3 days left")])))
    (with-current-buffer (claude-phone-show " *phone-test*" 'status nil)
      (let ((text (buffer-string)))
        (should (string-match-p "fail · 14m" text))
        (should (string-match-p "▲1 ✗1" text))
        (should-not (string-match-p "3 days left" text))
        (should-not (string-match-p "Mechanic: 14m" text))))))

(ert-deftest claude-phone-glance-record-and-unhandled-count ()
  (let ((claude-phone-glance nil) (claude-remote-unhandled nil)
        (claude-remote--seen nil))
    (claude-remote--handle '(:kind "glance" :source "glance.json" :data (:tasks [])))
    (should (equal claude-phone-glance '(:tasks [])))
    (should-not claude-remote-unhandled)
    (claude-remote--handle '(:kind "novel" :source "x" :data (:a 1)))
    (should (equal claude-remote-unhandled '(("novel" . 1))))))
(defmacro claude-phone-test--dropdown (&rest body)
  "Run BODY with the dropdown's child frame faked by the selected frame; no prompt may appear."
  `(let ((claude-remote-home-role "manager") (claude-phone-glance '(:roles ["mechanic" "user" "iris"]))
         (claude-remote-home--dropdown nil) (opened 0) (prompted nil))
     (cl-letf (((symbol-function 'claude-bus-roles) (lambda () '("manager" "user")))
               ((symbol-function 'frame-toggle-on-screen-keyboard) #'ignore)
               ((symbol-function 'claude-remote-home--dropdown-open)
                (lambda () (cl-incf opened) (claude-remote-home--dropdown-buffer)
                  (setq claude-remote-home--dropdown (selected-frame))))
               ((symbol-function 'delete-frame) #'ignore)
               ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (setq prompted t) ""))
               ((symbol-function 'completing-read) (lambda (&rest _) (setq prompted t) "")))
       (unwind-protect (progn ,@body)
         (remove-hook 'pre-command-hook #'claude-remote-home--dropdown-outside)
         (when-let* ((b (get-buffer " *homun roles*"))) (kill-buffer b))))))

(ert-deftest claude-phone-dropdown-lists-roles ()
  "To opens a dropdown of the gateway's roles, one per line, left-aligned and padded to one width, the current one marked."
  (claude-phone-test--dropdown
   (call-interactively #'claude-remote-home-compose-to)
   (should (= opened 1))
   (with-current-buffer " *homun roles*"
     (should (equal (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t)
                    '(" ✓ manager  " "   mechanic " "   iris     ")))
     (should (eq (get-text-property 1 'homun-button-role) 'chip-selected)))
   (should-not prompted)))

(ert-deftest claude-phone-dropdown-pick-sets-target-and-closes ()
  (claude-phone-test--dropdown
   (call-interactively #'claude-remote-home-compose-to)
   (with-current-buffer " *homun roles*"
     (goto-char (point-min))
     (search-forward "iris") (backward-char 1)
     (call-interactively (key-binding (kbd "RET"))))
   (should (equal claude-remote-home-role "iris"))
   (should-not claude-remote-home--dropdown)
   (should-not prompted)))

(ert-deftest claude-phone-dropdown-outside-tap-closes ()
  "A tap inside the dropdown's frame leaves it open; one anywhere else closes it."
  (claude-phone-test--dropdown
   (call-interactively #'claude-remote-home-compose-to)
   (let ((last-input-event (list 'down-mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
     (claude-remote-home--dropdown-outside) ; the fake dropdown is the selected frame: inside
     (should claude-remote-home--dropdown)
     (setq claude-remote-home--dropdown 'another-frame) ; now the tap is outside
     (claude-remote-home--dropdown-outside))
   (should-not claude-remote-home--dropdown)
   (should (equal claude-remote-home-role "manager"))))

(ert-deftest claude-phone-button-tap-gives-feedback ()
  "A touch on a button says what it does at once, then the result; a failure is a message."
  (let (log)
    (cl-letf (((symbol-function 'redisplay) #'ignore)
              ((symbol-function 'message) (lambda (f &rest a) (push (apply #'format f a) log) nil)))
      (with-temp-buffer
        (claude-phone--button "Update" (lambda () (interactive) (message "homun x: 1 file updated")))
        (claude-phone--button "Boom" (lambda () (interactive) (error "no net")))
        (widget-setup)
        (goto-char (point-min))
        (let ((w (widget-at (point-min))))
          (ignore-errors (widget-apply-action w (list 'touchscreen-end)))
          (ignore-errors (widgetry-button-press)))
        (goto-char (point-min)) (search-forward "Boom")
        (ignore-errors (widgetry-button-press))))
    (setq log (nreverse log))
    (should (member "Update…" log))
    (should (member "homun x: 1 file updated" log))
    (should (member "Boom failed: no net" log))))

(ert-deftest claude-phone-widget-click-goes-through-the-gateway ()
  "A transcript widget click on the phone queues its text for the role, never running python3."
  (let (sent done (claude-transcript-widget-sender #'claude-remote--widget-send))
    (cl-letf (((symbol-function 'claude-remote--user-write) (lambda (role text) (push (list role text) sent)))
              ((symbol-function 'message) #'ignore))
      (claude-transcript--widget-send "[clicked mobile-design-first on u1]" (lambda () (setq done t)) nil
                                      '("s" "n" "click" "v")))
    (should done)
    (should (equal sent '(("manager" "[clicked mobile-design-first on u1]"))))))

(ert-deftest claude-phone-board-attention-then-tasks ()
  "The design's Board: approvals and questions, then a doctor failure, under ATTENTION with a count;
a tap on a waiting row opens the approval card."
  (let* (seen (claude-phone-view-function (lambda (v) (push v seen)))
         (claude-phone-glance claude-phone-test--glance)
         (items (list (list :title "Approve: git push" :kind "approval" :urgency 2 :age 120
                            :answers (list (cons "Approve" #'ignore)))
                      (list :title "Pick a layout" :kind "question" :urgency 2 :age 840
                            :answers (list (cons "A" #'ignore))))))
    (with-current-buffer (claude-phone-show " *phone-test*" 'board items)
      (let ((text (buffer-string)))
        (should (string-match-p "ATTENTION +3" text))
        (should (string-match-p "▲  Approve: git push" text))
        (should (string-match-p "approval · 2m · tap to answer" text))
        (should (string-match-p "?  Pick a layout" text))
        (should (string-match-p "!  Doctor: bus stale" text))
        (should (< (string-match "ATTENTION" text) (string-match "TASKS +1 running" text))))
      (goto-char (point-min)) (search-forward "Approve: git")
      (push-button)
      (should (equal seen '(approval))))))

(ert-deftest claude-phone-deny-asks-a-reason ()
  "Deny… on the phone asks why and sends it; an empty answer is a plain deny."
  (claude-phone-test--queue
   (claude-approve-render '(((id . "1-3") (tool . "Bash") (summary . "git push"))))
   (let ((item (car (claude-remote-home--items))) sent)
     (cl-letf (((symbol-function 'claude-approve-answer) (lambda (id v) (push (cons id v) sent)))
               ((symbol-function 'frame-toggle-on-screen-keyboard) #'ignore))
       (dolist (text '("use a branch" " "))
         (funcall (cdr (assoc "Deny…" (plist-get item :answers))))
         (with-current-buffer claude-phone-ask-buffer (insert text)
           (let ((header header-line-format)) ; tap Send in the header line
             (funcall (lookup-key (get-text-property (string-match "Send" header) 'keymap header) [header-line mouse-1]))))
         (should-not (get-buffer-window claude-phone-ask-buffer))))
     (should (equal (nreverse sent) '(("1-3" . "{\"behavior\":\"deny\",\"message\":\"use a branch\"}")
                                      ("1-3" . "deny")))))))

(ert-deftest claude-phone-card-pages-and-backs ()
  (let* (seen (claude-phone-view-function (lambda (v) (push v seen))) (claude-phone-card 0)
         (mk (lambda (title) (list :title title :kind "approval" :urgency 2 :age 60 :body "$ git push"
                                   :answers (list (cons "Approve" #'ignore) (cons "Deny…" #'ignore))))))
    (with-current-buffer (claude-phone-show " *phone-test*" 'approval (list (funcall mk "One") (funcall mk "Two")))
      (let ((text (buffer-string)))
        (should (string-match-p "‹ Back.*1 of 2 ›" text))
        (should (string-match-p "▲ APPROVAL" text))
        (should (< (string-match "git push" text) (string-match "Approve" text) (string-match "Deny…" text))))
      (goto-char (point-min)) (search-forward "1 of") (call-interactively (key-binding (kbd "RET")))
      (should (= claude-phone-card 1))
      (goto-char (point-min)) (call-interactively (key-binding (kbd "RET")))
      (should (equal seen '(board approval))))))

(ert-deftest claude-phone-approve-tap-sends-allow ()
  "The phone rebuilds the queue from the requests the scene record carries; a tap on
Allow, once its own guard passed, posts the allow action the gateway writes to
approve/answers/ID, and the card goes."
  (claude-phone-test--queue
   (let* ((claude-approve-answer-function #'claude-remote--approve-answer) sent
          (root (claude-approve-scene `(((id . "1-4") (tool . "Bash") (summary . "ls")
                                         (since . ,(floor (float-time))) (risk . "read-only")))
                                      0)))
     (cl-letf (((symbol-function 'claude-remote-act) (lambda (kind args &rest _) (push (cons kind args) sent))))
       (claude-remote--handle
        (list :kind "scene" :source "approve.json"
              :data (list :id "approve" :title "Permissions (1)"
                          :root (json-parse-string (homun-stage-encode root) :object-type 'plist))))
       (let ((claude-approve-guard 10))
         (funcall (cdr (assoc "Allow" (plist-get (car (claude-remote-home--items)) :answers))))
         (should-not sent))
       (let ((item (car (claude-remote-home--items))))
         (claude-phone--run "Allow" (cdr (assoc "Allow" (plist-get item :answers)))))
       (should (equal sent '(("approve" :id "1-4" :answer "allow"))))
       (should-not claude-approve--pending)))))

(ert-deftest claude-phone-doctor-no-answer-is-unknown ()
  (dolist (res '(nil (:ok nil) (:ok t :reply "") (:ok t :reply "not json")))
    (let ((c (car (claude-remote-home-doctor-checks res))))
      (should (equal (plist-get c :status) "unknown"))
      (should (equal (plist-get c :name) "doctor get"))
      (should (equal (claude-phone--status-face "unknown") 'warning)))))

(ert-deftest claude-phone-doctor-error-is-fail ()
  (let ((c (car (claude-remote-home-doctor-checks '(:ok nil :error "old gateway")))))
    (should (equal (plist-get c :status) "fail"))
    (should (equal (plist-get c :summary) "old gateway"))))

(defvar claude-doctor--data)
(defvar claude-doctor--problem)

(ert-deftest claude-glance-doctor-not-ok-without-ok-checks ()
  (require 'claude-glance)
  (dolist (data '(nil ((checks)) ((checks . (((id . "a") (status . "ok")) ((id . "b") (status . "unknown")))))))
    (let ((claude-doctor--data data) (claude-doctor--problem nil))
      (should (eq (plist-get (plist-get (claude-glance-data) :doctor) :ok) :false))))
  (let ((claude-doctor--data '((checks . (((id . "a") (status . "ok")))))) (claude-doctor--problem nil))
    (should (eq (plist-get (plist-get (claude-glance-data) :doctor) :ok) t))))

(ert-deftest claude-phone-text-size-steps-and-persists ()
  (let* ((claude-remote-dir (file-name-as-directory (make-temp-file "ts" t)))
         (claude-remote-home--text-default nil)
         (before (progn (set-face-attribute 'default nil :height 130) 130)))
    (unwind-protect
        (progn
          (claude-remote-home-text-step 1)
          (should (> (claude-remote-home-text-size) before))
          (should (equal (with-temp-buffer (insert-file-contents (claude-remote-home--text-file))
                                           (read (current-buffer)))
                         (claude-remote-home-text-size)))
          (set-face-attribute 'default nil :height before)
          (claude-remote-home-text-restore)
          (should (> (claude-remote-home-text-size) before))
          (claude-remote-home-text-step 0)
          (should (= (claude-remote-home-text-size) before)))
      (set-face-attribute 'default nil :height before))))

(ert-deftest claude-phone-bottom-bar-keeps-all-pills-at-largest-step ()
  (let ((claude-remote-home--text-default nil)
        (claude-remote-dir (file-name-as-directory (make-temp-file "ts" t)))
        (before (progn (set-face-attribute 'default nil :height 130) 130)))
    (unwind-protect
        (with-temp-buffer
          (claude-remote-home--text-set (cdr claude-remote-home-text-range))
          (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 20)))
            (let ((bar (claude-remote-home-tabs)))
              (dolist (l '("T" "B" "S"))
                (should (string-match-p (regexp-quote l) bar))))))
      (set-face-attribute 'default nil :height before))))

(ert-deftest claude-phone-buttons-keep-size-at-small-text ()
  (let ((before (face-attribute 'default :height nil t))
        (claude-remote-home--text-default nil)
        (claude-remote-dir (file-name-as-directory (make-temp-file "ts" t))))
    (unwind-protect
        (with-temp-buffer
          (claude-remote-home--text-set 100)
          (dolist (role homun-button-roles)
            (should (= 130 (face-attribute (intern (format "homun-button-%s" role)) :height nil t))))
          (let ((bar (claude-remote-home-tabs)))
            (dolist (l '("T" "B" "S"))
              (should (string-match-p (regexp-quote l) bar)))))
      (set-face-attribute 'default nil :height before))))

(ert-deftest claude-phone-task-detail-fetches-and-sets-through-the-gateway ()
  (let ((claude-remote-home--view 'board) (claude-phone-view 'board) acts
        (claude-phone-seen-file nil) (claude-phone--seen nil) (claude-phone--seen-loaded t)
        (claude-remote-home-buffer "*homun-detail-test*"))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-remote-act)
                   (lambda (_kind _args argv &optional cb &rest _) (push (cons argv cb) acts)))
                  ((symbol-function 'claude-remote-home) (lambda () (get-buffer-create claude-remote-home-buffer)
                                                           (claude-remote-home-draw))))
          (get-buffer-create claude-remote-home-buffer)
          (claude-remote-home-task '(:title "agent" :kind "subagent" :state "running" :last "tool: ls" :tracker 7))
          (should (equal '("tracker" "show" "id" "7") (car (car acts))))
          (funcall (cdr (car acts))
                   (list :ok t :reply "{\"id\":7,\"title\":\"Fix it\",\"state\":\"TODO\",\"tags\":[\"a\"],\"body\":\"B\",\"notes\":[],\"branches\":[]}"))
          (with-current-buffer claude-remote-home-buffer
            (should (string-match-p "Fix it" (buffer-string)))
            (should (string-match-p "tool: ls" (buffer-string)))
            (goto-char (point-min))
            (search-forward "Done")
            (funcall (lookup-key (get-text-property (1- (point)) 'keymap) (kbd "RET"))))
          (should (equal '("tracker" "state" "id" "7" "state" "done") (car (car acts)))))
      (kill-buffer claude-remote-home-buffer))))

(ert-deftest claude-phone-transcript-record-is-not-unhandled ()
  "A transcript record is written to its file, so it is not counted as unhandled."
  (let ((claude-remote-unhandled nil) (claude-remote--seen nil)
        (dir (make-temp-file "rt" t)))
    (cl-letf (((symbol-function 'claude-remote--transcript) #'ignore))
      (claude-remote--handle '(:kind "transcript" :source "s" :data (:id "1")))
      (claude-remote--handle '(:kind "transcript" :source "s" :data (:id "2"))))
    (delete-directory dir t)
    (should-not claude-remote-unhandled)))

(ert-deftest claude-phone-status-lists-unhandled-kinds-one-per-line ()
  (let ((claude-phone-glance '(:roles ["m"])) (claude-phone-unhandled '(("a" . 3) ("b" . 12))))
    (with-current-buffer (claude-phone-show " *phone-test*" 'status nil)
      (let ((text (buffer-string)))
        (should (string-match-p "^ *a +3$" text))
        (should (string-match-p "^ *b +12$" text))))))

(ert-deftest claude-phone-handled-kinds-are-never-counted ()
  "Every kind in the dispatch table is handled, so none is counted as unhandled."
  (let ((claude-remote-unhandled nil))
    (cl-letf (((symbol-function 'claude-remote--on-bus) #'ignore)
              ((symbol-function 'claude-remote--on-transcript) #'ignore)
              ((symbol-function 'claude-remote--widget) #'ignore)
              ((symbol-function 'claude-remote--approve-scene) #'ignore)
              ((symbol-function 'claude-remote--approve-closed) #'ignore)
              ((symbol-function 'homun-stage-parse) #'identity)
              ((symbol-function 'claude-transcript-stream-set) #'ignore)
              ((symbol-function 'require) #'ignore))
      (dolist (entry claude-remote--handlers)
        (claude-remote--dispatch (car entry) "a.json" '(:a 1))))
    (should-not claude-remote-unhandled)))

(ert-deftest claude-phone-unknown-kind-is-counted ()
  (let ((claude-remote-unhandled nil))
    (claude-remote--dispatch "novel" "x" '(:a 1))
    (claude-remote--dispatch "novel" "x" '(:a 1))
    (should (equal claude-remote-unhandled '(("novel" . 2))))))

(ert-deftest claude-phone-doctor-reads-the-printed-gateway-reply ()
  (let ((c (car (claude-remote-home-doctor-checks
                 '(:ok t :reply "\"ok\\n{\\\"checks\\\":[{\\\"id\\\":\\\"a\\\",\\\"name\\\":\\\"a\\\",\\\"status\\\":\\\"ok\\\",\\\"summary\\\":\\\"s\\\"}]}\"")))))
    (should (equal (plist-get c :status) "ok")))
  (let ((c (car (claude-remote-home-doctor-checks '(:ok t :reply "\"err 1\\nboom\"")))))
    (should (equal (plist-get c :status) "unknown"))))

(ert-deftest claude-remote-home-loads-the-task-detail-renderer ()
  (should (featurep 'claude-task-detail))
  (should (fboundp 'claude-task-detail-insert)))

;;; The doctor strip and the service status view

(defun claude-phone-test--checks ()
  (list (list :id "a" :name "alpha" :area "Services" :status "fail" :summary "down" :hint "restart it" :open "/tmp/a.log")
        (list :id "b" :name "beta" :area "Services" :status "ok" :summary "up")
        (list :id "c" :name "gamma" :area "Host" :status "warn" :summary "low")))

(defun claude-phone-test--render (view)
  (let ((claude-phone-glance '(:roles [] :doctor (:ok :false)))
        (claude-phone-doctor (cons (float-time) (claude-phone-test--checks)))
        (claude-phone-role "x") (claude-phone-role-function #'ignore))
    (with-current-buffer (claude-phone-show " *phone-test*" view nil) (buffer-string))))

(ert-deftest claude-phone-status-doctor-is-a-strip ()
  (let ((text (claude-phone-test--render 'status)))
    (should (string-match-p "▲1 ✗1" text))
    (should-not (string-match-p "down\\|every check ok" text))
    (should (string-match-p "●C" text))))

(ert-deftest claude-phone-strip-glyph-faces-and-taps ()
  (let* ((claude-phone-glance '(:roles [] :doctor (:ok :false)))
         (claude-phone-doctor (cons (float-time) (claude-phone-test--checks)))
         seen (claude-phone-view-function (lambda (v) (push (cons v claude-phone-services-area) seen)))
         (claude-phone-role "x") (claude-phone-role-function #'ignore))
    (with-current-buffer (claude-phone-show " *phone-test*" 'status nil)
      (goto-char (point-min)) (search-forward "▲H")
      (should (memq 'warning (ensure-list (get-text-property (- (point) 2) 'face))))
      (push-button (- (point) 2))
      (search-forward "✗S")
      (should (memq 'shadow (ensure-list (get-text-property (1- (point)) 'face))))
      (should (memq 'error (ensure-list (get-text-property (- (point) 2) 'face))))
      (search-forward "▲1") (push-button (1- (point))))
    (should (equal (reverse seen) '((services . "Host") (services))))))

(ert-deftest claude-phone-services-rows-expand ()
  (let* ((claude-phone-services-open nil) (claude-phone-services-area "Host") seen
         (claude-phone-view-function (lambda (v) (push v seen))))
    (let ((text (claude-phone-test--render 'services)))
      (should (string-match-p "alpha" text)) (should (string-match-p "fail · down" text))
      (should-not (string-match-p "restart it" text)))
    (claude-phone--toggle-check "a")
    (let ((text (claude-phone-test--render 'services)))
      (should (string-match-p "restart it" text)) (should (string-match-p "/tmp/a.log" text)))
    (claude-phone--toggle-check "a")
    (should-not claude-phone-services-open)
    (should (equal seen '(services services)))))

;;; The update line on Status

(ert-deftest claude-phone-update-line-states ()
  (should-not (claude-phone-update-line nil 1000))
  (should-not (claude-phone-update-line :null 1000))
  (should (equal (claude-phone-update-line '(:phase "building" :since 880 :step 10 :total 30 :rev "abc12345") 1000)
                 "building · step 10/30 · 2m00s · ~4m left · launcher abc12345"))
  (should (equal (claude-phone-update-line '(:phase "building" :since 990 :step nil :total nil :rev nil) 1000)
                 "building · 0m10s"))
  (should (equal (claude-phone-update-line '(:phase "staged" :since 900 :rev "abc12345") 1000)
                 "staged, waiting · launcher abc12345"))
  (should (equal (claude-phone-update-line '(:phase "recreating" :since 940) 1000) "recreating · 1m00s"))
  (should (equal (claude-phone-update-line '(:phase "failed" :since 940) 1000) "failed")))

(ert-deftest claude-phone-update-section-hidden-when-idle ()
  (with-temp-buffer
    (let ((claude-phone-recreate-function #'ignore))
      (claude-phone--update '(:update :null))
      (should (equal (buffer-string) ""))
      (claude-phone--update (list :update (list :phase "staged" :since 1 :rev "abc")))
      (should (string-match-p "UPDATE" (buffer-string)))
      (should (string-match-p "Recreate" (buffer-string)))
      (erase-buffer)
      (claude-phone--update (list :update (list :phase "building" :since 1)))
      (should-not (string-match-p "Recreate" (buffer-string))))))
