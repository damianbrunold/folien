;; Writes the offline player of a bundle for the deck in a JSON file:
;;   scm tests/js/player-files.scm <deck.json> <out-dir>
;; deck.json: {"id", "title", "design", "doc", "assets": {sha: url}}.
;; For the browser test of the player (tests/browser/offline.test.mjs).
(import (scheme base) (scheme file) (scheme process-context) (scm module) (scm fs) (scm json simple))
(define root
  (directory-name (directory-name (directory-name (absolute-path (car (command-line)))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))
(import (app bundle))
(define args (cdr (command-line)))
(define deck (call-with-input-file (car args) json-read))
(define out (cadr args))
(define (ref k) (cdr (assoc k deck)))
(define (ensure-dirs path)
  ;; creates the directories of a relative file path under out
  (let loop ((i 0))
    (when (< i (string-length path))
      (when (char=? (string-ref path i) #\/)
        (let ((d (string-append out "/" (substring path 0 i))))
          (unless (directory-exists? d) (make-directory d))))
      (loop (+ i 1)))))
(for-each
 (lambda (e)
   (ensure-dirs (car e))
   (let ((target (string-append out "/" (car e))))
     (if (eq? (cadr e) 'text)
         (call-with-output-file target (lambda (p) (write-string (cddr e) p)))
         (copy-file (cddr e) target))))
 (player-entries (string-append root "/static") (ref "id") (ref "title") (ref "design") (ref "doc")
                 (ref "assets")))
