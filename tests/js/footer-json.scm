;; Prints (footer-elements) of every slide of the deck document given as
;; JSON (argument 2) in design (argument 1), for the node tests: the
;; renderer's footerElements must agree.
(import (scheme base) (scheme write) (scheme process-context) (scm module) (scm fs) (scm json simple))
(define root
  (directory-name (directory-name (directory-name (absolute-path (car (command-line)))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))
(import (app designs) (app model))
(define design (find-design (cadr (command-line))))
(define doc (json-parse (caddr (command-line))))
(display
 (json->string
  (let ((n (vector-length (doc-slides doc))))
    (let loop ((i (- n 1)) (acc '()))
      (if (< i 0)
          (list->vector acc)
          (loop (- i 1) (cons (list->vector (footer-elements doc design i "01.11.2026")) acc)))))))
