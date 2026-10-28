;; (app web) — routes, request handlers and the middleware stack.
;;
;; make-app returns the server-level handler (lambda (req) resp): bin/server.scm
;; serves it, and the tests call it directly with a request.
;;
;; Pages are server-rendered forms with POST/redirect/GET. The editor talks
;; to the JSON API under /api: a deck is read with GET and saved with PUT
;; naming the revision it is based on; a save over a newer revision gets
;; 409 so that two tabs cannot silently overwrite each other.
;;
;; The privileged role is "admin"; bin/seed-admin.scm creates it and grants
;; it to the first user. Forms need no CSRF token: the session cookie is
;; SameSite=Strict, so the browser never sends it with a request that
;; another site started.

(define-library (app web)
  (import (scheme base)
          (srfi 18)
          (scm crypto password)
          (scm json simple)
          (scm uri)
          (scm fs)
          (scm crypto)
          (scheme time)
          (scheme file)
          (scm net http request)
          (scm net http response)
          (scm net http route)
          (scm net http forms)
          (scm net http static)
          (scm net http session)
          (scm net http middleware)
          (app site)
          (app db)
          (app users)
          (app auth)
          (app designs)
          (app model)
          (app decks)
          (app assets)
          (app remote)
          (app export-pdf)
          (app bundle)
          (app views))
  (export make-app admin-role)
  (begin

    (define admin-role "admin")
    (define cookie-name "folien_session")

    (define (setting settings key)
      (let ((p (assq key settings)))
        (if p (cdr p) (error "make-app: missing setting" key))))

    ;; 303 to a path in the app, optionally with header pairs (cookies).
    (define (redirect path . headers)
      (make-http-response 303 (cons (cons "Location" (url path)) headers) ""))

    ;; A failed password check costs the client half a second, which slows
    ;; down guessing.
    (define (penalty) (thread-sleep! 0.5))

    (define (id->string x) (if (number? x) (number->string x) x))

    ;; Results travel across the POST/redirect/GET as a code in the query
    ;; string: /admin?m=<code>.
    (define notices
      '(("user-created"   success . "Benutzer erstellt.")
        ("user-deleted"   success . "Benutzer gelöscht.")
        ("role-created"   success . "Rolle erstellt.")
        ("role-assigned"  success . "Rolle zugewiesen.")
        ("role-removed"   success . "Rolle entfernt.")
        ("dup-user"       error   . "Dieser Benutzername ist schon vergeben.")
        ("bad-username"   error   . "Ungültiger Benutzername (Buchstaben, Ziffern, . _ -).")
        ("short-password" error   . "Das Passwort muss mindestens 8 Zeichen haben.")
        ("bad-role"       error   . "Ungültiger Rollenname.")
        ("self-delete"    error   . "Sie können Ihr eigenes Konto nicht löschen.")
        ("self-admin"     error   . "Sie können sich die Admin-Rolle nicht selbst entziehen.")
        ("duplicated"     success . "Präsentation dupliziert.")
        ("archived"       success . "Präsentation archiviert.")
        ("restored"       success . "Präsentation reaktiviert.")
        ("trashed"        success . "Präsentation in den Papierkorb verschoben.")
        ("deleted"        success . "Präsentation endgültig gelöscht.")
        ("renamed"        success . "Präsentation umbenannt.")
        ("bad-title"      error   . "Der Titel muss 1 bis 200 Zeichen lang sein.")
        ("bad-design"     error   . "Unbekanntes Design.")))

    (define (notice-from-query req)
      (let* ((q (url-query-params (http-request-url req)))
             (code (assoc "m" q))
             (n (and code (assoc (cdr code) notices))))
        (and n (cons (cadr n) (cddr n)))))

    (define (to-admin code) (redirect (string-append "/admin?m=" code)))

    ;; --- JSON helpers -------------------------------------------------

    (define (json-status status value)
      (make-http-response status
                          '(("Content-Type" . "application/json; charset=utf-8")
                            ("Cache-Control" . "no-store"))
                          (json->string value)))

    (define (json-error status message)
      (json-status status `(("error" . ,message))))

    (define (parse-json-body req)
      ;; The parsed body, or #f if it is missing or not JSON.
      (let ((body (http-request-body req)))
        (and body
             (guard (e (#t #f))
               (json-parse body)))))

    (define (deck->json deck)
      `(("id" . ,(col deck "id"))
        ("title" . ,(col deck "title"))
        ("design" . ,(col deck "design"))
        ("status" . ,(col deck "status"))
        ("revision" . ,(->int (col deck "revision")))
        ("doc" . ,(deck-doc deck))))

    ;; --- assets ---------------------------------------------------------

    (define (number-or-null v)
      (cond ((number? v) v)
            ((and (string? v) (string->number v)) => (lambda (n) n))
            (else 'null)))

    (define (asset->json row)
      `(("sha" . ,(col row "sha256"))
        ("mime" . ,(col row "mime"))
        ("size" . ,(number-or-null (col row "size")))
        ("width" . ,(number-or-null (col row "width")))
        ("height" . ,(number-or-null (col row "height")))
        ("name" . ,(col row "name"))))

    ;; The client's file name, without directories, at most 200 characters.
    (define (clean-name s)
      (let* ((s (or s "upload"))
             (base (let loop ((i (- (string-length s) 1)))
                     (cond ((< i 0) s)
                           ((memv (string-ref s i) '(#\/ #\\)) (substring s (+ i 1) (string-length s)))
                           (else (loop (- i 1))))))
             (base (if (string=? base "") "upload" base)))
        (if (> (string-length base) 200) (substring base 0 200) base)))

    ;; Assets are content-addressed, so a URL never changes its content:
    ;; cached for good. The sandbox policy keeps an uploaded SVG opened on
    ;; its own from running script.
    (define asset-csp "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox")

;; The default policy of (scm net http middleware), plus blob: images
    ;; and media: the editor reads dropped files through object URLs.
    (define csp
      (string-append "default-src 'self'; script-src 'self'; style-src 'self'; "
                     "img-src 'self' data: blob:; media-src 'self' blob:; "
                     "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; "
                     "base-uri 'none'; object-src 'none'"))

;; --- export -----------------------------------------------------------

    ;; attachment; filename="<ascii fallback>"; filename*=UTF-8''<encoded>
    (define (download-disposition name)
      (string-append
       "attachment; filename=\""
       (string-map (lambda (c)
                     (if (and (char<=? #\space c #\~) (not (memv c '(#\" #\\ #\/))))
                         c
                         #\_))
                   name)
       "\"; filename*=UTF-8''" (percent-encode name)))

    ;; Options of a PDF export from the query string; #f if invalid.
    (define (pdf-options q)
      (let* ((get (lambda (k d) (let ((p (assoc k q))) (if p (cdr p) d))))
             (per-page (string->number (get "per-page" "1")))
             (notes (get "notes" "0"))
             (builds (get "builds" "final")))
        (and (memv per-page '(1 2 4))
             (member notes '("0" "1"))
             (member builds '("final" "steps"))
             `((per-page . ,per-page)
               (notes . ,(string=? notes "1"))
               (builds . ,(string->symbol builds))))))

    (define (pdf-file-name title opts)
      (string-append
       title
       (if (cdr (assq 'notes opts)) " (Notizen)" "")
       (let ((n (cdr (assq 'per-page opts))))
         (if (= n 1) "" (string-append " (" (number->string n) " pro Seite)")))
       ".pdf"))

;; Bundles are built into data-dir/bundles, once per version of a deck
    ;; (its revision, title and design), and served from there; files older
    ;; than a day are removed when the next one is built.
    (define bundle-max-age-ms (* 24 60 60 1000))

    (define (bundle-file data-dir static-dir db deck)
      (let* ((dir (string-append data-dir "/bundles"))
             (key (bytevector->hex
                   (bytevector-copy
                    (sha256-hash (string-append (col deck "id") "|" (id->string (col deck "revision"))
                                                "|" (col deck "title") "|" (col deck "design")
                                                "|" (number->string bundle-version)))
                    0 12)))
             (path (string-append dir "/" (col deck "id") "-" key ".zip")))
        (unless (directory-exists? dir)
          (guard (e (#t #f)) (make-directory dir)))
        (unless (file-exists? path)
          (let ((now-ms (* 1000 (current-second))))
            (for-each (lambda (f)
                        (let ((p (string-append dir "/" f)))
                          (guard (e (#t #f))
                            (when (> (- now-ms (file-modification-timestamp p)) bundle-max-age-ms)
                              (delete-file p)))))
                      (directory-files dir)))
          (let ((tmp (string-append path ".tmp-" (random-string "abcdefghijklmnop" 8))))
            (guard (e (#t (when (file-exists? tmp) (delete-file tmp)) (raise e)))
              (write-bundle! db data-dir static-dir deck tmp)
              (move-file tmp path))))
        path))

    ;; --- presenting -----------------------------------------------------

    ;; Messages between presenting windows, rebuilt from the fields that
    ;; are known so nothing else passes through: {"type": "state" | "goto"
    ;; | "blank" | "hello", "pos"?: {"slide", "step"}, "blank"?: null |
    ;; "black" | "white", "from"?: string}.
    (define (clean-message m)
      (and (list? m)
           (let ((type (jref m "type"))
                 (pos (jref m "pos"))
                 (blank (jref m "blank" 'null))
                 (from (jref m "from")))
             (and (member type '("state" "goto" "blank" "hello"))
                  (or (not pos)
                      (and (list? pos)
                           (exact-integer? (jref pos "slide")) (<= 0 (jref pos "slide") 10000)
                           (exact-integer? (jref pos "step")) (<= 0 (jref pos "step") 10000)))
                  (member blank '(null "black" "white"))
                  (or (not from) (and (string? from) (<= (string-length from) 40)))
                  `(("type" . ,type)
                    ,@(if pos `(("pos" . (("slide" . ,(jref pos "slide"))
                                          ("step" . ,(jref pos "step")))))
                          '())
                    ("blank" . ,blank)
                    ,@(if from `(("from" . ,from)) '()))))))

    ;; A listener stays connected this long, then the browser reconnects
    ;; (EventSource does), so a thread is never held for good.
    (define stream-seconds (* 30 60))

    (define (event-stream deck-id)
      (make-http-stream-response
       200
       '(("Content-Type" . "text/event-stream; charset=utf-8")
         ("Cache-Control" . "no-store")
         ("X-Accel-Buffering" . "no"))
       (lambda (port)
         (let ((l (subscribe! deck-id))
               (send (lambda (s)
                       (write-bytevector (string->utf8 s) port)
                       (flush-output-port port))))
           (dynamic-wind
             (lambda () #f)
             (lambda ()
               (send "retry: 2000\n\n")
               ;; Writing to a client that has gone raises, which ends the
               ;; stream; a comment every 15 s finds out.
               (let loop ((left stream-seconds))
                 (when (> left 0)
                   (let ((m (next-message l 15)))
                     (send (if m (string-append "data: " m "\n\n") ": ping\n\n"))
                     (loop (if m left (- left 15)))))))
             (lambda () (unsubscribe! l)))))))

    (define (make-app settings)
      "Syntax: (make-app settings)
Library: (app web)
Description: Builds the app's request handler. settings is an alist:
  url-prefix, static-dir (absolute path), data-dir (absolute path, for
  uploaded assets), db (from make-db), session-secret, session-max-age
  (seconds), secure-cookies?."
      (let* ((site (make-site (setting settings 'url-prefix)
                              (setting settings 'static-dir)))
             (prefix (site-prefix site))
             (db (setting settings 'db))
             (data-dir (setting settings 'data-dir))
             (static-dir (setting settings 'static-dir))
             (max-upload (let ((p (assq 'max-upload-bytes settings)))
                           (if p (cdr p) (* 1024 1024 1024))))
             (auth (make-auth
                    (make-session-config
                     cookie-name
                     (setting settings 'session-secret)
                     (setting settings 'session-max-age)
                     `((path . ,(cookie-path site))
                       (secure? . ,(setting settings 'secure-cookies?))))
                    db))
             (router (make-router)))

        (define (route! method path handler)
          (router-add! router method (string-append prefix path) handler))

        (define (admin? user)
          (user-has-role? db (col user "id") admin-role))

        (define (who user) (list (col user "username") (admin? user)))

        ;; Runs handler with the signed-in user row as a third argument, or
        ;; sends the browser to the sign-in page.
        (define (signed-in handler)
          (lambda (req params)
            (let ((user (session-user auth req)))
              (if user (handler req params user) (redirect "/login")))))

        ;; The same for the JSON API: 401 instead of a redirect.
        (define (api-signed-in handler)
          (lambda (req params)
            (let ((user (session-user auth req)))
              (if user (handler req params user) (json-error 401 "not signed in")))))

        (define (admin-only handler)
          (signed-in
            (lambda (req params user)
              (if (admin? user)
                  (handler req params user)
                  (http-forbidden "Nur für Admins")))))

        (define (list-page status)
          (signed-in
            (lambda (req params user)
              (html-response
               (decks-page (who user) status (list-decks db (col user "id") status)
                           (notice-from-query req))))))

        ;; A full-window page of the owner's deck (any status).
        (define (deck-app-page render)
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (if deck
                    (html-response (render deck))
                    (make-http-response 404 '(("Content-Type" . "text/html; charset=utf-8"))
                                        (not-found-page (who user))))))))

        (define (status-change status target)
          (signed-in
            (lambda (req params user)
              (set-deck-status! db (col user "id") (params-ref params "id") status)
              (redirect target))))

        ;; no-cache: the ES modules import each other without a ?v= cache
        ;; buster, so the browser must revalidate them (cheap, by ETag).
        (route! "GET" "/static/*" (make-static-handler (setting settings 'static-dir)
                                                       '((cache-control . "no-cache"))))

        ;; --- deck lists ---

        (route! "GET" "/" (list-page "active"))
        (route! "GET" "/archive" (list-page "archived"))
        (route! "GET" "/trash" (list-page "trashed"))

        ;; --- decks ---

        (route! "POST" "/decks"
          (signed-in
            (lambda (req params user)
              (let* ((form (http-request-form req))
                     (title (form-ref form "title" ""))
                     (design (form-ref form "design" default-design-id)))
                (cond
                  ((not (valid-title? title)) (redirect "/?m=bad-title"))
                  ((not (find-design design)) (redirect "/?m=bad-design"))
                  (else
                   (redirect (string-append
                              "/decks/" (create-deck! db (col user "id") title design)))))))))

        (route! "GET" "/decks/:id"
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (if deck
                    (html-response
                     (deck-page (who user) deck
                                (vector-length (doc-slides (deck-doc deck)))
                                (notice-from-query req)))
                    (make-http-response 404 '(("Content-Type" . "text/html; charset=utf-8"))
                                        (not-found-page (who user))))))))

        ;; The editor; archived and trashed decks only have the viewer.
        (route! "GET" "/decks/:id/edit"
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (cond
                  ((not deck)
                   (make-http-response 404 '(("Content-Type" . "text/html; charset=utf-8"))
                                       (not-found-page (who user))))
                  ((not (string=? (col deck "status") "active"))
                   (redirect (string-append "/decks/" (col deck "id"))))
                  (else (html-response (editor-page deck))))))))

        (route! "POST" "/decks/:id/rename"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id"))
                    (title (form-ref (http-request-form req) "title" "")))
                (if (valid-title? title)
                    (begin (rename-deck! db (col user "id") id title)
                           (redirect (string-append "/decks/" id "?m=renamed")))
                    (redirect (string-append "/decks/" id "?m=bad-title")))))))

        (route! "POST" "/decks/:id/duplicate"
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (when deck
                  (duplicate-deck! db (col user "id") (col deck "id")
                                   (let ((t (string-append (col deck "title") " (Kopie)")))
                                     (if (valid-title? t) t (col deck "title")))))
                (redirect "/?m=duplicated")))))

        (route! "POST" "/decks/:id/archive" (status-change "archived" "/?m=archived"))
        (route! "POST" "/decks/:id/restore" (status-change "active" "/?m=restored"))
        (route! "POST" "/decks/:id/trash" (status-change "trashed" "/?m=trashed"))

        (route! "POST" "/decks/:id/delete"
          (signed-in
            (lambda (req params user)
              (delete-deck! db (col user "id") (params-ref params "id"))
              (redirect "/trash?m=deleted"))))

        ;; --- JSON API ---

        (route! "GET" "/api/designs"
          (api-signed-in
            (lambda (req params user)
              (json-status 200 (list->vector designs)))))

        (route! "GET" "/api/decks/:id"
          (api-signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (if deck
                    (json-status 200 (deck->json deck))
                    (json-error 404 "no such deck"))))))

        ;; Body: {"revision": n, "design": id, "doc": {...}, "title"?}. Answers
        ;; 200 {"revision": new}, 400 for an invalid document, 403 for an
        ;; archived or trashed deck, 404, or 409 {"revision": current} when
        ;; someone saved in between.
        (route! "PUT" "/api/decks/:id"
          (api-signed-in
            (lambda (req params user)
              (let* ((owner (col user "id"))
                     (id (params-ref params "id"))
                     (body (parse-json-body req))
                     (deck (load-deck db owner id)))
                (cond
                  ((not deck) (json-error 404 "no such deck"))
                  ((not (string=? (col deck "status") "active"))
                   (json-error 403 "deck is read-only"))
                  ((not (and (list? body) (exact-integer? (jref body "revision"))))
                   (json-error 400 "expected {revision, design, doc}"))
                  (else
                   (let* ((design (jref body "design" (col deck "design")))
                          (doc (jref body "doc"))
                          (title (jref body "title"))
                          (problem (if (and title (not (valid-title? title)))
                                       "title: must be 1 to 200 characters"
                                       (validate-doc doc design))))
                     (if problem
                         (json-error 400 problem)
                         (let ((rev (if title
                                        (save-doc! db owner id (jref body "revision") doc design title)
                                        (save-doc! db owner id (jref body "revision") doc design))))
                           (if rev
                               (json-status 200 `(("revision" . ,(->int rev))))
                               (json-status 409
                                 `(("error" . "conflict")
                                   ("revision" . ,(->int (col (load-deck db owner id)
                                                              "revision")))))))))))))))

;; --- assets ---

        ;; Body: the file. Query: name, and the client's w and h (pixels).
        ;; 201 with the asset; 400 empty, 403 read-only deck, 404, 413 too
        ;; large (from the server), 415 a type that is not accepted.
        (route! "POST" "/api/decks/:id/assets"
          (api-signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (status (deck-status db (col user "id") id))
                     (q (url-query-params (http-request-url req)))
                     (qref (lambda (k) (let ((p (assoc k q))) (and p (cdr p))))))
                (cond
                  ((not status) (json-error 404 "no such deck"))
                  ((not (string=? status "active")) (json-error 403 "deck is read-only"))
                  (else
                   (let ((r (store-upload! db data-dir id req (clean-name (qref "name"))
                                           (qref "w") (qref "h"))))
                     (cond
                       ((eq? r 'empty) (json-error 400 "empty upload"))
                       ((eq? r 'unsupported)
                        (json-error 415 "unsupported file type (PNG, JPEG, GIF, WebP, SVG, MP4, WebM)"))
                       (else (json-status 201 (asset->json r)))))))))))

        (route! "GET" "/api/decks/:id/assets"
          (api-signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (if (deck-status db (col user "id") id)
                    (json-status 200 (list->vector (map asset->json (list-deck-assets db id))))
                    (json-error 404 "no such deck"))))))

        ;; The file, with byte ranges (videos seek).
        (route! "GET" "/api/decks/:id/assets/:sha"
          (signed-in
            (lambda (req params user)
              (let* ((sha (params-ref params "sha"))
                     (row (deck-asset db (col user "id") (params-ref params "id") sha)))
                (if (not row)
                    (http-not-found)
                    (let ((r (file-response (asset-file data-dir sha)
                                            `((request . ,req)
                                              (content-type . ,(col row "mime"))
                                              (cache-control . "private, max-age=31536000, immutable")))))
                      (http-response-with-headers
                       r (http-response-status r)
                       (cons (cons "Content-Security-Policy" asset-csp)
                             (http-response-headers r)))))))))

;; --- presenting ---

        ;; The deck as PDF; query: per-page (1, 2, 4), notes (0, 1),
        ;; builds (final, steps).
        (route! "GET" "/decks/:id/export.pdf"
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id")))
                    (opts (pdf-options (url-query-params (http-request-url req)))))
                (cond
                  ((not deck) (http-not-found))
                  ((not opts) (http-bad-request "Ungültige Exportoptionen"))
                  (else
                   (make-http-response
                    200
                    `(("Content-Type" . "application/pdf")
                      ("Content-Disposition"
                       . ,(download-disposition (pdf-file-name (col deck "title") opts)))
                      ("Cache-Control" . "no-store"))
                    (deck->pdf (deck-doc deck) (col deck "design") (col deck "title")
                               data-dir opts))))))))

        ;; Everything as one zip: document, assets, PDFs, offline player.
        (route! "GET" "/decks/:id/export.zip"
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (if (not deck)
                    (http-not-found)
                    (make-http-file-response
                     200
                     `(("Content-Type" . "application/zip")
                       ("Content-Disposition"
                        . ,(download-disposition (string-append (col deck "title") ".zip")))
                       ("Cache-Control" . "no-store"))
                     (bundle-file data-dir static-dir db deck)))))))

        ;; A bundle (the zip as the body) becomes a new deck: 201 {"id"},
        ;; or 400 {"error"} with a message for the user.
        (route! "POST" "/api/import"
          (api-signed-in
            (lambda (req params user)
              (let* ((spooled (http-request-body-file req))
                     (bytes (and (not spooled) (http-request-body-bytes req)))
                     (tmp (and (not spooled)
                               (string-append data-dir "/import-" (random-string "abcdefghijklmnop" 12)))))
                (cond
                  ((and (not spooled) (or (not bytes) (= 0 (bytevector-length bytes))))
                   (json-error 400 "Die Datei ist leer."))
                  (else
                   (when tmp
                     (let ((p (open-binary-output-file tmp)))
                       (write-bytevector bytes p)
                       (close-port p)))
                   (dynamic-wind
                     (lambda () #f)
                     (lambda ()
                       (guard (e ((bundle-error? e) (json-error 400 (bundle-error-message e))))
                         (json-status 201 `(("id" . ,(import-bundle! db data-dir (col user "id")
                                                                     (or spooled tmp) max-upload))))))
                     (lambda () (when (and tmp (file-exists? tmp)) (delete-file tmp))))))))))

        (route! "GET" "/decks/:id/present" (deck-app-page present-page))
        (route! "GET" "/decks/:id/presenter" (deck-app-page presenter-page))
        (route! "GET" "/decks/:id/remote" (deck-app-page remote-page))

        (route! "GET" "/api/decks/:id/events"
          (api-signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (if (deck-status db (col user "id") id)
                    (event-stream id)
                    (json-error 404 "no such deck"))))))

        (route! "POST" "/api/decks/:id/events"
          (api-signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (body (http-request-body req))
                     (m (and body (<= (string-length body) 2000)
                             (clean-message (guard (e (#t #f)) (json-parse body))))))
                (cond
                  ((not (deck-status db (col user "id") id)) (json-error 404 "no such deck"))
                  ((not m) (json-error 400 "bad message"))
                  (else
                   (json-status 202 `(("listeners" . ,(publish! id (json->string m)))))))))))

        ;; --- sign-in ---

        (route! "GET" "/login"
          (lambda (req params)
            (if (session-user auth req)
                (redirect "/")
                (html-response (login-page #f)))))

        (route! "POST" "/login"
          (lambda (req params)
            (let* ((form (http-request-form req))
                   (user (sign-in auth (form-ref form "username" "")
                                  (form-ref form "password" ""))))
              (if user
                  (redirect "/" (start-session auth user))
                  (begin (penalty) (html-response (login-page #t)))))))

        (route! "POST" "/logout"
          (lambda (req params) (redirect "/login" (end-session auth))))

        ;; --- profile ---

        (route! "GET" "/profile"
          (signed-in
            (lambda (req params user)
              (let ((done? (assoc "updated" (url-query-params (http-request-url req)))))
                (html-response
                 (profile-page (col user "username") (admin? user)
                               (and done? '(success . "Passwort geändert."))))))))

        (route! "POST" "/profile/password"
          (signed-in
            (lambda (req params user)
              (let* ((form (http-request-form req))
                     (new (form-ref form "new" ""))
                     (fail (lambda (text)
                             (html-response
                              (profile-page (col user "username") (admin? user)
                                            (cons 'error text))))))
                (cond
                  ((not (sign-in auth (col user "username") (form-ref form "current" "")))
                   (penalty)
                   (fail "Das aktuelle Passwort ist falsch."))
                  ((< (string-length new) min-password-length)
                   (fail "Das neue Passwort muss mindestens 8 Zeichen haben."))
                  ((not (string=? new (form-ref form "confirm" "")))
                   (fail "Die neuen Passwörter stimmen nicht überein."))
                  (else
                   ;; The new hash ends all other sessions; this browser
                   ;; gets a fresh cookie.
                   (let ((user (change-password! auth user new)))
                     (redirect "/profile?updated" (start-session auth user)))))))))

        ;; --- admin console ---

        (route! "GET" "/admin"
          (admin-only
            (lambda (req params user)
              (html-response
               (admin-page (col user "username") (col user "id")
                           (list-users db) (list-roles db)
                           (all-user-roles db) (notice-from-query req))))))

        (route! "POST" "/admin/users"
          (admin-only
            (lambda (req params user)
              (let* ((form (http-request-form req))
                     (username (form-ref form "username" ""))
                     (password (form-ref form "password" "")))
                (cond
                  ((not (valid-username? username)) (to-admin "bad-username"))
                  ((< (string-length password) min-password-length)
                   (to-admin "short-password"))
                  ((find-user-by-name db username) (to-admin "dup-user"))
                  (else
                   ;; The user and the admin role together, or neither.
                   (with-db-transaction db
                     (lambda (tx)
                       (let ((id (create-user! tx username (password-hash password))))
                         (when (form-ref form "admin" #f)
                           (create-role! tx admin-role)
                           (assign-role-by-name! tx id admin-role)))))
                   (to-admin "user-created")))))))

        (route! "POST" "/admin/users/:id/delete"
          (admin-only
            (lambda (req params user)
              (if (equal? (params-ref params "id") (id->string (col user "id")))
                  (to-admin "self-delete")
                  (begin
                    (delete-user! db (params-ref params "id"))
                    (to-admin "user-deleted"))))))

        (route! "POST" "/admin/roles"
          (admin-only
            (lambda (req params user)
              (let ((name (form-ref (http-request-form req) "name" "")))
                (if (valid-role-name? name)
                    (begin (create-role! db name) (to-admin "role-created"))
                    (to-admin "bad-role"))))))

        (route! "POST" "/admin/users/:id/roles"
          (admin-only
            (lambda (req params user)
              (assign-role! db (params-ref params "id")
                            (form-ref (http-request-form req) "role_id" ""))
              (to-admin "role-assigned"))))

        (route! "POST" "/admin/users/:id/roles/:rid/delete"
          (admin-only
            (lambda (req params user)
              (let ((uid (params-ref params "id"))
                    (rid (params-ref params "rid")))
                ;; Keep at least the admin who is doing this.
                (if (and (equal? uid (id->string (col user "id")))
                         (equal? (role-name db rid) admin-role))
                    (to-admin "self-admin")
                    (begin
                      (unassign-role! db uid rid)
                      (to-admin "role-removed")))))))

        ;; Outside the prefix: the health probe talks to the app directly.
        (router-add! router "GET" "/healthz"
          (lambda (req params) (text-response "ok\n")))

        ;; Outermost first: log every request, add the security headers,
        ;; make the site current for url/asset, and turn errors into a
        ;; logged 500 page.
        (with-access-log
         (with-security-headers
          (with-site site
           (with-error-handler (router->handler router)
                               (lambda (req) (html-response (error-page)))))
          csp))))))
