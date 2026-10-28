;; Prints the designs as /api/designs serves them, for the node tests.
(import (scheme base) (scheme write) (scheme process-context) (scm module) (scm fs) (scm json simple))
(define root
  (directory-name (directory-name (directory-name (absolute-path (car (command-line)))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))
(import (app designs))
(display (json->string (list->vector designs)))
