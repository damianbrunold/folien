;; Tests for (app images): uploads are checked and measured as shown,
;; exports get upright, downscaled images, thumbnails are cached copies.
;; Run: scm tests/test_pure_images.scm

(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm image)
        (scm test))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app images))

(test-runner-factory scm-test-runner)
(test-begin "folien images")

;; A w x h image: the left half red, the right half blue.
(define (two-tone w h)
  (let ((px (make-bytevector (* w h 4) 255)))
    (do ((y 0 (+ y 1))) ((= y h))
      (do ((x 0 (+ x 1))) ((= x w))
        (let ((k (* 4 (+ x (* y w)))))
          (if (< x (quotient w 2))
              (begin (bytevector-u8-set! px (+ k 1) 0) (bytevector-u8-set! px (+ k 2) 0))
              (begin (bytevector-u8-set! px k 0) (bytevector-u8-set! px (+ k 1) 0))))))
    (make-image w h px)))

;; A JPEG with an EXIF APP1 segment giving orientation o (big-endian TIFF).
(define (with-orientation jpeg o)
  (let ((exif (bytevector #xFF #xE1 0 34
                          69 120 105 102 0 0                ; "Exif\0\0"
                          77 77 0 42 0 0 0 8                ; "MM", 42, IFD at 8
                          0 1                               ; one entry
                          1 18 0 3 0 0 0 1 0 o 0 0          ; 0x0112 SHORT 1 = o
                          0 0 0 0)))                        ; no next IFD
    (bytevector-append (bytevector-copy jpeg 0 2) exif (bytevector-copy jpeg 2))))

(define (info-of bv) (let ((i (image-info bv))) (list (cdr (assq 'width i)) (cdr (assq 'height i))
                                                      (cdr (assq 'orientation i)))))

(define stored (image->jpeg (two-tone 40 20) 90))
(define rotated (with-orientation stored 6))

(test-group "checking uploads"
  (test-equal '(40 20 6) (info-of rotated))
  (test-equal "measured as shown" '(20 . 40) (check-image rotated))
  (test-equal '(40 . 20) (check-image (image->png (two-tone 40 20))))
  (test-equal 'invalid (check-image (bytevector-copy stored 0 300)))
  (test-equal 'invalid (check-image (string->utf8 "no image")))
  ;; a PNG header claiming 10000 x 10000 pixels
  (let ((png (image->png (two-tone 4 4))))
    (bytevector-u8-set! png 18 #x27) (bytevector-u8-set! png 19 #x10)
    (bytevector-u8-set! png 22 #x27) (bytevector-u8-set! png 23 #x10)
    (test-equal 'too-large (check-image png))))

(test-group "exports"
  (let ((out (export-image rotated "image/jpeg" 400 400 #f)))
    (test-equal "turned upright" '(20 40 1) (info-of (car out)))
    (test-equal "image/jpeg" (cdr out))
    ;; turned 90 degrees clockwise: the red (left) half is now on top
    (let* ((img (image-decode (car out))) (px (image-pixels img)))
      (test-assert "red on top" (> (bytevector-u8-ref px (* 4 (+ 10 (* 5 20)))) 200))
      (test-assert "blue below" (> (bytevector-u8-ref px (+ 2 (* 4 (+ 10 (* 35 20))))) 200))))
  (test-assert "upright and small enough: the original"
    (eq? stored (car (export-image stored "image/jpeg" 400 400 #f))))
  (let ((big (image->png (two-tone 400 300))))
    (test-equal "downscaled to two pixels per unit" '(100 75 1)
      (info-of (car (export-image big "image/png" 50 50 #f))))
    (test-equal "cover fills the box" '(134 100 1)
      (info-of (car (export-image big "image/png" 50 50 #t)))))
  (let ((broken (bytevector-append (bytevector-copy stored 0 300))))
    (test-assert "what does not decode passes through"
      (eq? broken (car (export-image broken "image/jpeg" 1 1 #f))))))

(test-group "thumbnails"
  (let* ((dir (mktempdir '(prefix . "folien-images")))
         (sha (make-string 64 #\a))
         (src (string-append dir "/src.jpg")))
    (let ((p (open-binary-output-file src))) (write-bytevector rotated p) (close-port p))
    (let ((v (image-variant dir sha src "image/jpeg" 320)))
      (test-assert (file-exists? (car v)))
      (test-equal "image/jpeg" (cdr v))
      (let ((p (open-binary-input-file (car v))))
        (test-equal "upright" '(20 40 1) (info-of (read-bytevector 100000 p)))
        (close-port p))
      (test-equal "cached" v (image-variant dir sha src "image/jpeg" 320)))
    (test-equal "a missing source" #f (image-variant dir (make-string 64 #\b) (string-append dir "/none") "image/png" 320))
    (rm dir 'recursive)))

(test-end "folien images")
