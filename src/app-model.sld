;; (app model) — the presentation document: creation and validation.
;;
;; A deck's content is one JSON document (alists with string keys, vectors
;; for arrays; see (scm json simple)), stored as jsonb next to the deck's
;; title, design and revision:
;;
;;   {"format": 1,
;;    "slides": [{"id", "layout", "hidden"?, "transition"?, "notes"?,
;;                "elements": [element ...]} ...]}
;;
;;   element: {"id", "type": text|image|video|shape|line|table,
;;             "placeholder"?: role,          ; inherits from the layout
;;             "x", "y", "w", "h"?, "rot"?,   ; required unless placeholder
;;             "style"?, "build"?, "text"?, "asset"?, "alt"?, ...}
;;
;;   rich text: {"paragraphs": [{"align"?, "list"?, "level"?,
;;                               "runs": [{"text", "b"?, "i"?, "u"?,
;;                                         "color"?, "size"?, "link"?}]}]}
;;
;; Colours are theme tokens ("accent") or "#rrggbb". The browser is the
;; main editor of documents, so validate-doc checks everything a renderer
;; or exporter relies on, and anything that could carry script (links).
;; Unknown keys are tolerated so that older servers do not reject newer
;; editors' documents outright; renderers ignore what they don't know.

(define-library (app model)
  (import (scheme base)
          (scheme char)
          (scm crypto)
          (app designs))
  (export doc-format
          new-id
          new-doc
          new-slide
          validate-doc
          doc-slides
          jref)
  (begin

    (define doc-format 1)

    (define max-slides 1000)
    (define max-elements 500)
    (define max-text-length 100000)

    (define id-chars "abcdefghijklmnopqrstuvwxyz0123456789")

    (define (new-id)
      "Syntax: (new-id)
Library: (app model)
Description: A fresh random id for a slide or element (12 characters)."
      (random-string id-chars 12))

    (define (jref obj key . default)
      (let ((p (and (list? obj) (assoc key obj))))
        (cond (p (cdr p))
              ((pair? default) (car default))
              (else #f))))

    (define (doc-slides doc) (jref doc "slides" #()))

    ;; --- creation -----------------------------------------------------

    (define (rich-text str)
      `(("paragraphs" . #((("runs" . #((("text" . ,str)))))))))

    (define (new-slide design-id layout-id . texts)
      "Syntax: (new-slide design-id layout-id [(role . text) ...])
Library: (app model)
Description: A slide with layout-id of the design and one element per
  placeholder of the layout: text placeholders get the text given for
  their role, else empty text; image placeholders stay empty."
      (let* ((design (find-design design-id))
             (layout (or (find-layout design layout-id)
                         (error "new-slide: unknown layout" layout-id))))
        `(("id" . ,(new-id))
          ("layout" . ,layout-id)
          ("elements"
           . ,(vector-map
               (lambda (ph)
                 (let* ((role (jref ph "role"))
                        (text (let ((t (assoc role texts))) (if t (cdr t) ""))))
                   (if (equal? role "image")
                       `(("id" . ,(new-id)) ("type" . "image") ("placeholder" . ,role))
                       `(("id" . ,(new-id)) ("type" . "text") ("placeholder" . ,role)
                         ("text" . ,(rich-text text))))))
               (jref layout "placeholders"))))))

    (define (new-doc design-id title)
      "Syntax: (new-doc design-id title)
Library: (app model)
Description: The document of a new deck: one title slide with title as
  its title text."
      `(("format" . ,doc-format)
        ("slides" . ,(vector (new-slide design-id "title" (cons "title" title))))))

    ;; --- validation ---------------------------------------------------
    ;; Each check returns #f when fine, else a message naming the path of
    ;; the offending value. validate-doc returns the first problem.

    (define-syntax check-all
      (syntax-rules ()
        ((_) #f)
        ((_ e rest ...) (or e (check-all rest ...)))))

    (define (problem path msg) (string-append path ": " msg))

    (define (object? x)
      (and (list? x) (let loop ((x x))
                       (or (null? x)
                           (and (pair? (car x)) (string? (caar x)) (loop (cdr x)))))))

    (define (each-in vec path proc)
      ;; First problem of (proc item item-path index) over the vector.
      (let loop ((i 0))
        (and (< i (vector-length vec))
             (or (proc (vector-ref vec i)
                       (string-append path "[" (number->string i) "]")
                       i)
                 (loop (+ i 1))))))

    (define (opt obj key path pred what)
      (let ((p (assoc key obj)))
        (and p (not (pred (cdr p)))
             (problem (string-append path "." key) what))))

    (define (req obj key path pred what)
      (let ((p (assoc key obj)))
        (if p
            (and (not (pred (cdr p))) (problem (string-append path "." key) what))
            (problem (string-append path "." key) "missing"))))

    (define (valid-id? s)
      (and (string? s)
           (<= 1 (string-length s) 64)
           (let loop ((i 0))
             (or (= i (string-length s))
                 (let ((c (string-ref s i)))
                   (and (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_)))
                        (char<? c #\x80)
                        (loop (+ i 1))))))))

    (define (hex-color? s)
      (and (string? s)
           (= (string-length s) 7)
           (char=? (string-ref s 0) #\#)
           (let loop ((i 1))
             (or (= i 7)
                 (and (memv (char-downcase (string-ref s i))
                            (string->list "0123456789abcdef"))
                      (loop (+ i 1)))))))

    (define color-tokens
      '("background" "text" "muted" "accent" "accent2" "accent3" "light" "on-accent"))

    (define (color? s)
      (or (hex-color? s) (and (member s color-tokens) #t) (equal? s "none")))

    (define (number-in? lo hi) (lambda (x) (and (real? x) (<= lo x hi))))
    (define coordinate? (number-in? -100000 100000))
    (define size? (number-in? 0 100000))

    (define (one-of . xs) (lambda (x) (and (member x xs) #t)))

    (define (string-prefix? p s)
      (and (>= (string-length s) (string-length p))
           (string=? (substring s 0 (string-length p)) p)))

    ;; Links in text: web and mail addresses, or a jump to a slide in the
    ;; deck ("#slide-<id>"). Nothing else, so no javascript: URLs.
    (define (safe-link? s)
      (and (string? s)
           (<= (string-length s) 2000)
           (let ((l (string-map char-downcase s)))
             (or (string-prefix? "https://" l)
                 (string-prefix? "http://" l)
                 (string-prefix? "mailto:" l)
                 (string-prefix? "#slide-" l)))))

    (define (check-run run path)
      (if (not (object? run))
          (problem path "not an object")
          (check-all
           (req run "text" path
                (lambda (t) (and (string? t) (<= (string-length t) max-text-length)))
                "not a string (or too long)")
           (opt run "b" path boolean? "not a boolean")
           (opt run "i" path boolean? "not a boolean")
           (opt run "u" path boolean? "not a boolean")
           (opt run "color" path color? "not a colour")
           (opt run "size" path (number-in? 1 1000) "not a font size")
           (opt run "link" path safe-link? "not an allowed link"))))

    (define (check-paragraph para path)
      (if (not (object? para))
          (problem path "not an object")
          (check-all
           (opt para "align" path (one-of "left" "center" "right" "justify") "bad alignment")
           (opt para "list" path (one-of "none" "bullet" "number") "bad list type")
           (opt para "level" path (number-in? 0 8) "bad list level")
           (req para "runs" path vector? "not an array")
           (each-in (jref para "runs" #()) (string-append path ".runs")
                    (lambda (r p i) (check-run r p))))))

    (define (check-rich-text text path)
      (if (not (object? text))
          (problem path "not an object")
          (check-all
           (req text "paragraphs" path vector? "not an array")
           (each-in (jref text "paragraphs" #()) (string-append path ".paragraphs")
                    (lambda (para p i) (check-paragraph para p))))))

    (define (check-style style path)
      (if (not (object? style))
          (problem path "not an object")
          (check-all
           (opt style "fill" path color? "not a colour")
           (opt style "stroke" path color? "not a colour")
           (opt style "strokeWidth" path (number-in? 0 1000) "bad stroke width")
           (opt style "opacity" path (number-in? 0 1) "bad opacity")
           (opt style "font" path (one-of "heading" "body") "bad font token")
           (opt style "size" path (number-in? 1 1000) "bad font size")
           (opt style "color" path color? "not a colour")
           (opt style "align" path (one-of "left" "center" "right" "justify") "bad alignment")
           (opt style "valign" path (one-of "top" "middle" "bottom") "bad alignment"))))

    (define (check-build build path)
      (if (not (object? build))
          (problem path "not an object")
          (check-all
           (req build "order" path (number-in? 1 1000) "bad build order")
           (opt build "effect" path
                (one-of "appear" "fade" "fly-left" "fly-right" "fly-up" "fly-down" "zoom")
                "unknown effect"))))

    (define element-types '("text" "image" "video" "shape" "line" "table"))

    (define (check-element el path ids)
      (if (not (object? el))
          (problem path "not an object")
          (let ((placeholder? (assoc "placeholder" el)))
            (check-all
             (req el "id" path valid-id? "bad id")
             (and (member (jref el "id") ids) (problem (string-append path ".id") "duplicate"))
             (req el "type" path (lambda (t) (and (member t element-types) #t)) "unknown type")
             (opt el "placeholder" path valid-id? "bad placeholder role")
             (if placeholder?
                 (check-all (opt el "x" path coordinate? "not a number")
                            (opt el "y" path coordinate? "not a number")
                            (opt el "w" path size? "not a size")
                            (opt el "h" path size? "not a size"))
                 (check-all (req el "x" path coordinate? "not a number")
                            (req el "y" path coordinate? "not a number")
                            (req el "w" path size? "not a size")
                            (opt el "h" path size? "not a size")))
             (opt el "rot" path (number-in? -360 360) "bad rotation")
             (opt el "asset" path
                  (lambda (a) (and (string? a) (<= 1 (string-length a) 128))) "bad asset reference")
             (opt el "alt" path
                  (lambda (a) (and (string? a) (<= (string-length a) 2000))) "bad alt text")
             (let ((s (assoc "style" el)))
               (and s (check-style (cdr s) (string-append path ".style"))))
             (let ((b (assoc "build" el)))
               (and b (check-build (cdr b) (string-append path ".build"))))
             (let ((t (assoc "text" el)))
               (and t (check-rich-text (cdr t) (string-append path ".text"))))))))

    (define (check-transition tr path)
      (if (not (object? tr))
          (problem path "not an object")
          (check-all
           (req tr "type" path
                (one-of "none" "fade" "push-left" "push-up" "wipe-left" "zoom")
                "unknown transition")
           (opt tr "duration" path (number-in? 0 10000) "bad duration"))))

    (define (check-slide slide path slide-ids)
      (if (not (object? slide))
          (problem path "not an object")
          (check-all
           (req slide "id" path valid-id? "bad id")
           (and (member (jref slide "id") slide-ids)
                (problem (string-append path ".id") "duplicate"))
           (req slide "layout" path valid-id? "bad layout id")
           (opt slide "hidden" path boolean? "not a boolean")
           (let ((tr (assoc "transition" slide)))
             (and tr (check-transition (cdr tr) (string-append path ".transition"))))
           (let ((n (assoc "notes" slide)))
             (and n (check-rich-text (cdr n) (string-append path ".notes"))))
           (req slide "elements" path
                (lambda (v) (and (vector? v) (<= (vector-length v) max-elements)))
                "not an array (or too many elements)")
           (let ((els (jref slide "elements" #())))
             (let loop ((i 0) (ids '()))
               (and (< i (vector-length els))
                    (let ((el (vector-ref els i))
                          (p (string-append path ".elements[" (number->string i) "]")))
                      (or (check-element el p ids)
                          (loop (+ i 1) (cons (jref el "id") ids))))))))))

    (define (validate-doc doc design-id)
      "Syntax: (validate-doc doc design-id)
Library: (app model)
Description: #f if doc is a well-formed deck document for the design,
  else a message describing the first problem, e.g.
  \"slides[2].elements[0].x: not a number\". Slide layouts must exist in
  the design."
      (let ((design (find-design design-id)))
        (cond
          ((not design) (problem "design" "unknown design"))
          ((not (object? doc)) (problem "document" "not an object"))
          (else
           (check-all
            (req doc "format" "document" (lambda (f) (eqv? f doc-format)) "unsupported format")
            (req doc "slides" "document"
                 (lambda (v) (and (vector? v) (<= 1 (vector-length v) max-slides)))
                 "must be an array of 1 to 1000 slides")
            (let ((slides (doc-slides doc)))
              (let loop ((i 0) (ids '()))
                (and (< i (vector-length slides))
                     (let ((slide (vector-ref slides i))
                           (p (string-append "slides[" (number->string i) "]")))
                       (or (check-slide slide p ids)
                           (and (not (find-layout design (jref slide "layout")))
                                (problem (string-append p ".layout") "not in the design"))
                           (loop (+ i 1) (cons (jref slide "id") ids))))))))))))))
