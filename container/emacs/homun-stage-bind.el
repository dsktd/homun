;;; homun-stage-bind.el --- Live {bind} values: publish, redraw per frame, stale alarms -*- lexical-binding: t -*-

;; `homun-stage-publish' sets a topic's value; scenes bound to it redraw on the next
;; homun-clock frame (coalesced).  The bus feed tails ~/claude/.services/bus/stage/inbox.jsonl:
;; `homun-msg send stage <topic> <json>' publishes <json> under <topic>.  A scene with stale_ms
;; whose bound topic is silent that long is hatched and raises `alarm.stale' once.

;;; Code:

(require 'cl-lib)
(require 'homun-clock)
(require 'homun-stage)
(require 'homun-stage-store)

(defvar homun-stage-bind--times (make-hash-table :test #'equal) "Topic to its last publish time.")
(defvar homun-stage-bind--born (make-hash-table :test #'equal) "Scene id to when its watch began.")
(defvar homun-stage-bind--dirty nil "Scene ids to redraw on the next frame.")
(defvar homun-stage-bind--alarmed nil "Topics already alarmed, until published again.")
(defvar homun-stage-bind--timer nil)
(defvar homun-stage-bind-alarm-function
  (lambda (msg) (require 'claude-bus) (claude-bus-send "user" "alarm.stale" msg))
  "Called with the alarm text.")
(defvar homun-stage-bind-time-function #'float-time)

(defun homun-stage-bind--now () (funcall homun-stage-bind-time-function))

(defun homun-stage-bind--scenes-of (topic)
  (cl-loop for s being the hash-values of homun-stage-scenes
           when (member topic (homun-stage--topics (homun-stage-scene-root s))) collect s))

(defun homun-stage-publish (topic value)
  "Set TOPIC to VALUE and redraw the scenes bound to it on the next frame."
  (puthash topic value homun-stage-bindings)
  (puthash topic (homun-stage-bind--now) homun-stage-bind--times)
  (setq homun-stage-bind--alarmed (delete topic homun-stage-bind--alarmed)
        homun-stage-stale (delete topic homun-stage-stale))
  (dolist (s (homun-stage-bind--scenes-of topic))
    (cl-pushnew (homun-stage-scene-id s) homun-stage-bind--dirty :test #'equal))
  (homun-clock-register 'stage-bind #'homun-stage-bind--frame)
  (homun-stage-bind--arm))

(defun homun-stage-bind--render (id)
  (when-let* ((s (gethash id homun-stage-scenes))) (homun-stage-render s)))

(defun homun-stage-bind--frame (_snap)
  "The clock client: redraw the dirty scenes; always nil (idle until the next
publish)."
  (let ((ids homun-stage-bind--dirty))
    (setq homun-stage-bind--dirty nil)
    (mapc #'homun-stage-bind--render ids))
  nil)

(defun homun-stage-bind--silent (s now)
  "The bound topics of scene S that have been silent for its stale_ms."
  (when-let* ((ms (homun-stage-scene-stale-ms s)))
    (let ((born (gethash (homun-stage-scene-id s) homun-stage-bind--born now)))
      (cl-remove-if-not
       (lambda (topic) (> (* 1000 (- now (max born (gethash topic homun-stage-bind--times 0)))) ms))
       (homun-stage--topics (homun-stage-scene-root s))))))

(defun homun-stage-bind-check ()
  "Hatch the silent bindings and alarm once per silent topic; rearm for the next
deadline."
  (setq homun-stage-bind--timer nil)
  (let ((now (homun-stage-bind--now)))
    (cl-loop for s being the hash-values of homun-stage-scenes
             do (dolist (topic (homun-stage-bind--silent s now))
                  (unless (member topic homun-stage-stale)
                    (push topic homun-stage-stale)
                    (cl-pushnew (homun-stage-scene-id s) homun-stage-bind--dirty :test #'equal))
                  (unless (member topic homun-stage-bind--alarmed)
                    (push topic homun-stage-bind--alarmed)
                    (funcall homun-stage-bind-alarm-function
                             (format "stale: scene %s, topic %s silent over %d ms"
                                     (homun-stage-scene-id s) topic (homun-stage-scene-stale-ms s))))))
    (when homun-stage-bind--dirty
      (homun-clock-register 'stage-bind #'homun-stage-bind--frame))
    (homun-stage-bind--arm)))

(defun homun-stage-bind--arm ()
  "One timer, at the earliest deadline of a live (not yet silent) binding."
  (when homun-stage-bind--timer (cancel-timer homun-stage-bind--timer) (setq homun-stage-bind--timer nil))
  (let ((now (homun-stage-bind--now)) next)
    (cl-loop for s being the hash-values of homun-stage-scenes
             for ms = (homun-stage-scene-stale-ms s)
             when ms
             do (dolist (topic (homun-stage--topics (homun-stage-scene-root s)))
                  (unless (member topic homun-stage-stale)
                    (let ((at (+ (max (gethash (homun-stage-scene-id s) homun-stage-bind--born now)
                                      (gethash topic homun-stage-bind--times 0))
                                 (/ ms 1000.0))))
                      (when (or (null next) (< at next)) (setq next at))))))
    (when (and next (not (bound-and-true-p homun-stage-bind--no-timer)))
      (setq homun-stage-bind--timer
            (run-at-time (max 0.05 (+ 0.01 (- next now))) nil #'homun-stage-bind-check)))))

(defun homun-stage-bind-watch (s)
  "Begin the stale watch of the scene S (called when it is shown)."
  (puthash (homun-stage-scene-id s) (homun-stage-bind--now) homun-stage-bind--born)
  (homun-stage-bind--arm))

(add-hook 'homun-stage-shown-hook #'homun-stage-bind-watch)

;;; The bus feed

(defvar homun-stage-bind--tail nil)

(defun homun-stage-bind--message (m)
  "Publish the bus message M: its alarm is the topic, its msg the JSON value."
  (let ((topic (plist-get m :alarm)) (msg (plist-get m :msg)))
    (when (and (stringp topic) (string-match-p "\\`\\(stage\\|state\\)\\." topic) (stringp msg))
      (homun-stage-publish
       topic (condition-case nil (json-parse-string msg :object-type 'alist :null-object nil :false-object :false)
               (error msg))))))

(defun homun-stage-bind-start ()
  "Follow the stage topic inbox of the bus."
  (require 'claude-bus)
  (unless homun-stage-bind--tail
    (setq homun-stage-bind--tail
          (claude-bus-tail (claude-bus-path "stage" "inbox.jsonl") #'homun-stage-bind--message
                           :cursor "stage"))))

(provide 'homun-stage-bind)
;;; homun-stage-bind.el ends here
