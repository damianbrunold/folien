;; (app views) — HTML rendering. All dynamic values flow through the
;; auto-escaping (scm html builder); only fixed strings (the SVG icons) are
;; emitted raw. No inline scripts or style attributes: the
;; Content-Security-Policy forbids them. The interface is in German.

(define-library (app views)
  (import (scheme base)
          (scm html builder)
          (app site)
          (app designs)
          (app users))            ; col
  (export login-page decks-page deck-page editor-page profile-page admin-page
          error-page not-found-page)
  (begin

    (define theme-icons
      (raw (string-append
            "<svg class=\"i-sun\" viewBox=\"0 0 24 24\" width=\"20\" height=\"20\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" aria-hidden=\"true\"><circle cx=\"12\" cy=\"12\" r=\"4\"/><path d=\"M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4\"/></svg>"
            "<svg class=\"i-moon\" viewBox=\"0 0 24 24\" width=\"20\" height=\"20\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" aria-hidden=\"true\"><path d=\"M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z\"/></svg>")))

    ;; who: #f when signed out, else (username admin?).
    ;; extra: more (head ...) children, e.g. page scripts.
    (define (page title who body . extra)
      (string-append
       (html->string
        (html5
         '(@ (lang "de"))
         `(head
           (meta (@ (charset "utf-8")))
           (meta (@ (name "viewport") (content "width=device-width, initial-scale=1")))
           (title ,(string-append title " · Folien"))
           (link (@ (rel "icon") (href ,(asset "favicon.svg"))))
           (link (@ (rel "stylesheet") (href ,(asset "css/app.css"))))
           (script (@ (src ,(asset "js/theme-init.js"))))
           (script (@ (src ,(asset "js/theme-toggle.js")) (defer #t)))
           ,@extra)
         `(body
           (header (@ (class "app-header"))
             (h1 (a (@ (href ,(url "/"))) "Folien"))
             (nav (@ (class "nav"))
               ;; The username links to the profile page, which is where
               ;; signing out lives. Admins also get the console.
               ,@(if who
                     `((a (@ (href ,(url "/"))) "Präsentationen")
                       (a (@ (href ,(url "/archive"))) "Archiv")
                       (a (@ (href ,(url "/trash"))) "Papierkorb")
                       ,@(if (cadr who) `((a (@ (href ,(url "/admin"))) "Verwaltung")) '())
                       (a (@ (href ,(url "/profile")) (class "who")) ,(car who)))
                     '())
               (button (@ (class "icon-btn js-theme-toggle") (type "button")
                          (aria-label "Hell/Dunkel umschalten"))
                 ,theme-icons)))
           (main ,body))))
       "\n"))

    ;; msg: #f, or (kind . text) with kind 'error or 'success.
    (define (notice msg)
      (if msg
          `(p (@ (class ,(string-append "notice " (symbol->string (car msg)))))
              ,(cdr msg))
          ""))

    (define (id->string x) (if (number? x) (number->string x) x))

    (define (login-page error?)
      (page "Anmelden" #f
        `(section (@ (class "card narrow"))
           (h2 "Anmelden")
           ,(notice (and error? '(error . "Benutzername oder Passwort ist falsch.")))
           (form (@ (method "post") (action ,(url "/login")))
             (label "Benutzername"
               (input (@ (name "username") (autocomplete "username")
                         (autofocus #t) (required #t))))
             (label "Passwort"
               (input (@ (name "password") (type "password")
                         (autocomplete "current-password") (required #t))))
             (button (@ (type "submit") (class "primary")) "Anmelden")))))

    ;; --- deck lists ---------------------------------------------------

    (define (design-name id)
      (let ((d (find-design id)))
        (if d (design-ref d "name") id)))

    ;; "2026-10-28 20:03:01.123+01" -> "28.10.2026 20:03"
    (define (format-time ts)
      (if (and (string? ts) (>= (string-length ts) 16))
          (string-append (substring ts 8 10) "." (substring ts 5 7) "."
                         (substring ts 0 4) " " (substring ts 11 16))
          ""))

    (define (action-button id path label . classes)
      `(form (@ (method "post") (action ,(url (string-append "/decks/" id path)))
                (class "inline"))
         (button (@ (type "submit")
                    (class ,(if (pair? classes) (car classes) "small")))
                 ,label)))

    (define (deck-actions status id)
      (cond
        ((string=? status "active")
         (list `(a (@ (class "button small") (href ,(url (string-append "/decks/" id "/edit"))))
                  "Bearbeiten")
               `(a (@ (class "button small") (href ,(url (string-append "/decks/" id)))) "Ansehen")
               (action-button id "/duplicate" "Duplizieren")
               (action-button id "/archive" "Archivieren")
               (action-button id "/trash" "Löschen" "small danger")))
        ((string=? status "archived")
         (list `(a (@ (class "button small") (href ,(url (string-append "/decks/" id)))) "Ansehen")
               (action-button id "/duplicate" "Duplizieren")
               (action-button id "/restore" "Reaktivieren")
               (action-button id "/trash" "Löschen" "small danger")))
        (else
         (list (action-button id "/restore" "Wiederherstellen")
               (action-button id "/delete" "Endgültig löschen" "small danger")))))

    (define (deck-row deck)
      (let ((id (col deck "id"))
            (status (col deck "status")))
        `(tr
          (td ,(if (string=? status "trashed")
                   (col deck "title")
                   `(a (@ (href ,(url (string-append "/decks/" id
                                                     (if (string=? status "active") "/edit" "")))))
                       ,(col deck "title"))))
          (td ,(design-name (col deck "design")))
          (td (@ (class "nowrap"))
              ,(format-time (if (string=? status "active")
                                (col deck "updated_at")
                                (col deck "status_at"))))
          (td (div (@ (class "actions")) ,@(deck-actions status id))))))

    (define (deck-table decks status)
      (if (null? decks)
          `(p (@ (class "muted"))
              ,(cond ((string=? status "active") "Noch keine Präsentationen.")
                     ((string=? status "archived") "Das Archiv ist leer.")
                     (else "Der Papierkorb ist leer.")))
          `(table (@ (class "data"))
             (thead (tr (th "Titel") (th "Design")
                        (th ,(cond ((string=? status "active") "Geändert")
                                   ((string=? status "archived") "Archiviert")
                                   (else "Gelöscht")))
                        (th "")))
             (tbody ,@(map deck-row decks)))))

    (define (new-deck-form)
      `(form (@ (method "post") (action ,(url "/decks")) (class "row-form"))
         (input (@ (name "title") (placeholder "Titel der neuen Präsentation")
                   (aria-label "Titel") (maxlength "200") (required #t)))
         (select (@ (name "design") (aria-label "Design"))
           ,@(map (lambda (d)
                    `(option (@ (value ,(design-ref d "id"))) ,(design-ref d "name")))
                  designs))
         (button (@ (type "submit") (class "primary")) "Erstellen")))

    ;; status: "active", "archived" or "trashed".
    (define (decks-page who status decks msg)
      (let ((title (cond ((string=? status "active") "Präsentationen")
                         ((string=? status "archived") "Archiv")
                         (else "Papierkorb"))))
        (page title who
          `(section
             (h2 ,title)
             ,(notice msg)
             ,(if (string=? status "active")
                  `(div (@ (class "card")) (h3 "Neue Präsentation") ,(new-deck-form))
                  "")
             ,(if (string=? status "archived")
                  '(p (@ (class "muted"))
                      "Archivierte Präsentationen sind schreibgeschützt. "
                      "Reaktivieren Sie eine, um sie wieder zu bearbeiten.")
                  "")
             ,(if (string=? status "trashed")
                  '(p (@ (class "muted"))
                      "Präsentationen im Papierkorb können wiederhergestellt "
                      "oder endgültig gelöscht werden.")
                  "")
             ,(deck-table decks status)))))

    ;; --- one deck -----------------------------------------------------
    ;; The deck's facts, actions and rename form; below them the viewer
    ;; (static/js/viewer.js), which loads the deck from the JSON API.

    (define (deck-page who deck slide-count msg)
      (let* ((id (col deck "id"))
             (status (col deck "status"))
             (active? (string=? status "active")))
        (page (col deck "title") who
          `(section
             (div (@ (class "deck-head"))
               (div
                 (h2 ,(col deck "title"))
                 (p (@ (class "muted"))
                    ,(design-name (col deck "design")) " · "
                    ,(number->string slide-count) ,(if (= slide-count 1) " Folie" " Folien")
                    " · Revision " ,(id->string (col deck "revision"))
                    ,(cond ((string=? status "archived") " · archiviert (schreibgeschützt)")
                           ((string=? status "trashed") " · im Papierkorb")
                           (else ""))))
               (div (@ (class "actions")) ,@(deck-actions status id)))
             ,(notice msg)
             (div (@ (id "viewer") (class "viewer")
                     (data-deck-url ,(url (string-append "/api/decks/" id)))
                     (data-designs-url ,(url "/api/designs")))
               (noscript "Zum Anzeigen der Folien wird JavaScript benötigt."))
             ,(if active?
                  `(form (@ (method "post") (action ,(url (string-append "/decks/" id "/rename")))
                            (class "row-form spaced"))
                     (input (@ (name "title") (value ,(col deck "title")) (aria-label "Titel")
                               (maxlength "200") (required #t)))
                     (button (@ (type "submit")) "Umbenennen"))
                  ""))
          `(link (@ (rel "stylesheet") (href ,(asset "css/slides.css"))))
          `(script (@ (type "module") (src ,(asset "js/viewer.js")))))))

    ;; --- the editor ---------------------------------------------------
    ;; A full-window application (static/js/editor.js) without the site
    ;; header; the page only carries the URLs it needs.

    (define (editor-page deck)
      (let ((id (col deck "id")))
        (string-append
         (html->string
          (html5
           '(@ (lang "de"))
           `(head
             (meta (@ (charset "utf-8")))
             (meta (@ (name "viewport") (content "width=device-width, initial-scale=1")))
             (title ,(string-append (col deck "title") " · Folien"))
             (link (@ (rel "icon") (href ,(asset "favicon.svg"))))
             (link (@ (rel "stylesheet") (href ,(asset "css/app.css"))))
             (link (@ (rel "stylesheet") (href ,(asset "css/slides.css"))))
             (link (@ (rel "stylesheet") (href ,(asset "css/editor.css"))))
             (script (@ (src ,(asset "js/theme-init.js"))))
             (script (@ (type "module") (src ,(asset "js/editor.js")))))
           `(body (@ (class "editor-body"))
              (div (@ (id "editor") (class "editor")
                      (data-deck-url ,(url (string-append "/api/decks/" id)))
                      (data-designs-url ,(url "/api/designs"))
                      (data-view-url ,(url (string-append "/decks/" id)))
                      (data-home-url ,(url "/")))
                (noscript "Der Editor braucht JavaScript.")))))
         "\n")))

    ;; --- profile ------------------------------------------------------

    (define (profile-page username admin? msg)
      (page "Profil" (list username admin?)
        `(section (@ (class "card narrow"))
           (h2 "Profil")
           ,(notice msg)
           (p "Passwort ändern für " (strong ,username) ".")
           (form (@ (method "post") (action ,(url "/profile/password")))
             (label "Aktuelles Passwort"
               (input (@ (name "current") (type "password")
                         (autocomplete "current-password") (required #t))))
             (label "Neues Passwort"
               (input (@ (name "new") (type "password") (minlength "8")
                         (autocomplete "new-password") (required #t))))
             (label "Neues Passwort bestätigen"
               (input (@ (name "confirm") (type "password") (minlength "8")
                         (autocomplete "new-password") (required #t))))
             (button (@ (type "submit") (class "primary")) "Passwort ändern"))
           (form (@ (method "post") (action ,(url "/logout")) (class "logout-form"))
             (button (@ (type "submit")) "Abmelden")))))

    ;; --- admin console ------------------------------------------------

    (define (role-chip user-id assignment)
      ;; assignment: alist (user_id role_id name); removed via a small form.
      `(form (@ (method "post")
                (action ,(url (string-append "/admin/users/" user-id "/roles/"
                                             (id->string (col assignment "role_id"))
                                             "/delete")))
                (class "chip"))
         (span ,(col assignment "name"))
         (button (@ (class "chip-x") (type "submit") (title "Rolle entfernen")
                    (aria-label ,(string-append "Rolle " (col assignment "name") " entfernen")))
                 "×")))

    (define (assign-form user-id roles)
      `(form (@ (method "post")
                (action ,(url (string-append "/admin/users/" user-id "/roles")))
                (class "assign"))
         (select (@ (name "role_id") (aria-label "Rolle"))
           ,@(map (lambda (r)
                    `(option (@ (value ,(id->string (col r "id")))) ,(col r "name")))
                  roles))
         (button (@ (type "submit")) "Zuweisen")))

    (define (user-row user roles assignments self-id)
      (let* ((uid (id->string (col user "id")))
             (self? (string=? uid self-id))
             (mine (let loop ((as assignments))
                     (cond ((null? as) '())
                           ((string=? (id->string (col (car as) "user_id")) uid)
                            (cons (car as) (loop (cdr as))))
                           (else (loop (cdr as)))))))
        `(tr
          (td ,(col user "username")
              ,(if self? '(span (@ (class "muted")) " (Sie)") ""))
          (td (div (@ (class "chips"))
                ,@(if (null? mine)
                      '((span (@ (class "muted")) "—"))
                      (map (lambda (a) (role-chip uid a)) mine))))
          (td ,(if (null? roles) "" (assign-form uid roles)))
          (td ,(if self?
                   ""                   ; never offer to delete yourself
                   `(form (@ (method "post")
                             (action ,(url (string-append "/admin/users/" uid "/delete")))
                             (class "inline"))
                      (button (@ (class "danger") (type "submit")) "Löschen")))))))

    (define (admin-page username self-id users roles assignments msg)
      (page "Verwaltung" (list username #t)
        `(section
           (h2 "Benutzer")
           ,(notice msg)
           (table (@ (class "data"))
             (thead (tr (th "Benutzer") (th "Rollen") (th "Zuweisen") (th "")))
             (tbody
              ,@(map (lambda (u) (user-row u roles assignments (id->string self-id)))
                     users)))

           (h3 "Benutzer hinzufügen")
           (form (@ (method "post") (action ,(url "/admin/users")) (class "row-form"))
             (input (@ (name "username") (placeholder "Benutzername")
                       (aria-label "Benutzername") (required #t)))
             (input (@ (name "password") (type "password") (minlength "8")
                       (autocomplete "new-password")
                       (placeholder "Passwort (min. 8)") (aria-label "Passwort")
                       (required #t)))
             (label (@ (class "check"))
               (input (@ (type "checkbox") (name "admin") (value "1")))
               " Admin")
             (button (@ (type "submit") (class "primary")) "Benutzer erstellen"))

           (h2 "Rollen")
           ,(if (null? roles)
                '(p (@ (class "muted")) "Noch keine Rollen.")
                `(ul (@ (class "roles"))
                   ,@(map (lambda (r) `(li ,(col r "name"))) roles)))
           (h3 "Rolle hinzufügen")
           (form (@ (method "post") (action ,(url "/admin/roles")) (class "row-form"))
             (input (@ (name "name") (placeholder "Rollenname")
                       (aria-label "Rollenname") (required #t)))
             (button (@ (type "submit") (class "primary")) "Rolle erstellen")))))

    (define (error-page)
      (page "Fehler" #f
        '(section (h2 "Etwas ist schiefgelaufen")
                  (p "Der Fehler wurde protokolliert."))))

    (define (not-found-page who)
      (page "Nicht gefunden" who
        `(section (h2 "Nicht gefunden")
                  (p "Diese Präsentation gibt es nicht (mehr).")
                  (p (a (@ (href ,(url "/"))) "Zu den Präsentationen")))))))
