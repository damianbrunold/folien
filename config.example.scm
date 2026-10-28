;; folien configuration: a list of (define name value) forms, read
;; as data by src/app-config.sld. bin/server.scm reads config.scm; the first
;; run creates it from this file, with a fresh session-secret. Set the
;; database password before you start the server.

;; Bind loopback only; a reverse proxy (deploy/nginx.conf.example) fronts
;; the public interface and terminates TLS.
(define http-host "127.0.0.1")
(define http-port 8090)

;; Concurrent requests. Every window following a presentation (the
;; presentation, the presenter console, a remote) holds one while open.
(define http-max-threads 64)

;; Path the app is mounted under, e.g. "/team"; "" for the host root. The
;; reverse proxy must pass paths through unchanged.
(define url-prefix "")

;; PostgreSQL over TCP. The role needs CREATE on the database the first
;; time, so the migrations can build the schema.
(define db-host "127.0.0.1")
(define db-port 5432)
(define db-user "folien")
(define db-password "change-me")
(define db-name "folien")
(define db-pool-size 8)

;; Signs the session cookies (base64 of 32 random bytes). To rotate it,
;; list the new key first: ("new" "old"); sessions signed with the old key
;; stay valid until you remove it. bin/gen-secret.scm prints a new key.
(define session-secret "REPLACE_WITH_BASE64_SECRET")
(define session-max-age (* 60 60 24 7))   ; 7 days

;; Cookies are sent over HTTPS only when #t. Keep #f for http://127.0.0.1
;; during development; deploy/install.sh sets #t.
(define secure-cookies? #f)

;; Relative to the app directory.
(define static-dir "static")

;; Uploaded images and videos go to data-dir/assets; relative to the app
;; directory unless absolute. deploy/install.sh sets /var/lib/folien.
(define data-dir "var")

;; The largest upload, in bytes. Bodies above 1 MB are spooled to a
;; temporary file, so this does not need memory.
(define max-upload-bytes (* 1024 1024 1024))

;; bin/maintenance.scm (nightly) deletes decks that are longer than this
;; in the trash, in days.
(define trash-days 30)

;; bin/backup.scm keeps this many database dumps in data-dir/backups.
(define backup-keep 14)
