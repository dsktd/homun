;;; homun-freeze-watch-test.el --- ERT for homun-freeze-watch -*- lexical-binding: t -*-
(require 'ert)
(require 'homun-freeze-watch)

(ert-deftest homun-freeze-watch-logs-a-gap-with-the-timer-that-ran-in-it ()
  (let* ((log (make-temp-file "gaps")) (now 100.0)
         (homun-freeze-watch-log log) (homun-freeze-watch--own-profiler nil)
         (homun-freeze-watch-time-function (lambda () now))
         (homun-freeze-watch--last nil) (homun-freeze-watch--runs nil))
    (unwind-protect
        (progn
          (homun-freeze-watch-tick)
          (setq now 100.3)
          (homun-freeze-watch-tick)
          (should (zerop (file-attribute-size (file-attributes log))))
          (ignore-errors
            (homun-freeze-watch--record 'timer "stuck" (lambda () (setq now 103.0) (error "C-g")) nil))
          (homun-freeze-watch-tick)
          (let ((e (with-temp-buffer (insert-file-contents log) (read (current-buffer)))))
            (should (> (plist-get e :gap) 2))
            (should (equal (plist-get e :runs) (list (list (quote timer) "stuck" 2.7))))))
      (delete-file log))))

(defmacro homun-freeze-watch-test--with-log (&rest body)
  `(let* ((log (make-temp-file "gaps")) (homun-freeze-watch-log log))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file log)) (ignore-errors (delete-file (concat log ".1"))))))

(defun homun-freeze-watch-test--line (ago gap)
  (format "%S\n" (list :at (format-time-string "%FT%T%z" (- (float-time) ago)) :gap gap :gc 0.0
                       :runs nil :stacks '((3 "a" "b") (2 "c") (1 "d") (1 "e")))))

(ert-deftest homun-freeze-watch-entry-is-one-line ()
  (let ((homun-freeze-watch--runs (list (list 1.0 2.0 'timer "two\nlines"))))
    (should-not (string-search "\n" (let ((print-escape-newlines t))
                                      (prin1-to-string (homun-freeze-watch--entry 5.0 2.0)))))))

(ert-deftest homun-freeze-watch-rotates-at-the-limit ()
  (homun-freeze-watch-test--with-log
   (let ((homun-freeze-watch-max-bytes 10))
     (write-region "0123456789abcdef\n" nil log nil 'silent)
     (homun-freeze-watch--rotate)
     (should-not (file-exists-p log))
     (should (file-exists-p (concat log ".1"))))))

(ert-deftest homun-freeze-watch-counts-gaps-over-one-second-in-the-last-hour ()
  (homun-freeze-watch-test--with-log
   (write-region (concat (homun-freeze-watch-test--line 60 2.0)
                         (homun-freeze-watch-test--line 120 0.7)
                         (homun-freeze-watch-test--line 7200 5.0))
                 nil log nil 'silent)
   (should (= 1 (homun-freeze-watch-count 1.0 3600)))))

(ert-deftest homun-freeze-report-shows-time-gap-and-top-three-stacks ()
  (homun-freeze-watch-test--with-log
   (write-region (homun-freeze-watch-test--line 60 2.5) nil log nil 'silent)
   (with-current-buffer (homun-freeze-report 5)
     (should (string-match-p "2\\.50s" (buffer-string)))
     (should (string-match-p "3x a < b" (buffer-string)))
     (should-not (string-match-p "e$" (buffer-string))))))

(ert-deftest homun-freeze-watch-lends-the-profiler-and-takes-it-back ()
  (let ((homun-freeze-watch-mode t) (homun-freeze-watch--own-profiler nil)
        (homun-freeze-watch--lent nil) (running nil) (starts 0))
    (cl-letf (((symbol-function 'profiler-cpu-running-p) (lambda () running))
              ((symbol-function 'profiler-cpu-start) (lambda (_) (cl-incf starts) (setq running t)))
              ((symbol-function 'profiler-cpu-stop) (lambda () (setq running nil))))
      (homun-freeze-watch--claim)
      (should homun-freeze-watch--own-profiler)
      (should (homun-freeze-watch-profiler-lend))
      (should-not homun-freeze-watch--own-profiler)
      (should-not (homun-freeze-watch-profiler-lend))   ; one borrower at a time
      (setq running t)                                  ; the borrower profiles
      (homun-freeze-watch--claim)
      (should (= starts 1))
      (setq running nil)
      (homun-freeze-watch-profiler-reclaim)
      (should homun-freeze-watch--own-profiler)
      (should (= starts 2)))))

(ert-deftest homun-freeze-watch-takes-the-profiler-when-a-foreign-one-stops ()
  ;; On with a profile already running, the mode had no stacks for good (nil :stacks)
  (let ((homun-freeze-watch-mode t) (homun-freeze-watch--own-profiler nil)
        (homun-freeze-watch--lent nil) (running t)
        (homun-freeze-watch-time-function (lambda () 1.0)) (homun-freeze-watch--last nil))
    (cl-letf (((symbol-function 'profiler-cpu-running-p) (lambda () running))
              ((symbol-function 'profiler-cpu-start) (lambda (_) (setq running t)))
              ((symbol-function 'profiler-cpu-log) (lambda () (make-hash-table))))
      (homun-freeze-watch-tick)
      (should-not homun-freeze-watch--own-profiler)
      (setq running nil)
      (homun-freeze-watch-tick)
      (should homun-freeze-watch--own-profiler))))
