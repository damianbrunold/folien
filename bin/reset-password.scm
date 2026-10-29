;; Usage: scm bin/reset-password.scm [--config path] <username>
;;
;; Sets a new password for an existing user (prompting for it), e.g. when
;; it was forgotten. The user's open sessions end; roles stay as they are.

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm terminal))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (scm crypto password) (app config) (app db) (app users) (app auth))

(define (fail msg) (display msg (current-error-port)) (newline (current-error-port)) (exit 1))

(define args (cdr (command-line)))
(define config-args
  (if (and (pair? args) (string=? (car args) "--config") (pair? (cdr args)))
      (list (cadr args))
      '()))
(define rest-args (if (null? config-args) args (cddr args)))
(unless (and (pair? rest-args) (null? (cdr rest-args)))
  (fail "usage: scm bin/reset-password.scm [--config path] <username>"))
(define username (car rest-args))

(define cfg (load-config root config-args))
(define db
  (make-db (config-ref cfg 'db-host "127.0.0.1")
           (config-ref cfg 'db-port 5432)
           (config-ref cfg 'db-user "folien")
           (config-ref cfg 'db-password "")
           (config-ref cfg 'db-name "folien")
           1))

(define user (find-user-by-name db username))
(unless user (fail (string-append "no user " username)))

(define (ask-new-password)
  (let* ((a (read-password "New password: "))
         (b (if (eof-object? a) a (read-password "Confirm:      "))))
    (cond ((or (eof-object? a) (eof-object? b)) (fail "aborted"))
          ((not (string=? a b)) (fail "passwords do not match"))
          ((< (string-length a) min-password-length)
           (fail "password must be at least 8 characters"))
          (else a))))

(set-password-hash! db (col user "id") (password-hash (ask-new-password)))
(display (string-append "new password set for " username "\n"))
