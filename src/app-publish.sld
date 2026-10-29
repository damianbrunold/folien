;; (app publish) — publications: frozen copies of a deck that anyone with
;; the address may see, without signing in.
;;
;; The owner publishes the deck as it is now; the copy (title, design,
;; document without notes and hidden slides, an automatic date fixed to
;; the day it was published) stays as it is, whatever happens to the
;; deck later, until the owner withdraws it. A deck can have many: one
;; for each time a talk is given, say. Their addresses:
;;
;;   /p/<name>            the newest publication of the deck
;;   /p/<name>/<stamp>    one of them, for good: "2026-10-29", a second
;;                        one that day "2026-10-29-2"
;;
;; name is the deck's public token (random, made at the first
;; publication, never changes) or the readable slug the owner chose
;; (lower-case letters, digits and hyphens); both lead to the same
;; publications. Assets are content-addressed, so a publication only
;; links the files it shows (publication_assets) and shares them with its
;; deck. Publications of a deck in the trash are not shown; deleting the
;; deck deletes them.

(define-library (app publish)
  (import (scheme base)
          (scheme char)
          (scm crypto)
          (scm json simple)
          (only (srfi 19) current-date date->string)
          (app db)
          (app users)             ; col
          (app model)
          (app decks)
          (app bundle))           ; referenced-assets
  (export valid-slug?
          valid-label?
          publication-doc
          deck-public-names
          list-publications
          publish-deck!
          withdraw-publication!
          set-public-slug!
          find-publication
          public-publications
          publication-asset-mime)
  (begin

    (define token-chars "abcdefghijklmnopqrstuvwxyz0123456789")
    (define token-length 16)

    (define (owner? db owner-id deck-id)
      (and (db-scalar db "SELECT 1 FROM presentations WHERE id = $1 AND owner_id = $2"
                      deck-id (->int owner-id))
           #t))

    ;; --- names ----------------------------------------------------------

    (define (valid-slug? s)
      "Syntax: (valid-slug? s)
Library: (app publish)
Description: Whether s can be a deck's public slug: 3 to 60 lower-case
  letters (a-z), digits and single hyphens, neither first nor last."
      (and (string? s)
           (<= 3 (string-length s) 60)
           (let loop ((cs (string->list s)) (prev #\-))
             (cond ((null? cs) (not (char=? prev #\-)))
                   ((char=? (car cs) #\-) (and (not (char=? prev #\-)) (loop (cdr cs) #\-)))
                   ((or (char<=? #\a (car cs) #\z) (char<=? #\0 (car cs) #\9)) (loop (cdr cs) (car cs)))
                   (else #f)))))

    (define (valid-label? s)
      (and (string? s) (<= (string-length s) 120)))

    ;; A name for a deck's publications is taken if it is any deck's token
    ;; or slug.
    (define (name-taken? db name)
      (and (db-scalar db "SELECT 1 FROM presentations WHERE public_token = $1 OR public_slug = $1" name)
           #t))

    (define (ensure-token! db deck-id)
      (or (db-scalar db "SELECT public_token FROM presentations WHERE id = $1" deck-id)
          (let loop ()
            (let ((t (random-string token-chars token-length)))
              (if (name-taken? db t)
                  (loop)
                  (begin
                    (db-exec db "UPDATE presentations SET public_token = $2 WHERE id = $1 AND public_token IS NULL"
                             deck-id t)
                    (db-scalar db "SELECT public_token FROM presentations WHERE id = $1" deck-id)))))))

    (define (deck-public-names db owner-id deck-id)
      "Syntax: (deck-public-names db owner-id deck-id)
Library: (app publish)
Description: (token . slug) of the owner's deck, each a string or #f
  (no publication yet, no slug); #f if the deck is not the owner's."
      (let ((row (db-row db "SELECT public_token, public_slug FROM presentations WHERE id = $1 AND owner_id = $2"
                         deck-id (->int owner-id))))
        (and row
             (cons (col row "public_token") (col row "public_slug")))))

    (define (set-public-slug! db owner-id deck-id slug)
      "Syntax: (set-public-slug! db owner-id deck-id slug)
Library: (app publish)
Description: Sets the readable name of the owner's deck's publications
  (\"\" removes it). 'ok, 'invalid, 'taken, or #f if the deck is not the
  owner's. The token keeps working either way."
      (cond
        ((not (owner? db owner-id deck-id)) #f)
        ((string=? slug "")
         (db-exec db "UPDATE presentations SET public_slug = NULL WHERE id = $1" deck-id)
         'ok)
        ((not (valid-slug? slug)) 'invalid)
        ((equal? slug (db-scalar db "SELECT public_slug FROM presentations WHERE id = $1" deck-id)) 'ok)
        ((name-taken? db slug) 'taken)
        (else
         (guard (e (#t 'taken))       ; another deck took it just now
           (db-exec db "UPDATE presentations SET public_slug = $2 WHERE id = $1" deck-id slug)
           'ok))))

    ;; --- publishing -------------------------------------------------------

    (define (publication-doc doc date-text)
      "Syntax: (publication-doc doc date-text)
Library: (app publish)
Description: The document as published: shareable-doc (no notes, no
  hidden slides), and an automatic footer date fixed to date-text (the
  day of publishing, \"29.10.2026\"), so the copy does not change."
      (map (lambda (p)
             (if (and (equal? (car p) "footer") (list? (cdr p))
                      (equal? (jref (cdr p) "date") "auto"))
                 (cons "footer"
                       (append (let drop ((ps (cdr p)))
                                 (cond ((null? ps) '())
                                       ((member (caar ps) '("date" "dateText")) (drop (cdr ps)))
                                       (else (cons (car ps) (drop (cdr ps))))))
                               `(("date" . "fixed") ("dateText" . ,date-text))))
                 p))
           (shareable-doc doc)))

    ;; The first of date, date-2, date-3 ... the deck has not used.
    (define (free-stamp db deck-id date)
      (let loop ((n 1))
        (let ((stamp (if (= n 1) date (string-append date "-" (number->string n)))))
          (if (db-scalar db "SELECT 1 FROM publications WHERE presentation_id = $1 AND stamp = $2"
                         deck-id stamp)
              (loop (+ n 1))
              stamp))))

    (define (publish-deck! db owner-id deck-id label)
      "Syntax: (publish-deck! db owner-id deck-id label)
Library: (app publish)
Description: Publishes the owner's deck as it is now, with label (\"\" or
  a few words: where the talk was given). The new publication's stamp,
  or #f if the deck is not the owner's or is in the trash."
      (let ((deck (and (owner? db owner-id deck-id) (load-deck db owner-id deck-id))))
        (and deck
             (not (equal? (col deck "status") "trashed"))
             (with-db-transaction db
               (lambda (tx)
                 (ensure-token! tx deck-id)
                 (let* ((now (current-date))
                        (doc (publication-doc (deck-doc deck) (date->string now "~d.~m.~Y")))
                        (stamp (free-stamp tx deck-id (date->string now "~Y-~m-~d")))
                        (id (db-scalar tx
                              (string-append "INSERT INTO publications (presentation_id, stamp, label, title, "
                                             "design, doc, revision, created_by) "
                                             "VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8) RETURNING id")
                              deck-id stamp label (col deck "title") (col deck "design")
                              (json->string doc) (->int (col deck "revision")) (->int owner-id))))
                   (for-each (lambda (sha)
                               (db-exec tx
                                 (string-append "INSERT INTO publication_assets (publication_id, sha256) "
                                                "SELECT $1, sha256 FROM assets WHERE sha256 = $2 "
                                                "ON CONFLICT DO NOTHING")
                                 (->int id) sha))
                             (referenced-assets doc))
                   stamp))))))

    (define (withdraw-publication! db owner-id deck-id publication-id)
      "Syntax: (withdraw-publication! db owner-id deck-id publication-id)
Library: (app publish)
Description: Deletes a publication of the owner's deck: its address
  stops working. #t, or #f if there is no such one."
      (and (owner? db owner-id deck-id)
           (db-scalar db "DELETE FROM publications WHERE id = $1 AND presentation_id = $2 RETURNING 1"
                      (->int publication-id) deck-id)
           #t))

    (define (list-publications db deck-id)
      "Syntax: (list-publications db deck-id)
Library: (app publish)
Description: The deck's publications, newest first: id, stamp, label,
  title, revision, created_at, slides (their number)."
      (db-rows db
        (string-append "SELECT id, stamp, label, title, revision, created_at, "
                       "jsonb_array_length(doc->'slides') AS slides "
                       "FROM publications WHERE presentation_id = $1 ORDER BY created_at DESC, id DESC")
        deck-id))

    ;; --- the public side ----------------------------------------------------

    (define public-from
      (string-append "FROM publications b JOIN presentations p ON p.id = b.presentation_id "
                     "WHERE (p.public_token = $1 OR p.public_slug = $1) AND p.status <> 'trashed' "))

    (define (find-publication db name stamp)
      "Syntax: (find-publication db name stamp)
Library: (app publish)
Description: The publication with stamp (#f: the newest) of the deck
  whose token or slug is name, if it is to be shown: id, stamp, label,
  title, design, doc (JSON text), created_at. Else #f."
      (and (string? name)
           (<= 1 (string-length name) 60)
           (if stamp
               (db-row db (string-append "SELECT b.id, b.stamp, b.label, b.title, b.design, b.doc::text AS doc, "
                                         "b.created_at " public-from "AND b.stamp = $2")
                       name stamp)
               (db-row db (string-append "SELECT b.id, b.stamp, b.label, b.title, b.design, b.doc::text AS doc, "
                                         "b.created_at " public-from
                                         "ORDER BY b.created_at DESC, b.id DESC LIMIT 1")
                       name))))

    (define (public-publications db name)
      "Syntax: (public-publications db name)
Library: (app publish)
Description: All shown publications of the deck named name, newest
  first: stamp, label, title, created_at."
      (db-rows db (string-append "SELECT b.stamp, b.label, b.title, b.created_at " public-from
                                 "ORDER BY b.created_at DESC, b.id DESC")
               name))

    (define (publication-asset-mime db publication-id sha)
      "Syntax: (publication-asset-mime db publication-id sha)
Library: (app publish)
Description: The type of an asset the publication shows, or #f if it
  does not show it."
      (db-scalar db
        (string-append "SELECT a.mime FROM publication_assets ba JOIN assets a ON a.sha256 = ba.sha256 "
                       "WHERE ba.publication_id = $1 AND ba.sha256 = $2")
        (->int publication-id) sha))))
