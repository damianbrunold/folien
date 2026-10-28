;; (app decks) — presentation queries. A deck is a row of `presentations`:
;; id (uuid text), owner_id, title, design, status (active / archived /
;; trashed), doc (jsonb), revision.
;;
;; Every function takes the acting user's id and only touches decks that
;; user may: the owner's own, or those shared with them (presentation_shares:
;; view or edit), so a handler cannot reach someone else's deck by guessing
;; an id. Changing a deck's content needs the owner or an edit share;
;; archiving, trashing, deleting and sharing need the owner. Archived and
;; trashed decks are read-only; a shared deck in the trash is hidden from
;; those it is shared with.

(define-library (app decks)
  (import (scheme base)
          (scheme char)
          (scm system)
          (scm json simple)
          (app db)
          (app users)             ; col
          (app model))
  (export list-decks
          list-shared-decks
          load-deck
          deck-status
          deck-access
          can-edit?
          list-shares
          share-deck!
          unshare-deck!
          list-templates
          set-template!
          set-tags!
          parse-tags
          deck-tags
          list-snapshots
          create-snapshot!
          restore-snapshot!
          delete-snapshot!
          deck-doc
          create-deck!
          create-deck-with-doc!
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
      "id, title, design, status, revision, created_at, updated_at, status_at, tags::text AS tags, is_template")

    ;; --- search ---------------------------------------------------------

    ;; q for ILIKE, with its wildcards taken literally.
    (define (like-pattern q)
      (string-append
       "%"
       (let loop ((cs (string->list q)) (acc '()))
         (if (null? cs)
             (list->string (reverse acc))
             (loop (cdr cs)
                   (if (memv (car cs) '(#\\ #\% #\_))
                       (cons (car cs) (cons #\\ acc))
                       (cons (car cs) acc)))))
       "%"))

    ;; SQL conditions for a search text ($a) and a tag ($b), each '' for
    ;; none; p is the presentations table.
    (define (filter-sql a b)
      (string-append
       " AND ($" a " = '%%' OR p.title ILIKE $" a " OR EXISTS "
       "(SELECT 1 FROM jsonb_array_elements_text(p.tags) t WHERE t ILIKE $" a "))"
       " AND ($" b " = '' OR p.tags ? $" b ")"))

    (define (list-decks db owner-id status . filters)
      "Syntax: (list-decks db owner-id status [query [tag]])
Library: (app decks)
Description: The owner's decks with status (\"active\", \"archived\",
  \"trashed\"), most recently changed first, without their documents;
  only those whose title or a tag contains query and that have tag, if
  given (\"\" for none)."
      (let ((q (if (pair? filters) (car filters) ""))
            (tag (if (and (pair? filters) (pair? (cdr filters))) (cadr filters) "")))
        (db-rows db
          (string-append "SELECT " summary-columns " FROM presentations p "
                         "WHERE owner_id = $1 AND status = $2" (filter-sql "3" "4")
                         " ORDER BY updated_at DESC")
          (->int owner-id) status (like-pattern q) tag)))

    ;; The decks a user may see, with their role: owner, edit or view.
    (define access-from
      (string-append
       "FROM presentations p JOIN users u ON u.id = p.owner_id "
       "LEFT JOIN presentation_shares s ON s.presentation_id = p.id AND s.user_id = $2 "))

    (define access-where
      "(p.owner_id = $2 OR (s.user_id IS NOT NULL AND p.status <> 'trashed'))")

    (define access-role
      "CASE WHEN p.owner_id = $2 THEN 'owner' ELSE s.role END AS role")

    (define (load-deck db user-id id)
      "Syntax: (load-deck db user-id id)
Library: (app decks)
Description: The deck row with id, including doc (as JSON text), role
  (\"owner\", \"edit\" or \"view\") and owner_name, if the user may see
  it; else #f."
      (db-row db
        (string-append "SELECT p.id, p.title, p.design, p.status, p.revision, p.created_at, "
                       "p.updated_at, p.status_at, p.doc::text AS doc, u.username AS owner_name, "
                       "p.tags::text AS tags, p.is_template, "
                       access-role " " access-from
                       "WHERE p.id = $1 AND " access-where)
        id (->int user-id)))

    (define (deck-access db user-id id)
      "Syntax: (deck-access db user-id id)
Library: (app decks)
Description: (status . role) of the deck with id for the user, or #f if
  the user may not see it."
      (let ((row (db-row db
                   (string-append "SELECT p.status, " access-role " " access-from
                                  "WHERE p.id = $1 AND " access-where)
                   id (->int user-id))))
        (and row (cons (col row "status") (col row "role")))))

    (define (deck-status db user-id id)
      "Syntax: (deck-status db user-id id)
Library: (app decks)
Description: The status of the deck with id if the user may see it
  (\"active\", \"archived\", \"trashed\"), else #f."
      (let ((a (deck-access db user-id id)))
        (and a (car a))))

    (define (can-edit? role)
      "Syntax: (can-edit? role)
Library: (app decks)
Description: True for the owner and edit shares."
      (and (member role '("owner" "edit")) #t))

    (define (list-shared-decks db user-id . filters)
      "Syntax: (list-shared-decks db user-id [query [tag]])
Library: (app decks)
Description: The active and archived decks shared with the user, most
  recently changed first, with role and owner_name; filtered as by
  list-decks."
      (let ((q (if (pair? filters) (car filters) ""))
            (tag (if (and (pair? filters) (pair? (cdr filters))) (cadr filters) "")))
        (db-rows db
          (string-append "SELECT p.id, p.title, p.design, p.status, p.revision, p.updated_at, "
                         "p.status_at, p.tags::text AS tags, p.is_template, s.role, u.username AS owner_name "
                         "FROM presentation_shares s JOIN presentations p ON p.id = s.presentation_id "
                         "JOIN users u ON u.id = p.owner_id "
                         "WHERE s.user_id = $1 AND p.status <> 'trashed'" (filter-sql "2" "3")
                         " ORDER BY p.updated_at DESC")
          (->int user-id) (like-pattern q) tag)))

    ;; --- templates and tags -------------------------------------------------

    (define (list-templates db user-id)
      "Syntax: (list-templates db user-id)
Library: (app decks)
Description: The active templates the user may start from (their own
  and those shared with them): id, title, design, owner_name."
      (db-rows db
        (string-append "SELECT p.id, p.title, p.design, u.username AS owner_name "
                       "FROM presentations p JOIN users u ON u.id = p.owner_id "
                       "LEFT JOIN presentation_shares s ON s.presentation_id = p.id AND s.user_id = $1 "
                       "WHERE p.is_template AND p.status = 'active' "
                       "AND (p.owner_id = $1 OR s.user_id IS NOT NULL) ORDER BY lower(p.title)")
        (->int user-id)))

    (define (set-template! db owner-id id on?)
      (db-exec db "UPDATE presentations SET is_template = $1 WHERE id = $2 AND owner_id = $3"
               on? id (->int owner-id)))

    (define (parse-tags text)
      "Syntax: (parse-tags text)
Library: (app decks)
Description: Tags from comma-separated text: trimmed, without empty and
  duplicate ones, at most 20 of at most 40 characters."
      (let loop ((parts (split-commas text)) (acc '()))
        (cond ((or (null? parts) (= (length acc) 20)) (reverse acc))
              (else
               (let ((t (trim (car parts))))
                 (loop (cdr parts)
                       (if (or (string=? t "") (> (string-length t) 40) (member t acc))
                           acc
                           (cons t acc))))))))

    (define (split-commas s)
      (let loop ((i 0) (start 0) (acc '()))
        (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
              ((char=? (string-ref s i) #\,) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
              (else (loop (+ i 1) start acc)))))

    (define (trim s)
      (let* ((n (string-length s))
             (a (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) i)))
             (b (let loop ((j n)) (if (and (> j a) (char-whitespace? (string-ref s (- j 1)))) (loop (- j 1)) j))))
        (substring s a b)))

    (define (set-tags! db user-id id tags)
      "Syntax: (set-tags! db user-id id tags)
Library: (app decks)
Description: Sets the tags (a list of strings) of a deck the user may
  change."
      (db-exec db
        (string-append "UPDATE presentations SET tags = $1::jsonb WHERE id = $2 "
                       "AND (owner_id = $3 OR EXISTS (SELECT 1 FROM presentation_shares "
                       "WHERE presentation_id = $2 AND user_id = $3 AND role = 'edit'))")
        (json->string (list->vector tags)) id (->int user-id)))

    (define (deck-tags row)
      "Syntax: (deck-tags row)
Library: (app decks)
Description: The tags of a deck row (a list of strings)."
      (let ((p (assoc "tags" row)))
        (if (and p (string? (cdr p)))
            (vector->list (json-parse (cdr p)))
            '())))

    (define (list-shares db deck-id)
      "Syntax: (list-shares db deck-id)
Library: (app decks)
Description: Who the deck is shared with: user_id, username, role."
      (db-rows db
        (string-append "SELECT s.user_id, u.username, s.role FROM presentation_shares s "
                       "JOIN users u ON u.id = s.user_id WHERE s.presentation_id = $1 "
                       "ORDER BY u.username")
        deck-id))

    (define (share-deck! db owner-id deck-id user-id role)
      "Syntax: (share-deck! db owner-id deck-id user-id role)
Library: (app decks)
Description: Shares the owner's deck with user-id as role (\"view\" or
  \"edit\"), or changes the role. Returns #f if owner-id does not own the
  deck or would share with themselves."
      (and (not (equal? (->int owner-id) (->int user-id)))
           (db-scalar db "SELECT 1 FROM presentations WHERE id = $1 AND owner_id = $2"
                      deck-id (->int owner-id))
           (begin
             (db-exec db
               (string-append "INSERT INTO presentation_shares (presentation_id, user_id, role) "
                              "VALUES ($1, $2, $3) ON CONFLICT (presentation_id, user_id) "
                              "DO UPDATE SET role = EXCLUDED.role")
               deck-id (->int user-id) role)
             #t)))

    (define (unshare-deck! db owner-id deck-id user-id)
      (db-exec db
        (string-append "DELETE FROM presentation_shares WHERE presentation_id = $1 AND user_id = $2 "
                       "AND EXISTS (SELECT 1 FROM presentations WHERE id = $1 AND owner_id = $3)")
        deck-id (->int user-id) (->int owner-id)))

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

    (define (create-deck-with-doc! db owner-id title design-id doc)
      "Syntax: (create-deck-with-doc! db owner-id title design-id doc)
Library: (app decks)
Description: Creates an active deck with doc (already validated) and
  returns its id."
      (let ((id (uuidgen)))
        (db-exec db
          (string-append "INSERT INTO presentations (id, owner_id, title, design, doc) "
                         "VALUES ($1, $2, $3, $4, $5::jsonb)")
          id (->int owner-id) title design-id (json->string doc))
        id))

    (define (save-doc! db owner-id id base-revision doc design-id . title)
      "Syntax: (save-doc! db owner-id id base-revision doc design-id [title])
Library: (app decks)
Description: Stores doc (already validated), design and, if given, title
  (already validated) for an active deck the user owns or may edit, if
  its revision is still base-revision. Returns the new revision, or #f when the deck
  changed in the meantime, is not active, or does not exist."
      (db-scalar db
        (string-append "UPDATE presentations "
                       "SET doc = $1::jsonb, design = $2, revision = revision + 1, "
                       "title = COALESCE($6, title), updated_at = now() "
                       "WHERE id = $3 AND revision = $5 AND status = 'active' "
                       "AND (owner_id = $4 OR EXISTS (SELECT 1 FROM presentation_shares "
                       "WHERE presentation_id = $3 AND user_id = $4 AND role = 'edit')) "
                       "RETURNING revision")
        (json->string doc) design-id id (->int owner-id) (->int base-revision)
        (if (pair? title) (car title) 'null)))

    (define (rename-deck! db user-id id title)
      (db-exec db
        (string-append "UPDATE presentations SET title = $1, updated_at = now() "
                       "WHERE id = $2 AND status = 'active' "
                       "AND (owner_id = $3 OR EXISTS (SELECT 1 FROM presentation_shares "
                       "WHERE presentation_id = $2 AND user_id = $3 AND role = 'edit'))")
        title id (->int user-id)))

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
Description: Copies a deck the user may see, with the links to its
  assets, as a new active deck of the user's named title and returns the
  new id, or #f if there is no such deck."
      (let ((new-id (uuidgen)))
        (with-db-transaction db
          (lambda (tx)
            (and (db-scalar tx
                   (string-append
                    "INSERT INTO presentations (id, owner_id, title, design, doc) "
                    "SELECT $1, $4, $2, p.design, p.doc " access-from-dup
                    "WHERE p.id = $3 AND " access-where-dup " RETURNING id")
                   new-id title id (->int owner-id))
                 ;; The copy may use the same images and videos.
                 (begin
                   (db-exec tx
                     (string-append
                      "INSERT INTO presentation_assets (presentation_id, sha256, name) "
                      "SELECT $1, sha256, name FROM presentation_assets "
                      "WHERE presentation_id = $2")
                     new-id id)
                   new-id))))))

    ;; access-from / access-where with the user as $4 (duplicate-deck!)
    (define access-from-dup
      (string-append
       "FROM presentations p "
       "LEFT JOIN presentation_shares s ON s.presentation_id = p.id AND s.user_id = $4 "))
    (define access-where-dup
      "(p.owner_id = $4 OR (s.user_id IS NOT NULL AND p.status <> 'trashed'))")

    ;; --- versions ---------------------------------------------------------

    ;; True if the user may change the deck's content (active, owner or
    ;; edit share).
    (define (editable? db user-id id)
      (let ((row (db-row db
                   (string-append "SELECT p.status, " access-role " " access-from
                                  "WHERE p.id = $1 AND " access-where)
                   id (->int user-id))))
        (and row
             (equal? (col row "status") "active")
             (member (col row "role") '("owner" "edit"))
             #t)))

    (define (list-snapshots db deck-id)
      "Syntax: (list-snapshots db deck-id)
Library: (app decks)
Description: The deck's versions, newest first: id, name, revision,
  created_at, author (username or null)."
      (db-rows db
        (string-append "SELECT v.id, v.name, v.revision, v.created_at, u.username AS author "
                       "FROM snapshots v LEFT JOIN users u ON u.id = v.created_by "
                       "WHERE v.presentation_id = $1 ORDER BY v.created_at DESC, v.id DESC")
        deck-id))

    (define (create-snapshot! db user-id deck-id name)
      "Syntax: (create-snapshot! db user-id deck-id name)
Library: (app decks)
Description: Keeps the deck's current content as a version called name;
  #f if the user may not change the deck."
      (and (editable? db user-id deck-id)
           (begin
             (db-exec db
               (string-append "INSERT INTO snapshots (presentation_id, name, title, design, doc, "
                              "revision, created_by) SELECT id, $2, title, design, doc, revision, $3 "
                              "FROM presentations WHERE id = $1")
               deck-id name (->int user-id))
             #t)))

    (define (restore-snapshot! db user-id deck-id snapshot-id auto-name)
      "Syntax: (restore-snapshot! db user-id deck-id snapshot-id auto-name)
Library: (app decks)
Description: Makes a version the deck's content again, after keeping the
  current content as a version called auto-name; the revision goes up,
  so editors open elsewhere notice. #f if not allowed or not found."
      (and (editable? db user-id deck-id)
           (with-db-transaction db
             (lambda (tx)
               (and (db-scalar tx "SELECT 1 FROM snapshots WHERE id = $1 AND presentation_id = $2"
                               (->int snapshot-id) deck-id)
                    (begin
                      (create-snapshot! tx user-id deck-id auto-name)
                      (db-exec tx
                        (string-append "UPDATE presentations p SET doc = v.doc, title = v.title, "
                                       "design = v.design, revision = p.revision + 1, updated_at = now() "
                                       "FROM snapshots v WHERE v.id = $1 AND p.id = $2")
                        (->int snapshot-id) deck-id)
                      #t))))))

    (define (delete-snapshot! db user-id deck-id snapshot-id)
      (and (editable? db user-id deck-id)
           (begin
             (db-exec db "DELETE FROM snapshots WHERE id = $1 AND presentation_id = $2"
                      (->int snapshot-id) deck-id)
             #t)))

    (define (delete-deck! db owner-id id)
      "Syntax: (delete-deck! db owner-id id)
Library: (app decks)
Description: Deletes the owner's deck for good, but only from the trash."
      (db-exec db
        "DELETE FROM presentations WHERE id = $1 AND owner_id = $2 AND status = 'trashed'"
        id (->int owner-id)))))
