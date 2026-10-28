;; Usage: scm bin/maintenance.scm [config-path]
;;
;; The daily clean-up (src/app-maintenance.sld): empties the trash after
;; trash-days, removes assets no deck uses and files nobody needs.
;; deploy/systemd/folien-maintenance.timer runs it every night.

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm log))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app config) (app db) (app maintenance))

(define cfg (load-config root (cdr (command-line))))
(define db
  (make-db (config-ref cfg 'db-host "127.0.0.1")
           (config-ref cfg 'db-port 5432)
           (config-ref cfg 'db-user "folien")
           (config-ref cfg 'db-password "")
           (config-ref cfg 'db-name "folien")
           1))

(define report
  (run-maintenance! db (resolve-path root (config-ref cfg 'data-dir "var"))
                    (config-ref cfg 'trash-days 30)))

(log-info "maintenance"
          (string-append "deleted from the trash: " (number->string (cdr (assq 'decks report)))
                         ", unused assets: " (number->string (cdr (assq 'assets report)))
                         ", files: " (number->string (cdr (assq 'files report)))))
