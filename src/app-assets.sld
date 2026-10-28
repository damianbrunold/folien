;; (app assets) — uploaded images and videos.
;;
;; A file is stored once under data-dir/assets/<first 2 hex>/<sha256>,
;; named by the SHA-256 of its content, and linked to the decks that use
;; it (presentation_assets). Its type comes from its first bytes, never
;; from the client: PNG, JPEG, GIF, WebP and SVG images, MP4 and WebM
;; videos. Large uploads arrive spooled to a temporary file by the HTTP
;; server and are moved into place without being read into memory.

(define-library (app assets)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scm fs)
          (scm crypto)
          (scm net http request)
          (app db)
          (app users))           ; col
  (export store-upload!
          store-asset-file!
          file-sha
          mime-extension
          deck-asset
          list-deck-assets
          asset-file
          sniff-mime
          valid-sha?
          ensure-asset-dir)
  (begin

    (define (valid-sha? s)
      (and (string? s)
           (= (string-length s) 64)
           (let loop ((i 0))
             (or (= i 64)
                 (and (memv (string-ref s i) (string->list "0123456789abcdef"))
                      (loop (+ i 1)))))))

    (define (assets-root data-dir) (string-append data-dir "/assets"))

    (define (asset-file data-dir sha)
      "Syntax: (asset-file data-dir sha)
Library: (app assets)
Description: The path of the stored file with content hash sha."
      (string-append (assets-root data-dir) "/" (substring sha 0 2) "/" sha))

    (define (ensure-dir path)
      (unless (directory-exists? path)
        ;; Another upload may create it at the same time.
        (guard (e (#t (unless (directory-exists? path) (raise e))))
          (make-directory path))))

    (define (ensure-asset-dir data-dir)
      "Syntax: (ensure-asset-dir data-dir)
Library: (app assets)
Description: Creates data-dir and data-dir/assets if needed."
      (ensure-dir data-dir)
      (ensure-dir (assets-root data-dir)))

    ;; --- content types ------------------------------------------------

    (define (bytes-at? bv offset expected)
      (and (<= (+ offset (length expected)) (bytevector-length bv))
           (let loop ((i 0) (xs expected))
             (or (null? xs)
                 (and (= (bytevector-u8-ref bv (+ offset i)) (car xs))
                      (loop (+ i 1) (cdr xs)))))))

    (define (ascii s) (map char->integer (string->list s)))

    ;; An SVG document: text that starts with "<" (after a byte order
    ;; mark and white space) and has an <svg element early on.
    (define (svg? bv)
      (let* ((n (min 1024 (bytevector-length bv)))
             (start (if (bytes-at? bv 0 '(#xEF #xBB #xBF)) 3 0))
             (first (let loop ((i start))
                      (cond ((>= i n) #f)
                            ((memv (bytevector-u8-ref bv i) '(32 9 10 13)) (loop (+ i 1)))
                            (else i)))))
        (and first
             (= (bytevector-u8-ref bv first) (char->integer #\<))
             (let ((text (string-map char-downcase
                                     (list->string
                                      (map (lambda (b) (if (< b 128) (integer->char b) #\?))
                                           (bytes->list bv first n))))))
               (let loop ((i 0))
                 (and (<= (+ i 4) (string-length text))
                      (or (string=? (substring text i (+ i 4)) "<svg")
                          (loop (+ i 1)))))))))

    (define (bytes->list bv from to)
      (let loop ((i (- to 1)) (acc '()))
        (if (< i from) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))

    (define (sniff-mime head)
      "Syntax: (sniff-mime bytevector)
Library: (app assets)
Description: The content type of a file from its first bytes, or #f if
  it is not an image or video type folien accepts."
      (cond
        ((bytes-at? head 0 '(#x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A)) "image/png")
        ((bytes-at? head 0 '(#xFF #xD8 #xFF)) "image/jpeg")
        ((or (bytes-at? head 0 (ascii "GIF87a")) (bytes-at? head 0 (ascii "GIF89a"))) "image/gif")
        ((and (bytes-at? head 0 (ascii "RIFF")) (bytes-at? head 8 (ascii "WEBP"))) "image/webp")
        ((bytes-at? head 4 (ascii "ftyp")) "video/mp4")
        ((bytes-at? head 0 '(#x1A #x45 #xDF #xA3)) "video/webm")
        ((svg? head) "image/svg+xml")
        (else #f)))

    (define (file-head path)
      (let* ((p (open-binary-input-file path))
             (bv (read-bytevector 1024 p)))
        (close-port p)
        (if (eof-object? bv) (bytevector) bv)))

    (define (head-of bv)
      (bytevector-copy bv 0 (min 1024 (bytevector-length bv))))

    ;; --- storing --------------------------------------------------------

    (define (write-bytes path bv)
      (let ((p (open-binary-output-file path)))
        (write-bytevector bv p)
        (close-port p)))

    (define (->int-or-null x)
      (let ((n (and (string? x) (string->number x))))
        (if (and n (exact-integer? n) (<= 1 n 100000)) n 'null)))

    (define (file-sha path)
      "Syntax: (file-sha path)
Library: (app assets)
Description: The SHA-256 of a file's content, as hex."
      (bytevector->hex (sha256-file path)))

    (define (mime-extension mime)
      "Syntax: (mime-extension mime)
Library: (app assets)
Description: The file extension for an accepted content type."
      (cond ((equal? mime "image/png") "png")
            ((equal? mime "image/jpeg") "jpg")
            ((equal? mime "image/gif") "gif")
            ((equal? mime "image/webp") "webp")
            ((equal? mime "image/svg+xml") "svg")
            ((equal? mime "video/mp4") "mp4")
            ((equal? mime "video/webm") "webm")
            (else "bin")))

    ;; Puts content into the store under sha (unless it is there), via
    ;; (write! tmp-path), then links it to the deck. Returns its row.
    (define (place-and-link! db data-dir deck-id sha mime size name width height write!)
      (let ((dir (string-append (assets-root data-dir) "/" (substring sha 0 2)))
            (target (asset-file data-dir sha)))
        (ensure-asset-dir data-dir)
        (ensure-dir dir)
        (unless (file-exists? target)
          ;; Into place under a temporary name, then renamed, so a
          ;; half-written file is never served.
          (let ((tmp (string-append target ".tmp-" (random-string "abcdefghijklmnop" 8))))
            (write! tmp)
            (move-file tmp target)))
        (with-db-transaction db
          (lambda (tx)
            (db-exec tx
              (string-append "INSERT INTO assets (sha256, mime, size, width, height) "
                             "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (sha256) DO NOTHING")
              sha mime size (->int-or-null width) (->int-or-null height))
            (db-exec tx
              (string-append "INSERT INTO presentation_assets (presentation_id, sha256, name) "
                             "VALUES ($1, $2, $3) ON CONFLICT DO NOTHING")
              deck-id sha name)))
        (deck-asset-row db deck-id sha)))

    (define (store-asset-file! db data-dir deck-id path name width height)
      "Syntax: (store-asset-file! db data-dir deck-id path name width height)
Library: (app assets)
Description: Stores the file at path (which it moves away) as an asset
  of the deck and returns its row, or 'empty or 'unsupported as
  store-upload! does (the file then stays)."
      (let* ((size (file-size path))
             (mime (and (> size 0) (sniff-mime (file-head path)))))
        (cond
          ((= size 0) 'empty)
          ((not mime) 'unsupported)
          (else
           (place-and-link! db data-dir deck-id (file-sha path) mime size name width height
                            (lambda (tmp) (move-file path tmp)))))))

    (define (store-upload! db data-dir deck-id req name width height)
      "Syntax: (store-upload! db data-dir deck-id req name width height)
Library: (app assets)
Description: Stores the body of req as an asset of the deck (whose owner
  the caller has checked) and returns its row: sha256, mime, size, width,
  height, name. width and height are the client's measurements (strings
  or #f). Returns 'empty for an empty body and 'unsupported for a type
  that is not accepted."
      (let ((spooled (http-request-body-file req)))
        (if spooled
            (store-asset-file! db data-dir deck-id spooled name width height)
            (let* ((bytes (or (http-request-body-bytes req) (bytevector)))
                   (size (bytevector-length bytes))
                   (mime (and (> size 0) (sniff-mime (head-of bytes)))))
              (cond
                ((= size 0) 'empty)
                ((not mime) 'unsupported)
                (else
                 (place-and-link! db data-dir deck-id (bytevector->hex (sha256-hash bytes))
                                  mime size name width height
                                  (lambda (tmp) (write-bytes tmp bytes)))))))))

    (define asset-columns
      "a.sha256, a.mime, a.size, a.width, a.height, pa.name, pa.added_at")

    (define (deck-asset-row db deck-id sha)
      (db-row db
        (string-append "SELECT " asset-columns " FROM presentation_assets pa "
                       "JOIN assets a ON a.sha256 = pa.sha256 "
                       "WHERE pa.presentation_id = $1 AND pa.sha256 = $2")
        deck-id sha))

    (define (deck-asset db owner-id deck-id sha)
      "Syntax: (deck-asset db user-id deck-id sha)
Library: (app assets)
Description: The asset row if sha is an asset of a deck the user may
  see (owner or shared), else #f."
      (and (valid-sha? sha)
           (db-row db
             (string-append "SELECT " asset-columns " FROM presentation_assets pa "
                            "JOIN assets a ON a.sha256 = pa.sha256 "
                            "JOIN presentations p ON p.id = pa.presentation_id "
                            "WHERE pa.presentation_id = $1 AND pa.sha256 = $2 "
                            "AND (p.owner_id = $3 OR (p.status <> 'trashed' AND EXISTS "
                            "(SELECT 1 FROM presentation_shares s "
                            "WHERE s.presentation_id = $1 AND s.user_id = $3)))")
             deck-id sha (let ((x owner-id)) (if (string? x) (string->number x) x)))))

    (define (list-deck-assets db deck-id)
      "Syntax: (list-deck-assets db deck-id)
Library: (app assets)
Description: The deck's assets, newest first."
      (db-rows db
        (string-append "SELECT " asset-columns " FROM presentation_assets pa "
                       "JOIN assets a ON a.sha256 = pa.sha256 "
                       "WHERE pa.presentation_id = $1 ORDER BY pa.added_at DESC")
        deck-id))))
