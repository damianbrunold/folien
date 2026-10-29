;; (app bundle) — a deck as one zip file, and back.
;;
;; A bundle holds everything a deck needs and what one usually wants from
;; it:
;;
;;   manifest.json       format, version, title, design, the assets
;;   presentation.json   the document (src/app-model.sld)
;;   assets/<sha>.<ext>  the images and videos it uses
;;   exports/            slides, notes, handouts with 2 and 4 per page as
;;                       PDF; the deck as PowerPoint file
;;   player/index.html   an offline player: open it in a browser
;;   LIESMICH.txt        what all this is
;;
;; Importing a bundle makes a new deck for the importing user. A bundle
;; comes from outside, so nothing in it is trusted: only the two JSON
;; files and the assets the document refers to are read, by their known
;; names (no path in the archive is ever used as a file name), sizes are
;; checked before and while unpacking, every asset must hash to its name
;; and be a type folien accepts, the document must validate.
;;
;; The offline player also comes on its own, without notes and hidden
;; slides, for presenting without a network: as one HTML file with
;; everything in it (write-offline-html!; its images and videos are
;; turned into blob URLs when it opens), or as a zip of the player's
;; folder with the files beside it (write-offline-zip!: better for large
;; videos).

(define-library (app bundle)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scm fs)
          (scm zip)
          (scm crypto)
          (scm datetime)
          (scheme time)
          (scm json simple)
          (scm string)
          (app db)
          (app users)            ; col
          (app designs)
          (app model)
          (app decks)
          (app assets)
          (app export-pdf)
          (app export-pptx)
          (app jsbundle))
  (export bundle-version
          write-bundle!
          write-offline-zip!
          write-offline-html!
          player-entries
          write-player-html
          import-bundle!
          bundle-error?
          bundle-error-message
          referenced-assets)
  (begin

    (define bundle-format "folien-bundle")
    (define bundle-version 1)

    ;; The modules of the offline player, dependencies first.
    (define player-modules
      '("render.js" "shortcuts.js" "deck-nav.js" "player.js" "sync.js" "present-app.js" "offline.js"))

    ;; --- errors -------------------------------------------------------

    (define-record-type bundle-error
      (make-bundle-error message)
      bundle-error?
      (message bundle-error-message))

    (define (fail message) (raise (make-bundle-error message)))

    ;; --- the assets of a document ---------------------------------------

    (define (referenced-assets doc)
      "Syntax: (referenced-assets doc)
Library: (app bundle)
Description: The asset hashes the document's elements refer to (asset
  and poster), without duplicates."
      (let loop ((slides (vector->list (doc-slides doc))) (acc '()))
        (if (null? slides)
            (reverse acc)
            (loop (cdr slides)
                  (let els ((es (vector->list (jref (car slides) "elements" #()))) (acc acc))
                    (if (null? es)
                        acc
                        (els (cdr es)
                             (let add ((keys '("asset" "poster")) (acc acc))
                               (if (null? keys)
                                   acc
                                   (let ((v (jref (car es) (car keys))))
                                     (add (cdr keys)
                                          (if (and (valid-sha? v) (not (member v acc)))
                                              (cons v acc)
                                              acc))))))))))))

    ;; --- writing ----------------------------------------------------------

    (define (text-entry! z name text)
      (let ((p (zip-add-text-entry z name)))
        (write-string text p)
        (flush-output-port p)))

    (define (number-or-null v)
      (cond ((number? v) v)
            ((and (string? v) (string->number v)) => (lambda (n) n))
            (else 'null)))

    (define (html-escape s)
      (let loop ((cs (string->list s)) (acc '()))
        (if (null? cs)
            (apply string-append (reverse acc))
            (loop (cdr cs)
                  (cons (case (car cs)
                          ((#\&) "&amp;") ((#\<) "&lt;") ((#\>) "&gt;") ((#\") "&quot;")
                          (else (string (car cs))))
                        acc)))))

    (define (player-html title)
      (string-append
       "<!doctype html>\n<html lang=\"de\">\n<head>\n<meta charset=\"utf-8\">\n"
       "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
       "<title>" (html-escape title) "</title>\n"
       "<link rel=\"stylesheet\" href=\"css/slides.css\">\n"
       "<link rel=\"stylesheet\" href=\"css/present.css\">\n"
       "</head>\n<body class=\"present-body\">\n"
       "<div id=\"present\" class=\"present\"></div>\n"
       "<script src=\"deck-data.js\"></script>\n"
       "<script src=\"folien-player.js\"></script>\n"
       "</body>\n</html>\n"))

    (define (readme title)
      (string-append
       "Folien – " title "\n"
       "\n"
       "Dieses Archiv enthält die Präsentation mit allem, was dazugehört:\n"
       "\n"
       "  player/index.html   Die Präsentation im Browser zeigen, ohne Internet\n"
       "                      und ohne Folien-Server: die Datei im Browser öffnen,\n"
       "                      F für Vollbild, Pfeiltasten oder Leertaste zum Blättern.\n"
       "  exports/            Die Präsentation als PDF: folien.pdf (die Folien),\n"
       "                      notizen.pdf (mit Notizen), handout-2.pdf und\n"
       "                      handout-4.pdf (2 oder 4 Folien pro Seite), und\n"
       "                      folien.pptx für PowerPoint.\n"
       "  presentation.json   Die Präsentation selbst, assets/ ihre Bilder und Videos,\n"
       "  manifest.json       das Verzeichnis dazu.\n"
       "\n"
       "In Folien lässt sich das ganze Archiv wieder importieren\n"
       "(Präsentationen → Importieren); es entsteht eine neue Präsentation.\n"))

    (define (player-entries static-dir deck-id title design-id doc asset-urls . prefix)
      "Syntax: (player-entries static-dir deck-id title design-id doc asset-urls [prefix])
Library: (app bundle)
Description: The files of the offline player: a list of (name text . s)
  or (name file . path), names relative to the bundle: prefix (default
  \"player/\") and the player's own. asset-urls maps asset hashes to URLs
  relative to <prefix>index.html."
      (define dir (if (pair? prefix) (car prefix) "player/"))
      (append
       (list (cons (string-append dir "index.html") (cons 'text (player-html title)))
             (cons (string-append dir "deck-data.js")
                   (cons 'text (string-append
                                "window.FOLIEN_BUNDLE = "
                                (json->string
                                 `(("deck" . (("id" . ,deck-id) ("title" . ,title)))
                                   ("doc" . ,doc)
                                   ("design" . ,(find-design design-id))
                                   ("assets" . ,asset-urls)))
                                ";\n")))
             (cons (string-append dir "folien-player.js")
                   (cons 'text (bundle-modules (string-append static-dir "/js") player-modules))))
       (map (lambda (css) (cons (string-append dir "css/" css)
                                (cons 'file (string-append static-dir "/css/" css))))
            '("slides.css" "present.css"))
       (map (lambda (font) (cons (string-append dir "fonts/" font)
                                 (cons 'file (string-append static-dir "/fonts/" font))))
            (font-files (find-design design-id)))))

    ;; The font files (static/fonts) of a design's family, and the code
    ;; font's.
    (define (font-files design)
      (let* ((body (cdr (assoc "body" (design-ref design "fonts"))))
             (family (cdr (assoc "family" body))))
        (append
         (if (equal? family "Roboto Slab")
             '("RobotoSlab-Regular.woff2" "RobotoSlab-Bold.woff2" "RobotoSlab-LICENSE.txt")
             '("Inter-Regular.woff2" "Inter-Black.woff2" "Inter-LICENSE.txt"))
         '("JetBrainsMono-Regular.woff2" "JetBrainsMono-Bold.woff2" "JetBrainsMono-LICENSE.txt"))))

    ;; The asset rows (list-deck-assets) of the deck's assets that doc
    ;; refers to and that are there.
    (define (doc-asset-rows db data-dir deck-id doc)
      (let ((linked (list-deck-assets db deck-id)))
        (let loop ((shas (referenced-assets doc)) (acc '()))
          (if (null? shas)
              (reverse acc)
              (let ((row (let find ((ls linked))
                           (cond ((null? ls) #f)
                                 ((equal? (col (car ls) "sha256") (car shas)) (car ls))
                                 (else (find (cdr ls)))))))
                (loop (cdr shas)
                      (if (and row (file-exists? (asset-file data-dir (car shas))))
                          (cons row acc)
                          acc)))))))

    (define (asset-path row)
      (string-append "assets/" (col row "sha256") "." (mime-extension (col row "mime"))))

    (define (write-bundle! db data-dir static-dir deck out-path)
      "Syntax: (write-bundle! db data-dir static-dir deck out-path)
Library: (app bundle)
Description: Writes the bundle of deck (a row from load-deck) to the
  zip file out-path."
      (let* ((id (col deck "id"))
             (title (col deck "title"))
             (design-id (col deck "design"))
             (doc (deck-doc deck))
             (rows (doc-asset-rows db data-dir id doc))
             (manifest
              `(("format" . ,bundle-format)
                ("version" . ,bundle-version)
                ("app" . "folien")
                ("exported" . ,(format-iso8601 (exact (floor (current-second)))))
                ("title" . ,title)
                ("design" . ,design-id)
                ("docFormat" . ,doc-format)
                ("assets"
                 . ,(list->vector
                     (map (lambda (row)
                            `(("sha" . ,(col row "sha256"))
                              ("mime" . ,(col row "mime"))
                              ("name" . ,(col row "name"))
                              ("size" . ,(number-or-null (col row "size")))
                              ("width" . ,(number-or-null (col row "width")))
                              ("height" . ,(number-or-null (col row "height")))
                              ("file" . ,(asset-path row))))
                          rows)))
                ("player" . "player/index.html")))
             (asset-urls (map (lambda (row)
                                (cons (col row "sha256") (string-append "../" (asset-path row))))
                              rows))
             (pdf (lambda (opts) (deck->pdf doc design-id title data-dir opts))))
        (call-with-output-zip out-path
          (lambda (z)
            (text-entry! z "LIESMICH.txt" (readme title))
            (text-entry! z "manifest.json" (json->pretty-string manifest))
            (text-entry! z "presentation.json" (json->pretty-string doc))
            (for-each (lambda (row)
                        (zip-add-file-entry z (asset-path row) (asset-file data-dir (col row "sha256"))))
                      rows)
            (zip-add-stored-entry z "exports/folien.pdf" (pdf '()))
            (zip-add-stored-entry z "exports/notizen.pdf" (pdf '((notes . #t))))
            (zip-add-stored-entry z "exports/handout-2.pdf" (pdf '((per-page . 2))))
            (zip-add-stored-entry z "exports/handout-4.pdf" (pdf '((per-page . 4))))
            (zip-add-stored-entry z "exports/folien.pptx" (deck->pptx doc design-id title data-dir))
            (for-each (lambda (e)
                        (if (eq? (cadr e) 'text)
                            (text-entry! z (car e) (cddr e))
                            (zip-add-file-entry z (car e) (cddr e))))
                      (player-entries static-dir id title design-id doc asset-urls))))))

    ;; --- the offline player on its own ------------------------------------

    (define (offline-readme title)
      (string-append
       "Folien – " title "\n"
       "\n"
       "Die Präsentation zum Zeigen ohne Internet und ohne Folien-Server:\n"
       "index.html im Browser öffnen (alle Dateien dieses Ordners zusammen\n"
       "lassen), F für Vollbild, Pfeiltasten oder Leertaste zum Blättern,\n"
       "B schwarz, W weiss.\n"
       "\n"
       "Notizen und ausgeblendete Folien sind nicht dabei.\n"))

    (define (write-offline-zip! db data-dir static-dir deck out-path)
      "Syntax: (write-offline-zip! db data-dir static-dir deck out-path)
Library: (app bundle)
Description: Writes the offline player of deck (a row from load-deck),
  without notes and hidden slides, as a zip of its folder to out-path:
  index.html, its script, styles and fonts, assets/, LIESMICH.txt."
      (let* ((id (col deck "id"))
             (title (col deck "title"))
             (doc (shareable-doc (deck-doc deck)))
             (rows (doc-asset-rows db data-dir id doc)))
        (call-with-output-zip out-path
          (lambda (z)
            (text-entry! z "LIESMICH.txt" (offline-readme title))
            (for-each (lambda (row)
                        (zip-add-file-entry z (asset-path row) (asset-file data-dir (col row "sha256"))))
                      rows)
            (for-each (lambda (e)
                        (if (eq? (cadr e) 'text)
                            (text-entry! z (car e) (cddr e))
                            (zip-add-file-entry z (car e) (cddr e))))
                      (player-entries static-dir id title (col deck "design") doc
                                      (map (lambda (row) (cons (col row "sha256") (asset-path row))) rows)
                                      ""))))))

    (define (read-text-file path)
      (call-with-input-file path
        (lambda (p)
          (let loop ((acc '()))
            (let ((s (read-string 65536 p)))
              (if (eof-object? s)
                  (apply string-append (reverse acc))
                  (loop (cons s acc))))))))

    ;; The file at path as base64, written to port a piece at a time (a
    ;; multiple of 3 bytes, so the pieces join up).
    (define (write-base64-file path port)
      (let ((in (open-binary-input-file path)))
        (let loop ()
          (let ((bv (read-bytevector (* 3 1024 1024) in)))
            (unless (eof-object? bv)
              (write-string (base64-encode bv) port)
              (loop))))
        (close-port in)))

    ;; Inside <script>: "</" never ends the element early.
    (define (script-safe s) (string-replace-all s "</" "<\\/"))

    (define (write-player-html port static-dir deck-id title design-id doc assets)
      "Syntax: (write-player-html port static-dir deck-id title design-id doc assets)
Library: (app bundle)
Description: Writes the offline player as one HTML file to port: styles
  with the fonts as data URLs, the deck, the assets (a list of
  (sha mime . path)) as base64 blocks, which offline.js turns into blob
  URLs, and the player's script."
      (let* ((fonts (font-files (find-design design-id)))
             (font-url (lambda (f) (string-append "url(\"../fonts/" f "\")")))
             (css (lambda (name)
                    (let loop ((fs fonts) (text (read-text-file (string-append static-dir "/css/" name))))
                      (cond ((null? fs) text)
                            ((string-suffix? ".woff2" (car fs))
                             (loop (cdr fs)
                                   (if (string-contains-from text (font-url (car fs)) 0)
                                       (let ((p (open-output-string)))
                                         (write-string "url(\"data:font/woff2;base64," p)
                                         (write-base64-file (string-append static-dir "/fonts/" (car fs)) p)
                                         (write-string "\")" p)
                                         (string-replace-all text (font-url (car fs)) (get-output-string p)))
                                       text)))
                            (else (loop (cdr fs) text))))))
             (w (lambda strings (for-each (lambda (s) (write-string s port)) strings))))
        (w "<!doctype html>\n<html lang=\"de\">\n<head>\n<meta charset=\"utf-8\">\n"
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
           "<title>" (html-escape title) "</title>\n"
           "<style>\n" (css "slides.css") "\n</style>\n"
           "<style>\n" (css "present.css") "\n</style>\n")
        ;; the fonts' licences go with them
        (for-each (lambda (f)
                    (when (string-suffix? ".txt" f)
                      (w "<script type=\"text/plain\" class=\"font-license\" data-file=\"" f "\">\n"
                         (script-safe (read-text-file (string-append static-dir "/fonts/" f)))
                         "\n</script>\n")))
                  fonts)
        (w "</head>\n<body class=\"present-body\">\n"
           "<div id=\"present\" class=\"present\"></div>\n")
        (for-each (lambda (a)
                    (w "<script type=\"application/x-folien-asset\" data-sha=\"" (car a)
                       "\" data-mime=\"" (html-escape (cadr a)) "\">")
                    (write-base64-file (cddr a) port)
                    (w "</script>\n"))
                  assets)
        (w "<script>window.FOLIEN_BUNDLE = "
           (script-safe (json->string
                         `(("deck" . (("id" . ,deck-id) ("title" . ,title)))
                           ("doc" . ,doc)
                           ("design" . ,(find-design design-id))
                           ("assets" . ()))))
           ";</script>\n"
           "<script>\n"
           (script-safe (bundle-modules (string-append static-dir "/js") player-modules))
           "</script>\n</body>\n</html>\n")))

    (define (write-offline-html! db data-dir static-dir deck out-path)
      "Syntax: (write-offline-html! db data-dir static-dir deck out-path)
Library: (app bundle)
Description: Writes the offline player of deck (a row from load-deck),
  without notes and hidden slides, as one HTML file to out-path."
      (let* ((id (col deck "id"))
             (doc (shareable-doc (deck-doc deck)))
             (rows (doc-asset-rows db data-dir id doc))
             (port (open-output-file out-path)))
        (write-player-html port static-dir id (col deck "title") (col deck "design") doc
                           (map (lambda (row)
                                  (cons (col row "sha256")
                                        (cons (col row "mime") (asset-file data-dir (col row "sha256")))))
                                rows))
        (close-port port)))

    ;; --- reading --------------------------------------------------------

    (define max-json-bytes (* 50 1024 1024))
    (define max-entries 10000)

    (define (read-json z name)
      (let ((size (guard (e (#t (fail (string-append "Im Archiv fehlt " name "."))))
                    (zip-entry-size z name))))
        (when (and size (> size max-json-bytes))
          (fail (string-append name " ist zu gross.")))
        (guard (e ((bundle-error? e) (raise e))
                  (#t (fail (string-append name " ist kein gültiges JSON."))))
          (json-parse (utf8->string (zip-read-entry-bytevector z name))))))

    (define (string-suffix? suffix s)
      (and (>= (string-length s) (string-length suffix))
           (string=? (substring s (- (string-length s) (string-length suffix)) (string-length s))
                     suffix)))

    ;; The archive entry of an asset: the manifest's "file" if it is the
    ;; expected name, else the first assets/<sha>.<ext> there is.
    (define (asset-entry names sha manifest-assets)
      (let* ((prefix (string-append "assets/" sha "."))
             (declared (let find ((as manifest-assets))
                         (cond ((null? as) #f)
                               ((equal? (jref (car as) "sha") sha) (jref (car as) "file"))
                               (else (find (cdr as)))))))
        (or (and (string? declared)
                 (>= (string-length declared) (string-length prefix))
                 (string=? (substring declared 0 (string-length prefix)) prefix)
                 (member declared names)
                 declared)
            (let find ((ns names))
              (cond ((null? ns) #f)
                    ((and (>= (string-length (car ns)) (string-length prefix))
                          (string=? (substring (car ns) 0 (string-length prefix)) prefix))
                     (car ns))
                    (else (find (cdr ns))))))))

    (define (manifest-field manifest-assets sha key)
      (let find ((as manifest-assets))
        (cond ((null? as) #f)
              ((equal? (jref (car as) "sha") sha) (jref (car as) key))
              (else (find (cdr as))))))

    (define (->string-or-false v)
      (cond ((exact-integer? v) (number->string v)) (else #f)))

    (define (import-bundle! db data-dir owner-id zip-path max-asset-bytes)
      "Syntax: (import-bundle! db data-dir owner-id zip-path max-asset-bytes)
Library: (app bundle)
Description: Makes a new deck for the owner from the bundle at zip-path
  and returns its id. Raises a bundle-error (with a message for the
  user) when the file is not a bundle folien can read."
      (let ((tmp-dir (string-append data-dir "/tmp")))
        (unless (directory-exists? tmp-dir)
          (guard (e (#t #f)) (make-directory tmp-dir)))
        (let ((z (guard (e (#t (fail "Die Datei ist kein lesbares ZIP-Archiv.")))
                   (open-input-zip-file zip-path))))
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ((names (zip-entry-names z)))
                (when (> (length names) max-entries)
                  (fail "Das Archiv enthält zu viele Dateien."))
                (unless (member "manifest.json" names)
                  (fail "Das ist kein Folien-Archiv (manifest.json fehlt)."))
                (let* ((manifest (read-json z "manifest.json"))
                       (version (jref manifest "version")))
                  (unless (and (list? manifest) (equal? (jref manifest "format") bundle-format))
                    (fail "Das ist kein Folien-Archiv."))
                  (unless (and (exact-integer? version) (<= 1 version bundle-version))
                    (fail "Dieses Archiv stammt aus einer neueren Version von Folien."))
                  (let* ((doc (read-json z "presentation.json"))
                         (design (let ((d (jref manifest "design")))
                                   (if (and (string? d) (find-design d)) d default-design-id)))
                         (title (let ((t (jref manifest "title")))
                                  (if (valid-title? t) t "Importierte Präsentation")))
                         (problem (validate-doc doc design))
                         (manifest-assets (let ((a (jref manifest "assets" #())))
                                            (if (vector? a) (vector->list a) '()))))
                    (when problem
                      (fail (string-append "Die Präsentation im Archiv ist ungültig (" problem ").")))
                    ;; Unpack and check the assets before making the deck.
                    (let ((files
                           (map (lambda (sha)
                                  (let ((entry (asset-entry names sha manifest-assets)))
                                    (unless entry
                                      (fail (string-append "Im Archiv fehlt ein Bild oder Video ("
                                                           (substring sha 0 12) "…).")))
                                    (let ((size (zip-entry-size z entry)))
                                      (when (and size (> size max-asset-bytes))
                                        (fail "Eine Datei im Archiv ist zu gross.")))
                                    (let ((tmp (string-append tmp-dir "/import-"
                                                              (random-string "abcdefghijklmnop" 12))))
                                      (guard (e (#t (when (file-exists? tmp) (delete-file tmp))
                                                    (fail "Eine Datei im Archiv ist zu gross oder beschädigt.")))
                                        (zip-extract-entry z entry tmp max-asset-bytes))
                                      (unless (equal? (file-sha tmp) sha)
                                        (delete-file tmp)
                                        (fail "Eine Datei im Archiv ist beschädigt (Prüfsumme)."))
                                      (cons sha tmp))))
                                (referenced-assets doc))))
                      (let ((id (create-deck-with-doc! db owner-id title design doc)))
                        (guard (e (#t (for-each (lambda (f) (when (file-exists? (cdr f)) (delete-file (cdr f))))
                                                files)
                                      (db-exec db "DELETE FROM presentations WHERE id = $1" id)
                                      (raise e)))
                          (for-each
                           (lambda (f)
                             (let* ((sha (car f))
                                    (name (let ((n (manifest-field manifest-assets sha "name")))
                                            (if (and (string? n) (<= 1 (string-length n) 200))
                                                n
                                                (string-append sha "."))))
                                    (r (store-asset-file! db data-dir id (cdr f) name
                                                          (->string-or-false (manifest-field manifest-assets sha "width"))
                                                          (->string-or-false (manifest-field manifest-assets sha "height")))))
                               (when (symbol? r)
                                 (fail (if (memq r '(invalid too-large))
                                           "Ein Bild im Archiv ist beschädigt oder zu gross."
                                           "Eine Datei im Archiv hat einen Typ, den Folien nicht annimmt.")))))
                           files))
                        id))))))
            (lambda () (close-input-zip z))))))))
