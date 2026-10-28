;; (app users) — user, role and user-role queries. All SQL is parameterized
;; through (app db), and every function takes a db handle, so it works the
;; same inside a transaction. Rows are alists keyed by column name; read a
;; field with (col row "name"). Password hashing lives in (app auth).

(define-library (app users)
  (import (scheme base)
          (scheme char)
          (app db))
  (export col
          valid-username? valid-role-name?
          find-user-by-name load-user
          list-users all-user-roles create-user! delete-user! set-password-hash!
          list-roles create-role!
          assign-role! assign-role-by-name! unassign-role!
          user-role-names user-has-role? role-name)
  (begin

    (define (col row name) (cdr (assoc name row)))

    ;; ids arrive from forms and the database as strings; bigint parameters
    ;; take numbers.
    (define (->int x)
      (cond ((string? x) (string->number x))
            ((exact-integer? x) x)
            (else #f)))

    (define (valid-name? s)
      (and (string? s)
           (<= 1 (string-length s) 64)
           (let loop ((i 0))
             (or (= i (string-length s))
                 (let ((c (string-ref s i)))
                   (and (or (char-alphabetic? c) (char-numeric? c)
                            (memv c '(#\. #\_ #\-)))
                        (loop (+ i 1))))))))

    (define (valid-username? s)
      "Syntax: (valid-username? s)
Library: (app users)
Description: True if s is 1-64 characters of letters, digits and . _ -"
      (valid-name? s))

    (define (valid-role-name? s)
      "Syntax: (valid-role-name? s)
Library: (app users)
Description: Same rule as valid-username?."
      (valid-name? s))

    ;; --- users --------------------------------------------------------

    (define (find-user-by-name db name)
      (db-row db "SELECT id, username, pass_hash FROM users WHERE username = $1"
              name))

    (define (load-user db id)
      (let ((n (->int id)))
        (and n (db-row db "SELECT id, username, pass_hash FROM users WHERE id = $1" n))))

    (define (list-users db)
      "Syntax: (list-users db)
Library: (app users)
Description: All users, ordered by username. Pair with all-user-roles to
  attach each user's roles."
      (db-rows db "SELECT id, username, created_at FROM users ORDER BY username"))

    (define (all-user-roles db)
      "Syntax: (all-user-roles db)
Library: (app users)
Description: Every (user_id, role_id, name) assignment, so callers can
  group roles by user without one query per user."
      (db-rows db
        (string-append
         "SELECT ur.user_id, r.id AS role_id, r.name "
         "FROM user_roles ur JOIN roles r ON r.id = ur.role_id "
         "ORDER BY r.name")))

    (define (create-user! db username hash)
      "Syntax: (create-user! db username hash)
Library: (app users)
Description: Inserts a user with a password hash and returns the new id.
  Raises on a duplicate username."
      (db-scalar db
        "INSERT INTO users (username, pass_hash) VALUES ($1, $2) RETURNING id"
        username hash))

    (define (delete-user! db id)
      (db-exec db "DELETE FROM users WHERE id = $1" (->int id)))

    (define (set-password-hash! db id hash)
      (db-exec db "UPDATE users SET pass_hash = $1 WHERE id = $2" hash (->int id)))

    ;; --- roles --------------------------------------------------------

    (define (list-roles db)
      (db-rows db "SELECT id, name FROM roles ORDER BY name"))

    (define (role-name db id)
      (let ((n (->int id)))
        (and n (db-scalar db "SELECT name FROM roles WHERE id = $1" n))))

    (define (create-role! db name)
      "Syntax: (create-role! db name)
Library: (app users)
Description: Inserts a role; does nothing if it already exists."
      (db-exec db
        "INSERT INTO roles (name) VALUES ($1) ON CONFLICT (name) DO NOTHING"
        name))

    (define (assign-role! db user-id role-id)
      (db-exec db
        (string-append "INSERT INTO user_roles (user_id, role_id) "
                       "VALUES ($1, $2) ON CONFLICT DO NOTHING")
        (->int user-id) (->int role-id)))

    (define (assign-role-by-name! db user-id role-name)
      (db-exec db
        (string-append
         "INSERT INTO user_roles (user_id, role_id) "
         "SELECT $1, id FROM roles WHERE name = $2 ON CONFLICT DO NOTHING")
        (->int user-id) role-name))

    (define (unassign-role! db user-id role-id)
      (db-exec db "DELETE FROM user_roles WHERE user_id = $1 AND role_id = $2"
               (->int user-id) (->int role-id)))

    (define (user-role-names db user-id)
      "Syntax: (user-role-names db user-id)
Library: (app users)
Description: The names of the user's roles."
      (map (lambda (r) (col r "name"))
           (db-rows db
             (string-append
              "SELECT r.name FROM roles r "
              "JOIN user_roles ur ON ur.role_id = r.id "
              "WHERE ur.user_id = $1 ORDER BY r.name")
             (->int user-id))))

    (define (user-has-role? db user-id name)
      "Syntax: (user-has-role? db user-id name)
Library: (app users)
Description: True if the user holds the named role."
      (and (db-row db
             (string-append
              "SELECT 1 FROM user_roles ur "
              "JOIN roles r ON r.id = ur.role_id "
              "WHERE ur.user_id = $1 AND r.name = $2")
             (->int user-id) name)
           #t))))
