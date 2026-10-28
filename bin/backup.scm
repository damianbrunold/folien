;; Usage: scm bin/backup.scm [config-path]
;;
;; Writes a compressed dump of the database (pg_dump) to
;; data-dir/backups/folien-YYYY-MM-DD-HHMM.sql.gz and keeps the newest
;; backup-keep (default 14). The assets are files in data-dir/assets,
;; named by their content: back them up with the dumps, e.g. by copying
;; data-dir (rsync, restic, ...) after this has run.
;; Restore: gunzip -c <dump> | psql <database>, then put data-dir back.

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm log)
        (scm system)
        (scm datetime))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app config))

(define cfg (load-config root (cdr (command-line))))
(define data-dir (resolve-path root (config-ref cfg 'data-dir "var")))
(define dir (string-append data-dir "/backups"))
(unless (directory-exists? data-dir) (make-directory data-dir))
(unless (directory-exists? dir) (make-directory dir))

;; "2026-10-28 23:16" -> "2026-10-28-2316"
(define stamp
  (let ((n (now)))
    (string-append (substring n 0 10) "-" (substring n 11 13) (substring n 14 16))))
(define target (string-append dir "/folien-" stamp ".sql.gz"))

(define result
  (run-program/capture
   ;; pipefail: a failing pg_dump fails the pipe
   (list "bash" "-c" "set -o pipefail; pg_dump --no-owner \"$PGDATABASE\" | gzip > \"$TARGET\"")
   ;; options are (key value) lists; env an alist of (name value)
   `((env (("PGHOST" ,(config-ref cfg 'db-host "127.0.0.1"))
           ("PGPORT" ,(number->string (config-ref cfg 'db-port 5432)))
           ("PGUSER" ,(config-ref cfg 'db-user "folien"))
           ("PGPASSWORD" ,(config-ref cfg 'db-password ""))
           ("PGDATABASE" ,(config-ref cfg 'db-name "folien"))
           ("TARGET" ,target))))))
(define code (and result (car result)))

(cond
  ((and (eqv? code 0) (file-exists? target) (> (file-size target) 0))
   (log-info "backup" (string-append "wrote " target))
   ;; keep the newest backup-keep
   (let* ((keep (config-ref cfg 'backup-keep 14))
          (dumps (let loop ((fs (directory-files dir)) (acc '()))
                   (cond ((null? fs) acc)
                         ((and (> (string-length (car fs)) 7)
                               (string=? (substring (car fs) 0 7) "folien-"))
                          (loop (cdr fs) (cons (car fs) acc)))
                         (else (loop (cdr fs) acc)))))
          ;; the names sort by time; newest first
          (sorted (let sort ((xs dumps) (out '()))
                    (if (null? xs)
                        out
                        (sort (cdr xs)
                              (let ins ((ys out))
                                (cond ((null? ys) (list (car xs)))
                                      ((string>? (car xs) (car ys)) (cons (car xs) ys))
                                      (else (cons (car ys) (ins (cdr ys)))))))))))
     (let loop ((ds sorted) (i 0))
       (unless (null? ds)
         (when (>= i keep) (delete-file (string-append dir "/" (car ds))))
         (loop (cdr ds) (+ i 1))))))
  (else
   (log-error "backup" (string-append "pg_dump failed: " (if result (caddr result) "could not run it")))
   (when (file-exists? target) (delete-file target))
   (exit 1)))
