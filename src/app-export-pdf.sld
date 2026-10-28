;; (app export-pdf) — a deck as PDF, drawn natively with (scm pdf).
;;
;; It draws what static/js/render.js shows: the same document model,
;; layouts and design tokens, text broken into lines as the browser does
;; it ((scm text layout) with the same rules: pre-wrap, CSS line boxes,
;; the renderer's paragraph spacing and list indents), in the same glyphs
;; (Inter from (scm fonts inter), OpenType features applied, written as
;; TrueType and embedded), kerned. Bold and heading text use Inter
;; Black, italics are slanted. Text is real text: selectable, searchable,
;; web links clickable.
;;
;; Layouts: 1, 2 or 4 slides per page, with or without the notes. One
;; slide per page without notes gives 960 x 540 pt pages (PowerPoint's
;; 16:9); the others are A4 portrait handouts. Builds show their final
;; state, or one page per step. Hidden slides are left out. Videos show
;; their poster frame.

(define-library (app export-pdf)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme inexact)
          (srfi 69)
          (scm fs)
          (scm pdf)
          (scm truetype)
          (scm fonts inter)
          (scm text layout)
          (scm svg raster)
          (only (scm raster) canvas-width canvas->png)
          (app designs)
          (app model)
          (app assets))
  (export deck->pdf)
  (begin

    (define SLIDE-W 1920)
    (define SLIDE-H 1080)

    ;; --- fonts --------------------------------------------------------
    ;; The TrueType files are made once per process.

    (define ttf-cache #f)
    (define (ttf-files)
      (unless ttf-cache
        (set! ttf-cache (cons (font->truetype inter-regular "Inter")
                              (font->truetype inter-black "Inter" "Black"))))
      ttf-cache)

    (define (kerning-of tt)
      (let ((k (/ 1000.0 (font-units-per-em tt))))
        (lambda (a b) (* k (font-kerning tt a b)))))

    (define regular-kerning (kerning-of inter-regular))
    (define black-kerning (kerning-of inter-black))

    ;; Inter's extent above and below the baseline, per size unit.
    (define ascent-factor (/ (font-ascent inter-regular) (font-units-per-em inter-regular)))
    (define descent-factor (/ (- (font-descent inter-regular)) (font-units-per-em inter-regular)))

    ;; Everything a drawing needs.
    (define-record-type ctx
      (make-ctx pdf regular black design data-dir images)
      ctx?
      (pdf ctx-pdf)
      (regular ctx-regular)
      (black ctx-black)
      (design ctx-design)
      (data-dir ctx-data-dir)
      (images ctx-images))       ; sha -> pdf image or 'none

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
    (define (make-run ctx text black? size color italic? underline? link)
      (let* ((font (if black? (ctx-black ctx) (ctx-regular ctx)))
             (kern (if black? black-kerning regular-kerning)))
        (make-text-run text
                       (lambda (s) (pdf-text-width font size s kern))
                       size (* ascent-factor size) (* descent-factor size)
                       `((font . ,font) (kern . ,kern) (size . ,size) (color . ,color)
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
                     (strut (make-run ctx "" base-black? base-size base-color #f #f #f))
                     (trs (map (lambda (r)
                                 (make-run ctx (jr r "text")
                                           (or base-black? (eq? (jr r "b") #t))
                                           (or (jr r "size") base-size)
                                           (if (jr r "color") (rgb ctx (jr r "color")) base-color)
                                           (eq? (jr r "i") #t)
                                           (or (eq? (jr r "u") #t) (and (jr r "link") #t))
                                           (jr r "link")))
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
                          (link-box x (- baseline (* descent-factor size))
                                    (+ x (car width)) (+ baseline (* ascent-factor size)))
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

    ;; The embedded image of an asset (each once per document), or #f
    ;; when it cannot be drawn (missing, a format the PDF cannot take).
    ;; svg-size: the pixel size to rasterize an SVG at.
    (define (asset-image ctx sha svg-size)
      (let ((cached (hash-table-ref/default (ctx-images ctx) sha #f)))
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
                                  ((equal? mime "image/jpeg") (pdf-embed-jpeg (ctx-pdf ctx) bv))
                                  ((equal? mime "image/png") (pdf-embed-png (ctx-pdf ctx) bv))
                                  ((equal? mime "image/svg+xml")
                                   (pdf-embed-png (ctx-pdf ctx) (svg-png (utf8->string bv) svg-size)))
                                  (else #f)))))))
             (hash-table-set! (ctx-images ctx) sha (or img 'none))
             img)))))

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
             (img (and sha (asset-image ctx sha (* 2 (max w h))))))
        (when img
          (let* ((iw (pdf-image-width img))
                 (ih (pdf-image-height img))
                 (cover? (equal? (jr el "fit") "cover"))
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
               (let ((text (jr el "text")))
                 (when text
                   (call-with-values
                     (lambda () (layout-rich-text ctx text style w))
                     (lambda (placed total)
                       (let* ((valign (or (jr style "valign") "top"))
                              (offset (cond ((equal? valign "middle") (/ (- h total) 2))
                                            ((equal? valign "bottom") (- h total))
                                            (else 0)))
                              (link-box (and (= rot 0)
                                             (lambda (x0 y0 x1 y1)
                                               ;; local -> slide -> page
                                               (let ((a (to-page (+ x x0) (- (+ y h) y0)))
                                                     (b (to-page (+ x x1) (- (+ y h) y1))))
                                                 (list (car a) (cadr a) (car b) (cadr b)))))))
                         (draw-text-lines ctx page placed (- h offset) link-box)))))))
              ((equal? type "shape")
               (draw-shape ctx page (string->symbol (or (jr el "shape") "rect")) w h style))
              ((equal? type "line") (draw-line ctx page el w h style))
              ((or (equal? type "image") (equal? type "video")) (draw-image ctx page el w h))
              (else #f))))))

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
            (vector-for-each
             (lambda (el)
               (let ((b (jr el "build")))
                 (unless (and b (> (jr b "order" 0) max-order))
                   (draw-element ctx page layout el #f to-page))))
             (jr slide "elements" #()))))
        ;; A thin frame on handouts, where the slide is not the page.
        #t))

    ;; --- notes ----------------------------------------------------------

    ;; Notes as lines for a column of width w at size points: a list of
    ;; (y . line) from the top, and the total height.
    (define (layout-notes ctx notes w size)
      (if (not notes)
          (values '() 0)
          (let ((plain-ctx (make-ctx (ctx-pdf ctx) (ctx-regular ctx) (ctx-black ctx)
                                     notes-design (ctx-data-dir ctx) (ctx-images ctx))))
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
             (w (pdf-text-width (ctx-regular ctx) size text regular-kerning))
             (x (if (and (pair? align) (eq? (car align) 'right)) (- x w) x)))
        (pdf-with-state page
          (lambda ()
            (pdf-set-fill-gray page 0.35)
            (pdf-draw-text page (ctx-regular ctx) size x y text 'kerning regular-kerning)))))

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
             (ttf (ttf-files))
             (ctx (make-ctx pdf
                            (pdf-embed-truetype-font pdf (car ttf) "Inter")
                            (pdf-embed-truetype-font pdf (cdr ttf) "Inter-Black")
                            (find-design design-id)
                            data-dir
                            (make-hash-table equal?)))
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
