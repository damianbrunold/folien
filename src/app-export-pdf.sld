;; (app export-pdf) — a deck as PDF, drawn natively with (scm pdf).
;;
;; It draws what static/js/render.js shows: the same document model,
;; layouts and design tokens, text broken into lines as the browser does
;; it ((scm text layout) with the same rules: pre-wrap, CSS line boxes,
;; the renderer's paragraph spacing and list indents), in the same glyphs
;; (the design's family from (scm fonts inter) or (scm fonts roboto-slab),
;; written as TrueType and embedded), kerned. Bold and heading text use
;; the family's heavy face (Inter Black, Roboto Slab Bold), italics are
;; slanted. Runs marked as code are set in the design's code font
;; (JetBrains Mono) from the dabscm-fonts package via (scm fonts); without
;; the package they keep the text's font. Text is real text: selectable, searchable,
;; web links clickable.
;;
;; Layouts: 1, 2 or 4 slides per page, with or without the notes. One
;; slide per page without notes gives 960 x 540 pt pages (PowerPoint's
;; 16:9); the others are A4 portrait handouts. Builds show their final
;; state, or one page per step. Hidden slides are left out. Videos show
;; their poster frame. Photos are embedded upright (EXIF orientation) and
;; downscaled to what the slide shows ((app images)).

(define-library (app export-pdf)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme inexact)
          (scheme lazy)
          (srfi 69)
          (only (srfi 19) current-date date->string)
          (scm fs)
          (scm pdf)
          (scm truetype)
          (scm fonts inter)
          (scm fonts roboto-slab)
          (only (scm fonts) find-font find-font-file)
          (scm text layout)
          (scm svg raster)
          (only (scm raster) canvas-width canvas->png)
          (app designs)
          (app model)
          (app assets)
          (app images)
          (only (scm image) image-decode image->png))
  (export deck->pdf)
  (begin

    (define SLIDE-W 1920)
    (define SLIDE-H 1080)

    ;; --- fonts --------------------------------------------------------
    ;; The families the designs name: per family its regular and heavy
    ;; font, as (font PostScript-name style).

    (define families
      `(("Inter" (,inter-regular "Inter" "Regular") (,inter-black "Inter-Black" "Black"))
        ("Roboto Slab" (,roboto-slab-regular "RobotoSlab-Regular" "Regular")
                       (,roboto-slab-bold "RobotoSlab-Bold" "Bold"))))

    (define (family-of design)
      (let* ((body (jr (design-ref design "fonts") "body"))
             (f (assoc (or (and body (jr body "family")) "Inter") families)))
        (if f f (car families))))

    ;; The TrueType files are made once per process and font.
    (define ttf-cache '())
    (define (ttf-file family spec)
      (let ((hit (assq (car spec) ttf-cache)))
        (if hit
            (cdr hit)
            (let ((ttf (font->truetype (car spec) (car family) (caddr spec))))
              (set! ttf-cache (cons (cons (car spec) ttf) ttf-cache))
              ttf))))

    (define (kerning-of tt)
      (let ((k (/ 1000.0 (font-units-per-em tt))))
        (lambda (a b) (* k (font-kerning tt a b)))))

    ;; A font as text is drawn with it: the embedded PDF font, its kerning
    ;; and its extent above and below the baseline, per size unit.
    (define-record-type face
      (make-face font kern ascent descent)
      face?
      (font face-font)
      (kern face-kern)
      (ascent face-ascent)
      (descent face-descent))

    (define (embed-face pdf family spec)
      (let ((tt (car spec)))
        (make-face (pdf-embed-truetype-font pdf (ttf-file family spec) (cadr spec))
                   (kerning-of tt)
                   (/ (font-ascent tt) (font-units-per-em tt))
                   (/ (- (font-descent tt)) (font-units-per-em tt)))))

    ;; A font file found by (scm fonts), embedded as it is (the PDF writer
    ;; subsets it).
    (define (embed-file-face pdf font bytes name)
      (make-face (pdf-embed-truetype-font pdf bytes name)
                 (kerning-of font)
                 (/ (font-ascent font) (font-units-per-em font))
                 (/ (- (font-descent font)) (font-units-per-em font))))

    ;; The code font's faces (regular . bold), or #f when the font is not
    ;; installed: embedded when the first code run needs them.
    (define (code-faces pdf design)
      (delay
        (let* ((code (jr (design-ref design "fonts") "code"))
               (family (and code (jr code "family")))
               (regular (and family (find-font family 400)))
               (bold (and family (find-font family 700))))
          (and regular bold
               (let ((ps (list->string (filter-chars (lambda (c) (not (char=? c #\space)))
                                                     (string->list family)))))
                 (cons (embed-file-face pdf regular (find-font-file family 400)
                                        (string-append ps "-Regular"))
                       (embed-file-face pdf bold (find-font-file family 700)
                                        (string-append ps "-Bold"))))))))

    (define (filter-chars keep? cs)
      (cond ((null? cs) '())
            ((keep? (car cs)) (cons (car cs) (filter-chars keep? (cdr cs))))
            (else (filter-chars keep? (cdr cs)))))

    ;; Everything a drawing needs. regular and black are faces; code a
    ;; promise of the code faces (see code-faces).
    (define-record-type ctx
      (make-ctx pdf regular black code design data-dir images doc today)
      ctx?
      (pdf ctx-pdf)
      (regular ctx-regular)
      (black ctx-black)
      (code ctx-code)
      (design ctx-design)
      (data-dir ctx-data-dir)
      (images ctx-images)        ; sha -> pdf image or 'none
      (doc ctx-doc)              ; for the footer fields
      (today ctx-today))         ; the automatic date: "29.10.2026"

    (define (jr obj key . d) (apply jref obj key d))

    ;; --- colours ------------------------------------------------------

    (define (hex2 s i) (/ (string->number (substring s i (+ i 2)) 16) 255.0))

    ;; (r g b) for a token or "#rrggbb", #f for none.
    (define (rgb ctx c)
      (cond
        ((or (not c) (equal? c "none")) #f)
        ((and (string? c) (= (string-length c) 7) (char=? (string-ref c 0) #\#))
         (list (hex2 c 1) (hex2 c 3) (hex2 c 5)))
        (else (rgb ctx (jr (design-ref (ctx-design ctx) "colors") c "#000000")))))

    (define (set-fill! page c)
      (when c (pdf-set-fill-rgb page (car c) (cadr c) (caddr c))))
    (define (set-stroke! page c)
      (when c (pdf-set-stroke-rgb page (car c) (cadr c) (caddr c))))

    ;; --- elements (as render.js resolves them) --------------------------

    (define (merge-style a b)
      ;; b over a (alists)
      (append (if b b '())
              (let loop ((xs (or a '())))
                (cond ((null? xs) '())
                      ((and b (assoc (car (car xs)) b)) (loop (cdr xs)))
                      (else (cons (car xs) (loop (cdr xs))))))))

    (define (find-placeholder layout role)
      (and layout role
           (let loop ((i 0) (phs (jr layout "placeholders" #())))
             (cond ((= i (vector-length phs)) #f)
                   ((equal? (jr (vector-ref phs i) "role") role) (vector-ref phs i))
                   (else (loop (+ i 1) phs))))))

    ;; (x y w h rot style) of an element.
    (define (resolve layout el)
      (let* ((ph (find-placeholder layout (jr el "placeholder")))
             (pick (lambda (k d) (let ((v (jr el k))) (if v v (if ph (jr ph k d) d))))))
        (list (pick "x" 0) (pick "y" 0) (pick "w" 100) (pick "h" 100)
              (or (jr el "rot") 0)
              (merge-style (and ph (jr ph "style" '())) (jr el "style" '())))))

    ;; --- text ---------------------------------------------------------

    (define (font-weight-of ctx token)
      (let ((f (jr (design-ref (ctx-design ctx) "fonts") token)))
        (if f (jr f "weight" 400) 400)))

    ;; A text run for the layout: its data is an alist the drawing reads.
    (define (make-run ctx text black? size color italic? underline? link . code)
      (let* ((code-faces (and (pair? code) (car code) (force (ctx-code ctx))))
             (face (cond (code-faces (if black? (cdr code-faces) (car code-faces)))
                         (black? (ctx-black ctx))
                         (else (ctx-regular ctx))))
             (font (face-font face))
             (kern (face-kern face)))
        (make-text-run text
                       (lambda (s) (pdf-text-width font size s kern))
                       size (* (face-ascent face) size) (* (face-descent face) size)
                       `((font . ,font) (kern . ,kern) (face . ,face) (size . ,size) (color . ,color)
                         (italic . ,italic?) (underline . ,underline?) (link . ,link)))))

    (define (rdata run key) (cdr (assq key (text-run-data run))))

    ;; Lays out rich text in a box of width w: a list of
    ;; (y-offset-from-top . line) with markers as (marker x text run), and
    ;; the total height. base: the box's style alist.
    (define (layout-rich-text ctx text base w)
      (let* ((settings (design-ref (ctx-design ctx) "text"))
             (lh (jr settings "lineHeight" 1.2))
             (spacing (jr settings "paraSpacing" 0.35))
             (bullet (jr settings "bullet" "•"))
             (base-size (or (jr base "size") 40))
             (base-black? (>= (font-weight-of ctx (or (jr base "font") "body")) 700))
             ;; a code block: all of it in the code font
             (base-code? (equal? (jr base "font") "code"))
             (base-color (rgb ctx (or (jr base "color") "text")))
             (paras (vector->list (jr text "paragraphs" #())))
             (n (length paras)))
        (let loop ((ps paras) (i 0) (y 0) (counters '()) (out '()))
          (if (null? ps)
              (values (reverse out) y)
              (let* ((p (car ps))
                     (runs (filter-runs (vector->list (jr p "runs" #()))))
                     (first-size (or (and (pair? runs) (jr (car runs) "size")) base-size))
                     (list-kind (jr p "list" "none"))
                     (level (jr p "level" 0))
                     (indent (if (equal? list-kind "none") 0 (* (+ level 1) 1.1 first-size)))
                     (counters (next-counters counters list-kind level))
                     (strut (make-run ctx "" base-black? base-size base-color #f #f #f base-code?))
                     (trs (map (lambda (r)
                                 (make-run ctx (jr r "text")
                                           (or base-black? (eq? (jr r "b") #t))
                                           (or (jr r "size") base-size)
                                           (if (jr r "color") (rgb ctx (jr r "color")) base-color)
                                           (eq? (jr r "i") #t)
                                           (or (eq? (jr r "u") #t) (and (jr r "link") #t))
                                           (jr r "link")
                                           (or base-code? (eq? (jr r "code") #t))))
                               runs))
                     (align (string->symbol (or (jr p "align") (jr base "align") "left")))
                     (lines (layout-paragraph trs (max 1 (- w indent))
                                              `((align . ,align) (line-height . ,lh)
                                                (strut . ,strut))))
                     (marker (and (not (equal? list-kind "none"))
                                  (list (* level 1.1 first-size)
                                        (if (equal? list-kind "number")
                                            (string-append (number->string (cddr (car counters))) ".")
                                            bullet)
                                        strut)))
                     (placed (let place ((ls lines) (y y) (first #t) (acc '()))
                               (if (null? ls)
                                   (cons y acc)
                                   (place (cdr ls) (+ y (line-height (car ls))) #f
                                          (cons (list y (car ls) indent (and first marker)) acc)))))
                     (end-y (car placed))
                     (gap (if (< i (- n 1)) (* spacing first-size) 0)))
                (loop (cdr ps) (+ i 1) (+ end-y gap) counters
                      (append (cdr placed) out)))))))

    (define (filter-runs runs)
      (let loop ((rs runs))
        (cond ((null? rs) '())
              ((equal? (jr (car rs) "text" "") "") (loop (cdr rs)))
              (else (cons (car rs) (loop (cdr rs)))))))

    ;; Numbering per list level, as render.js counts: (level . n) alist,
    ;; reset when the kind changes or a plain paragraph comes.
    (define (next-counters counters kind level)
      (if (equal? kind "none")
          '()
          (let* ((kept (let loop ((cs counters))
                         (cond ((null? cs) '())
                               ((> (car (car cs)) level) (loop (cdr cs)))
                               (else (cons (car cs) (loop (cdr cs)))))))
                 (here (assv level kept))
                 (same? (and here (equal? (cadr here) kind)))
                 (n (if same? (+ (cddr here) 1) 1))
                 (rest (let loop ((cs kept))
                         (cond ((null? cs) '())
                               ((= (car (car cs)) level) (loop (cdr cs)))
                               (else (cons (car cs) (loop (cdr cs))))))))
            (cons (cons level (cons kind n)) rest))))

    ;; Draws laid-out text with its top at top-y and its left edge at x0
    ;; (default 0; local coordinates, y up). link-box: a procedure from a
    ;; local rect to page coordinates, or #f (no link annotations).
    (define (draw-text-lines ctx page placed top-y link-box . x0)
      (define left (if (pair? x0) (car x0) 0))
      (for-each
       (lambda (pl)
         (let* ((y (car pl)) (line (cadr pl)) (indent (caddr pl)) (marker (cadddr pl))
                (baseline (- top-y y (line-baseline line))))
           (when marker
             (draw-piece ctx page (+ left (car marker)) baseline (cadr marker) (caddr marker) #f))
           (for-each
            (lambda (item)
              (draw-piece ctx page (+ left indent (item-x item)) baseline (item-text item)
                          (item-run item) link-box (item-width item)))
            (line-items line))))
       placed))

    (define (draw-piece ctx page x baseline text run link-box . width)
      (let ((size (rdata run 'size)))
        (pdf-with-state page
          (lambda ()
            (set-fill! page (rdata run 'color))
            (pdf-draw-text page (rdata run 'font) size x baseline text
                           'kerning (rdata run 'kern)
                           'skew (if (rdata run 'italic) 14 0))
            (when (and (rdata run 'underline) (pair? width))
              (pdf-rect page x (- baseline (* 0.11 size)) (car width) (* 0.07 size))
              (pdf-fill page))))
        (let ((link (rdata run 'link)))
          (when (and link link-box (pair? width) (web-link? link))
            (pdf-add-link page
                          (link-box x (- baseline (* (face-descent (rdata run 'face)) size))
                                    (+ x (car width))
                                    (+ baseline (* (face-ascent (rdata run 'face)) size)))
                          link)))))

    (define (web-link? s)
      (let ((l (string-downcase s)))
        (or (string-prefix? "https://" l) (string-prefix? "http://" l) (string-prefix? "mailto:" l))))

    (define (string-prefix? p s)
      (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

    ;; --- shapes ---------------------------------------------------------

    (define kappa 0.5522847498)

    (define (ellipse-path page x y w h)
      (let ((rx (/ w 2)) (ry (/ h 2)) (cx (+ x (/ w 2))) (cy (+ y (/ h 2))))
        (pdf-move-to page (+ cx rx) cy)
        (pdf-curve-to page (+ cx rx) (+ cy (* kappa ry)) (+ cx (* kappa rx)) (+ cy ry) cx (+ cy ry))
        (pdf-curve-to page (- cx (* kappa rx)) (+ cy ry) (- cx rx) (+ cy (* kappa ry)) (- cx rx) cy)
        (pdf-curve-to page (- cx rx) (- cy (* kappa ry)) (- cx (* kappa rx)) (- cy ry) cx (- cy ry))
        (pdf-curve-to page (+ cx (* kappa rx)) (- cy ry) (+ cx rx) (- cy (* kappa ry)) (+ cx rx) cy)
        (pdf-close-path page)))

    (define (rounded-path page x y w h r)
      (let ((r (min r (/ w 2) (/ h 2))) (k (* kappa (min r (/ w 2) (/ h 2)))))
        (pdf-move-to page (+ x r) y)
        (pdf-line-to page (- (+ x w) r) y)
        (pdf-curve-to page (+ (- (+ x w) r) k) y (+ x w) (- (+ y r) k) (+ x w) (+ y r))
        (pdf-line-to page (+ x w) (- (+ y h) r))
        (pdf-curve-to page (+ x w) (+ (- (+ y h) r) k) (+ (- (+ x w) r) k) (+ y h) (- (+ x w) r) (+ y h))
        (pdf-line-to page (+ x r) (+ y h))
        (pdf-curve-to page (- (+ x r) k) (+ y h) x (+ (- (+ y h) r) k) x (- (+ y h) r))
        (pdf-line-to page x (+ y r))
        (pdf-curve-to page x (- (+ y r) k) (- (+ x r) k) y (+ x r) y)
        (pdf-close-path page)))

    ;; The polygon shapes of render.js (shapePath), in y-up coordinates.
    (define (polygon page pts h)
      (pdf-move-to page (car (car pts)) (- h (cadr (car pts))))
      (for-each (lambda (p) (pdf-line-to page (car p) (- h (cadr p)))) (cdr pts))
      (pdf-close-path page))

    (define (shape-points kind w h)
      (case kind
        ((triangle) (list (list (/ w 2) 0) (list w h) (list 0 h)))
        ((arrow)
         (let ((t (* h 0.3)) (head (min (* w 0.4) h)))
           (list (list 0 t) (list (- w head) t) (list (- w head) 0) (list w (/ h 2))
                 (list (- w head) h) (list (- w head) (- h t)) (list 0 (- h t)))))
        ((chevron)
         (let ((k (min (* w 0.4) (/ h 2))))
           (list (list 0 0) (list (- w k) 0) (list w (/ h 2)) (list (- w k) h) (list 0 h) (list k (/ h 2)))))
        (else (list (list 0 0) (list w 0) (list w h) (list 0 h)))))

    (define (draw-shape ctx page kind w h style)
      (let* ((fill (rgb ctx (or (jr style "fill") "accent")))
             (stroke (rgb ctx (or (jr style "stroke") "none")))
             (sw (or (jr style "strokeWidth") 0))
             (css-box? (memq kind '(rect rounded ellipse)))
             ;; A CSS border lies inside the box.
             (inset (if (and css-box? stroke (> sw 0)) (/ sw 2) 0))
             (path (lambda (d)
                     (case kind
                       ((rect) (pdf-rect page d d (- w (* 2 d)) (- h (* 2 d))))
                       ((rounded) (rounded-path page d d (- w (* 2 d)) (- h (* 2 d))
                                                (- (* 0.12 (min w h)) d)))
                       ((ellipse) (ellipse-path page d d (- w (* 2 d)) (- h (* 2 d))))
                       (else (polygon page (shape-points kind w h) h))))))
        (when fill
          (set-fill! page fill)
          (path 0)
          (pdf-fill page))
        (when (and stroke (> sw 0))
          (set-stroke! page stroke)
          (pdf-set-line-width page sw)
          (path inset)
          (pdf-stroke page))))

    (define (draw-line ctx page el w h style)
      (let ((stroke (rgb ctx (or (jr style "stroke") "text")))
            (sw (or (jr style "strokeWidth") 4)))
        (when stroke
          (set-stroke! page stroke)
          (pdf-set-line-width page sw)
          (pdf-set-line-cap page pdf-line-cap-round)
          (if (eq? (jr el "flip") #t)
              (begin (pdf-move-to page 0 0) (pdf-line-to page w h))
              (begin (pdf-move-to page 0 h) (pdf-line-to page w 0)))
          (pdf-stroke page))))

    ;; --- images -------------------------------------------------------

    (define (read-bytes path)
      (let* ((p (open-binary-input-file path))
             (bv (read-bytevector (file-size path) p)))
        (close-port p)
        (if (eof-object? bv) (bytevector) bv)))

    ;; The embedded image of an asset in a box of w x h slide units (each
    ;; once per document and box), or #f when it cannot be drawn
    ;; (missing, a format the PDF cannot take). SVGs are rasterized at
    ;; twice the box size.
    (define (asset-image ctx sha w h cover?)
      (let* ((key (list sha w h cover?))
             (cached (hash-table-ref/default (ctx-images ctx) key #f)))
        (cond
          ((eq? cached 'none) #f)
          (cached cached)
          (else
           (let* ((path (and (valid-sha? sha) (asset-file (ctx-data-dir ctx) sha)))
                  (img (and path (file-exists? path)
                            (guard (e (#t #f))
                              (let* ((bv (read-bytes path))
                                     (mime (sniff-mime (bytevector-copy bv 0 (min 1024 (bytevector-length bv))))))
                                (cond
                                  ((raster-mime? mime)
                                   (let ((out (export-image bv mime w h cover?)))
                                     (if (eq? (car out) bv)
                                         ;; the original: embedded once, whatever the box
                                         (let ((k (list 'original sha)))
                                           (or (hash-table-ref/default (ctx-images ctx) k #f)
                                               (let ((img (embed-raster ctx bv mime)))
                                                 (hash-table-set! (ctx-images ctx) k img)
                                                 img)))
                                         (embed-raster ctx (car out) (cdr out)))))
                                  ((equal? mime "image/svg+xml")
                                   (pdf-embed-png (ctx-pdf ctx) (svg-png (utf8->string bv) (* 2 (max w h)))))
                                  (else #f)))))))
             (hash-table-set! (ctx-images ctx) key (or img 'none))
             img)))))

    (define (embed-raster ctx bytes mime)
      (if (equal? mime "image/jpeg")
          (pdf-embed-jpeg (ctx-pdf ctx) bytes)
          ;; (scm pdf) takes 8-bit RGB(A) PNGs; others (paletted, 16-bit)
          ;; are redrawn
          (guard (e (#t (pdf-embed-png (ctx-pdf ctx) (image->png (image-decode bytes)))))
            (pdf-embed-png (ctx-pdf ctx) bytes))))

    ;; An SVG as PNG about svg-size pixels across (the element's size at
    ;; print resolution), whatever the SVG's own size.
    (define (svg-png text svg-size)
      (let* ((c (svg->canvas text))
             (s (max 0.25 (min 8 (/ svg-size (max 1 (canvas-width c)))))))
        (if (< (abs (- s 1)) 0.1)
            (canvas->png c)
            (svg->png text `((scale . ,s))))))

    (define (draw-image ctx page el w h)
      (let* ((sha (or (and (equal? (jr el "type") "video") (jr el "poster")) (jr el "asset")))
             (cover? (equal? (jr el "fit") "cover"))
             (img (and sha (asset-image ctx sha w h cover?))))
        (when img
          (let* ((iw (pdf-image-width img))
                 (ih (pdf-image-height img))
                 (s (if cover? (max (/ w iw) (/ h ih)) (min (/ w iw) (/ h ih))))
                 (dw (* s iw)) (dh (* s ih)))
            (pdf-with-state page
              (lambda ()
                (pdf-rect page 0 0 w h)
                (pdf-clip page)
                (pdf-end-path page)
                (pdf-draw-image page img (/ (- w dw) 2) (/ (- h dh) 2) dw dh)))))))

    ;; --- slides -------------------------------------------------------

    ;; Draws one element of a slide in slide units (the caller's CTM maps
    ;; the slide, y up). to-page: slide point -> page point, for links.
    (define (draw-element ctx page layout el decoration? to-page)
      (let* ((r (resolve layout el))
             (x (list-ref r 0)) (y (list-ref r 1)) (w (list-ref r 2)) (h (list-ref r 3))
             (rot (list-ref r 4)) (style (list-ref r 5))
             (type (jr el "type")))
        (pdf-with-state page
          (lambda ()
            ;; Element frame: origin at its bottom-left, y up, rotated
            ;; about its centre (CSS turns clockwise).
            (pdf-translate page (+ x (/ w 2)) (- SLIDE-H y (/ h 2)))
            (unless (= rot 0) (pdf-rotate page (- rot)))
            (pdf-translate page (- (/ w 2)) (- (/ h 2)))
            (let ((op (jr style "opacity")))
              (when (and op (< op 1)) (pdf-set-opacity page op)))
            (cond
              ((equal? type "text")
               (let ((fill (rgb ctx (jr style "fill"))))
                 (when fill
                   (set-fill! page fill)
                   (pdf-rect page 0 0 w h)
                   (pdf-fill page)))
               ;; the text inside the padding, as render.js pads the box
               (let* ((text (jr el "text"))
                      (pad (min (jr style "pad" 0) (/ w 2) (/ h 2)))
                      (tw (- w pad pad))
                      (th (- h pad pad)))
                 (when text
                   (call-with-values
                     (lambda () (layout-rich-text ctx text style tw))
                     (lambda (placed total)
                       (let* ((valign (or (jr style "valign") "top"))
                              (offset (cond ((equal? valign "middle") (/ (- th total) 2))
                                            ((equal? valign "bottom") (- th total))
                                            (else 0))))
                         (draw-text-lines ctx page placed (- h pad offset)
                                          (link-box-of to-page x y h rot) pad)))))))
              ((equal? type "table")
               (draw-table ctx page (jr el "table") w h style (link-box-of to-page x y h rot)))
              ((equal? type "shape")
               (draw-shape ctx page (string->symbol (or (jr el "shape") "rect")) w h style))
              ((equal? type "line") (draw-line ctx page el w h style))
              ((or (equal? type "image") (equal? type "video")) (draw-image ctx page el w h))
              (else #f))))))

    ;; Link rectangles of an element at (x y) of height h: local (y up)
    ;; -> slide -> page; #f if it is rotated (no link annotations).
    (define (link-box-of to-page x y h rot)
      (and (= rot 0)
           (lambda (x0 y0 x1 y1)
             (let ((a (to-page (+ x x0) (- (+ y h) y0)))
                   (b (to-page (+ x x1) (- (+ y h) y1))))
               (list (car a) (cadr a) (car b) (cadr b))))))

    ;; --- tables ---------------------------------------------------------
    ;; As render.js draws them: equal columns, each row at least h / rows
    ;; high and as high as its text needs, the header row in the heading
    ;; font on the accent colour, body rows banded, text centred
    ;; vertically.

    (define table-pad-x 16)
    (define table-pad-y 10)

    (define (table-row-fill table i)
      (let ((header? (eq? (jr table "header") #t)))
        (cond ((and (= i 0) header?) "accent")
              ((odd? (- i (if header? 1 0))) "light")
              (else "background"))))

    (define (draw-table ctx page table w h style link-box)
      (let* ((rows (vector->list (jr table "rows" #())))
             (n (length rows))
             (cols (if (pair? rows) (vector-length (car rows)) 1))
             (col-w (/ w cols))
             (min-h (/ h (max n 1)))
             (header? (eq? (jr table "header") #t))
             (header-style (merge-style style '(("font" . "heading") ("color" . "on-accent")))))
        (let loop ((rows rows) (i 0) (top 0))
          (when (pair? rows)
            (let* ((cells (map (lambda (cell)
                                 (call-with-values
                                   (lambda ()
                                     (layout-rich-text ctx cell (if (and header? (= i 0)) header-style style)
                                                       (max 1 (- col-w (* 2 table-pad-x)))))
                                   cons))
                               (vector->list (car rows))))
                   (row-h (apply max min-h (map (lambda (c) (+ (cdr c) (* 2 table-pad-y))) cells))))
              (set-fill! page (rgb ctx (table-row-fill table i)))
              (pdf-rect page 0 (- h top row-h) w row-h)
              (pdf-fill page)
              (let each ((cs cells) (j 0))
                (when (pair? cs)
                  (draw-text-lines ctx page (car (car cs))
                                   (- h top (/ (- row-h (cdr (car cs))) 2))
                                   link-box
                                   (+ (* j col-w) table-pad-x))
                  (each (cdr cs) (+ j 1))))
              (loop (cdr rows) (+ i 1) (+ top row-h)))))))

    ;; The distinct build orders of a slide, ascending.
    (define (build-orders slide)
      (let loop ((els (vector->list (jr slide "elements" #()))) (acc '()))
        (if (null? els)
            (sort-numbers acc)
            (let ((b (jr (car els) "build")))
              (loop (cdr els)
                    (if (and b (jr b "order") (not (memv (jr b "order") acc)))
                        (cons (jr b "order") acc)
                        acc))))))

    (define (sort-numbers xs)
      (let loop ((xs xs) (out '()))
        (if (null? xs)
            out
            (loop (cdr xs)
                  (let ins ((ys out))
                    (cond ((null? ys) (list (car xs)))
                          ((< (car xs) (car ys)) (cons (car xs) ys))
                          (else (cons (car ys) (ins (cdr ys))))))))))

    ;; Draws a slide with its bottom-left at (x0, y0) of the page, scale
    ;; points per slide unit, showing builds up to order max-order.
    (define (draw-slide ctx page slide x0 y0 scale max-order)
      (let* ((design (ctx-design ctx))
             (layout (find-layout design (jr slide "layout")))
             (to-page (lambda (sx sy) (list (+ x0 (* scale sx)) (+ y0 (* scale sy))))))
        (pdf-with-state page
          (lambda ()
            (pdf-transform page scale 0 0 scale x0 y0)
            (pdf-rect page 0 0 SLIDE-W SLIDE-H)
            (pdf-clip page)
            (pdf-end-path page)
            (set-fill! page (rgb ctx (or (jr slide "background") "background")))
            (pdf-rect page 0 0 SLIDE-W SLIDE-H)
            (pdf-fill page)
            (when layout
              (vector-for-each (lambda (d) (draw-element ctx page #f d #t to-page))
                               (jr layout "decorations" #())))
            (for-each (lambda (f) (draw-element ctx page #f f #t to-page))
                      (footer-elements (ctx-doc ctx) design (slide-index (ctx-doc ctx) slide)
                                       (ctx-today ctx)))
            (vector-for-each
             (lambda (el)
               (let ((b (jr el "build")))
                 (unless (and b (> (jr b "order" 0) max-order))
                   (draw-element ctx page layout el #f to-page))))
             (jr slide "elements" #()))))
        ;; A thin frame on handouts, where the slide is not the page.
        #t))

    (define (slide-index doc slide)
      (let ((slides (doc-slides doc)))
        (let loop ((i 0))
          (if (eq? (vector-ref slides i) slide) i (loop (+ i 1))))))

    ;; --- notes ----------------------------------------------------------

    ;; Notes as lines for a column of width w at size points: a list of
    ;; (y . line) from the top, and the total height.
    (define (layout-notes ctx notes w size)
      (if (not notes)
          (values '() 0)
          (let ((plain-ctx (make-ctx (ctx-pdf ctx) (ctx-regular ctx) (ctx-black ctx) (ctx-code ctx)
                                     notes-design (ctx-data-dir ctx) (ctx-images ctx) #f "")))
            (layout-rich-text plain-ctx notes
                              `(("font" . "body") ("size" . ,size) ("color" . "#222222"))
                              w))))

    ;; Notes are set as page text: black on white, regular weight.
    (define notes-design
      `(("colors" . (("text" . "#222222")))
        ("fonts" . (("body" . (("weight" . 400)))))
        ("text" . (("bullet" . "•") ("lineHeight" . 1.35) ("paraSpacing" . 0.5)))))

    ;; --- pages ----------------------------------------------------------

    (define A4-W 595.28)
    (define A4-H 841.89)
    (define MARGIN 40)

    (define (slide-frame page x y w h)
      (pdf-with-state page
        (lambda ()
          (pdf-set-stroke-gray page 0.75)
          (pdf-set-line-width page 0.5)
          (pdf-rect page x y w h)
          (pdf-stroke page))))

    (define (small-text ctx page x y text . align)
      (let* ((size 8)
             (face (ctx-regular ctx))
             (w (pdf-text-width (face-font face) size text (face-kern face)))
             (x (if (and (pair? align) (eq? (car align) 'right)) (- x w) x)))
        (pdf-with-state page
          (lambda ()
            (pdf-set-fill-gray page 0.35)
            (pdf-draw-text page (face-font face) size x y text 'kerning (face-kern face))))))

    ;; The pages to draw: (slide . max-order) per page of slides.
    (define (frames doc steps?)
      (let loop ((slides (vector->list (doc-slides doc))) (acc '()))
        (cond
          ((null? slides) (reverse acc))
          ((eq? (jr (car slides) "hidden") #t) (loop (cdr slides) acc))
          (else
           (let* ((s (car slides))
                  (orders (build-orders s)))
             (loop (cdr slides)
                   (if (and steps? (pair? orders))
                       (append (reverse (map (lambda (o) (cons s o)) (cons 0 orders))) acc)
                       (cons (cons s 100000) acc))))))))

    (define (deck->pdf doc design-id title data-dir . opts)
      "Syntax: (deck->pdf doc design-id title data-dir [options])
Library: (app export-pdf)
Description: The deck document as a PDF (bytevector). options is an
  alist: (per-page . 1 | 2 | 4) slides per page (default 1), (notes . #t)
  with the notes, (builds . steps) one page per build step instead of
  the final state."
      (let* ((opts (if (pair? opts) (car opts) '()))
             (opt (lambda (k d) (let ((p (assq k opts))) (if p (cdr p) d))))
             (per-page (opt 'per-page 1))
             (notes? (opt 'notes #f))
             (steps? (eq? (opt 'builds 'final) 'steps))
             (pdf (make-pdf))
             (design (find-design design-id))
             (family (family-of design))
             (ctx (make-ctx pdf
                            (embed-face pdf family (cadr family))
                            (embed-face pdf family (caddr family))
                            (code-faces pdf design)
                            design
                            data-dir
                            (make-hash-table equal?)
                            doc
                            (date->string (current-date) "~d.~m.~Y")))
             (fs (frames doc steps?)))
        (pdf-set-metadata! pdf 'title title)
        (pdf-set-metadata! pdf 'creator "Folien")
        (cond
          ((and (= per-page 1) (not notes?))
           (for-each (lambda (f)
                       (let ((page (pdf-add-page! pdf 960 540)))
                         (draw-slide ctx page (car f) 0 0 0.5 (cdr f))))
                     fs))
          ((= per-page 1) (notes-pages ctx pdf fs title))
          (else (handout-pages ctx pdf fs title per-page notes?)))
        (pdf->bytevector pdf)))

    ;; One slide per A4 page with its notes below; long notes continue
    ;; on further pages.
    (define (notes-pages ctx pdf fs title)
      (let* ((w (- A4-W (* 2 MARGIN)))
             (sh (* w (/ SLIDE-H SLIDE-W)))
             (count (length fs)))
        (let loop ((fs fs) (n 1))
          (unless (null? fs)
            (let* ((page (pdf-add-page! pdf A4-W A4-H))
                   (top (- A4-H MARGIN 10))
                   (slide-y (- top sh)))
              (draw-slide ctx page (car (car fs)) MARGIN slide-y (/ w SLIDE-W) (cdr (car fs)))
              (slide-frame page MARGIN slide-y w sh)
              (footer ctx page title n count)
              (call-with-values
                (lambda () (layout-notes ctx (jr (car (car fs)) "notes") w 11))
                (lambda (placed total)
                  (let more ((placed placed) (page page) (top (- slide-y 24)) (shift 0))
                    (let* ((room (- top (+ MARGIN 20)))
                           (fits (filter-placed placed shift room))
                           (rest (list-tail placed (length fits))))
                      (draw-text-lines ctx page (map (lambda (p) (cons (- (car p) shift) (cdr p))) fits)
                                       top #f MARGIN)
                      (when (pair? rest)
                        (let ((next (pdf-add-page! pdf A4-W A4-H)))
                          (footer ctx next title n count)
                          (more rest next (- A4-H MARGIN 10) (car (car rest)))))))))
              (loop (cdr fs) (+ n 1)))))))

    ;; The leading lines of placed whose bottom is within room (after
    ;; subtracting shift from their y).
    (define (filter-placed placed shift room)
      (let loop ((ps placed) (acc '()))
        (if (or (null? ps)
                (> (+ (- (car (car ps)) shift) (line-height (cadr (car ps)))) room))
            (reverse acc)
            (loop (cdr ps) (cons (car ps) acc)))))

    (define (footer ctx page title n count)
      (small-text ctx page MARGIN 22 title)
      (small-text ctx page (- A4-W MARGIN) 22
                  (string-append "Folie " (number->string n) " / " (number->string count)) 'right))

    ;; 2 or 4 slides per A4 page: stacked (2) or a 2 x 2 grid (4) without
    ;; notes; with notes, a row per slide, the notes beside it.
    (define (handout-pages ctx pdf fs title per-page notes?)
      (let* ((inner-w (- A4-W (* 2 MARGIN)))
             (inner-h (- A4-H (* 2 MARGIN) 20))
             (gap 18)
             (rows (if (and (= per-page 4) (not notes?)) 2 per-page))
             (cols (if (and (= per-page 4) (not notes?)) 2 1))
             (cell-w (/ (- inner-w (* (- cols 1) gap)) cols))
             (cell-h (/ (- inner-h (* (- rows 1) gap)) rows))
             (slide-w (if notes?
                          (min (* cell-w 0.55) (* cell-h (/ SLIDE-W SLIDE-H)))
                          (min cell-w (* cell-h (/ SLIDE-W SLIDE-H)))))
             (slide-h (* slide-w (/ SLIDE-H SLIDE-W)))
             ;; Without notes the slides sit in a compact grid, centred
             ;; on the page; with notes each row takes its share.
             (pitch (if notes? (+ cell-h gap) (+ slide-h (* 2 gap))))
             (top0 (if notes?
                       (- A4-H MARGIN)
                       (+ (/ A4-H 2) (/ (+ (* rows slide-h) (* (- rows 1) 2 gap)) 2))))
             (pages (quotient (+ (length fs) (- per-page 1)) per-page)))
        (let loop ((fs fs) (k 0) (page #f) (pn 0))
          (unless (null? fs)
            (let* ((new? (= 0 (remainder k per-page)))
                   (page (if new? (pdf-add-page! pdf A4-W A4-H) page))
                   (pn (if new? (+ pn 1) pn))
                   (i (remainder k per-page))
                   (row (quotient i cols))
                   (col (remainder i cols))
                   (cell-x (+ MARGIN (* col (+ cell-w gap))))
                   (cell-top (- top0 (* row pitch)))
                   (sx (if notes? cell-x (+ cell-x (/ (- cell-w slide-w) 2))))
                   (sy (- cell-top slide-h)))
              (when new?
                (small-text ctx page MARGIN 22 title)
                (small-text ctx page (- A4-W MARGIN) 22
                            (string-append "Seite " (number->string pn) " / " (number->string pages)) 'right))
              (draw-slide ctx page (car (car fs)) sx sy (/ slide-w SLIDE-W) (cdr (car fs)))
              (slide-frame page sx sy slide-w slide-h)
              (when notes?
                (let ((nw (- cell-w slide-w gap)))
                  (call-with-values
                    (lambda () (layout-notes ctx (jr (car (car fs)) "notes") nw 9))
                    (lambda (placed total)
                      (draw-text-lines ctx page (filter-placed placed 0 cell-h)
                                       cell-top #f (+ sx slide-w gap))))))
              (loop (cdr fs) (+ k 1) page pn))))))))
