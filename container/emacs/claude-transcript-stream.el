;;; claude-transcript-stream.el --- The reply being written, live in the transcript -*- lexical-binding: t -*-

;; A headless Manager's broker writes stream-json with partial messages to
;; ~/claude/.services/manager/stream/stream.jsonl.  The transcript buffer itself follows the
;; session file, which only gets finished messages; this file adds one "streaming" entry at
;; the transcript's live position that grows with the text deltas and goes once the finished
;; message lands (or the turn ends, is interrupted or the session restarts).
;;
;; Two feeds set the same state: on the desktop a file watch on stream.jsonl folds its new
;; records (`claude-transcript-stream-fold'); on the phone the cockpit gateway sends a
;; coalesced `live' record (`claude-transcript-stream-set').  Redraws run on `homun-clock', at
;; most once per `claude-transcript-stream-interval' seconds.  A stream event no branch knows
;; is counted and appended to the stream's unhandled.jsonl; every other record is drawn by the
;; transcript from the session file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'homun-clock)

(declare-function claude-transcript--live-position "claude-transcript")
(declare-function claude-transcript--insert-assistant "claude-transcript")
(defvar claude-transcript--last)
(defvar claude-transcript--code-memo)
(defvar magit-root-section)
(defvar magit-insert-section--parent)
(declare-function claude-transcript--keeping-windows "claude-transcript")
(declare-function claude-transcript--main-buffer-p "claude-transcript")
(declare-function homun-stage-agent--read "homun-stage-agent")
(declare-function homun-stage-agent--start "homun-stage-agent")
(declare-function homun-stage-agent--kind "homun-stage-agent")
(declare-function homun-stage-agent--unhandled "homun-stage-agent")
(defvar claude-transcript-phone)

(defvar claude-transcript-stream-dir (expand-file-name "~/claude/.services/manager/stream/")
  "The Manager's headless stream directory (stream.jsonl, turns, unhandled.jsonl).")

(defvar claude-transcript-stream-interval 0.1
  "Seconds between redraws of the streaming entry: at most 10 per second.")

(defvar claude-transcript-stream-linger 3
  "Seconds a finished block stays shown when no finished entry replaces it.")

(defvar claude-transcript-stream-chars 6000 "Characters of the block in progress shown.")

(defvar claude-transcript-stream-handled
  '("stream_event/content_block_start" "stream_event/content_block_delta/text_delta"
    "stream_event/content_block_delta/thinking_delta" "stream_event/content_block_delta/input_json_delta"
    "stream_event/content_block_delta/signature_delta" "stream_event/content_block_stop"
    "stream_event/message_start" "stream_event/message_delta" "stream_event/message_stop"
    "stream_event/ping")
  "Stream event kinds this view folds; see
design/homun-generic/experiments/headless/events.md.")

;;;; State

(defvar claude-transcript-stream--text "" "The block being written.")
(defvar claude-transcript-stream--state 'idle "idle, streaming or done.")
(defvar claude-transcript-stream--done-at nil "When the block finished.")
(defvar claude-transcript-stream--at nil "When the newest delta was written (sender's clock).")
(defvar claude-transcript-stream--drawn nil "Non-nil when the buffers need no redraw.")
(defvar claude-transcript-stream--drawn-at 0 "When the entry was last drawn.")
(defvar claude-transcript-stream--timer nil "A one-shot redraw while the clock is paused.")
(defvar claude-transcript-stream--memo (make-hash-table :test #'equal)
  "The reply's code blocks as formatted, so a redraw fontifies only the block that
grows.")
(defvar-local claude-transcript-stream--span nil
  "(START . END) markers of the streaming entry in this buffer, or nil: erasing it
scans nothing.")
(defvar claude-transcript-stream-unhandled 0 "Stream events this view did not know.")
(defvar claude-transcript-stream-latency nil
  "Seconds from the newest delta's arrival to its redraw, at the last
redraw (phone: from the gateway's fold).")

(defun claude-transcript-stream--change (text state &optional at)
  "Set the block to TEXT in STATE (AT: when its newest part was written) and ask
for a redraw."
  (unless (and (equal text claude-transcript-stream--text) (eq state claude-transcript-stream--state))
    (when (eq state 'idle) (clrhash claude-transcript-stream--memo))
    (setq claude-transcript-stream--text text
          claude-transcript-stream--done-at (and (eq state 'done) (float-time))
          claude-transcript-stream--state state
          claude-transcript-stream--at (or at (float-time))
          claude-transcript-stream--drawn nil)
    (claude-transcript-stream--wake)))

(defun claude-transcript-stream-clear ()
  "Drop the block: the turn ended, was interrupted or the session restarted."
  (claude-transcript-stream--change "" 'idle))

;;;; Folding the stream (desktop)

(defvar claude-transcript-stream--run (list :log nil)
  "The plist `homun-stage-agent--unhandled' counts into.")

(defun claude-transcript-stream--event (event text)
  "TEXT grown by the stream EVENT, or nil when EVENT starts nothing and adds
nothing."
  (let-alist event
    (pcase .type
      ("message_start" "")
      ("content_block_start"
       (concat text (if (string-empty-p text) "" "\n")
               (pcase .content_block.type
                 ("tool_use" (format "⚙ %s " .content_block.name))
                 ("thinking" "∴ ")
                 (_ ""))))
      ("content_block_delta"
       (when-let* ((more (or .delta.text .delta.thinking)))
         (claude-transcript-stream--grow text more))))))

(defun claude-transcript-stream--grow (text more)
  "TEXT and MORE, cut to its last `claude-transcript-stream-chars' once twice as
long.
Only that tail is shown, so a long reply costs each delta no more than the tail."
  (let ((text (concat text more)))
    (if (> (length text) (* 2 claude-transcript-stream-chars))
        (substring text (- (length text) claude-transcript-stream-chars))
      text)))

(defun claude-transcript-stream-fold (records)
  "Fold the stream RECORDS into the block.
`assistant' finishes it (the transcript draws the finished message); `result',
an interrupt and a session's `system/init' drop it."
  (let ((text claude-transcript-stream--text) (state claude-transcript-stream--state))
    (dolist (rec records)
      (let ((kind (homun-stage-agent--kind rec)))
        (cond
         ((alist-get 'parent_tool_use_id rec))  ; a subagent's: its own transcript
         ((string-prefix-p "stream_event" kind)
          (if (not (member kind claude-transcript-stream-handled))
              (progn (cl-incf claude-transcript-stream-unhandled)
                     (homun-stage-agent--unhandled claude-transcript-stream--run rec kind))
            (when-let* ((more (claude-transcript-stream--event (alist-get 'event rec)
                                                               (if (eq state 'streaming) text ""))))
              (setq text more state 'streaming))))
         ((equal kind "assistant") (when (eq state 'streaming) (setq state 'done)))
         ((or (string-prefix-p "result" kind) (equal kind "system/init"))
          (setq text "" state 'idle)))))
    (claude-transcript-stream--change text state)))

(defvar claude-transcript-stream--offset nil "Bytes of stream.jsonl folded.")
(defvar claude-transcript-stream--watch nil)

(defun claude-transcript-stream--file ()
  (expand-file-name "stream.jsonl" claude-transcript-stream-dir))

(defun claude-transcript-stream--read ()
  "Fold what stream.jsonl gained.  A shorter file is a new stream: start at its
end."
  (require 'homun-stage-agent)
  (let* ((file (claude-transcript-stream--file))
         (size (file-attribute-size (file-attributes file))))
    (when size
      (when (< size (or claude-transcript-stream--offset 0))
        (claude-transcript-stream-clear)
        (setq claude-transcript-stream--offset size))
      (when (> size claude-transcript-stream--offset)
        (pcase-let ((`(,records . ,offset)
                     (homun-stage-agent--read file claude-transcript-stream--offset)))
          (setq claude-transcript-stream--offset offset)
          (claude-transcript-stream-fold records))))))

(defun claude-transcript-stream-follow ()
  "Follow the Manager's stream, when it runs headless.  Start at its unfinished
turn, so a block begun before a daemon restart shows whole."
  (when (and (not claude-transcript-stream--watch)
             (not (bound-and-true-p claude-transcript-phone))
             (file-readable-p (claude-transcript-stream--file)))
    (require 'homun-stage-agent)
    (setq claude-transcript-stream--run
          (list :log (expand-file-name "unhandled.jsonl" claude-transcript-stream-dir))
          claude-transcript-stream--offset (homun-stage-agent--start claude-transcript-stream-dir 0)
          claude-transcript-stream--watch
          (file-notify-add-watch (claude-transcript-stream--file) '(change)
                                 (lambda (_event) (ignore-errors (claude-transcript-stream--read)))))
    (claude-transcript-stream--read)))

(defun claude-transcript-stream-unfollow ()
  (when claude-transcript-stream--watch
    (file-notify-rm-watch claude-transcript-stream--watch)
    (setq claude-transcript-stream--watch nil)))

;;;; The gateway's live record (phone)

(defun claude-transcript-stream-set (data)
  "Show the gateway's live record DATA, a plist (:text :state :at)."
  (claude-transcript-stream--change
   (or (plist-get data :text) "")
   (pcase (plist-get data :state) ("streaming" 'streaming) ("done" 'done) (_ 'idle))
   (plist-get data :at)))

;;;; Drawing

(defun claude-transcript-stream--buffer-p ()
  "Non-nil when the current buffer shows the reply being written."
  (and (eq major-mode 'claude-transcript-mode)
       (or (bound-and-true-p claude-transcript-phone) (claude-transcript--main-buffer-p))))

(defun claude-transcript-stream-erase ()
  "Remove the streaming entry from the current buffer."
  (when-let* ((span claude-transcript-stream--span))
    (setq claude-transcript-stream--span nil)
    (let ((inhibit-read-only t))
      (when (marker-buffer (car span))
        (delete-region (car span) (cdr span))))
    (set-marker (car span) nil)
    (set-marker (cdr span) nil)))

(defun claude-transcript-stream--entry ()
  "The block as an `assistant' entry, as the transcript file will hold it, or nil
when empty."
  (let ((text claude-transcript-stream--text))
    (unless (or (eq claude-transcript-stream--state 'idle) (string-empty-p text))
      `((type . "assistant") (uuid . "streaming")
        (timestamp . ,(format-time-string "%FT%TZ" nil t))
        (message . ((content . [((type . "text")
                                 (text . ,(substring text (max 0 (- (length text)
                                                                    claude-transcript-stream-chars)))))])))))))

(defun claude-transcript-stream-draw ()
  "Put the streaming entry of the current buffer at its live position.
It is drawn by the code that draws the finished message, so name row, faces and
markdown are the same from the first delta; the swap changes nothing visible."
  (claude-transcript-stream-erase)
  ;; The cut first block takes a new key at each cut: keep the table small
  (when (> (hash-table-count claude-transcript-stream--memo) 200)
    (clrhash claude-transcript-stream--memo))
  (when-let* ((entry (claude-transcript-stream--entry)))
    (let ((inhibit-read-only t)
          (claude-transcript--last claude-transcript--last)
          ;; A section of its own, outside the transcript's tree
          (magit-root-section magit-root-section)
          (magit-insert-section--parent nil)
          (claude-transcript--code-memo claude-transcript-stream--memo))
      (save-excursion
        (goto-char (claude-transcript--live-position))
        (let ((start (point)))
          (claude-transcript--insert-assistant entry)
          (add-text-properties start (point) '(claude-transcript-streaming t read-only t))
          (setq claude-transcript-stream--span (cons (copy-marker start t) (point-marker))))))))

(defun claude-transcript-stream-landed ()
  "A finished entry landed in the transcript: a done block has been replaced by it."
  (when (eq claude-transcript-stream--state 'done)
    (clrhash claude-transcript-stream--memo)
    (setq claude-transcript-stream--text "" claude-transcript-stream--state 'idle
          claude-transcript-stream--drawn nil)))

(defun claude-transcript-stream--redraw ()
  (let ((now (float-time)))
    (setq claude-transcript-stream--drawn t claude-transcript-stream--drawn-at now
          claude-transcript-stream-latency (and claude-transcript-stream--at
                                                (- now claude-transcript-stream--at)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (claude-transcript-stream--buffer-p)
          (ignore-errors
            (claude-transcript--keeping-windows 0 #'claude-transcript-stream-draw)))))))

(defun claude-transcript-stream-tick (&optional _snap)
  "Redraw when the block changed and the interval passed; non-nil while there is
more to draw."
  (when (and (eq claude-transcript-stream--state 'done)
             (> (- (float-time) claude-transcript-stream--done-at) claude-transcript-stream-linger))
    (claude-transcript-stream-landed))
  (unless claude-transcript-stream--drawn
    (when (>= (- (float-time) claude-transcript-stream--drawn-at) claude-transcript-stream-interval)
      (claude-transcript-stream--redraw)))
  (or (not claude-transcript-stream--drawn) (eq claude-transcript-stream--state 'done)))

(defun claude-transcript-stream--wake ()
  "Ask the clock for frames; while it is paused (an unfocused frame), one timer
stands in."
  (homun-clock-register 'claude-transcript-stream #'claude-transcript-stream-tick)
  (when (and (fboundp 'homun-clock--paused-p) (homun-clock--paused-p)
             (not (timerp claude-transcript-stream--timer)))
    (setq claude-transcript-stream--timer
          (run-at-time claude-transcript-stream-interval nil
                       (lambda ()
                         (setq claude-transcript-stream--timer nil)
                         (when (claude-transcript-stream-tick) (claude-transcript-stream--wake)))))))

(provide 'claude-transcript-stream)
;;; claude-transcript-stream.el ends here
