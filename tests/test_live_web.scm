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
        (scm json simple)
        (scm zip)
        (scheme file)
        (srfi 18)
        (scm net sockets)
        (scm net http server))

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
  (define data-dir (mktempdir '(prefix . "folien-live-data")))
  (define app
    (make-app `((url-prefix . "")
                (static-dir . ,(string-append root "/static"))
                (data-dir . ,data-dir)
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
  (define (filter-decks db title)
    (db-rows db "SELECT id FROM presentations WHERE title = $1" title))
  (define (send-bytes method url cookie bytes)
    (parameterize ((log-port (open-output-string)))
      (app (make-http-request method url
                              (append (if cookie (list (cons "Cookie" cookie)) '())
                                      '(("Content-Type" . "application/octet-stream")))
                              bytes))))
  (define (status r) (http-response-status r))
  ;; The deck id from a redirect to /decks/<id>.
  (define (deck-id-of r) (substring (location r) 7 (string-length (location r))))
  (define (user-id name) (let ((id (col (find-user-by-name db name) "id")))
                           (if (number? id) (number->string id) id)))

  ;; A fresh schema, and an admin as bin/seed-admin.scm makes one.
  (db-exec db "DROP TABLE IF EXISTS presentation_shares, presentation_assets, assets, presentations, user_roles, roles, users, schema_migrations")
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

          ;; Assets: upload, list, fetch (with ranges), use in the document.
          (let* ((png (bytevector-append
                       (bytevector #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A)
                       (make-bytevector 100 1)))
                 (up (send-bytes "POST" (string-append api "/assets?name=a%2Fb.png&w=10&h=20") carol png))
                 (asset (json-body up))
                 (sha (jref asset "sha"))
                 (asset-url (string-append api "/assets/" sha)))
            (test-equal 201 (status up))
            (test-equal "image/png" (jref asset "mime"))
            (test-equal "b.png" (jref asset "name"))
            (test-equal 108 (jref asset "size"))
            (test-equal 10 (jref asset "width"))
            (test-equal 64 (string-length sha))
            ;; the same file again: one asset
            (send-bytes "POST" (string-append api "/assets?name=again.png") carol png)
            (test-equal 1 (vector-length (json-body (send "GET" (string-append api "/assets") carol))))
            (let ((r (send "GET" asset-url carol)))
              (test-equal 200 (status r))
              (test-equal "image/png" (http-response-header r "Content-Type"))
              (test-assert (has? (http-response-header r "Content-Security-Policy") "sandbox"))
              (test-assert (has? (http-response-header r "Cache-Control") "immutable"))
              (test-equal png (http-response-body r)))
            (let ((r (parameterize ((log-port (open-output-string)))
                       (app (make-http-request "GET" asset-url
                                               (list (cons "Cookie" carol) '("Range" . "bytes=0-3"))
                                               #f)))))
              (test-equal 206 (status r))
              (test-equal (bytevector #x89 #x50 #x4E #x47) (http-response-body r)))
            ;; Not for other users, not for unknown hashes.
            (test-equal 404 (status (send "GET" asset-url dave)))
            (test-equal 404 (status (send "GET" (string-append api "/assets/" (make-string 64 #\0)) carol)))
            (test-equal 404 (status (send-bytes "POST" (string-append api "/assets") dave png)))
            (test-equal 415 (status (send-bytes "POST" (string-append api "/assets") carol
                                                (string->utf8 "#!/bin/sh"))))
            (test-equal 400 (status (send-bytes "POST" (string-append api "/assets") carol (bytevector))))
            ;; An SVG is recognised as such.
            (test-equal "image/svg+xml"
              (jref (json-body (send-bytes "POST" (string-append api "/assets?name=x.svg") carol
                                           (string->utf8 "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>")))
                    "mime"))
            ;; The document may use it; a bad reference is refused.
            (let* ((slide (vector-ref (doc-slides doc) 0))
                   (img `(("id" . "img1") ("type" . "image") ("x" . 0) ("y" . 0) ("w" . 100) ("h" . 100)
                          ("asset" . ,sha)))
                   (with-img (lambda (a)
                               `(("format" . 1)
                                 ("slides" . ,(vector
                                               (map (lambda (p)
                                                      (if (equal? (car p) "elements")
                                                          (cons "elements" (vector (map (lambda (q) (if (equal? (car q) "asset") (cons "asset" a) q)) img)))
                                                          p))
                                                    slide)))))))
              (test-equal 400 (status (send-json "PUT" api carol `(("revision" . 4) ("doc" . ,(with-img "../../etc/passwd"))))))
              (test-equal 200 (status (send-json "PUT" api carol `(("revision" . 4) ("doc" . ,(with-img sha))))))
              (test-equal 200 (status (send-json "PUT" api carol `(("revision" . 5) ("doc" . ,doc))))))
            (test-assert (file-exists? (string-append data-dir "/assets/" (substring sha 0 2) "/" sha))))

;; PDF export.
          (let ((r (send "GET" (string-append "/decks/" id "/export.pdf?per-page=2&notes=1") carol)))
            (test-equal 200 (status r))
            (test-equal "application/pdf" (http-response-header r "Content-Type"))
            (test-assert (has? (http-response-header r "Content-Disposition") "(Notizen) (2 pro Seite).pdf"))
            (test-equal "%PDF" (utf8->string (bytevector-copy (http-response-body r) 0 4))))
          (test-equal 400 (status (send "GET" (string-append "/decks/" id "/export.pdf?per-page=3") carol)))
          (let ((r (send "GET" (string-append "/decks/" id "/export.pptx") carol)))
            (test-equal 200 (status r))
            (test-assert (has? (http-response-header r "Content-Type") "presentationml"))
            (test-equal "PK" (utf8->string (bytevector-copy (http-response-body r) 0 2))))
          (test-equal 404 (status (send "GET" (string-append "/decks/" id "/export.pptx") dave)))
          (test-equal 404 (status (send "GET" (string-append "/decks/" id "/export.pdf") dave)))
          (test-assert (has? (body (send "GET" (string-append "/decks/" id) carol)) "export.pdf"))

          ;; Presenting: the pages, and messages through the event stream.
          (for-each
           (lambda (page)
             (let ((r (send "GET" (string-append "/decks/" id "/" page) carol)))
               (test-equal page 200 (status r))
               (test-assert page (has? (body r) (string-append "js/" page ".js")))
               (test-assert page (has? (body r) "data-events-url")))
             (test-equal 404 (status (send "GET" (string-append "/decks/" id "/" page) dave))))
           '("present" "presenter" "remote"))
          (let ((events (string-append api "/events")))
            (test-equal 202 (status (send-json "POST" events carol
                                               '(("type" . "goto") ("pos" . (("slide" . 1) ("step" . 0)))))))
            (test-equal 0 (jref (json-body (send-json "POST" events carol '(("type" . "hello")))) "listeners"))
            (test-equal 400 (status (send-json "POST" events carol '(("type" . "eval")))))
            (test-equal 400 (status (send-json "POST" events carol
                                               '(("type" . "goto") ("pos" . (("slide" . "x") ("step" . 0)))))))
            (test-equal 400 (status (send-json "POST" events carol '(("type" . "blank") ("blank" . "red")))))
            (test-equal 404 (status (send-json "POST" events dave '(("type" . "hello")))))
            (test-equal 404 (status (send "GET" events dave)))
            ;; A real server: a listener gets what another client posts.
            (let ((server (tcp-http-serve 18190 app 0 "127.0.0.1" 0 0 500)))
              (dynamic-wind
                (lambda () #f)
                (lambda ()
                  (thread-sleep! 0.3)
                  (let* ((s (tcp-connect "127.0.0.1" 18190))
                         (out (socket-binary-output-port s))
                         (in (socket-binary-input-port s))
                         ;; Byte by byte: read-bytevector would wait for a
                         ;; full buffer, and an event stream does not end.
                         (read-until
                          (lambda (part)
                            (let loop ((acc '()))
                              (let ((text (utf8->string (apply bytevector (reverse acc)))))
                                (if (string-contains-from text part 0)
                                    text
                                    (let ((b (read-u8 in)))
                                      (if (eof-object? b) text (loop (cons b acc))))))))))
                    (write-bytevector
                     (string->utf8 (string-append "GET " events " HTTP/1.1\r\nHost: x\r\nCookie: " carol "\r\n\r\n"))
                     out)
                    (flush-output-port out)
                    (let ((head (read-until "retry: 2000")))
                      (test-assert (has? head "200 OK"))
                      (test-assert (has? head "text/event-stream")))
                    (test-equal 1 (jref (json-body (send-json "POST" events carol
                                                              '(("type" . "state") ("pos" . (("slide" . 0) ("step" . 1)))
                                                                ("blank" . "black") ("from" . "w1"))))
                                        "listeners"))
                    (test-assert (has? (read-until "\"w1\"}")
                                       "data: {\"type\":\"state\",\"pos\":{\"slide\":0,\"step\":1},\"blank\":\"black\",\"from\":\"w1\"}"))
                    (socket-close s)))
                (lambda () (server-stop server)))))

          ;; Invalid documents are refused.
          (let ((r (send-json "PUT" api carol `(("revision" . 6) ("doc" . (("format" . 1)))))))
            (test-equal 400 (status r))
            (test-assert (has? (jref (json-body r) "error") "slides")))
          (test-equal 400 (status (send "PUT" api carol "not json")))

          ;; Archived decks are read-only, and come back when restored.
          (send "POST" (string-append "/decks/" id "/archive") carol)
          (test-assert (not (has? (body (send "GET" "/" carol)) ">Neu<")))
          (test-assert (has? (body (send "GET" "/archive" carol)) ">Neu<"))
          (test-equal (string-append "/decks/" id)
                      (location (send "GET" (string-append "/decks/" id "/edit") carol)))
          (test-equal 403 (status (send-json "PUT" api carol `(("revision" . 6) ("doc" . ,doc)))))
          (test-equal 403 (status (send-bytes "POST" (string-append api "/assets") carol (bytevector #xFF #xD8 #xFF 0))))
          (send "POST" (string-append "/decks/" id "/restore") carol)
          (test-equal 200 (status (send-json "PUT" api carol `(("revision" . 6) ("doc" . ,doc)))))

          ;; Duplicate and rename.
          (send "POST" (string-append "/decks/" id "/duplicate") carol)
          ;; the copy has the assets too
          (let ((copy-id (col (car (filter-decks db "Neu (Kopie)")) "id")))
            (test-equal 2 (vector-length (json-body (send "GET" (string-append "/api/decks/" copy-id "/assets") carol)))))
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

    (test-group "bundles: export, import, refusals"
      (send "POST" "/admin/users" admin "username=erin&password=erinpassword")
      (let* ((erin (sign-in "erin" "erinpassword"))
             (id (deck-id-of (send "POST" "/decks" erin "title=B%C3%BCndel&design=zh")))
             (api (string-append "/api/decks/" id))
             (png (bytevector-append (bytevector #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A)
                                     (make-bytevector 50 7)))
             (sha (jref (json-body (send-bytes "POST" (string-append api "/assets?name=b.png") erin png)) "sha"))
             (deck (json-body (send "GET" api erin)))
             (slide (vector-ref (doc-slides (jref deck "doc")) 0))
             (doc `(("format" . 1)
                    ("slides" . ,(vector
                                  (map (lambda (p)
                                         (if (equal? (car p) "elements")
                                             (cons "elements"
                                                   (vector-append
                                                    (cdr p)
                                                    (vector `(("id" . "img") ("type" . "image") ("asset" . ,sha)
                                                              ("x" . 100) ("y" . 100) ("w" . 400) ("h" . 300)))))
                                             p))
                                       slide)))))
             (count-decks (lambda ()
                            (let ((n (db-scalar db "SELECT count(*) FROM presentations WHERE owner_id = $1"
                                                (col (find-user-by-name db "erin") "id"))))
                              (if (string? n) (string->number n) n)))))
        (test-equal 200 (status (send-json "PUT" api erin `(("revision" . 1) ("doc" . ,doc)))))
        (let* ((r (send "GET" (string-append "/decks/" id "/export.zip") erin))
               (zip-bytes (http-response-body r))
               (zip-file (string-append data-dir "/test-export.zip")))
          (test-equal 200 (status r))
          (test-equal "application/zip" (http-response-header r "Content-Type"))
          (test-assert (has? (http-response-header r "Content-Disposition") ".zip"))
          (let ((p (open-binary-output-file zip-file)))
            (write-bytevector zip-bytes p)
            (close-port p))
          (call-with-input-zip zip-file
            (lambda (z)
              (let ((names (zip-entry-names z)))
                (for-each (lambda (n) (test-assert n (member n names)))
                          (list "manifest.json" "presentation.json" "LIESMICH.txt"
                                (string-append "assets/" sha ".png")
                                "exports/folien.pdf" "exports/notizen.pdf"
                                "exports/handout-2.pdf" "exports/handout-4.pdf" "exports/folien.pptx"
                                "player/index.html" "player/deck-data.js" "player/folien-player.js"
                                "player/css/slides.css" "player/fonts/Inter-Regular.woff2"))
                (test-equal png (zip-read-entry-bytevector z (string-append "assets/" sha ".png")))
                (test-equal "Bündel"
                  (jref (json-parse (utf8->string (zip-read-entry-bytevector z "manifest.json"))) "title")))))
          ;; The same file again comes from the cache.
          (test-equal zip-bytes (http-response-body (send "GET" (string-append "/decks/" id "/export.zip") erin)))
          ;; Import: a new deck with the same document and its asset.
          (let* ((before (count-decks))
                 (r (send-bytes "POST" "/api/import" erin zip-bytes))
                 (new-id (jref (json-body r) "id"))
                 (new-deck (json-body (send "GET" (string-append "/api/decks/" new-id) erin))))
            (test-equal 201 (status r))
            (test-assert (not (equal? new-id id)))
            (test-equal (+ before 1) (count-decks))
            (test-equal "Bündel" (jref new-deck "title"))
            (test-equal "zh" (jref new-deck "design"))
            ;; (compared as stored: jsonb orders the keys)
            (test-equal (json->string (jref (json-body (send "GET" api erin)) "doc"))
                        (json->string (jref new-deck "doc")))
            (test-equal 200 (status (send "GET" (string-append "/api/decks/" new-id "/assets/" sha) erin))))
          ;; Somebody else's import is theirs: dave cannot see erin's deck.
          (test-equal 404 (status (send "GET" (string-append "/api/decks/" id) (sign-in "dave" "davepassword")))))

        ;; Refusals: nothing is created.
        (let* ((before (count-decks))
               (zip (lambda (entries)
                      (call-with-output-zip-bytevector
                       (lambda (z)
                         (for-each (lambda (e)
                                     (zip-add-stored-entry z (car e)
                                                           (if (string? (cdr e)) (string->utf8 (cdr e)) (cdr e))))
                                   entries)))))
               (manifest (lambda (extra)
                           (json->string `(("format" . "folien-bundle") ("version" . 1) ("title" . "X")
                                           ("design" . "zh") ,@extra))))
               (good-doc (json->string doc))
               (refused (lambda (label bytes part)
                          (let ((r (send-bytes "POST" "/api/import" erin bytes)))
                            (test-equal label 400 (status r))
                            (test-assert label (has? (jref (json-body r) "error") part))))))
          (refused "not a zip" (string->utf8 "hello") "kein lesbares ZIP")
          (refused "empty" (bytevector) "leer")
          (refused "no manifest" (zip `(("presentation.json" . ,good-doc))) "manifest.json fehlt")
          (refused "wrong format" (zip `(("manifest.json" . "{\"format\":\"other\"}"))) "kein Folien-Archiv")
          (refused "newer" (zip `(("manifest.json" . ,(json->string '(("format" . "folien-bundle") ("version" . 99))))))
                   "neueren Version")
          (refused "bad json" (zip `(("manifest.json" . ,(manifest '())) ("presentation.json" . "{"))) "kein gültiges JSON")
          (refused "invalid doc" (zip `(("manifest.json" . ,(manifest '())) ("presentation.json" . "{\"format\":1}")))
                   "ungültig")
          (refused "asset missing" (zip `(("manifest.json" . ,(manifest '())) ("presentation.json" . ,good-doc)))
                   "fehlt ein Bild")
          (refused "asset tampered"
                   (zip `(("manifest.json" . ,(manifest '())) ("presentation.json" . ,good-doc)
                          (,(string-append "assets/" sha ".png") . ,(bytevector-append png (bytevector 1)))))
                   "Prüfsumme")
          (test-equal before (count-decks)))))

    (test-group "sharing"
      (send "POST" "/admin/users" admin "username=frank&password=frankpassword")
      (send "POST" "/admin/users" admin "username=gina&password=ginapassword")
      (let* ((frank (sign-in "frank" "frankpassword"))
             (gina (sign-in "gina" "ginapassword"))
             (id (deck-id-of (send "POST" "/decks" frank "title=Geteilt&design=folien")))
             (api (string-append "/api/decks/" id))
             (page (string-append "/decks/" id))
             (png (bytevector-append (bytevector #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A) (make-bytevector 20 3)))
             (sha (jref (json-body (send-bytes "POST" (string-append api "/assets") frank png)) "sha"))
             (gina-id (user-id "gina"))
             (doc (jref (json-body (send "GET" api frank)) "doc"))
             (rev (lambda () (jref (json-body (send "GET" api frank)) "revision")))
             (status-of (lambda () (jref (json-body (send "GET" api frank)) "status"))))
        (test-equal "not shared yet" 404 (status (send "GET" api gina)))
        (test-assert (not (has? (body (send "GET" "/shared" gina)) (string-append "/decks/" id))))
        ;; View
        (test-equal (string-append page "?m=shared")
                    (location (send "POST" (string-append page "/shares") frank "username=gina&role=view")))
        (test-assert (has? (body (send "GET" "/shared" gina)) (string-append "/decks/" id)))
        (test-assert (has? (body (send "GET" "/shared" gina)) "darf ansehen"))
        (test-equal 200 (status (send "GET" api gina)))
        (test-equal "view" (jref (json-body (send "GET" api gina)) "role"))
        (test-assert (has? (body (send "GET" page gina)) "von frank, Sie dürfen ansehen"))
        (test-assert "no sharing card for others" (not (has? (body (send "GET" page gina)) "Freigeben</h3>")))
        (test-assert (has? (body (send "GET" page frank)) "Freigeben</h3>"))
        (test-equal 403 (status (send-json "PUT" api gina `(("revision" . ,(rev)) ("doc" . ,doc)))))
        (test-equal (string-append page "?m=read-only") (location (send "GET" (string-append page "/edit") gina)))
        (test-equal (string-append page "?m=read-only")
                    (location (send "POST" (string-append page "/rename") gina "title=Gekapert")))
        (test-equal 200 (status (send "GET" (string-append api "/assets/" sha) gina)))
        (test-equal 403 (status (send-bytes "POST" (string-append api "/assets") gina png)))
        (test-equal 200 (status (send "GET" (string-append page "/export.pdf") gina)))
        (test-equal 200 (status (send "GET" (string-append page "/present") gina)))
        ;; only the owner archives, trashes, deletes, shares
        (send "POST" (string-append page "/archive") gina)
        (send "POST" (string-append page "/trash") gina)
        (test-equal "active" (status-of))
        (test-equal (string-append page "?m=not-owner")
                    (location (send "POST" (string-append page "/shares") gina "username=dave&role=edit")))
        ;; a copy for gina is hers
        (send "POST" (string-append page "/duplicate") gina)
        (test-assert (has? (body (send "GET" "/" gina)) "Geteilt (Kopie)"))
        ;; Edit
        (send "POST" (string-append page "/shares") frank "username=gina&role=edit")
        (test-equal "edit" (jref (json-body (send "GET" api gina)) "role"))
        (test-equal 200 (status (send-json "PUT" api gina `(("revision" . ,(rev)) ("doc" . ,doc)))))
        (test-equal 201 (status (send-bytes "POST" (string-append api "/assets") gina
                                            (bytevector-append png (bytevector 9)))))
        (test-equal 200 (status (send "GET" (string-append page "/edit") gina)))
        (test-equal (string-append page "?m=no-user")
                    (location (send "POST" (string-append page "/shares") frank "username=nobody&role=view")))
        (test-equal (string-append page "?m=not-owner")
                    (location (send "POST" (string-append page "/shares") frank "username=frank&role=view")))
        ;; in the trash, the deck is gone for those it is shared with
        (send "POST" (string-append page "/trash") frank)
        (test-equal 404 (status (send "GET" api gina)))
        (send "POST" (string-append page "/restore") frank)
        (test-equal 200 (status (send "GET" api gina)))
        ;; unshare
        (test-equal (string-append page "?m=unshared")
                    (location (send "POST" (string-append page "/shares/" gina-id "/delete") frank)))
        (test-equal 404 (status (send "GET" api gina)))
        (test-equal 404 (status (send "GET" (string-append api "/assets/" sha) gina)))))

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
