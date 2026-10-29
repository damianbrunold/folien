;; (app maintenance) — the daily clean-up (bin/maintenance.scm, run by a
;; systemd timer):
;;
;;   - decks in the trash for more than trash-days are deleted for good;
;;   - assets no deck or publication links to any more are removed (row
;;     and file); a file is shared by every deck and publication that uses
;;     the same content, so it goes only when the last link has gone;
;;   - files in the asset store without a row (an upload that broke off),
;;     leftovers of uploads and imports (data-dir/tmp, *.tmp-*) and cached
;;     bundles are removed.
;;
;; Everything younger than a grace period (an hour for assets, a day for
;; files) stays, so work in progress is never touched. "Now" is a
;; parameter, so the tests can let time pass.

(define-library (app maintenance)
  (import (scheme base)
          (scheme time)
          (scm fs)
          (app db)
          (app users)          ; col
          (app assets))
  (export run-maintenance!)
  (begin

    (define hour-ms (* 60 60 1000))
    (define day-ms (* 24 hour-ms))

    (define (->int x) (if (string? x) (string->number x) x))

    (define (string-contains? s part)
      (let loop ((i 0))
        (and (<= (+ i (string-length part)) (string-length s))
             (or (string=? (substring s i (+ i (string-length part))) part)
                 (loop (+ i 1))))))

    ;; Files directly in dir (#f if it does not exist).
    (define (files-in dir)
      (if (directory-exists? dir)
          (map (lambda (f) (string-append dir "/" f)) (directory-files dir))
          '()))

    (define (older-than? path now-ms age-ms)
      (guard (e (#t #f))
        (> (- now-ms (file-modification-timestamp path)) age-ms)))

    (define (delete-quietly! path)
      (guard (e (#t #f))
        (delete-file path)
        #t))

    (define (run-maintenance! db data-dir trash-days . now)
      "Syntax: (run-maintenance! db data-dir trash-days [now-ms])
Library: (app maintenance)
Description: Runs the clean-up and returns what it did: an alist of
  counts (decks, assets, files)."
      (let* ((now-ms (if (pair? now) (car now) (exact (floor (* 1000 (current-second))))))
             (now-s (quotient now-ms 1000))
             ;; 1. the trash
             (decks (->int
                     (or (db-scalar db
                           (string-append
                            "WITH gone AS (DELETE FROM presentations WHERE status = 'trashed' "
                            "AND status_at < to_timestamp($1) - make_interval(days => $2) RETURNING 1) "
                            "SELECT count(*) FROM gone")
                           now-s trash-days)
                         0)))
             ;; 2. unlinked assets (older than an hour)
             (unlinked (db-rows db
                         (string-append
                          "SELECT a.sha256 FROM assets a WHERE NOT EXISTS "
                          "(SELECT 1 FROM presentation_assets pa WHERE pa.sha256 = a.sha256) "
                          "AND NOT EXISTS (SELECT 1 FROM publication_assets ba WHERE ba.sha256 = a.sha256) "
                          "AND a.created_at < to_timestamp($1) - interval '1 hour'")
                         now-s))
             (assets (let loop ((rows unlinked) (n 0))
                       (if (null? rows)
                           n
                           (let ((sha (col (car rows) "sha256")))
                             (db-exec db
                               (string-append "DELETE FROM assets WHERE sha256 = $1 AND NOT EXISTS "
                                              "(SELECT 1 FROM presentation_assets pa WHERE pa.sha256 = $1) "
                                              "AND NOT EXISTS (SELECT 1 FROM publication_assets ba WHERE ba.sha256 = $1)")
                               sha)
                             (delete-quietly! (asset-file data-dir sha))
                             (loop (cdr rows) (+ n 1))))))
             ;; 3. files nobody needs (older than a day)
             (files 0))
        ;; store files without a row, and broken-off temporary files
        (for-each
         (lambda (dir)
           (for-each
            (lambda (path)
              (let* ((name (let loop ((i (- (string-length path) 1)))
                             (if (char=? (string-ref path i) #\/)
                                 (substring path (+ i 1) (string-length path))
                                 (loop (- i 1)))))
                     (orphan? (or (string-contains? name ".tmp-")
                                  (not (valid-sha? name))
                                  (not (db-scalar db "SELECT 1 FROM assets WHERE sha256 = $1" name)))))
                (when (and orphan? (older-than? path now-ms day-ms) (delete-quietly! path))
                  (set! files (+ files 1)))))
            (files-in dir)))
         (if (directory-exists? (string-append data-dir "/assets"))
             (map (lambda (d) (string-append data-dir "/assets/" d))
                  (directory-directories (string-append data-dir "/assets")))
             '()))
        ;; thumbnail copies ((app images)) of assets that are gone
        (for-each
         (lambda (dir)
           (for-each
            (lambda (path)
              (let* ((name (let loop ((i (- (string-length path) 1)))
                             (if (char=? (string-ref path i) #\/)
                                 (substring path (+ i 1) (string-length path))
                                 (loop (- i 1)))))
                     (sha (and (>= (string-length name) 64) (substring name 0 64)))
                     (orphan? (or (string-contains? name ".tmp-")
                                  (not (valid-sha? sha))
                                  (not (db-scalar db "SELECT 1 FROM assets WHERE sha256 = $1" sha)))))
                (when (and orphan? (older-than? path now-ms day-ms) (delete-quietly! path))
                  (set! files (+ files 1)))))
            (files-in dir)))
         (if (directory-exists? (string-append data-dir "/variants"))
             (map (lambda (d) (string-append data-dir "/variants/" d))
                  (directory-directories (string-append data-dir "/variants")))
             '()))
        ;; leftovers of uploads and imports, cached bundles
        (for-each
         (lambda (path)
           (when (and (older-than? path now-ms day-ms) (delete-quietly! path))
             (set! files (+ files 1))))
         (append (files-in (string-append data-dir "/tmp"))
                 (files-in (string-append data-dir "/bundles"))
                 (let loop ((fs (files-in data-dir)) (acc '()))
                   (cond ((null? fs) acc)
                         ((string-contains? (car fs) "/import-") (loop (cdr fs) (cons (car fs) acc)))
                         (else (loop (cdr fs) acc))))))
        `((decks . ,decks) (assets . ,assets) (files . ,files))))))
