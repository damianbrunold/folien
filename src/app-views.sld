;; (app views) — HTML rendering. All dynamic values flow through the
;; auto-escaping (scm html builder); only fixed strings (the SVG icons) are
;; emitted raw. No inline scripts or style attributes: the
;; Content-Security-Policy forbids them. The interface is in German.

(define-library (app views)
  (import (scheme base)
          (scm html builder)
          (scm uri)
          (app decks)
          (app site)
          (app designs)
          (app users))            ; col
  (export login-page remote-link-expired-page decks-page deck-page editor-page present-page presenter-page remote-page
          profile-page admin-page
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
           (a (@ (class "skip-link") (href "#main")) "Zum Inhalt")
           (header (@ (class "app-header"))
             (h1 (a (@ (href ,(url "/"))) "Folien"))
             (nav (@ (class "nav"))
               ;; The username links to the profile page, which is where
               ;; signing out lives. Admins also get the console.
               ,@(if who
                     `((a (@ (href ,(url "/"))) "Präsentationen")
                       (a (@ (href ,(url "/shared"))) "Geteilt")
                       (a (@ (href ,(url "/archive"))) "Archiv")
                       (a (@ (href ,(url "/trash"))) "Papierkorb")
                       ,@(if (cadr who) `((a (@ (href ,(url "/admin"))) "Verwaltung")) '())
                       (a (@ (href ,(url "/profile")) (class "who")) ,(car who)))
                     '())
               (button (@ (class "icon-btn js-theme-toggle") (type "button")
                          (aria-label "Hell/Dunkel umschalten"))
                 ,theme-icons)))
           (main (@ (id "main") (tabindex "-1")) ,body))))
       "\n"))

;; page with an optional module script.
    (define (page-with-script title who script body)
      (if script
          (page title who body `(script (@ (type "module") (src ,(asset script)))))
          (page title who body)))

    ;; msg: #f, or (kind . text) with kind 'error or 'success.
    (define (notice msg)
      (if msg
          `(p (@ (class ,(string-append "notice " (symbol->string (car msg))))
                 (role ,(if (eq? (car msg) 'error) "alert" "status")))
              ,(cdr msg))
          ""))

    (define (id->string x) (if (number? x) (number->string x) x))

    ;; next: the page to go to after signing in (a site path), or #f.
    (define (login-page error? . next)
      (page "Anmelden" #f
        `(section (@ (class "card narrow"))
           (h2 "Anmelden")
           ,(notice (and error? '(error . "Benutzername oder Passwort ist falsch.")))
           (form (@ (method "post") (action ,(url "/login")))
             ,(if (and (pair? next) (car next))
                  `(input (@ (type "hidden") (name "next") (value ,(car next))))
                  "")
             (label "Benutzername"
               (input (@ (name "username") (autocomplete "username")
                         (autofocus #t) (required #t))))
             (label "Passwort"
               (input (@ (name "password") (type "password")
                         (autocomplete "current-password") (required #t))))
             (button (@ (type "submit") (class "primary")) "Anmelden")))))

    ;; A remote QR code that no longer works (expired, renewed, or its
    ;; maker lost access): sign in instead, then to the remote.
    (define (remote-link-expired-page remote-path)
      (page "Fernbedienung" #f
        `(section (@ (class "card narrow"))
           (h2 "Dieser Code gilt nicht mehr")
           (p "Der QR-Code der Fernbedienung ist abgelaufen oder wurde ersetzt. "
              "Zeigen Sie in der Referentenansicht einen neuen an, oder melden Sie sich an.")
           (p (a (@ (class "button primary") (href ,(url (string-append "/login?next=" (percent-encode remote-path)))))
                 "Anmelden")))))

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

    (define (role-label role)
      (cond ((equal? role "edit") "darf bearbeiten")
            ((equal? role "view") "darf ansehen")
            (else "")))

    (define (list-path status)
      (cond ((string=? status "archived") "/archive")
            ((string=? status "trashed") "/trash")
            ((string=? status "shared") "/shared")
            (else "/")))

    (define (tag-chips status tags)
      (if (null? tags)
          ""
          `(span (@ (class "tags"))
             ,@(map (lambda (t)
                      `(a (@ (class "tag")
                             (href ,(url (string-append (list-path status) "?tag=" (percent-encode t)))))
                          ,t))
                    tags))))

    ;; --- deck cards ---------------------------------------------------
    ;; The lists show decks as cards: a picture of the first slide (drawn
    ;; by static/js/decks.js from data-slide), title, facts, tags, the
    ;; main action, and the others in a "⋯" menu (a details element, so
    ;; it works without JavaScript).

    (define (deck-path id . more)
      (url (apply string-append "/decks/" id more)))

    (define (menu-link href label . title)
      `(a (@ (class "menu-item") (href ,href) ,@(if (pair? title) `((title ,(car title))) '()))
          ,label))

    (define (menu-post id path label . danger)
      `(form (@ (method "post") (action ,(deck-path id path)))
         (button (@ (type "submit") (class ,(if (pair? danger) "menu-item menu-danger" "menu-item")))
                 ,label)))

    (define zip-title "Alles als ZIP: Folien, Bilder, PDFs, Offline-Player")

    ;; The overview's actions (the deck page): the main ones as buttons
    ;; (Bearbeiten where the user may edit, presenting, the remote), the
    ;; rest in a "⋯" menu as on the cards. Export is in its own section.
    (define (overview-actions status id role)
      (let* ((edit? (and (string=? status "active") (member role '("owner" "edit")) #t))
             (button-link (lambda (path label primary? . attrs)
                            `(a (@ (class ,(if primary? "button small primary-link" "button small"))
                                   (href ,(deck-path id path)) ,@attrs)
                                ,label)))
             (presenting
              (if (string=? status "trashed")
                  '()
                  (list (button-link "/present" "Präsentieren" (not edit?))
                        (button-link "/presenter" "Referentenansicht" #f)
                        ;; viewer.js shows the QR code instead of following
                        ;; the link (it needs the browser's address)
                        `(a (@ (class "button small js-remote-qr") (href ,(deck-path id "/remote"))
                               (aria-controls "remote-qr-box")
                               (title "QR-Code der Fernbedienung für das Telefon"))
                            "Fernbedienung"))))
             (menu (cond
                     ((not (string=? role "owner"))
                      (list (menu-post id "/duplicate" "Kopie für mich")))
                     ((string=? status "active")
                      (list (menu-post id "/duplicate" "Duplizieren")
                            (menu-post id "/archive" "Archivieren")
                            (menu-post id "/trash" "In den Papierkorb" #t)))
                     ((string=? status "archived")
                      (list (menu-post id "/restore" "Reaktivieren")
                            (menu-post id "/duplicate" "Duplizieren")
                            (menu-post id "/trash" "In den Papierkorb" #t)))
                     (else
                      (list (menu-post id "/delete" "Endgültig löschen" #t))))))
        `(,@(if edit? (list (button-link "/edit" "Bearbeiten" #t)) '())
          ,@(if (string=? status "trashed")
                (list `(form (@ (method "post") (action ,(deck-path id "/restore")) (class "inline"))
                         (button (@ (type "submit") (class "small")) "Wiederherstellen")))
                '())
          ,@presenting
          (details (@ (class "menu"))
            (summary (@ (class "button small") (aria-label "Weitere Aktionen") (title "Weitere Aktionen"))
                     "⋯")
            (div (@ (class "menu-list")) ,@menu)))))

    ;; (main-actions . menu-items) of a deck in a list, for the user's role.
    (define (card-actions status id role)
      (let ((open-btn (lambda (path label primary?)
                        `(a (@ (class ,(if primary? "button small primary-link" "button small"))
                               (href ,(deck-path id path)))
                            ,label))))
        (cond
          ((not (string=? role "owner"))
           (cons (if (and (string=? role "edit") (string=? status "active"))
                     (list (open-btn "/edit" "Bearbeiten" #t))
                     (list (open-btn "" "Ansehen" #t)))
                 (list (menu-link (deck-path id) "Übersicht")
                       (menu-link (deck-path id "/present") "Präsentieren")
                       (menu-post id "/duplicate" "Kopie für mich")
                       (menu-link (deck-path id "/export.zip") "Als ZIP herunterladen" zip-title))))
          ((string=? status "active")
           (cons (list (open-btn "/edit" "Bearbeiten" #t))
                 (list (menu-link (deck-path id) "Übersicht und Export")
                       (menu-link (deck-path id "/present") "Präsentieren")
                       (menu-post id "/duplicate" "Duplizieren")
                       (menu-link (deck-path id "/export.zip") "Als ZIP herunterladen" zip-title)
                       (menu-post id "/archive" "Archivieren")
                       (menu-post id "/trash" "In den Papierkorb" #t))))
          ((string=? status "archived")
           (cons (list (open-btn "" "Ansehen" #f))
                 (list (menu-post id "/restore" "Reaktivieren")
                       (menu-post id "/duplicate" "Duplizieren")
                       (menu-link (deck-path id "/export.zip") "Als ZIP herunterladen" zip-title)
                       (menu-post id "/trash" "In den Papierkorb" #t))))
          (else
           (cons (list `(form (@ (method "post") (action ,(deck-path id "/restore")) (class "inline"))
                          (button (@ (type "submit") (class "small")) "Wiederherstellen")))
                 (list (menu-post id "/delete" "Endgültig löschen" #t)))))))

    (define (deck-card status)
      (lambda (deck)
        (let* ((id (col deck "id"))
               (deck-status (col deck "status"))
               (role (let ((p (assoc "role" deck))) (if p (cdr p) "owner")))
               (editable? (and (string=? deck-status "active") (member role '("owner" "edit"))))
               (href (and (not (string=? deck-status "trashed"))
                          (deck-path id (if editable? "/edit" ""))))
               (first-slide (let ((p (assoc "first_slide" deck))) (and p (string? (cdr p)) (cdr p))))
               (thumb `(div (@ (class "slide-frame js-thumb")
                               (data-design ,(col deck "design"))
                               (data-asset-base ,(url (string-append "/api/decks/" id "/assets/")))
                               ,@(if first-slide `((data-slide ,first-slide)) '()))))
               (actions (card-actions deck-status id role))
               (template? (member (let ((p (assoc "is_template" deck))) (and p (cdr p))) '(#t "t" "true"))))
          `(li (@ (class "deck-card"))
             ,(if href
                  `(a (@ (class "deck-thumb") (href ,href) (tabindex "-1") (aria-hidden "true")) ,thumb)
                  `(div (@ (class "deck-thumb")) ,thumb))
             (div (@ (class "deck-body"))
               (h3 (@ (class "deck-title"))
                   ,(if href `(a (@ (href ,href)) ,(col deck "title")) (col deck "title")))
               (p (@ (class "deck-meta"))
                  ,(design-name (col deck "design"))
                  " · "
                  ,(cond ((member deck-status '("active" "shared")) "geändert ")
                         ((string=? deck-status "archived") "archiviert ")
                         (else "gelöscht "))
                  (span (@ (class "nowrap"))
                        ,(format-time (if (string=? deck-status "active")
                                          (col deck "updated_at")
                                          (col deck "status_at")))))
               ,(if (string=? role "owner")
                    ""
                    `(p (@ (class "deck-meta")) "von " ,(col deck "owner_name") " · " ,(role-label role)))
               (div (@ (class "deck-chips"))
                 ,(if template? '(span (@ (class "badge")) "Vorlage") "")
                 ,(if (and (string=? status "shared") (string=? deck-status "archived"))
                      '(span (@ (class "badge")) "Archiviert")
                      "")
                 ,(tag-chips status (deck-tags deck))))
             (div (@ (class "deck-actions"))
               ,@(car actions)
               (details (@ (class "menu"))
                 (summary (@ (class "button small") (aria-label "Weitere Aktionen") (title "Weitere Aktionen"))
                          "⋯")
                 (div (@ (class "menu-list")) ,@(cdr actions))))))))

    (define (deck-table decks status)
      (if (null? decks)
          `(p (@ (class "muted"))
              ,(cond ((string=? status "active") "Noch keine Präsentationen.")
                     ((string=? status "archived") "Das Archiv ist leer.")
                     ((string=? status "shared") "Niemand hat Ihnen eine Präsentation freigegeben.")
                     (else "Der Papierkorb ist leer.")))
          `(ul (@ (class "deck-grid") (data-designs-url ,(url "/api/designs")))
             ,@(map (deck-card status) decks))))

    (define (new-deck-form templates)
      `(form (@ (method "post") (action ,(url "/decks")) (class "row-form"))
         (input (@ (name "title") (placeholder "Titel der neuen Präsentation")
                   (aria-label "Titel") (maxlength "200") (required #t)))
         (select (@ (name "design") (aria-label "Design"))
           ,@(map (lambda (d)
                    `(option (@ (value ,(design-ref d "id"))) ,(design-ref d "name")))
                  designs))
         ,(if (null? templates)
              ""
              `(select (@ (name "template") (aria-label "Vorlage"))
                 (option (@ (value "")) "ohne Vorlage")
                 ,@(map (lambda (t)
                          `(option (@ (value ,(col t "id")))
                                   ,(string-append "Vorlage: " (col t "title"))))
                        templates)))
         (button (@ (type "submit") (class "primary")) "Erstellen")))

    ;; The search form of a list, and the tag it is filtered by.
    (define (search-bar status filters)
      (let ((q (car filters)) (tag (cdr filters)))
        `(div (@ (class "search-bar"))
           (form (@ (method "get") (action ,(url (list-path status))) (class "row-form"))
             (input (@ (name "q") (type "search") (value ,q) (placeholder "Titel oder Stichwort suchen")
                       (aria-label "Suchen")))
             ,(if (string=? tag "") "" `(input (@ (type "hidden") (name "tag") (value ,tag))))
             (button (@ (type "submit") (class "small")) "Suchen"))
           ,(if (and (string=? q "") (string=? tag ""))
                ""
                `(p (@ (class "muted"))
                    ,(if (string=? tag "") "" `(span "Stichwort " (strong ,tag) " "))
                    ,(if (string=? q "") "" `(span "Suche «" ,q "» "))
                    (a (@ (href ,(url (list-path status)))) "alle zeigen"))))))

    ;; status: "active", "archived", "trashed" or "shared" (with me).
    ;; filters: (query . tag); templates: for the new-deck form.
    (define (decks-page who status decks msg filters templates)
      (let ((title (cond ((string=? status "active") "Präsentationen")
                         ((string=? status "archived") "Archiv")
                         ((string=? status "shared") "Mit mir geteilt")
                         (else "Papierkorb"))))
        (page title who
          `(section
             (h2 ,title)
             ,(notice msg)
             ,(if (string=? status "active")
                  `(div (@ (class "card")) (h3 "Neue Präsentation") ,(new-deck-form templates)
                     (div (@ (class "import-row"))
                       (label (@ (class "button small file-button"))
                         "Aus ZIP importieren …"
                         (input (@ (type "file") (accept ".zip,application/zip")
                                   (class "js-import visually-hidden")
                                   (data-import-url ,(url "/api/import"))
                                   (data-deck-base ,(url "/decks/")))))
                       (span (@ (class "muted js-import-status"))
                             "Ein mit Folien exportiertes ZIP wird zu einer neuen Präsentation.")))
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
             ,(search-bar status filters)
             ,(deck-table decks status))
          `(link (@ (rel "stylesheet") (href ,(asset "css/slides.css"))))
          `(script (@ (type "module") (src ,(asset "js/decks.js")))))))

    ;; --- one deck -----------------------------------------------------
    ;; The deck's facts, actions and rename form; below them the viewer
    ;; (static/js/viewer.js), which loads the deck from the JSON API.

    (define (join-tags tags)
      (let loop ((ts tags) (acc ""))
        (cond ((null? ts) acc)
              ((string=? acc "") (loop (cdr ts) (car ts)))
              (else (loop (cdr ts) (string-append acc ", " (car ts)))))))

    (define (shares-card id shares)
      `(section (@ (class "card spaced-card"))
         (h3 "Freigeben")
         ,(if (null? shares)
              '(p (@ (class "muted")) "Diese Präsentation ist niemandem freigegeben.")
              `(table (@ (class "data"))
                 (tbody
                  ,@(map (lambda (sh)
                           `(tr (td ,(col sh "username"))
                                (td (@ (class "muted")) ,(role-label (col sh "role")))
                                (td (form (@ (method "post")
                                             (action ,(url (string-append "/decks/" id "/shares/"
                                                                          (id->string (col sh "user_id"))
                                                                          "/delete")))
                                             (class "inline"))
                                      (button (@ (type "submit") (class "small")) "Entfernen")))))
                         shares))))
         (form (@ (method "post") (action ,(url (string-append "/decks/" id "/shares")))
                  (class "row-form"))
           (input (@ (name "username") (placeholder "Benutzername") (aria-label "Benutzername")
                     (required #t)))
           (select (@ (name "role") (aria-label "Recht"))
             (option (@ (value "view")) "darf ansehen")
             (option (@ (value "edit")) "darf bearbeiten"))
           (button (@ (type "submit")) "Freigeben"))))

    (define (versions-card id versions)
      `(section (@ (id "versions") (class "card spaced-card"))
         (h3 "Versionen")
         (form (@ (method "post") (action ,(url (string-append "/decks/" id "/versions")))
                  (class "row-form"))
           (input (@ (name "name") (placeholder "Name, z. B. «Vor der Sitzung»") (aria-label "Name")
                     (maxlength "200") (required #t)))
           (button (@ (type "submit")) "Aktuellen Stand speichern"))
         ,(if (null? versions)
              '(p (@ (class "muted")) "Noch keine Versionen gespeichert.")
              `(table (@ (class "data spaced-table"))
                 (tbody
                  ,@(map (lambda (v)
                           (let ((vid (id->string (col v "id"))))
                             `(tr (td ,(col v "name"))
                                  (td (@ (class "muted nowrap"))
                                      ,(format-time (col v "created_at"))
                                      ,(let ((a (col v "author"))) (if (string? a) (string-append " · " a) "")))
                                  (td (div (@ (class "actions"))
                                        ,(action-button id (string-append "/versions/" vid "/restore")
                                                        "Wiederherstellen")
                                        ,(action-button id (string-append "/versions/" vid "/delete")
                                                        "Löschen" "small danger"))))))
                         versions))))))

    (define (deck-page who deck slide-count msg shares versions)
      (let* ((id (col deck "id"))
             (status (col deck "status"))
             (role (col deck "role"))
             (owner? (string=? role "owner"))
             (active? (and (string=? status "active") (member role '("owner" "edit")) #t)))
        (page (col deck "title") who
          `(section
             (div (@ (class "deck-head"))
               (div
                 (p (@ (class "eyebrow")) "Übersicht")
                 (h2 ,(col deck "title"))
                 (p (@ (class "muted"))
                    ,(design-name (col deck "design")) " · "
                    ,(number->string slide-count) ,(if (= slide-count 1) " Folie" " Folien")
                    " · Revision " ,(id->string (col deck "revision"))
                    ,(cond ((string=? status "archived") " · archiviert (schreibgeschützt)")
                           ((string=? status "trashed") " · im Papierkorb")
                           (else ""))
                    ,(if owner?
                         ""
                         (string-append " · von " (col deck "owner_name") ", Sie dürfen "
                                        (if (equal? role "edit") "bearbeiten" "ansehen")))))
               (div (@ (class "actions overview-actions"))
                 ,@(overview-actions status id role)))
             ,(notice msg)
             (div (@ (id "viewer") (class "viewer")
                     (data-deck-url ,(url (string-append "/api/decks/" id)))
                     (data-designs-url ,(url "/api/designs"))
                     (data-present-url ,(url (string-append "/decks/" id "/present")))
                     (data-presenter-url ,(url (string-append "/decks/" id "/presenter"))))
               (noscript "Zum Anzeigen der Folien wird JavaScript benötigt."))
             (section (@ (id "export") (class "card spaced-card"))
               (h3 "Als PDF exportieren")
               (form (@ (method "get") (action ,(url (string-append "/decks/" id "/export.pdf")))
                        (class "row-form"))
                 (label (@ (class "inline-field")) "Folien pro Seite"
                   (select (@ (name "per-page"))
                     (option (@ (value "1")) "1")
                     (option (@ (value "2")) "2")
                     (option (@ (value "4")) "4")))
                 (label (@ (class "inline-field")) "Notizen"
                   (select (@ (name "notes"))
                     (option (@ (value "0")) "ohne")
                     (option (@ (value "1")) "mit")))
                 (label (@ (class "inline-field")) "Aufbau"
                   (select (@ (name "builds"))
                     (option (@ (value "final")) "fertige Folien")
                     (option (@ (value "steps")) "jeder Schritt eine Seite")))
                 (button (@ (type "submit") (class "primary")) "PDF herunterladen"))
               (p (@ (class "muted bundle-note"))
                  (a (@ (href ,(url (string-append "/decks/" id "/export.pptx"))))
                     "Als PowerPoint (.pptx) herunterladen")
                  " · "
                  (a (@ (href ,(url (string-append "/decks/" id "/export.zip"))))
                     "Alles als ZIP herunterladen")
                  " – die Präsentation mit Bildern und Videos, den PDFs und einem "
                  "Player, der ohne Server im Browser läuft. Das ZIP lässt sich wieder importieren."))
             ,(if active?
                  `(form (@ (method "post") (action ,(url (string-append "/decks/" id "/rename")))
                            (class "row-form spaced"))
                     (input (@ (name "title") (value ,(col deck "title")) (aria-label "Titel")
                               (maxlength "200") (required #t)))
                     (button (@ (type "submit")) "Umbenennen"))
                  "")
             ,(if active?
                  `(section (@ (class "card spaced-card"))
                     (h3 "Stichwörter")
                     (form (@ (method "post") (action ,(url (string-append "/decks/" id "/tags")))
                              (class "row-form"))
                       (input (@ (name "tags") (value ,(join-tags (deck-tags deck)))
                                 (placeholder "z. B. Bericht, 2026, Gesundheit") (aria-label "Stichwörter")))
                       (button (@ (type "submit")) "Speichern"))
                     ,(if owner?
                          (let ((on? (member (col deck "is_template") '(#t "t" "true"))))
                            `(form (@ (method "post") (action ,(url (string-append "/decks/" id "/template")))
                                      (class "row-form"))
                               (input (@ (type "hidden") (name "on") (value ,(if on? "0" "1"))))
                               (span (@ (class "muted"))
                                     ,(if on? "Diese Präsentation ist eine Vorlage. "
                                          "Als Vorlage steht eine Präsentation beim Erstellen zur Wahl. "))
                               (button (@ (type "submit"))
                                       ,(if on? "Keine Vorlage mehr" "Als Vorlage verwenden"))))
                          ""))
                  "")
             ,(if active? (versions-card id versions) "")
             ,(if (and owner? (not (string=? status "trashed"))) (shares-card id shares) ""))
          `(link (@ (rel "stylesheet") (href ,(asset "css/slides.css"))))
          `(script (@ (type "module") (src ,(asset "js/viewer.js")))))))

    ;; --- full-window applications --------------------------------------
    ;; The editor, the presentation, the presenter console and the remote
    ;; are applications in static/js without the site header; their page
    ;; only carries the URLs they need, as data attributes.

    (define (deck-urls deck)
      (let ((id (col deck "id")))
        `((data-deck-url ,(url (string-append "/api/decks/" id)))
          (data-designs-url ,(url "/api/designs"))
          (data-events-url ,(url (string-append "/api/decks/" id "/events")))
          (data-view-url ,(url (string-append "/decks/" id)))
          (data-present-url ,(url (string-append "/decks/" id "/present")))
          (data-presenter-url ,(url (string-append "/decks/" id "/presenter")))
          (data-remote-url ,(url (string-append "/decks/" id "/remote")))
          (data-home-url ,(url "/")))))

    (define (app-page deck title-suffix body-class root-id stylesheets script)
      (string-append
       (html->string
        (html5
         '(@ (lang "de"))
         `(head
           (meta (@ (charset "utf-8")))
           (meta (@ (name "viewport") (content "width=device-width, initial-scale=1")))
           (title ,(string-append (col deck "title") title-suffix " · Folien"))
           (link (@ (rel "icon") (href ,(asset "favicon.svg"))))
           ,@(map (lambda (css) `(link (@ (rel "stylesheet") (href ,(asset css)))))
                  (append '("css/app.css" "css/slides.css") stylesheets))
           (script (@ (src ,(asset "js/theme-init.js"))))
           (script (@ (type "module") (src ,(asset script)))))
         `(body (@ (class ,body-class))
            (div (@ (id ,root-id) (class ,root-id) ,@(deck-urls deck))
              (noscript "Diese Seite braucht JavaScript.")))))
       "\n"))

    (define (editor-page deck)
      (app-page deck "" "editor-body" "editor" '("css/editor.css") "js/editor.js"))

    (define (present-page deck)
      (app-page deck " (Präsentation)" "present-body" "present" '("css/present.css")
                "js/present.js"))

    (define (presenter-page deck)
      (app-page deck " (Referentenansicht)" "presenter-body" "presenter" '("css/present.css")
                "js/presenter.js"))

    (define (remote-page deck)
      (app-page deck " (Fernbedienung)" "remote-body" "remote" '("css/present.css")
                "js/remote.js"))

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
