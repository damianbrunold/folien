;; Tests against a real PostgreSQL database: sign-in, sessions, the admin
;; console, transactions. They DROP the app's tables first, so they only run
;; against a database whose name ends in "_test", given by a config file:
;;
;;   FOLIEN_TEST_CONFIG=tests/test-config.scm scm tests/test_live_web.scm
;;
;; (a copy of config.scm with db-name "folien_test"). Without the
;; variable the tests are skipped.

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (scm module)
        (scm fs)
        (scm log)
        (scm string)
        (scm test)
        (scm crypto)
        (scm crypto password)
        (scm net http request)
        (scm net http response)
        (scm json simple))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app config) (app db) (app users) (app model) (app web))

(test-runner-factory scm-test-runner)
(test-begin "folien web (live database)")

(define config-path (get-environment-variable "FOLIEN_TEST_CONFIG"))

(define (run-tests cfg)
  (define fast-iterations 1000)
  (define db
    (make-db (config-ref cfg 'db-host "127.0.0.1") (config-ref cfg 'db-port 5432)
             (config-ref cfg 'db-user "") (config-ref cfg 'db-password "")
             (config-ref cfg 'db-name "") 2))
  (define app
    (make-app `((url-prefix . "")
                (static-dir . ,(string-append root "/static"))
                (db . ,db)
                (session-secret . ,(base64-encode (random-bytes 32)))
                (session-max-age . 3600)
                (secure-cookies? . #f))))
  (define (send method url cookie . form)
    (parameterize ((log-port (open-output-string))
                   (password-pbkdf2-iterations fast-iterations))
      (app (make-http-request
            method url
            (append (if cookie (list (cons "Cookie" cookie)) '())
                    (if (pair? form)
                        '(("Content-Type" . "application/x-www-form-urlencoded"))
                        '()))
            (if (pair? form) (car form) #f)))))
  (define (location r) (http-response-header r "Location"))
  (define (body r)
    (let ((b (http-response-body r)))
      (if (bytevector? b) (utf8->string b) b)))
  (define (has? s part) (and (string? s) (string-contains-from s part 0) #t))
  (define (cookie-of r)
    (let ((h (http-response-header r "Set-Cookie")))
      (and h (car (string-split-char h #\;)))))
  (define (sign-in name password)
    (cookie-of (send "POST" "/login" #f
                     (string-append "username=" name "&password=" password))))
  (define (send-json method url cookie value)
    (parameterize ((log-port (open-output-string)))
      (app (make-http-request
            method url
            (append (if cookie (list (cons "Cookie" cookie)) '())
                    '(("Content-Type" . "application/json")))
            (json->string value)))))
  (define (json-body r) (json-parse (body r)))
  (define (status r) (http-response-status r))
  ;; The deck id from a redirect to /decks/<id>.
  (define (deck-id-of r) (substring (location r) 7 (string-length (location r))))
  (define (user-id name) (let ((id (col (find-user-by-name db name) "id")))
                           (if (number? id) (number->string id) id)))

  ;; A fresh schema, and an admin as bin/seed-admin.scm makes one.
  (db-exec db "DROP TABLE IF EXISTS presentations, user_roles, roles, users, schema_migrations")
  (parameterize ((log-port (open-output-string)))
    (migrate! db (string-append root "/migrations")))
  (with-db-transaction db
    (lambda (tx)
      (create-role! tx admin-role)
      (assign-role-by-name!
       tx
       (create-user! tx "root"
                     (parameterize ((password-pbkdf2-iterations fast-iterations))
                       (password-hash "rootpassword")))
       admin-role)))

  (let ((admin (sign-in "root" "rootpassword")))
    (test-group "admin signs in"
      (test-assert admin)
      (test-assert (has? (body (send "GET" "/" admin)) "Neue Präsentation"))
      (test-equal 200 (http-response-status (send "GET" "/admin" admin))))

    (test-group "create users"
      (test-equal "/admin?m=user-created"
        (location (send "POST" "/admin/users" admin "username=bob&password=bobpassword")))
      (test-equal "/admin?m=dup-user"
        (location (send "POST" "/admin/users" admin "username=bob&password=bobpassword")))
      (test-equal "/admin?m=bad-username"
        (location (send "POST" "/admin/users" admin "username=b+b&password=bobpassword")))
      (test-equal "/admin?m=short-password"
        (location (send "POST" "/admin/users" admin "username=eve&password=short")))
      (test-equal "/admin?m=user-created"
        (location (send "POST" "/admin/users" admin "username=ann&password=annpassword&admin=1")))
      (test-equal '("admin") (user-role-names db (user-id "ann")))
      (test-equal '() (user-role-names db (user-id "bob")))
      (test-assert (has? (body (send "GET" "/admin?m=user-created" admin)) "Benutzer erstellt.")))

    (test-group "a failed transaction leaves nothing behind"
      (test-error
       (with-db-transaction db
         (lambda (tx)
           (create-user! tx "ghost" "x")
           (error "boom"))))
      (test-equal #f (find-user-by-name db "ghost")))

    (test-group "non-admins are kept out"
      (let ((bob (sign-in "bob" "bobpassword")))
        (test-equal 200 (http-response-status (send "GET" "/" bob)))
        (test-equal 403 (http-response-status (send "GET" "/admin" bob)))
        (test-equal 403 (http-response-status
                         (send "POST" "/admin/roles" bob "name=hackers")))
        (test-assert (not (has? (body (send "GET" "/" bob)) "/admin\"")))))

    (test-group "roles"
      (test-equal "/admin?m=role-created"
        (location (send "POST" "/admin/roles" admin "name=editor")))
      (test-equal "/admin?m=bad-role"
        (location (send "POST" "/admin/roles" admin "name=a+b")))
      (let ((rid (let ((r (assoc "editor" (map (lambda (r) (cons (col r "name") (col r "id")))
                                               (list-roles db)))))
                   (if (number? (cdr r)) (number->string (cdr r)) (cdr r)))))
        (send "POST" (string-append "/admin/users/" (user-id "bob") "/roles") admin
              (string-append "role_id=" rid))
        (test-equal '("editor") (user-role-names db (user-id "bob")))
        (send "POST" (string-append "/admin/users/" (user-id "bob") "/roles/" rid "/delete") admin)
        (test-equal '() (user-role-names db (user-id "bob")))))

    (test-group "an admin cannot lock themselves out"
      (let ((admin-rid (let ((id (db-scalar db "SELECT id FROM roles WHERE name = $1" admin-role)))
                         (if (number? id) (number->string id) id))))
        (test-equal "/admin?m=self-admin"
          (location (send "POST" (string-append "/admin/users/" (user-id "root")
                                                "/roles/" admin-rid "/delete")
                          admin)))
        (test-equal "/admin?m=self-delete"
          (location (send "POST" (string-append "/admin/users/" (user-id "root") "/delete")
                          admin)))))

    (test-group "sessions end with the user or the password"
      (let ((bob (sign-in "bob" "bobpassword"))
            (bob2 (sign-in "bob" "bobpassword")))
        (let ((fresh (cookie-of (send "POST" "/profile/password" bob
                                      "current=bobpassword&new=bobsnewpass&confirm=bobsnewpass"))))
          (test-assert fresh)
          (test-equal "/login" (location (send "GET" "/" bob2)))
          (test-equal 200 (http-response-status (send "GET" "/" fresh)))
          (send "POST" (string-append "/admin/users/" (user-id "bob") "/delete") admin)
          (test-equal #f (find-user-by-name db "bob"))
          (test-equal "/login" (location (send "GET" "/" fresh))))))

    (test-group "decks and the JSON API"
      (send "POST" "/admin/users" admin "username=carol&password=carolpassword")
      (send "POST" "/admin/users" admin "username=dave&password=davepassword")
      (let* ((carol (sign-in "carol" "carolpassword"))
             (dave (sign-in "dave" "davepassword"))
             (created (send "POST" "/decks" carol "title=Jahresbericht&design=zh"))
             (id (deck-id-of created))
             (api (string-append "/api/decks/" id)))
        (test-equal 303 (status created))
        (test-assert (has? (body (send "GET" "/" carol)) "Jahresbericht"))
        (test-assert (has? (body (send "GET" (string-append "/decks/" id) carol)) "Kanton Zürich"))
        (test-equal "/?m=bad-title" (location (send "POST" "/decks" carol "title=&design=zh")))
        (test-equal "/?m=bad-design" (location (send "POST" "/decks" carol "title=x&design=nope")))

        (let* ((deck (json-body (send "GET" api carol)))
               (doc (jref deck "doc")))
          (test-equal 1 (jref deck "revision"))
          (test-equal "zh" (jref deck "design"))
          (test-equal #f (validate-doc doc "zh"))

          ;; Another user cannot see or change it.
          (test-equal 404 (status (send "GET" api dave)))
          (test-equal 404 (status (send-json "PUT" api dave
                                             `(("revision" . 1) ("doc" . ,doc)))))
          (test-equal 404 (status (send "GET" (string-append "/decks/" id) dave)))

          ;; Save, then a stale save conflicts.
          (let* ((two-slides `(("format" . 1)
                               ("slides" . ,(vector (vector-ref (doc-slides doc) 0)
                                                    (new-slide "zh" "title-content")))))
                 (r (send-json "PUT" api carol `(("revision" . 1) ("doc" . ,two-slides)))))
            (test-equal 200 (status r))
            (test-equal 2 (jref (json-body r) "revision"))
            (let ((stale (send-json "PUT" api carol `(("revision" . 1) ("doc" . ,doc)))))
              (test-equal 409 (status stale))
              (test-equal 2 (jref (json-body stale) "revision")))
            (test-equal 2 (vector-length (doc-slides (jref (json-body (send "GET" api carol)) "doc")))))

          ;; Switching the design goes through the same save.
          (test-equal 200 (status (send-json "PUT" api carol
                                             `(("revision" . 2) ("design" . "folien") ("doc" . ,doc)))))
          (test-equal "folien" (jref (json-body (send "GET" api carol)) "design"))

          ;; The editor page, and a title saved with the document.
          (let ((r (send "GET" (string-append "/decks/" id "/edit") carol)))
            (test-equal 200 (status r))
            (test-assert (has? (body r) "id=\"editor\""))
            (test-assert (has? (body r) "js/editor.js")))
          (test-equal 404 (status (send "GET" (string-append "/decks/" id "/edit") dave)))
          (let ((r (send-json "PUT" api carol `(("revision" . 3) ("title" . "Neu") ("doc" . ,doc)))))
            (test-equal 200 (status r))
            (test-equal 4 (jref (json-body r) "revision"))
            (test-equal "Neu" (jref (json-body (send "GET" api carol)) "title")))
          (test-equal 400 (status (send-json "PUT" api carol `(("revision" . 4) ("title" . "") ("doc" . ,doc)))))

          ;; Invalid documents are refused.
          (let ((r (send-json "PUT" api carol `(("revision" . 4) ("doc" . (("format" . 1)))))))
            (test-equal 400 (status r))
            (test-assert (has? (jref (json-body r) "error") "slides")))
          (test-equal 400 (status (send "PUT" api carol "not json")))

          ;; Archived decks are read-only, and come back when restored.
          (send "POST" (string-append "/decks/" id "/archive") carol)
          (test-assert (not (has? (body (send "GET" "/" carol)) ">Neu<")))
          (test-assert (has? (body (send "GET" "/archive" carol)) ">Neu<"))
          (test-equal (string-append "/decks/" id)
                      (location (send "GET" (string-append "/decks/" id "/edit") carol)))
          (test-equal 403 (status (send-json "PUT" api carol `(("revision" . 4) ("doc" . ,doc)))))
          (send "POST" (string-append "/decks/" id "/restore") carol)
          (test-equal 200 (status (send-json "PUT" api carol `(("revision" . 4) ("doc" . ,doc)))))

          ;; Duplicate and rename.
          (send "POST" (string-append "/decks/" id "/duplicate") carol)
          (test-assert (has? (body (send "GET" "/" carol)) "Neu (Kopie)"))
          (send "POST" (string-append "/decks/" id "/rename") carol "title=Bericht+2026")
          (test-assert (has? (body (send "GET" "/" carol)) "Bericht 2026"))

          ;; Delete only works from the trash.
          (send "POST" (string-append "/decks/" id "/delete") carol)
          (test-equal 200 (status (send "GET" api carol)))
          (send "POST" (string-append "/decks/" id "/trash") carol)
          (test-assert (has? (body (send "GET" "/trash" carol)) "Bericht 2026"))
          (send "POST" (string-append "/decks/" id "/delete") carol)
          (test-equal 404 (status (send "GET" api carol))))))

    (test-group "outdated hashes are upgraded at sign-in"
      (parameterize ((password-pbkdf2-iterations 500))
        (create-user! db "old" (password-hash "oldpassword")))
      (test-assert (sign-in "old" "oldpassword"))
      (test-assert
       (not (parameterize ((password-pbkdf2-iterations fast-iterations))
              (password-needs-rehash? (col (find-user-by-name db "old") "pass_hash"))))))))

(cond
  ((not config-path)
   (display "skipped: set FOLIEN_TEST_CONFIG to a config for a *_test database\n"))
  (else
   (let* ((cfg (read-config config-path))
          (name (config-ref cfg 'db-name "")))
     (if (and (>= (string-length name) 5)
              (string=? (substring name (- (string-length name) 5) (string-length name))
                        "_test"))
         (run-tests cfg)
         (error "refusing to run: db-name must end in _test" name)))))

(test-end "folien web (live database)")
