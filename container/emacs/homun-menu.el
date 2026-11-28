;;; homun-menu.el --- the ? menu of the transcript, board, compose, Stage, doctor, phone and questions -*- lexical-binding: t -*-
;; Each view lists its keys in a transient; every entry is a plain command, so the keys and the
;; menu cannot disagree.  `describe-mode' stays one key away (h).
(require 'transient)

(autoload 'claude-transcript-visit "claude-transcript" nil t)
(autoload 'claude-transcript-copy-block "claude-transcript" nil t)
(autoload 'claude-transcript-search "claude-transcript" nil t)
(autoload 'claude-transcript-past "claude-transcript-past" nil t)
(autoload 'claude-transcript-refresh "claude-transcript" nil t)
(autoload 'claude-transcript-toggle-follow "claude-transcript" nil t)
(autoload 'claude-transcript-goto-end "claude-transcript" nil t)
(autoload 'claude-transcript-focus "claude-transcript-focus" nil t)
(dolist (command '(homun-iface-next homun-iface-previous homun-iface-next-turn
                   homun-iface-previous-turn homun-iface-next-item homun-iface-copy
                   homun-iface-open homun-iface-to-normal))
  (autoload command "homun-iface" nil t))
(autoload 'claude-board-open "claude-board" nil t)
(autoload 'claude-board-open-todo "claude-board" nil t)
(autoload 'claude-board-stop "claude-board" nil t)
(autoload 'claude-board-toggle-activity-detail "claude-board" nil t)
(autoload 'claude-board-toggle-column "claude-board" nil t)
(autoload 'claude-board-toggle-finished "claude-board" nil t)
(autoload 'claude-compose-send "claude-compose" nil t)
(autoload 'claude-compose-cancel "claude-compose" nil t)
(autoload 'claude-compose-previous "claude-compose" nil t)
(autoload 'claude-compose-next "claude-compose" nil t)
(autoload 'claude-compose-retry "claude-compose" nil t)
(autoload 'claude-compose-drop "claude-compose" nil t)
(autoload 'homun-stage-close-this "homun-stage-store" nil t)
(autoload 'homun-stage-pin-this "homun-stage-store" nil t)
(autoload 'homun-stage-scrub-back "homun-stage-store" nil t)
(autoload 'homun-stage-scrub-forward "homun-stage-store" nil t)
(autoload 'homun-stage-rows-open-at-point "homun-stage-rows" nil t)
(autoload 'homun-stage-rows-up "homun-stage-rows" nil t)
(autoload 'homun-stage-rows-down "homun-stage-rows" nil t)
(autoload 'homun-stage-rows-done-at-point "homun-stage-rows" nil t)
(autoload 'claude-doctor "claude-doctor" nil t)
(autoload 'claude-doctor-refresh "claude-doctor" nil t)
(declare-function homun-update "init")
(autoload 'claude-phone-talk "claude-phone" nil t)
(autoload 'claude-phone-board "claude-phone" nil t)
(autoload 'claude-phone-status "claude-phone" nil t)
(autoload 'claude-questions-menu "claude-questions" nil t)

;;;###autoload (autoload 'homun-menu-transcript "homun-menu" nil t)
(transient-define-prefix homun-menu-transcript ()
  "Keys of the transcript."
  [["Act"
    ("RET" "visit at point" claude-transcript-visit)
    ("C-c C-w" "copy code block" claude-transcript-copy-block)
    ("C-c C-r" "retry failed send" claude-compose-retry)
    ("C-c C-d" "drop failed send" claude-compose-drop)]
   ["View"
    ("g" "refresh" claude-transcript-refresh)
    ("s" "search" claude-transcript-search)
    ("/" "search past sessions" claude-transcript-past)
    ("f" "toggle follow" claude-transcript-toggle-follow)
    ("r" "focus view (reading)" claude-transcript-focus)
    ("M->" "end" claude-transcript-goto-end)
    ("h" "describe mode" describe-mode)
    ("q" "quit" bury-buffer)]
   ["Entries" :if (lambda () (and (fboundp 'evil-homun-interface-state-p)
                                  (evil-homun-interface-state-p)))
    ("M-j" "next entry" homun-iface-next)
    ("M-k" "previous entry" homun-iface-previous)
    ("]]" "next turn of yours" homun-iface-next-turn)
    ("[[" "previous turn of yours" homun-iface-previous-turn)
    ("TAB" "next item in entry" homun-iface-next-item)
    ("y" "copy entry or block" homun-iface-copy)
    ("o" "open link" homun-iface-open)
    ("i" "text: normal state" homun-iface-to-normal)]
   ["Screen" :if (lambda () (bound-and-true-p claude-transcript-phone))
    ("T" "Talk" claude-phone-talk)
    ("B" "Board" claude-phone-board)
    ("S" "Status" claude-phone-status)]
   ["Homun" :if (lambda () (bound-and-true-p claude-transcript-phone))
    ("U" "Update" homun-update)]])

;;;###autoload (autoload 'homun-menu-board "homun-menu" nil t)
(transient-define-prefix homun-menu-board ()
  "Keys of the board."
  [["Agent at point"
    ("RET" "open" claude-board-open)
    ("i" "detail" claude-board-detail)
    ("t" "todo" claude-board-open-todo)
    ("x" "stop" claude-board-stop)]
   ["View"
    ("g" "refresh" revert-buffer)
    ("d" "activity detail" claude-board-toggle-activity-detail)
    ("c" "columns" claude-board-toggle-column)
    ("f" "finished" claude-board-toggle-finished)
    ("h" "describe mode" describe-mode)
    ("q" "quit" quit-window)]])

;;;###autoload (autoload 'homun-menu-compose "homun-menu" nil t)
(transient-define-prefix homun-menu-compose ()
  "Keys of the compose buffer."
  [["Message"
    ("C-c C-c" "send" claude-compose-send)
    ("C-c C-k" "close, keep draft" claude-compose-cancel)]
   ["History"
    ("M-p" "previous" claude-compose-previous)
    ("M-n" "next" claude-compose-next)
    ("C-c C-r" "retry failed" claude-compose-retry)
    ("C-c C-d" "drop failed" claude-compose-drop)]])

;;;###autoload (autoload 'homun-menu-doctor "homun-menu" nil t)
(transient-define-prefix homun-menu-doctor ()
  "Keys of the doctor scene."
  [["Doctor"
    ("r" "run the checks again" claude-doctor-refresh)
    ("d" "show the doctor scene" claude-doctor)]])

;;;###autoload (autoload 'homun-menu-stage "homun-menu" nil t)
(transient-define-prefix homun-menu-stage ()
  "Keys of a Stage scene."
  [["Scene"
    ("k" "close" homun-stage-close-this)
    ("p" "pin or unpin" homun-stage-pin-this)
    ("[" "back in the patch log" homun-stage-scrub-back)
    ("]" "forward in the patch log" homun-stage-scrub-forward)
    ("RET" "open the item's detail" homun-stage-rows-open-at-point)
    ("M-<up>" "move the item up" homun-stage-rows-up)
    ("M-<down>" "move the item down" homun-stage-rows-down)
    ("d" "mark the item done" homun-stage-rows-done-at-point)]
   ["View"
    ("D" "doctor" homun-menu-doctor)
    ("h" "describe mode" describe-mode)
    ("q" "quit" quit-window)]])

(provide 'homun-menu)
;;; homun-menu.el ends here
