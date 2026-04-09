;;; sexp_reachability_proofs.scm
;;;
;;; Constructive reachability witnesses for a pluralist S-expression neighborhood.
;;; The proof style is SCM-like: define explicit bridge functions and show that
;;; observational fragments are preserved by composition through a common
;;; transport representation.

(define runtime-nanoclj 'nanoclj-zig)
(define runtime-basilisp 'basilisp)
(define runtime-hy 'hy)
(define runtime-fennel 'fennel)
(define runtime-clojure 'clojure)
(define runtime-scheme 'scheme)
(define runtime-common-lisp 'common-lisp)

(define (atom->transport x)
  (cond
    ((symbol? x) (list 'symbol (symbol->string x)))
    ((string? x) (list 'string x))
    ((number? x) (list 'number x))
    ((boolean? x) (list 'bool x))
    ((null? x) '(nil))
    (else (list 'opaque x))))

(define (transport x)
  (cond
    ((pair? x)
     (cons 'list (map transport x)))
    ((vector? x)
     (cons 'vector (map transport (vector->list x))))
    (else (atom->transport x))))

(define (transport-tag? tag x)
  (and (pair? x) (eq? (car x) tag)))

(define (decode-symbol x)
  (string->symbol (cadr x)))

(define (emit-scheme t)
  (cond
    ((transport-tag? 'symbol t) (decode-symbol t))
    ((transport-tag? 'string t) (cadr t))
    ((transport-tag? 'number t) (cadr t))
    ((transport-tag? 'bool t) (cadr t))
    ((transport-tag? 'nil t) '())
    ((transport-tag? 'list t) (map emit-scheme (cdr t)))
    ((transport-tag? 'vector t) (list->vector (map emit-scheme (cdr t))))
    (else '(unsupported))))

(define (emit-clojure t)
  (cond
    ((transport-tag? 'symbol t) (decode-symbol t))
    ((transport-tag? 'string t) (cadr t))
    ((transport-tag? 'number t) (cadr t))
    ((transport-tag? 'bool t) (cadr t))
    ((transport-tag? 'nil t) 'nil)
    ((transport-tag? 'list t) (map emit-clojure (cdr t)))
    ((transport-tag? 'vector t) (cons 'vector (map emit-clojure (cdr t))))
    (else '(unsupported))))

(define (emit-basilisp t)
  ;; On the pure data fragment, Basilisp shares the same witness shape as Clojure.
  (emit-clojure t))

(define (emit-common-lisp t)
  (cond
    ((transport-tag? 'symbol t) (decode-symbol t))
    ((transport-tag? 'string t) (cadr t))
    ((transport-tag? 'number t) (cadr t))
    ((transport-tag? 'bool t) (if (cadr t) 't 'nil))
    ((transport-tag? 'nil t) 'nil)
    ((transport-tag? 'list t) (map emit-common-lisp (cdr t)))
    ((transport-tag? 'vector t) (cons 'vector (map emit-common-lisp (cdr t))))
    (else '(unsupported))))

(define (emit-hy t)
  (cond
    ((transport-tag? 'symbol t) (decode-symbol t))
    ((transport-tag? 'string t) (cadr t))
    ((transport-tag? 'number t) (cadr t))
    ((transport-tag? 'bool t) (if (cadr t) 'True 'False))
    ((transport-tag? 'nil t) 'None)
    ((transport-tag? 'list t) (map emit-hy (cdr t)))
    ((transport-tag? 'vector t) (cons 'list (map emit-hy (cdr t))))
    (else '(unsupported))))

(define (emit-fennel t)
  (cond
    ((transport-tag? 'symbol t) (decode-symbol t))
    ((transport-tag? 'string t) (cadr t))
    ((transport-tag? 'number t) (cadr t))
    ((transport-tag? 'bool t) (cadr t))
    ((transport-tag? 'nil t) 'nil)
    ((transport-tag? 'list t) (map emit-fennel (cdr t)))
    ((transport-tag? 'vector t) (cons '[] (map emit-fennel (cdr t))))
    (else '(unsupported))))

(define (emit-nanoclj t)
  ;; nanoclj-zig is the controlling evaluator in this lattice, so its witness
  ;; matches the Clojure-shaped pure data fragment.
  (emit-clojure t))

(define (observe x)
  ;; Small observational fragment used for equivalence checking.
  (cond
    ((pair? x)
     (cons 'list (map observe x)))
    ((vector? x)
     (list 'vector (vector-length x)))
    ((symbol? x) '(symbol))
    ((string? x) (list 'string x))
    ((number? x) (list 'number x))
    ((boolean? x) (list 'bool x))
    ((null? x) '(nil))
    (else '(opaque))))

(define (behaviorally-reachable? x emitter)
  (equal? (observe x)
          (observe (emit-scheme (transport (emitter (transport x)))))))

(define (reachable-via-transport? x emitter)
  (equal? (observe x)
          (observe (emit-scheme (transport (emitter (transport x)))))))

(define sample-program
  '(let ((x 1)
         (y "bridge")
         (z (quote (a b c))))
     (list x y z #t)))

(define sample-vector
  (vector 'alpha 7 "omega"))

(define (proof-row name emitter)
  (list name
        (reachable-via-transport? sample-program emitter)
        (reachable-via-transport? sample-vector emitter)))

(define reachability-table
  (list
    (proof-row runtime-nanoclj emit-nanoclj)
    (proof-row runtime-basilisp emit-basilisp)
    (proof-row runtime-hy emit-hy)
    (proof-row runtime-fennel emit-fennel)
    (proof-row runtime-clojure emit-clojure)
    (proof-row runtime-common-lisp emit-common-lisp)))

(define bridge-lattice
  '((control
      (nanoclj-zig basilisp hy fennel))
    (clojure-workflow
      (basilisp nanoclj-zig hy fennel))
    (python-reach
      (hy basilisp nanoclj-zig fennel))
    (embedded-reach
      (fennel nanoclj-zig hy basilisp))))

(define (show-proof)
  (display "Pluralist S-expression reachability proofs") (newline)
  (display "=======================================") (newline)
  (display "Each row is: (runtime program-proof vector-proof)") (newline)
  (for-each
    (lambda (row) (write row) (newline))
    reachability-table)
  (newline)
  (display "Bridge lattice") (newline)
  (write bridge-lattice) (newline))

(show-proof)
