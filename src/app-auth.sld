;; (app auth) — sign-in, sessions and password changes.
;;
;; As in starter-login: (scm crypto password) hashes, a dummy check for
;; unknown usernames, hash upgrades at sign-in, and signed-cookie sessions
;; from (scm net http session). The cookie carries the user id and a stamp
;; of the password hash; every request loads the user again, so deleting a
;; user or changing a password ends their other sessions.

(define-library (app auth)
  (import (scheme base)
          (scm crypto)
          (scm crypto password)
          (scm net http session)
          (app db)
          (app users))
  (export make-auth
          sign-in
          session-user
          start-session
          end-session
          change-password!
          min-password-length)
  (begin

    (define min-password-length 8)

    (define-record-type auth
      (%make-auth session db)
      auth?
      (session auth-session)
      (db auth-db))

    (define (make-auth session-config db)
      "Syntax: (make-auth session-config db)
Library: (app auth)
Description: Ties a (scm net http session) config to the database."
      (%make-auth session-config db))

    ;; Changes whenever the password (and so the hash) changes.
    (define (password-stamp hash)
      (base64-encode (bytevector-copy (sha256-hash (string->utf8 hash)) 0 12)))

    (define (sign-in auth username password)
      "Syntax: (sign-in auth username password)
Library: (app auth)
Description: The user row if password is right for username, else #f.
  Upgrades an outdated password hash on success."
      (let* ((db (auth-db auth))
             (user (find-user-by-name db username)))
        (cond
          ((not (password-verify password (and user (col user "pass_hash")))) #f)
          ((password-needs-rehash? (col user "pass_hash"))
           (set-password-hash! db (col user "id") (password-hash password))
           (load-user db (col user "id")))
          (else user))))

    (define (session-user auth req)
      "Syntax: (session-user auth req)
Library: (app auth)
Description: The signed-in user's row, or #f if there is no valid session
  or the user was deleted or changed the password since."
      (let ((s (session-ref (auth-session auth) req)))
        (and (pair? s)
             (let* ((uid (assq 'uid s))
                    (stamp (assq 'stamp s))
                    (user (and uid (load-user (auth-db auth) (cdr uid)))))
               (and user stamp
                    (equal? (cdr stamp) (password-stamp (col user "pass_hash")))
                    user)))))

    (define (start-session auth user)
      "Syntax: (start-session auth user)
Library: (app auth)
Description: The Set-Cookie header pair that signs user in."
      (session-set-cookie (auth-session auth)
                          `((uid . ,(col user "id"))
                            (stamp . ,(password-stamp (col user "pass_hash"))))))

    (define (end-session auth)
      "Syntax: (end-session auth)
Library: (app auth)
Description: The Set-Cookie header pair that signs out."
      (session-clear-cookie (auth-session auth)))

    (define (change-password! auth user new-password)
      "Syntax: (change-password! auth user new-password)
Library: (app auth)
Description: Stores a new hash for user and returns the updated row. Other
  sessions of the user end; start a new one for this browser."
      (set-password-hash! (auth-db auth) (col user "id") (password-hash new-password))
      (load-user (auth-db auth) (col user "id")))))
