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
          player-entries
          import-bundle!
          bundle-error?
          bundle-error-message
          referenced-assets)
  (begin

    (define bundle-format "folien-bundle")
    (define bundle-version 1)

    ;; The modules of the offline player, dependencies first.
    (define player-modules
      '("render.js" "deck-nav.js" "player.js" "sync.js" "present-app.js" "offline.js"))

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

    (define (player-entries static-dir deck-id title design-id doc asset-urls)
      "Syntax: (player-entries static-dir deck-id title design-id doc asset-urls)
Library: (app bundle)
Description: The files of the offline player: a list of (name text . s)
  or (name file . path), names relative to the bundle. asset-urls maps
  asset hashes to URLs relative to player/index.html."
      (append
       (list (cons "player/index.html" (cons 'text (player-html title)))
             (cons "player/deck-data.js"
                   (cons 'text (string-append
                                "window.FOLIEN_BUNDLE = "
                                (json->string
                                 `(("deck" . (("id" . ,deck-id) ("title" . ,title)))
                                   ("doc" . ,doc)
                                   ("design" . ,(find-design design-id))
                                   ("assets" . ,asset-urls)))
                                ";\n")))
             (cons "player/folien-player.js"
                   (cons 'text (bundle-modules (string-append static-dir "/js") player-modules))))
       (map (lambda (css) (cons (string-append "player/css/" css)
                                (cons 'file (string-append static-dir "/css/" css))))
            '("slides.css" "present.css"))
       (map (lambda (font) (cons (string-append "player/fonts/" font)
                                 (cons 'file (string-append static-dir "/fonts/" font))))
            '("Inter-Regular.woff2" "Inter-Black.woff2" "Inter-LICENSE.txt"))))

    (define (write-bundle! db data-dir static-dir deck out-path)
      "Syntax: (write-bundle! db data-dir static-dir deck out-path)
Library: (app bundle)
Description: Writes the bundle of deck (a row from load-deck) to the
  zip file out-path."
      (let* ((id (col deck "id"))
             (title (col deck "title"))
             (design-id (col deck "design"))
             (doc (deck-doc deck))
             (linked (list-deck-assets db id))
             (rows (let loop ((shas (referenced-assets doc)) (acc '()))
                     (if (null? shas)
                         (reverse acc)
                         (let ((row (let find ((ls linked))
                                      (cond ((null? ls) #f)
                                            ((equal? (col (car ls) "sha256") (car shas)) (car ls))
                                            (else (find (cdr ls)))))))
                           (loop (cdr shas)
                                 (if (and row (file-exists? (asset-file data-dir (car shas))))
                                     (cons row acc)
                                     acc))))))
             (asset-path (lambda (row)
                           (string-append "assets/" (col row "sha256") "." (mime-extension (col row "mime")))))
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
                                 (fail "Eine Datei im Archiv hat einen Typ, den Folien nicht annimmt."))))
                           files))
                        id))))))
            (lambda () (close-input-zip z))))))))
