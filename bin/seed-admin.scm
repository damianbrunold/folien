;; Usage: scm bin/seed-admin.scm [--config path] <username>
;;
;; Sets up the first admin: applies migrations, ensures the "admin" role
;; exists, and creates username with that role (prompting for a password),
;; all in one transaction. If the user already exists, it only gets the
;; role. Safe to run again.

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm terminal))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (scm crypto password) (app config) (app db) (app users) (app auth) (app web))

(define (fail msg) (display msg (current-error-port)) (newline (current-error-port)) (exit 1))

(define args (cdr (command-line)))
(define config-args
  (if (and (pair? args) (string=? (car args) "--config") (pair? (cdr args)))
      (list (cadr args))
      '()))
(define rest-args (if (null? config-args) args (cddr args)))
(unless (and (pair? rest-args) (null? (cdr rest-args)))
  (fail "usage: scm bin/seed-admin.scm [--config path] <username>"))
(define username (car rest-args))
(unless (valid-username? username)
  (fail "invalid username (letters, digits, . _ -; at most 64)"))

(define cfg (load-config root config-args))
(define db
  (make-db (config-ref cfg 'db-host "127.0.0.1")
           (config-ref cfg 'db-port 5432)
           (config-ref cfg 'db-user "folien")
           (config-ref cfg 'db-password "")
           (config-ref cfg 'db-name "folien")
           1))

(migrate! db (resolve-path root "migrations"))

(define (ask-new-password)
  (let* ((a (read-password "Password: "))
         (b (if (eof-object? a) a (read-password "Confirm:  "))))
    (cond ((or (eof-object? a) (eof-object? b)) (fail "aborted"))
          ((not (string=? a b)) (fail "passwords do not match"))
          ((< (string-length a) min-password-length)
           (fail "password must be at least 8 characters"))
          (else a))))

(define existing (find-user-by-name db username))
(define hash (if existing #f (password-hash (ask-new-password))))

(with-db-transaction db
  (lambda (tx)
    (create-role! tx admin-role)
    (let ((id (if existing (col existing "id") (create-user! tx username hash))))
      (assign-role-by-name! tx id admin-role))))

(display (if existing
             (string-append username " exists; it has the admin role now\n")
             (string-append "created admin " username "\n")))
