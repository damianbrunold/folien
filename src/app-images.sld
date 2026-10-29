;; (app images) — what the server does with uploaded PNG and JPEG images,
;; with (scm image): checks that they decode, measures them as they are
;; shown (EXIF orientation applied), and makes upright, downscaled copies
;; for thumbnails and exports.
;;
;; Copies are cached under data-dir/variants/<first 2 hex>/<sha>-<px>.<ext>;
;; like assets they never change, so the cache needs no invalidation
;; (maintenance may delete it at any time).

(define-library (app images)
  (import (scheme base)
          (scheme file)
          (scm fs)
          (scm crypto)
          (scm image))
  (export raster-mime?
          check-image
          image-display-size
          variant-widths
          image-variant
          export-image)
  (begin

    ;; Images above this are refused: decoding them needs too much memory.
    (define max-pixels 50000000)

    (define (raster-mime? mime)
      (and (member mime '("image/png" "image/jpeg")) #t))

    (define (read-file path)
      (let* ((p (open-binary-input-file path))
             (bv (read-bytevector (file-size path) p)))
        (close-port p)
        (if (eof-object? bv) (bytevector) bv)))

    (define (write-file path bv)
      (let ((p (open-binary-output-file path)))
        (write-bytevector bv p)
        (close-port p)))

    (define (oriented-size info)
      (let ((w (cdr (assq 'width info)))
            (h (cdr (assq 'height info)))
            (o (cdr (assq 'orientation info))))
        (if (>= o 5) (cons h w) (cons w h))))

    (define (check-image bytes)
      "Syntax: (check-image bytevector)
Library: (app images)
Description: For a PNG or JPEG: (width . height) as shown (EXIF
  orientation applied) if it decodes, 'too-large above 50 megapixels,
  'invalid if it does not decode."
      (let ((info (image-info bytes)))
        (cond
          ((not info) 'invalid)
          ((> (* (cdr (assq 'width info)) (cdr (assq 'height info))) max-pixels) 'too-large)
          ((guard (e (#t #f)) (image-decode bytes (cons 'max-pixels max-pixels) '(orient . #f)))
           (oriented-size info))
          (else 'invalid))))

    (define (image-display-size path)
      "Syntax: (image-display-size path)
Library: (app images)
Description: (width . height) of the PNG or JPEG file at path as shown,
  from its headers only, or #f."
      (guard (e (#t #f))
        (let* ((p (open-binary-input-file path))
               (head (read-bytevector (min (file-size path) 262144) p)))
          (close-port p)
          (let ((info (and (bytevector? head) (image-info head))))
            (and info (oriented-size info))))))

    ;; --- copies -----------------------------------------------------------

    ;; The widths thumbnails may ask for (?w=), so the cache stays small.
    (define variant-widths '(320 640 1280))

    (define (variant-path data-dir sha px ext)
      (string-append data-dir "/variants/" (substring sha 0 2) "/" sha "-"
                     (number->string px) "." ext))

    (define (ensure-dir path)
      (unless (directory-exists? path)
        (guard (e (#t (unless (directory-exists? path) (raise e))))
          (make-directory path))))

    ;; The image upright and fitted into px x px; a JPEG stays JPEG, a PNG
    ;; (which may be transparent) PNG. Returns (bytes . mime).
    (define (scaled bytes mime px)
      (let* ((img (image-fit (image-decode bytes (cons 'max-pixels max-pixels)) px px)))
        (if (equal? mime "image/jpeg")
            (cons (image->jpeg img 85) "image/jpeg")
            (cons (image->png img) "image/png"))))

    (define (image-variant data-dir sha src mime px)
      "Syntax: (image-variant data-dir sha src mime px)
Library: (app images)
Description: The path and content type (path . mime) of the asset sha
  (stored at src, a PNG or JPEG of type mime) upright and at most px
  pixels wide and high, made once and cached; #f if it cannot be made."
      (let ((ext (if (equal? mime "image/jpeg") "jpg" "png")))
        (let ((path (variant-path data-dir sha px ext)))
          (cond
            ((file-exists? path) (cons path mime))
            ((not (file-exists? src)) #f)
            (else
             (guard (e (#t #f))
               (let ((out (scaled (read-file src) mime px)))
                 (ensure-dir data-dir)
                 (ensure-dir (string-append data-dir "/variants"))
                 (ensure-dir (string-append data-dir "/variants/" (substring sha 0 2)))
                 ;; under a temporary name, then renamed: never half-written
                 (let ((tmp (string-append path ".tmp-" (random-string "abcdefghijklmnop" 8))))
                   (write-file tmp (car out))
                   (move-file tmp path))
                 (cons path mime))))))))

    ;; Pixels per slide unit an export embeds (a 1920-unit slide: 3840 px).
    (define export-density 2)

    (define (export-image bytes mime box-w box-h cover?)
      "Syntax: (export-image bytevector mime box-w box-h cover?)
Library: (app images)
Description: A PNG or JPEG as an export should embed it in a box of
  box-w x box-h slide units (filled when cover?, else contained): upright
  (EXIF orientation applied) and with no more than two pixels per slide
  unit. Returns (bytes . mime): the original when it is upright and not
  more than a quarter larger than that, else a new image of the same
  type; the original too when it does not decode."
      (let ((info (image-info bytes)))
        (if (not info)
            (cons bytes mime)
            (let* ((wh (oriented-size info))
                   (iw (car wh)) (ih (cdr wh))
                   (s ((if cover? max min) (/ box-w iw) (/ box-h ih)))
                   (need (* export-density s))          ; wanted size / actual size
                   (upright? (= 1 (cdr (assq 'orientation info)))))
              (if (and upright? (>= need 0.8))
                  (cons bytes mime)
                  (guard (e (#t (cons bytes mime)))
                    (scaled bytes mime
                            (max 1 (exact (ceiling (* (max iw ih) (min 1 need))))))))))))))
