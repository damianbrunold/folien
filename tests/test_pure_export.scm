;; Tests for (app export-pdf): every layout exports, with the right pages,
;; images, links and transparency. (How the pages look is checked by eye:
;; render them with mutool or a PDF viewer.)
;; Run: scm tests/test_pure_export.scm

(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm string)
        (scm crypto)
        (scm png)
        (scm test))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app model) (app assets) (app export-pdf))

(test-runner-factory scm-test-runner)
(test-begin "folien export pdf")

;; --- assets in a temporary data directory --------------------------------

(define data-dir (mktempdir '(prefix . "folien-export")))

(define (store! bytes)
  (let* ((sha (bytevector->hex (sha256-hash bytes)))
         (path (asset-file data-dir sha)))
    (ensure-asset-dir data-dir)
    (let ((dir (string-append data-dir "/assets/" (substring sha 0 2))))
      (unless (directory-exists? dir) (make-directory dir)))
    (let ((p (open-binary-output-file path)))
      (write-bytevector bytes p)
      (close-port p))
    sha))

(define rgb-png (store! (png-encode-rgb 2 2 (bytevector 255 0 0 0 255 0 0 0 255 255 255 255))))
(define rgba-png (store! (png-encode-rgba 1 1 (bytevector 0 112 180 128))))
(define svg (store! (string->utf8 "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='#0070b4'/></svg>")))
(define gif (store! (string->utf8 "GIF89a not really")))

;; --- a deck ----------------------------------------------------------------

(define (text . paras)
  `(("paragraphs" . ,(list->vector paras))))
(define (para runs . props) `(,@props ("runs" . ,(list->vector runs))))

(define slide1
  `(("id" . "s1") ("layout" . "title-content")
    ("notes" . ,(text (para '((("text" . "Eine Notiz"))))))
    ("elements"
     . #((("id" . "t") ("type" . "text") ("placeholder" . "title")
          ("text" . ,(text (para '((("text" . "Titel mit Länge")))))))
         (("id" . "b") ("type" . "text") ("placeholder" . "body")
          ("text" . ,(text (para '((("text" . "Fett") ("b" . #t)) (("text" . " und ")) (("text" . "schräg") ("i" . #t))))
                           (para '((("text" . "zh.ch") ("link" . "https://www.zh.ch/"))) '("list" . "bullet"))
                           (para '((("text" . "eins"))) '("list" . "number"))
                           (para '((("text" . "zwei"))) '("list" . "number")))))
         (("id" . "r") ("type" . "shape") ("shape" . "rounded") ("x" . 100) ("y" . 700) ("w" . 300) ("h" . 200)
          ("rot" . 15) ("style" . (("fill" . "accent") ("opacity" . 0.5))))
         (("id" . "i1") ("type" . "image") ("asset" . ,rgb-png) ("x" . 500) ("y" . 700) ("w" . 300) ("h" . 200)
          ("fit" . "cover") ("build" . (("order" . 1) ("effect" . "fade"))))
         (("id" . "i2") ("type" . "image") ("asset" . ,rgba-png) ("x" . 900) ("y" . 700) ("w" . 100) ("h" . 100)
          ("build" . (("order" . 2))))
         (("id" . "i3") ("type" . "image") ("asset" . ,svg) ("x" . 1100) ("y" . 700) ("w" . 200) ("h" . 100))
         (("id" . "i4") ("type" . "image") ("asset" . ,gif) ("x" . 1400) ("y" . 700) ("w" . 100) ("h" . 100))
         (("id" . "v") ("type" . "video") ("asset" . ,gif) ("poster" . ,rgb-png)
          ("x" . 1500) ("y" . 900) ("w" . 160) ("h" . 90))
         (("id" . "l") ("type" . "line") ("x" . 0) ("y" . 1000) ("w" . 1920) ("h" . 0)
          ("style" . (("stroke" . "#ff0000") ("strokeWidth" . 8))))))))

(define slide2 `(("id" . "s2") ("layout" . "section") ("hidden" . #t) ("elements" . #())))
(define slide3 `(("id" . "s3") ("layout" . "blank") ("background" . "accent") ("elements" . #())))

(define doc `(("format" . 1) ("slides" . ,(vector slide1 slide2 slide3))))

(test-equal "the test deck is valid" #f (validate-doc doc "zh"))

(define (pdf . opts) (deck->pdf doc "zh" "Prüfung" data-dir (if (pair? opts) (car opts) '())))

(define (text-of bv)
  ;; bytes as latin-1 text, enough to find PDF syntax
  (list->string (map integer->char (let loop ((i (- (bytevector-length bv) 1)) (acc '()))
                                     (if (< i 0) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))))

(define (has? s part) (and (string-contains-from s part 0) #t))

(define (count-of s part)
  (let loop ((i 0) (n 0))
    (let ((j (string-contains-from s part i)))
      (if j (loop (+ j 1) (+ n 1)) n))))

(test-group "slides, one per page"
  (let* ((bv (pdf))
         (s (text-of bv)))
    ;; To look at it: FOLIEN_PDF_OUT=/tmp/x.pdf scm tests/test_pure_export.scm
    (let ((out (get-environment-variable "FOLIEN_PDF_OUT")))
      (when out
        (let ((p (open-binary-output-file out)))
          (write-bytevector bv p)
          (close-port p))))
    (test-equal "%PDF" (substring s 0 4))
    (test-assert "two pages (the hidden slide is left out)" (has? s "/Count 2"))
    (test-assert "16:9 pages" (has? s "/MediaBox [0 0 960 540]"))
    (test-assert "Inter embedded" (has? s "+Inter"))
    (test-assert "Inter Black embedded" (has? s "+Inter-Black"))
    (test-assert "the link" (has? s "https://www.zh.ch/"))
    (test-assert "transparency" (has? s "/ExtGState"))
    ;; RGB PNG (also the poster, embedded once), RGBA PNG and the SVG
    ;; rendered as RGBA PNG (each with its mask); the GIF is left out
    (test-equal 5 (count-of s "/Subtype /Image"))
    (test-assert (has? s "/SMask"))
    (test-assert "the title (UTF-16, it has an umlaut)" (has? s "/Title <FEFF"))))

(test-group "one page per build step"
  (test-assert "3 steps of slide 1 + slide 3" (has? (text-of (pdf '((builds . steps)))) "/Count 4")))

(test-group "handouts and notes"
  (let ((s (text-of (pdf '((notes . #t))))))
    (test-assert "A4" (has? s "/MediaBox [0 0 595.28 841.89]"))
    (test-assert (has? s "/Count 2")))
  (test-assert (has? (text-of (pdf '((per-page . 2)))) "/Count 1"))
  (test-assert (has? (text-of (pdf '((per-page . 4) (notes . #t)))) "/Count 1"))
  (test-assert (has? (text-of (pdf '((per-page . 2) (notes . #t) (builds . steps)))) "/Count 2")))

(test-group "missing files are left out"
  (let ((s (text-of (deck->pdf doc "folien" "x" (mktempdir '(prefix . "folien-empty")) '()))))
    (test-equal 0 (count-of s "/Subtype /Image"))
    (test-assert (has? s "/Count 2"))))

(test-end "folien export pdf")
