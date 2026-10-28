;; (app decks) — presentation queries. A deck is a row of `presentations`:
;; id (uuid text), owner_id, title, design, status (active / archived /
;; trashed), doc (jsonb), revision.
;;
;; Every function takes the owner's id and only touches that owner's decks,
;; so a handler cannot reach someone else's deck by guessing an id. Archived
;; and trashed decks are read-only: save-doc! and rename-deck! only change
;; active ones.

(define-library (app decks)
  (import (scheme base)
          (scm system)
          (scm json simple)
          (app db)
          (app users)             ; col
          (app model))
  (export list-decks
          load-deck
          deck-doc
          create-deck!
          save-doc!
          rename-deck!
          set-deck-status!
          duplicate-deck!
          delete-deck!
          valid-title?
          ->int)
  (begin

    (define (->int x)
      (cond ((exact-integer? x) x)
            ((string? x) (string->number x))
            (else #f)))

    (define (valid-title? s)
      (and (string? s) (<= 1 (string-length s) 200)))

    (define summary-columns
      "id, title, design, status, revision, created_at, updated_at, status_at")

    (define (list-decks db owner-id status)
      "Syntax: (list-decks db owner-id status)
Library: (app decks)
Description: The owner's decks with status (\"active\", \"archived\",
  \"trashed\"), most recently changed first, without their documents."
      (db-rows db
        (string-append "SELECT " summary-columns " FROM presentations "
                       "WHERE owner_id = $1 AND status = $2 "
                       "ORDER BY updated_at DESC")
        (->int owner-id) status))

    (define (load-deck db owner-id id)
      "Syntax: (load-deck db owner-id id)
Library: (app decks)
Description: The owner's deck row with id, including doc (as JSON text),
  or #f."
      (db-row db
        (string-append "SELECT " summary-columns ", doc::text AS doc FROM presentations "
                       "WHERE id = $1 AND owner_id = $2")
        id (->int owner-id)))

    (define (deck-doc deck)
      "Syntax: (deck-doc deck)
Library: (app decks)
Description: The parsed document of a deck row from load-deck."
      (json-parse (col deck "doc")))

    (define (create-deck! db owner-id title design-id)
      "Syntax: (create-deck! db owner-id title design-id)
Library: (app decks)
Description: Creates an active deck with a title slide and returns its id."
      (let ((id (uuidgen)))
        (db-exec db
          (string-append "INSERT INTO presentations (id, owner_id, title, design, doc) "
                         "VALUES ($1, $2, $3, $4, $5::jsonb)")
          id (->int owner-id) title design-id
          (json->string (new-doc design-id title)))
        id))

    (define (save-doc! db owner-id id base-revision doc design-id . title)
      "Syntax: (save-doc! db owner-id id base-revision doc design-id [title])
Library: (app decks)
Description: Stores doc (already validated), design and, if given, title
  (already validated) for the owner's active deck if its revision is
  still base-revision. Returns the new revision, or #f when the deck
  changed in the meantime, is not active, or does not exist."
      (db-scalar db
        (string-append "UPDATE presentations "
                       "SET doc = $1::jsonb, design = $2, revision = revision + 1, "
                       "title = COALESCE($6, title), updated_at = now() "
                       "WHERE id = $3 AND owner_id = $4 AND revision = $5 "
                       "AND status = 'active' RETURNING revision")
        (json->string doc) design-id id (->int owner-id) (->int base-revision)
        (if (pair? title) (car title) 'null)))

    (define (rename-deck! db owner-id id title)
      (db-exec db
        (string-append "UPDATE presentations SET title = $1, updated_at = now() "
                       "WHERE id = $2 AND owner_id = $3 AND status = 'active'")
        title id (->int owner-id)))

    (define (set-deck-status! db owner-id id status)
      "Syntax: (set-deck-status! db owner-id id status)
Library: (app decks)
Description: Moves the owner's deck to status (\"active\", \"archived\" or
  \"trashed\")."
      (db-exec db
        (string-append "UPDATE presentations SET status = $1, "
                       "status_at = CASE WHEN $1 = 'active' THEN NULL ELSE now() END "
                       "WHERE id = $2 AND owner_id = $3")
        status id (->int owner-id)))

    (define (duplicate-deck! db owner-id id title)
      "Syntax: (duplicate-deck! db owner-id id title)
Library: (app decks)
Description: Copies the owner's deck as a new active deck named title and
  returns the new id, or #f if there is no such deck."
      (let ((new-id (uuidgen)))
        (and (db-scalar db
               (string-append
                "INSERT INTO presentations (id, owner_id, title, design, doc) "
                "SELECT $1, owner_id, $2, design, doc FROM presentations "
                "WHERE id = $3 AND owner_id = $4 RETURNING id")
               new-id title id (->int owner-id))
             new-id)))

    (define (delete-deck! db owner-id id)
      "Syntax: (delete-deck! db owner-id id)
Library: (app decks)
Description: Deletes the owner's deck for good, but only from the trash."
      (db-exec db
        "DELETE FROM presentations WHERE id = $1 AND owner_id = $2 AND status = 'trashed'"
        id (->int owner-id)))))
