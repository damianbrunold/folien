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
          (only (scheme char) string-downcase char-alphabetic? char-numeric?)
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
          (scm net websocket)
          (only (scm qr) qr-encode qr->svg)
          (only (scm net http cookies) parse-cookie-header cookie-ref format-set-cookie)
          (app site)
          (app db)
          (app users)
          (app auth)
          (app designs)
          (app model)
          (app decks)
          (app assets)
          (app images)
          (app remote)
          (app export-pdf)
          (app export-pptx)
          (app bundle)
          (app publish)
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
        ("bad-design"     error   . "Unbekanntes Design.")
        ("shared"         success . "Freigabe gespeichert.")
        ("unshared"       success . "Freigabe entfernt.")
        ("no-user"        error   . "Diesen Benutzer gibt es nicht.")
        ("not-owner"      error   . "Das kann nur, wem die Präsentation gehört.")
        ("read-only"      error   . "Sie können diese Präsentation nur ansehen.")
        ("version-saved"  success . "Version gespeichert.")
        ("version-restored" success . "Version wiederhergestellt; der bisherige Stand ist als Version gespeichert.")
        ("version-deleted" success . "Version gelöscht.")
        ("bad-name"       error   . "Der Name muss 1 bis 200 Zeichen lang sein.")
        ("tags-saved"     success . "Stichwörter gespeichert.")
        ("template-on"    success . "Die Präsentation steht jetzt als Vorlage zur Wahl.")
        ("template-off"   success . "Die Präsentation ist keine Vorlage mehr.")
        ("no-template"    error   . "Diese Vorlage gibt es nicht (mehr).")
        ("published"      success . "Veröffentlicht: die Kopie ist unter ihrer Adresse zu sehen.")
        ("withdrawn"      success . "Veröffentlichung zurückgezogen; ihre Adresse gilt nicht mehr.")
        ("bad-label"      error   . "Der Anlass darf höchstens 120 Zeichen haben.")
        ("slug-saved"     success . "Name der Adresse gespeichert.")
        ("bad-slug"       error   . "Der Name: 3 bis 60 Kleinbuchstaben, Ziffern und einzelne Bindestriche.")
        ("slug-taken"     error   . "Diesen Namen hat schon eine andere Präsentation.")))

    ;; The search text and tag of a list page's query string ("" if none).
    (define (list-filters req)
      (let* ((q (url-query-params (http-request-url req)))
             (get (lambda (k) (let ((p (assoc k q))) (if p (cdr p) "")))))
        (cons (let ((s (get "q"))) (if (> (string-length s) 100) (substring s 0 100) s))
              (get "tag"))))

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
        ("role" . ,(col deck "role"))
        ("owner" . ,(col deck "owner_name"))
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

;; Bundles, offline players and the PDFs of publications are built into
    ;; data-dir/bundles, once per version of their content (for a deck its
    ;; revision, title and design), and served from there; files older
    ;; than a day are removed when the next one is built.
    (define bundle-max-age-ms (* 24 60 60 1000))

    ;; The cached file <name>-<hash of key><ext>, key a string naming the
    ;; content, written by (write! path) if it is not there.
    (define (cached-file data-dir name ext key write!)
      (let* ((dir (string-append data-dir "/bundles"))
             (hash (bytevector->hex (bytevector-copy (sha256-hash key) 0 12)))
             (path (string-append dir "/" name "-" hash ext)))
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
              (write! tmp)
              (move-file tmp path))))
        path))

    (define (deck-key deck kind)
      (string-append (col deck "id") "|" (id->string (col deck "revision"))
                     "|" (col deck "title") "|" (col deck "design") "|" kind))

    (define (bundle-file data-dir static-dir db deck)
      (cached-file data-dir (col deck "id") ".zip"
                   (deck-key deck (string-append (number->string bundle-version) "|pptx"))
                   (lambda (tmp) (write-bundle! db data-dir static-dir deck tmp))))

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

    ;; The same messages over a WebSocket, both ways: what the browser
    ;; sends is published to the deck (as POST .../events), what the deck
    ;; gets is forwarded by a second thread. A keepalive every 25 s finds
    ;; a client that has gone without closing, which frees the thread.
    (define keepalive-seconds 25)

    (define (event-socket deck-id)
      (http-websocket-upgrade
       (lambda (ws)
         (let* ((l (subscribe! deck-id))
                (forwarder
                 (make-thread
                  (lambda ()
                    (guard (e (#t #f))          ; sending fails once the socket is closed
                      (let loop ()
                        (let ((m (next-message l keepalive-seconds)))
                          (ws-send ws (or m "{\"type\":\"ping\"}"))
                          (loop))))))))
           (thread-start! forwarder)
           (dynamic-wind
             (lambda () #f)
             (lambda ()
               (let loop ()
                 (let ((text (ws-receive ws)))
                   (when text
                     (let ((m (and (string? text) (<= (string-length text) 2000)
                                   (clean-message (guard (e (#t #f)) (json-parse text))))))
                       (when m (publish! deck-id (json->string m))))
                     (loop)))))
             (lambda ()
               (unsubscribe! l)
               (ws-close ws)))))))

    ;; A browser sends the page's origin with a WebSocket handshake; one
    ;; from another site is refused (the session cookie is SameSite=Strict
    ;; as well). Clients that send none (not browsers) are let through.
    (define (same-origin? req)
      (let ((origin (http-request-header req "Origin"))
            (host (http-request-header req "Host")))
        (or (not origin)
            (and host
                 (let ((h (let ((i (string-search "://" origin)))
                            (if i (substring origin (+ i 3) (string-length origin)) origin))))
                   (string=? (string-downcase h) (string-downcase host)))))))

    (define (string-search part s)
      (let loop ((i 0))
        (cond ((> (+ i (string-length part)) (string-length s)) #f)
              ((string=? (substring s i (+ i (string-length part))) part) i)
              (else (loop (+ i 1))))))

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
                    db
                    (setting settings 'session-secret)))
             (router (make-router)))

        (define (route! method path handler)
          (router-add! router method (string-append prefix path) handler))

        (define (admin? user)
          (user-has-role? db (col user "id") admin-role))

        (define (who user) (list (col user "username") (admin? user)))

        ;; Runs handler with the signed-in user row as a third argument, or
        ;; sends the browser to the sign-in page, which comes back to the
        ;; page asked for (a GET) after signing in.
        (define (signed-in handler)
          (lambda (req params)
            (let ((user (session-user auth req)))
              (cond (user (handler req params user))
                    ((and (equal? (http-request-method req) "GET")
                          (not (equal? (site-relative (http-request-url req)) "/")))
                     (redirect (string-append "/login?next="
                                              (percent-encode (site-relative (http-request-url req))))))
                    (else (redirect "/login"))))))

        ;; "http(s)://host[:port]" and nothing more: a host name, an IPv4
        ;; address or a bracketed IPv6 address.
        (define (web-origin? s)
          (let* ((n (string-length s))
                 (after (cond ((and (> n 8) (string=? (substring s 0 8) "https://")) 8)
                              ((and (> n 7) (string=? (substring s 0 7) "http://")) 7)
                              (else #f))))
            (and after
                 (< n 300)
                 (> n after)
                 (let loop ((i after) (colon #f))
                   (cond ((= i n) #t)
                         ((let ((c (string-ref s i)))
                            (or (char-alphabetic? c) (char-numeric? c)
                                (memv c '(#\. #\- #\[ #\]))))
                          (and (< (char->integer (string-ref s i)) 128) (loop (+ i 1) colon)))
                         ((char=? (string-ref s i) #\:) (loop (+ i 1) #t))
                         (else #f))))))

        ;; A request URL without the site's prefix, as redirect takes it.
        (define (site-relative path)
          (let ((p (url "")))
            (if (and (> (string-length p) 0)
                     (>= (string-length path) (string-length p))
                     (string=? (substring path 0 (string-length p)) p))
                (substring path (string-length p) (string-length path))
                path)))

        ;; Where to go after signing in: a path of this site ("/decks/..."),
        ;; never another host ("//evil", "/\\evil", "https:...").
        (define (safe-next s)
          (and (string? s)
               (> (string-length s) 0)
               (< (string-length s) 2000)
               (char=? (string-ref s 0) #\/)
               (not (and (> (string-length s) 1)
                         (memv (string-ref s 1) '(#\/ #\\))))
               (let loop ((i 0))
                 (or (= i (string-length s))
                     (and (char>? (string-ref s i) #\space)
                          (not (char=? (string-ref s i) #\\))
                          (loop (+ i 1)))))
               s))

        ;; --- remote links ---
        ;; A phone that scanned the remote's QR code holds a remote link
        ;; token in the folien_remote cookie. It counts, as the user who
        ;; made it, for the remote's own requests and only for its deck: the
        ;; remote page, the deck's JSON, the designs, and the event stream
        ;; and socket. Everything else wants a session.

        (define remote-cookie "folien_remote")

        ;; The remote link token in the request's cookie, or #f.
        (define (remote-token req)
          (let ((h (http-request-header req "Cookie")))
            (and h (cookie-ref (parse-cookie-header h) remote-cookie))))

        ;; The user a remote link token stands for, for deck-id (#f: the
        ;; deck the token names), or #f.
        (define (token-user token deck-id)
          (let ((deck (or deck-id (remote-token-deck token))))
            (and deck
                 (remote-token-user auth token deck
                                    (lambda (uid) (deck-remote-epoch db uid deck))
                                    (current-second)))))

        ;; The session's user, or the remote link's for this deck.
        (define (remote-user req deck-id)
          (or (session-user auth req)
              (let ((t (remote-token req))) (and t (token-user t deck-id)))))

        ;; As api-signed-in, but a remote link for the route's deck (or,
        ;; without :id, for any deck) counts too.
        (define (api-remote handler)
          (lambda (req params)
            (let ((user (remote-user req (params-ref params "id"))))
              (if user (handler req params user) (json-error 401 "not signed in")))))

        ;; SameSite=Lax, unlike the session cookie: the phone opens the
        ;; link from its camera app, a cross-site navigation, and a Strict
        ;; cookie would not come along on the redirect that follows.
        (define (remote-cookie-header token)
          (cons "Set-Cookie"
                (apply format-set-cookie remote-cookie token remote-link-seconds (cookie-path site)
                       'lax
                       (if (setting settings 'secure-cookies?) '() '(no-secure)))))

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
              (let ((f (list-filters req)))
                (html-response
                 (decks-page (who user) status
                             (list-decks db (col user "id") status (car f) (cdr f))
                             (notice-from-query req) f
                             (if (string=? status "active") (list-templates db (col user "id")) '())))))))

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
        (route! "GET" "/shared"
          (signed-in
            (lambda (req params user)
              (let ((f (list-filters req)))
                (html-response
                 (decks-page (who user) "shared" (list-shared-decks db (col user "id") (car f) (cdr f))
                             (notice-from-query req) f '()))))))

        ;; --- decks ---

        (route! "POST" "/decks"
          (signed-in
            (lambda (req params user)
              (let* ((form (http-request-form req))
                     (title (form-ref form "title" ""))
                     (design (form-ref form "design" default-design-id))
                     (template (form-ref form "template" "")))
                (cond
                  ((not (valid-title? title)) (redirect "/?m=bad-title"))
                  ((not (string=? template ""))
                   ;; From a template: a copy of it (with its images).
                   (let ((tmpl (let find ((ts (list-templates db (col user "id"))))
                                 (cond ((null? ts) #f)
                                       ((equal? (col (car ts) "id") template) (car ts))
                                       (else (find (cdr ts)))))))
                     (if tmpl
                         (redirect (string-append
                                    "/decks/" (duplicate-deck! db (col user "id") template title) "/edit"))
                         (redirect "/?m=no-template"))))
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
                                (notice-from-query req)
                                (if (equal? (col deck "role") "owner")
                                    (list-shares db (col deck "id"))
                                    '())
                                (if (can-edit? (col deck "role"))
                                    (list-snapshots db (col deck "id"))
                                    '())
                                (and (equal? (col deck "role") "owner")
                                     (not (equal? (col deck "status") "trashed"))
                                     (cons (deck-public-names db (col user "id") (col deck "id"))
                                           (list-publications db (col deck "id"))))))
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
                  ((not (can-edit? (col deck "role")))
                   (redirect (string-append "/decks/" (col deck "id") "?m=read-only")))
                  (else (html-response (editor-page deck))))))))

;; Tags (field tags, comma-separated); for editors.
        (route! "POST" "/decks/:id/tags"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (set-tags! db (col user "id") id (parse-tags (form-ref (http-request-form req) "tags" "")))
                (redirect (string-append "/decks/" id "?m=tags-saved"))))))

        ;; Template on or off (field on: 1 or 0); for the owner.
        (route! "POST" "/decks/:id/template"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id"))
                    (on? (equal? (form-ref (http-request-form req) "on" "0") "1")))
                (set-template! db (col user "id") id on?)
                (redirect (string-append "/decks/" id "?m=" (if on? "template-on" "template-off")))))))

        ;; Versions: save (field name), restore, delete; for editors.
        (route! "POST" "/decks/:id/versions"
          (signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (name (form-ref (http-request-form req) "name" "")))
                (redirect
                 (string-append
                  "/decks/" id "?m="
                  (cond ((not (valid-title? name)) "bad-name")
                        ((create-snapshot! db (col user "id") id name) "version-saved")
                        (else "read-only"))
                  "#versions"))))))

        (route! "POST" "/decks/:id/versions/:vid/restore"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (redirect
                 (string-append
                  "/decks/" id "?m="
                  (if (restore-snapshot! db (col user "id") id (params-ref params "vid")
                                         "Stand vor dem Wiederherstellen")
                      "version-restored"
                      "read-only")
                  "#versions"))))))

        (route! "POST" "/decks/:id/versions/:vid/delete"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (delete-snapshot! db (col user "id") id (params-ref params "vid"))
                (redirect (string-append "/decks/" id "?m=version-deleted#versions"))))))

        ;; Sharing (the owner only): form fields username, role.
        (route! "POST" "/decks/:id/shares"
          (signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (form (http-request-form req))
                     (other (find-user-by-name db (form-ref form "username" "")))
                     (role (form-ref form "role" "view")))
                (redirect
                 (string-append
                  "/decks/" id "?m="
                  (cond ((not other) "no-user")
                        ((not (member role '("view" "edit"))) "no-user")
                        ((share-deck! db (col user "id") id (col other "id") role) "shared")
                        (else "not-owner"))))))))

        (route! "POST" "/decks/:id/shares/:uid/delete"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (unshare-deck! db (col user "id") id (params-ref params "uid"))
                (redirect (string-append "/decks/" id "?m=unshared"))))))

        (route! "POST" "/decks/:id/rename"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id"))
                    (title (form-ref (http-request-form req) "title" "")))
                (cond
                  ((not (valid-title? title)) (redirect (string-append "/decks/" id "?m=bad-title")))
                  ((not (let ((a (deck-access db (col user "id") id))) (and a (can-edit? (cdr a)))))
                   (redirect (string-append "/decks/" id "?m=read-only")))
                  (else (rename-deck! db (col user "id") id title)
                        (redirect (string-append "/decks/" id "?m=renamed"))))))))

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
          (api-remote
            (lambda (req params user)
              (json-status 200 (list->vector designs)))))

        (route! "GET" "/api/decks/:id"
          (api-remote
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
                  ((not (can-edit? (col deck "role")))
                   (json-error 403 "deck is shared for viewing only"))
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

        ;; Body: the file. Query: name, and the client's w and h (pixels;
        ;; PNGs and JPEGs are measured instead). 201 with the asset; 400
        ;; empty, 403 read-only deck, 404, 413 too large (bytes, or above
        ;; 50 megapixels), 415 a type that is not accepted, 422 an image
        ;; that does not decode.
        (route! "POST" "/api/decks/:id/assets"
          (api-signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (access (deck-access db (col user "id") id))
                     (q (url-query-params (http-request-url req)))
                     (qref (lambda (k) (let ((p (assoc k q))) (and p (cdr p))))))
                (cond
                  ((not access) (json-error 404 "no such deck"))
                  ((not (and (string=? (car access) "active") (can-edit? (cdr access))))
                   (json-error 403 "deck is read-only"))
                  (else
                   (let ((r (store-upload! db data-dir id req (clean-name (qref "name"))
                                           (qref "w") (qref "h"))))
                     (cond
                       ((eq? r 'empty) (json-error 400 "empty upload"))
                       ((eq? r 'unsupported)
                        (json-error 415 "unsupported file type (PNG, JPEG, GIF, WebP, SVG, MP4, WebM)"))
                       ((eq? r 'invalid) (json-error 422 "the image cannot be decoded"))
                       ((eq? r 'too-large) (json-error 413 "the image has too many pixels"))
                       (else (json-status 201 (asset->json r)))))))))))

        (route! "GET" "/api/decks/:id/assets"
          (api-signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (if (deck-status db (col user "id") id)
                    (json-status 200 (list->vector (map asset->json (list-deck-assets db id))))
                    (json-error 404 "no such deck"))))))

        ;; The file, with byte ranges (videos seek). ?w=320|640|1280 asks a
        ;; PNG or JPEG for an upright copy at most that large (thumbnails);
        ;; other types and widths get the file itself.
        (route! "GET" "/api/decks/:id/assets/:sha"
          (signed-in
            (lambda (req params user)
              (let* ((sha (params-ref params "sha"))
                     (row (deck-asset db (col user "id") (params-ref params "id") sha))
                     (w (let ((p (assoc "w" (url-query-params (http-request-url req)))))
                          (and p (string->number (cdr p)))))
                     (variant (and row w (memv w variant-widths) (raster-mime? (col row "mime"))
                                   (image-variant data-dir sha (asset-file data-dir sha) (col row "mime") w))))
                (if (not row)
                    (http-not-found)
                    (let ((r (file-response (if variant (car variant) (asset-file data-dir sha))
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

;; The deck as PowerPoint file.
        (route! "GET" "/decks/:id/export.pptx"
          (signed-in
            (lambda (req params user)
              (let ((deck (load-deck db (col user "id") (params-ref params "id"))))
                (if (not deck)
                    (http-not-found)
                    (make-http-response
                     200
                     `(("Content-Type"
                        . "application/vnd.openxmlformats-officedocument.presentationml.presentation")
                       ("Content-Disposition"
                        . ,(download-disposition (string-append (col deck "title") ".pptx")))
                       ("Cache-Control" . "no-store"))
                     (deck->pptx (deck-doc deck) (col deck "design") (col deck "title") data-dir)))))))

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

        ;; The offline player alone, without hidden slides: one HTML
        ;; file, or its folder as a zip. With the notes (for its presenter
        ;; console), or without them: ?notes=0.
        (let ((offline (lambda (kind ext content-type write!)
                         (signed-in
                           (lambda (req params user)
                             (let* ((deck (load-deck db (col user "id") (params-ref params "id")))
                                    (notes? (not (equal? (assoc "notes" (url-query-params (http-request-url req)))
                                                         '("notes" . "0"))))
                                    (kind (if notes? kind (string-append kind "-no-notes"))))
                               (if (not deck)
                                   (http-not-found)
                                   (make-http-file-response
                                    200
                                    `(("Content-Type" . ,content-type)
                                      ("Content-Disposition"
                                       . ,(download-disposition (string-append (col deck "title") ext)))
                                      ("Cache-Control" . "no-store"))
                                    (cached-file data-dir (string-append (col deck "id") "-" kind) (if (string=? ext ".html") ".html" ".zip")
                                                 (deck-key deck kind)
                                                 (lambda (tmp) (write! db data-dir static-dir deck notes? tmp)))))))))))
          (route! "GET" "/decks/:id/export.html"
            (offline "offline-html" ".html" "text/html; charset=utf-8" write-offline-html!))
          (route! "GET" "/decks/:id/export-offline.zip"
            (offline "offline-zip" " (offline).zip" "application/zip" write-offline-zip!)))

        ;; --- publishing (the owner) ---

        (route! "POST" "/decks/:id/publish"
          (signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (label (form-ref (http-request-form req) "label" "")))
                (cond
                  ((not (valid-label? label)) (redirect (string-append "/decks/" id "?m=bad-label#publish")))
                  ((publish-deck! db (col user "id") id label)
                   (redirect (string-append "/decks/" id "?m=published#publish")))
                  (else (redirect (string-append "/decks/" id "?m=not-owner"))))))))

        (route! "POST" "/decks/:id/publications/:pid/withdraw"
          (signed-in
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (redirect (string-append "/decks/" id
                                         (if (withdraw-publication! db (col user "id") id (params-ref params "pid"))
                                             "?m=withdrawn#publish"
                                             "?m=not-owner")))))))

        (route! "POST" "/decks/:id/public-name"
          (signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (slug (string-downcase (form-ref (http-request-form req) "slug" "")))
                     (r (set-public-slug! db (col user "id") id slug)))
                (redirect (string-append "/decks/" id
                                         (case r
                                           ((ok) "?m=slug-saved#publish")
                                           ((invalid) "?m=bad-slug#publish")
                                           ((taken) "?m=slug-taken#publish")
                                           (else "?m=not-owner"))))))))

        ;; --- publications (anyone, no sign-in) ---
        ;; /p/<name> is the deck's newest publication, /p/<name>/<stamp>
        ;; one of them; name is the deck's token or slug.

        (let* ((not-found (lambda ()
                            (make-http-response 404 '(("Content-Type" . "text/html; charset=utf-8"))
                                                (public-not-found-page))))
               (base-of (lambda (params pub)
                          (string-append "/p/" (params-ref params "name") "/" (col pub "stamp"))))
               ;; handler gets the publication of the route's name and stamp
               (public (lambda (handler)
                         (lambda (req params)
                           (let ((pub (find-publication db (params-ref params "name")
                                                        (params-ref params "stamp"))))
                             (if pub (handler req params pub) (not-found)))))))
          (define (show req params pub)
            (html-response (public-page (base-of params pub) pub
                                        (public-publications db (params-ref params "name")))))
          (route! "GET" "/p/:name" (public show))
          (route! "GET" "/p/:name/:stamp" (public show))
          (route! "GET" "/p/:name/:stamp/present"
            (public (lambda (req params pub)
                      (html-response (public-present-page (base-of params pub) pub)))))
          (route! "GET" "/p/:name/:stamp/deck.json"
            (public (lambda (req params pub)
                      (make-http-response
                       200
                       '(("Content-Type" . "application/json") ("Cache-Control" . "no-cache"))
                       ;; the document as stored, not parsed and written again
                       (string-append "{\"id\":" (json->string (base-of params pub))
                                      ",\"title\":" (json->string (col pub "title"))
                                      ",\"design\":" (json->string (col pub "design"))
                                      ",\"doc\":" (col pub "doc") "}")))))
          (route! "GET" "/p/:name/:stamp/designs.json"
            (public (lambda (req params pub)
                      (let ((d (find-design (col pub "design"))))
                        (json-status 200 (if d (vector d) (vector)))))))
          ;; As the deck's assets, but only those the publication shows.
          (route! "GET" "/p/:name/:stamp/assets/:sha"
            (public (lambda (req params pub)
                      (let* ((sha (params-ref params "sha"))
                             (mime (and (valid-sha? sha) (publication-asset-mime db (col pub "id") sha)))
                             (w (let ((p (assoc "w" (url-query-params (http-request-url req)))))
                                  (and p (string->number (cdr p)))))
                             (variant (and mime w (memv w variant-widths) (raster-mime? mime)
                                           (image-variant data-dir sha (asset-file data-dir sha) mime w))))
                        (if (not (and mime (file-exists? (asset-file data-dir sha))))
                            (http-not-found)
                            (let ((r (file-response (if variant (car variant) (asset-file data-dir sha))
                                                    `((request . ,req)
                                                      (content-type . ,mime)
                                                      (cache-control . "public, max-age=31536000, immutable")))))
                              (http-response-with-headers
                               r (http-response-status r)
                               (cons (cons "Content-Security-Policy" asset-csp)
                                     (http-response-headers r)))))))))
          (route! "GET" "/p/:name/:stamp/folien.pdf"
            (public (lambda (req params pub)
                      (make-http-file-response
                       200
                       `(("Content-Type" . "application/pdf")
                         ("Content-Disposition"
                          . ,(download-disposition (string-append (col pub "title") ".pdf")))
                         ("Cache-Control" . "no-cache"))
                       (cached-file data-dir (string-append "publication-" (id->string (col pub "id"))) ".pdf"
                                    (string-append (id->string (col pub "id")) "|" (col pub "stamp")
                                                   "|" (col pub "design"))
                                    (lambda (tmp)
                                      (let ((p (open-binary-output-file tmp)))
                                        (write-bytevector
                                         (deck->pdf (json-parse (col pub "doc")) (col pub "design")
                                                    (col pub "title") data-dir '())
                                         p)
                                        (close-port p)))))))))

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
        ;; The remote. With ?t=<token> (from the QR code): a valid token
        ;; goes into the remote cookie, and the address loses it.
        (route! "GET" "/decks/:id/remote"
          (lambda (req params)
            (let* ((id (params-ref params "id"))
                   (path (string-append "/decks/" id "/remote"))
                   (t (let ((p (assoc "t" (url-query-params (http-request-url req))))) (and p (cdr p)))))
              (cond
                ((and t (token-user t id))
                 (redirect path (remote-cookie-header t)))
                ((and t (not (session-user auth req)))
                 (make-http-response 403 '(("Content-Type" . "text/html; charset=utf-8"))
                                     (remote-link-expired-page path)))
                (t (redirect path))
                (else
                 (let* ((user (remote-user req id))
                        (deck (and user (load-deck db (col user "id") id))))
                   (cond (deck (html-response (remote-page deck)))
                         (user (make-http-response 404 '(("Content-Type" . "text/html; charset=utf-8"))
                                                   (not-found-page #f)))
                         (else (redirect (string-append "/login?next=" (percent-encode path)))))))))))

        ;; A new remote epoch: every remote link (QR code) of the deck
        ;; given out so far stops working. 204, or 404.
        (route! "POST" "/api/decks/:id/remote-links/renew"
          (api-signed-in
            (lambda (req params user)
              (cond ((not (same-origin? req)) (json-error 403 "cross-site request"))
                    ((renew-remote-epoch! db (col user "id") (params-ref params "id"))
                     (make-http-response 204 '() ""))
                    (else (json-error 404 "no such deck"))))))

        ;; The remote's address as a QR code (SVG), for a phone's camera,
        ;; with a remote link token of the asking user: the phone needs no
        ;; sign-in. origin: how the asking browser reaches this site
        ;; ("https://folien.example.org"); the code holds origin, the
        ;; deck's remote path and the token, nothing else.
        (route! "GET" "/decks/:id/remote-qr.svg"
          (signed-in
            (lambda (req params user)
              (let* ((id (params-ref params "id"))
                     (epoch (deck-remote-epoch db (col user "id") id))
                     (deck epoch)
                     (origin (let ((p (assoc "origin" (url-query-params (http-request-url req)))))
                               (and p (web-origin? (cdr p)) (cdr p)))))
                (cond
                  ((not deck) (make-http-response 404 '(("Content-Type" . "text/plain")) "not found"))
                  ((not origin) (make-http-response 400 '(("Content-Type" . "text/plain")) "bad origin"))
                  (else
                   (make-http-response
                    200
                    '(("Content-Type" . "image/svg+xml")
                      ("Cache-Control" . "no-store"))
                    (qr->svg (qr-encode (string-append origin (url (string-append "/decks/" id "/remote"))
                                                       "?t=" (make-remote-token auth user id epoch
                                                                                (current-second))))
                             8 4))))))))

        (route! "GET" "/api/decks/:id/events"
          (api-remote
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (if (deck-status db (col user "id") id)
                    (event-stream id)
                    (json-error 404 "no such deck"))))))

        ;; The same, both ways, over one WebSocket (preferred by sync.js).
        (route! "GET" "/api/decks/:id/socket"
          (api-remote
            (lambda (req params user)
              (let ((id (params-ref params "id")))
                (cond ((not (deck-status db (col user "id") id)) (json-error 404 "no such deck"))
                      ((not (same-origin? req)) (json-error 403 "cross-site request"))
                      (else (event-socket id)))))))

        (route! "POST" "/api/decks/:id/events"
          (api-remote
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
            (let ((next (safe-next (let ((p (assoc "next" (url-query-params (http-request-url req)))))
                                     (and p (cdr p))))))
              (if (session-user auth req)
                  (redirect (or next "/"))
                  (html-response (login-page #f next))))))

        (route! "POST" "/login"
          (lambda (req params)
            (let* ((form (http-request-form req))
                   (next (safe-next (form-ref form "next" "")))
                   (user (sign-in auth (form-ref form "username" "")
                                  (form-ref form "password" ""))))
              (if user
                  (redirect (or next "/") (start-session auth user))
                  (begin (penalty) (html-response (login-page #t next)))))))

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
