;; (app auth) — sign-in, sessions and password changes.
;;
;; As in starter-login: (scm crypto password) hashes, a dummy check for
;; unknown usernames, hash upgrades at sign-in, and signed-cookie sessions
;; from (scm net http session). The cookie carries the user id and a stamp
;; of the password hash; every request loads the user again, so deleting a
;; user or changing a password ends their other sessions.
;;
;; Remote links: a token that lets a phone use one deck's remote without
;; signing in (make-remote-token, remote-token-user). It names the user
;; who made it, the deck, the deck's remote epoch and an expiry, and is
;; signed with a key derived from the session secret, over the user's
;; password stamp too: it ends when it expires, when the password
;; changes, when the deck's epoch is raised, or when the user can no
;; longer see the deck (the caller checks each time).

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
          min-password-length
          make-remote-token
          remote-token-user
          remote-token-deck
          remote-link-seconds)
  (begin

    (define min-password-length 8)

    (define-record-type auth
      (%make-auth session db remote-key)
      auth?
      (session auth-session)
      (db auth-db)
      (remote-key auth-remote-key))

    (define (make-auth session-config db . secret)
      "Syntax: (make-auth session-config db [secret])
Library: (app auth)
Description: Ties a (scm net http session) config to the database.
  secret (the session secret, a string) signs remote links; without it
  there are none."
      (%make-auth session-config db
                  (and (pair? secret)
                       (hmac-sha256 (string->utf8 (car secret))
                                    (string->utf8 "folien remote link v1")))))

    ;; --- remote links -------------------------------------------------

    ;; How long a remote link works: a talk's day.
    (define remote-link-seconds (* 12 3600))

    (define (remote-mac auth uid deck epoch exp stamp)
      (bytevector->hex
       (hmac-sha256 (auth-remote-key auth)
                    (string->utf8 (string-append "1|" uid "|" deck "|" epoch "|" exp "|" stamp)))))

    (define (->str x) (if (number? x) (number->string x) x))

    (define (make-remote-token auth user deck-id epoch now)
      "Syntax: (make-remote-token auth user deck-id epoch now)
Library: (app auth)
Description: A remote link token for user's deck deck-id at its remote
  epoch, valid remote-link-seconds from now (seconds since the epoch):
  \"1.<user>.<deck>.<epoch>.<expiry>.<signature>\"."
      (let ((uid (->str (col user "id")))
            (exp (number->string (+ (exact (floor now)) remote-link-seconds)))
            (ep (number->string epoch)))
        (string-append "1." uid "." deck-id "." ep "." exp "."
                       (remote-mac auth uid deck-id ep exp (password-stamp (col user "pass_hash"))))))

    (define (remote-token-user auth token deck-id epoch-of now)
      "Syntax: (remote-token-user auth token deck-id epoch-of now)
Library: (app auth)
Description: The row of the user who made token, if it is a valid,
  unexpired remote link for deck-id: signed, the user's password
  unchanged, and its epoch the deck's current one. epoch-of: user id ->
  the deck's remote epoch if that user may see it, else #f. Else #f."
      (let ((parts (and (string? token) (< (string-length token) 400) (split-dots token))))
        (and parts
             (= (length parts) 6)
             (equal? (car parts) "1")
             (auth-remote-key auth)
             (let ((uid (list-ref parts 1)) (deck (list-ref parts 2)) (ep (list-ref parts 3))
                   (exp (list-ref parts 4)) (mac (list-ref parts 5)))
               (and (equal? deck deck-id)
                    (string->number exp)
                    (> (string->number exp) now)
                    (string->number uid)
                    (let ((user (load-user (auth-db auth) (string->number uid))))
                      (and user
                           (same-text? mac (remote-mac auth uid deck ep exp
                                                       (password-stamp (col user "pass_hash"))))
                           (let ((current (epoch-of (string->number uid))))
                             (and current (equal? (number->string current) ep)))
                           user)))))))

    (define (remote-token-deck token)
      "Syntax: (remote-token-deck token)
Library: (app auth)
Description: The deck id a remote link token names (unchecked), or #f."
      (let ((parts (and (string? token) (< (string-length token) 400) (split-dots token))))
        (and parts (= (length parts) 6) (list-ref parts 2))))

    (define (split-dots s)
      (let loop ((i 0) (start 0) (acc '()))
        (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
              ((char=? (string-ref s i) #\.) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
              (else (loop (+ i 1) start acc)))))

    ;; Compares all of both, so the time taken does not tell how much of a
    ;; forged signature was right.
    (define (same-text? a b)
      (and (= (string-length a) (string-length b))
           (let loop ((i 0) (diff 0))
             (if (= i (string-length a))
                 (= diff 0)
                 (loop (+ i 1)
                       (if (char=? (string-ref a i) (string-ref b i)) diff 1))))))

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
