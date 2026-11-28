;;; homun-expr.el --- The closed expression language of scenes -*- lexical-binding: t -*-

;; An expression is data, never code: a number, a variable name (a string looked up in an
;; environment alist) or a list ("op" ARGS...) whose op is one of `homun-expr-ops'.  There is no
;; way to define a function, so there is no recursion; `homun-expr-check' also caps the size
;; (`homun-expr-max-bytes' of JSON) and the nesting depth.  Scenes (homun-stage) evaluate with it.

(require 'cl-lib)
(require 'json)

(defconst homun-expr-max-bytes 2048 "The largest expression, as JSON bytes.")
(defconst homun-expr-max-depth 32 "The deepest nesting of an expression.")

(defun homun-expr--ease (x)
  "Smoothstep of X clamped to 0..1: slow at both ends."
  (let ((x (max 0.0 (min 1.0 (float x))))) (* x x (- 3 (* 2 x)))))

(defconst homun-expr-ops
  `((+ . ,#'+) (- . ,#'-) (* . ,#'*) (/ . ,(lambda (a b) (if (zerop b) 0.0 (/ (float a) b))))
    (sin . ,#'sin) (cos . ,#'cos) (abs . ,#'abs) (min . ,#'min) (max . ,#'max)
    (mod . ,(lambda (a b) (if (zerop b) 0.0 (mod (float a) b))))
    (pow . ,(lambda (a b) (expt (float a) b))) (sqrt . ,(lambda (a) (sqrt (max 0.0 a))))
    (floor . ,#'ffloor)
    (lerp . ,(lambda (a b x) (+ a (* (- b a) (float x)))))
    (ease . ,#'homun-expr--ease)
    (clamp . ,(lambda (x lo hi) (max lo (min hi x)))))
  "The operators an expression may use: all there is.")

(defun homun-expr-eval (x env)
  "Evaluate the expression X: a number, a variable of ENV, or (OP ARGS...)."
  (cond ((numberp x) x)
        ((stringp x) (or (cdr (assoc x env)) (error "Unknown variable %s" x)))
        ((and (consp x) (stringp (car x)))
         (let ((op (alist-get (intern (car x)) homun-expr-ops)))
           (unless op (error "Unknown operator %s" (car x)))
           (apply op (mapcar (lambda (a) (homun-expr-eval a env)) (cdr x)))))
        (t (error "Bad expression"))))

(defun homun-expr-check (x)
  "Return nil when X is a well-formed expression, else a string saying what is
wrong.
Variables are not resolved here: that needs the environment."
  (if (> (string-bytes (json-encode x)) homun-expr-max-bytes)
      (format "longer than %d bytes" homun-expr-max-bytes)
    (cl-labels ((walk (x depth)
                  (cond ((> depth homun-expr-max-depth)
                         (format "nested deeper than %d" homun-expr-max-depth))
                        ((or (numberp x) (stringp x)) nil)
                        ((and (consp x) (stringp (car x)))
                         (if (alist-get (intern (car x)) homun-expr-ops)
                             (cl-some (lambda (a) (walk a (1+ depth))) (cdr x))
                           (format "unknown operator %s" (car x))))
                        (t "not a number, variable or (op args...)"))))
      (walk x 0))))

(provide 'homun-expr)
;;; homun-expr.el ends here
