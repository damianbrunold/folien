;; Usage: scm bin/server.scm [config-path]
;;
;; Reads the config (config-path, or else config.scm, which the first run
;; creates from config.example.scm with a fresh secret), applies pending
;; migrations, then serves the app.

(import (scheme base)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm log)
        (scm net http server))

;; Resolve the project root from this script's path so it runs from anywhere,
;; and make src/ importable.
(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app config) (app db) (app assets) (app web))

(define cfg (load-config root (cdr (command-line))))
(define host (config-ref cfg 'http-host "127.0.0.1"))
(define port (config-ref cfg 'http-port 8090))
(define prefix (config-ref cfg 'url-prefix ""))

(define db
  (make-db (config-ref cfg 'db-host "127.0.0.1")
           (config-ref cfg 'db-port 5432)
           (config-ref cfg 'db-user "folien")
           (config-ref cfg 'db-password "")
           (config-ref cfg 'db-name "folien")
           (config-ref cfg 'db-pool-size 8)))

(migrate! db (resolve-path root "migrations"))

(define data-dir (resolve-path root (config-ref cfg 'data-dir "var")))
(ensure-asset-dir data-dir)

(define app
  (make-app
   `((url-prefix      . ,prefix)
     (static-dir      . ,(resolve-path root (config-ref cfg 'static-dir "static")))
     (data-dir        . ,data-dir)
     (db              . ,db)
     (session-secret  . ,(config-secret cfg 'session-secret))
     (session-max-age . ,(config-ref cfg 'session-max-age (* 60 60 24 7)))
     (secure-cookies? . ,(config-ref cfg 'secure-cookies? #t)))))

(log-info "app" (string-append "folien listening on http://" host ":"
                               (number->string port) prefix "/"))
;; Uploads up to max-upload-bytes; the server spools bodies over 1 MB to
;; temporary files.
(serve-forever port app 0 host 0 (config-ref cfg 'max-upload-bytes (* 1024 1024 1024)))
