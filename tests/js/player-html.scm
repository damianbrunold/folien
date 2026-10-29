;; Writes the one-file offline player for the deck in a JSON file:
;;   scm tests/js/player-html.scm <deck.json> <out.html>
;; deck.json: {"id", "title", "design", "doc", "files": {sha: [mime, path]}}.
;; For the browser test of the player (tests/browser/offline.test.mjs).
(import (scheme base) (scheme file) (scheme process-context) (scm module) (scm fs) (scm json simple))
(define root
  (directory-name (directory-name (directory-name (absolute-path (car (command-line)))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))
(import (app bundle))
(define args (cdr (command-line)))
(define deck (call-with-input-file (car args) json-read))
(define (ref k) (cdr (assoc k deck)))
(define port (open-output-file (cadr args)))
(write-player-html port (string-append root "/static") (ref "id") (ref "title") (ref "design") (ref "doc")
                   (map (lambda (f) (cons (car f) (cons (vector-ref (cdr f) 0) (vector-ref (cdr f) 1))))
                        (ref "files")))
(close-port port)
