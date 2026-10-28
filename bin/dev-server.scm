;; Development supervisor: restarts bin/server.scm whenever a watched file
;; changes (src/*.sld, migrations/*.sql, bin/server.scm, config.scm), and
;; auto-retries on a backoff if it exits on its own. Static files need no
;; restart.
;;
;; Usage: scm bin/dev-server.scm

(import (scheme base)
        (scheme process-context)
        (scm fs)
        (scm reloader))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))

(define (watched)
  (append (files-with-suffix (string-append root "/src") ".sld")
          (files-with-suffix (string-append root "/migrations") ".sql")
          (list (string-append root "/bin/server.scm")
                (string-append root "/config.scm"))))

(supervise (list "scm" (string-append root "/bin/server.scm"))
           watched
           `((label . "folien")
             (work-dir . ,root)
             (root . ,root)))
