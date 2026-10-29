;; (app export-pptx) — a deck as PowerPoint file, with
;; (scm ooxml presentation).
;;
;; Every element becomes a positioned PowerPoint object as the renderer
;; draws it: text boxes with the deck's text (fonts, sizes, colours,
;; bullets and numbering, links), tables, shapes, lines, pictures (fit and crop),
;; MP4 videos (other videos as their poster frame); layouts' decorations
;; become shapes of each slide, the footer fields too (slide number and
;; automatic date as PowerPoint fields). Slide transitions and builds become
;; PowerPoint transitions and animations, notes the slide notes. Hidden
;; slides are left out.
;;
;; The text is set in the design's family (Inter or Roboto Slab), headings
;; and bold runs bold (Inter's bold where the web shows Inter Black):
;; PowerPoint shows it as designed where the font is installed, otherwise
;; it substitutes a similar font, and line breaks may then differ. Runs
;; marked as code name the design's code font (JetBrains Mono).

(define-library (app export-pptx)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scheme inexact)
          (scm fs)
          (only (srfi 19) current-date date->string)
          (scm ooxml presentation)
          (scm svg raster)
          (app designs)
          (app model)
          (app assets)
          (app images))
  (export deck->pptx)
  (begin

    (define EMU 6350)                    ; per slide unit (1920 units = 13.33 in)
    (define (emu x) (exact (round (* x EMU))))
    (define (pt px) (/ px 2))            ; slide units to points

    ;; Per family its line height (ascent + descent) per em: PowerPoint's
    ;; single spacing; CSS line-height 1.2 is that times 1.2 / this.
    (define family-lines
      '(("Inter" . 1.2099609375)
        ("Roboto Slab" . 1.31884765625)))

    ;; The design's family and its line height.
    (define (family-of design)
      (let* ((body (jr (design-ref design "fonts") "body"))
             (f (assoc (or (and body (jr body "family")) "Inter") family-lines)))
        (if f f (car family-lines))))

    (define (jr obj key . d) (apply jref obj key d))

    ;; --- colours and elements ----------------------------------------------

    (define (hex design c)
      (cond
        ((or (not c) (equal? c "none")) #f)
        ((and (string? c) (= (string-length c) 7) (char=? (string-ref c 0) #\#))
         (string-upcase (substring c 1 7)))
        (else (hex design (jr (design-ref design "colors") c "#000000")))))

    (define (merge-style a b)
      (append (or b '())
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

    (define (resolve layout el)
      (let* ((ph (find-placeholder layout (jr el "placeholder")))
             (pick (lambda (k d) (let ((v (jr el k))) (if v v (if ph (jr ph k d) d))))))
        (list (pick "x" 0) (pick "y" 0) (pick "w" 100) (pick "h" 100)
              (or (jr el "rot") 0)
              (merge-style (and ph (jr ph "style" '())) (jr el "style" '())))))

    ;; --- text -----------------------------------------------------------

    (define (heading-font? design token)
      (let ((f (jr (design-ref design "fonts") (or token "body"))))
        (>= (if f (jr f "weight" 400) 400) 700)))

    (define (web-link? s)
      (let ((l (string-downcase s)))
        (or (string-prefix? "https://" l) (string-prefix? "http://" l) (string-prefix? "mailto:" l))))

    (define (string-prefix? p s)
      (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

    ;; Rich text as paragraphs for the writer. base: the box's style.
    (define (paragraphs design text base)
      (let* ((settings (design-ref design "text"))
             (lh (jr settings "lineHeight" 1.2))
             (spacing (jr settings "paraSpacing" 0.35))
             (bullet (jr settings "bullet" "•"))
             (base-size (or (jr base "size") 40))
             (base-black? (heading-font? design (jr base "font")))
             (base-color (hex design (or (jr base "color") "text")))
             (family (family-of design))
             (code-family (let ((c (jr (design-ref design "fonts") "code")))
                            (if c (jr c "family") (car family))))
             (base-align (string->symbol (or (jr base "align") "left")))
             (paras (vector->list (jr text "paragraphs" #())))
             (n (length paras)))
        (let loop ((ps paras) (i 0) (acc '()))
          (if (null? ps)
              (reverse acc)
              (let* ((p (car ps))
                     (runs (filter-runs (vector->list (jr p "runs" #()))))
                     (first-size (or (and (pair? runs) (jr (car runs) "size")) base-size))
                     (kind (jr p "list" "none"))
                     (level (jr p "level" 0))
                     (list? (not (equal? kind "none"))))
                (loop (cdr ps) (+ i 1)
                      (cons
                       `((align . ,(string->symbol (or (jr p "align") (symbol->string base-align))))
                         (bullet . ,(cond ((equal? kind "number") 'number)
                                          (list? bullet)
                                          (else #f)))
                         ,@(if list?
                               `((margin-left . ,(emu (* (+ level 1) 1.1 first-size)))
                                 (indent . ,(- (emu (* 1.1 first-size)))))
                               '())
                         (line-spacing . ,(/ lh (cdr family)))
                         (space-after . ,(if (< i (- n 1)) (pt (* spacing first-size)) 0))
                         (runs
                          . ,(if (null? runs)
                                 (list `((text . "") (size . ,(pt base-size))
                                         (font . ,(car family)) (bold . ,base-black?)))
                                 (map (lambda (r)
                                        (let ((black? (or base-black? (eq? (jr r "b") #t)))
                                              (link (jr r "link")))
                                          `((text . ,(jr r "text"))
                                            (size . ,(pt (or (jr r "size") base-size)))
                                            (font . ,(if (eq? (jr r "code") #t) code-family (car family)))
                                            (bold . ,black?)
                                            (italic . ,(eq? (jr r "i") #t))
                                            (underline . ,(or (eq? (jr r "u") #t) (and link #t)))
                                            (color . ,(if (jr r "color") (hex design (jr r "color")) base-color))
                                            ,@(let ((f (jr r "field")))
                                                (if f `((field . ,(string->symbol f))) '()))
                                            ,@(if (and link (web-link? link)) `((link . ,link)) '()))))
                                      runs))))
                       acc)))))))

    (define (filter-runs runs)
      (let loop ((rs runs))
        (cond ((null? rs) '())
              ((equal? (jr (car rs) "text" "") "") (loop (cdr rs)))
              (else (cons (car rs) (loop (cdr rs)))))))

    ;; --- images ---------------------------------------------------------

    (define (read-bytes path)
      (let* ((p (open-binary-input-file path))
             (bv (read-bytevector (file-size path) p)))
        (close-port p)
        (if (eof-object? bv) (bytevector) bv)))

    (define (u16be bv i) (+ (* 256 (bytevector-u8-ref bv i)) (bytevector-u8-ref bv (+ i 1))))
    (define (u32be bv i) (+ (* 65536 (u16be bv i)) (u16be bv (+ i 2))))

    ;; (width . height) in pixels of a PNG, JPEG or GIF, or #f.
    (define (image-size bv mime)
      (guard (e (#t #f))
        (cond
          ((equal? mime "image/png") (cons (u32be bv 16) (u32be bv 20)))
          ((equal? mime "image/gif")
           (cons (+ (bytevector-u8-ref bv 6) (* 256 (bytevector-u8-ref bv 7)))
                 (+ (bytevector-u8-ref bv 8) (* 256 (bytevector-u8-ref bv 9)))))
          ((equal? mime "image/jpeg")
           ;; the first start-of-frame marker
           (let loop ((i 2))
             (and (< (+ i 9) (bytevector-length bv))
                  (= (bytevector-u8-ref bv i) #xFF)
                  (let ((m (bytevector-u8-ref bv (+ i 1))))
                    (if (and (>= m #xC0) (<= m #xCF) (not (memv m '(#xC4 #xC8 #xCC))))
                        (cons (u16be bv (+ i 7)) (u16be bv (+ i 5)))
                        (loop (+ i 2 (u16be bv (+ i 2)))))))))
          (else #f))))

    (define (head-mime path)
      (let* ((p (open-binary-input-file path))
             (bv (read-bytevector 1024 p)))
        (close-port p)
        (and (bytevector? bv) (sniff-mime bv))))

    ;; A picture source for an asset in a box of w x h slide units:
    ;; (source mime width height key), or #f. PNGs and JPEGs upright and
    ;; downscaled to what the slide shows ((app images)); SVGs rasterized
    ;; at twice their element size.
    (define (picture-source data-dir sha w h cover?)
      (let ((path (and (valid-sha? sha) (asset-file data-dir sha))))
        (and path (file-exists? path)
             (let ((mime (head-mime path)))
               (cond
                 ((raster-mime? mime)
                  (let* ((bv (read-bytes path))
                         (out (export-image bv mime w h cover?))
                         (same? (eq? (car out) bv))
                         (size (image-size (car out) (cdr out))))
                    (and size
                         (list (if same? path (car out)) (cdr out) (car size) (cdr size)
                               (if same? sha (string-append sha "-" (number->string (car size))))))))
                 ((equal? mime "image/gif")
                  (let ((size (image-size (read-head path) mime)))
                    (and size (list path mime (car size) (cdr size) sha))))
                 ((equal? mime "image/svg+xml")
                  (guard (e (#t #f))
                    (let* ((text (utf8->string (read-bytes path)))
                           (png (svg->png text `((scale . 2)))))
                      (let ((size (image-size png "image/png")))
                        (and size (list png "image/png" (car size) (cdr size) (string-append sha ".png")))))))
                 (else #f))))))

    (define (read-head path)
      (let* ((p (open-binary-input-file path))
             (bv (read-bytevector (min 65536 (file-size path)) p)))
        (close-port p)
        (if (eof-object? bv) (bytevector) bv)))

    ;; Frame and crop of a picture in a box (contain or cover).
    (define (fit x y w h iw ih cover?)
      (if cover?
          (let* ((box (/ w h)) (img (/ iw ih)))
            (if (> img box)
                (let ((cut (/ (- 1 (/ box img)) 2))) (list x y w h (list cut 0 cut 0)))
                (let ((cut (/ (- 1 (/ img box)) 2))) (list x y w h (list 0 cut 0 cut)))))
          (let* ((s (min (/ w iw) (/ h ih))) (dw (* s iw)) (dh (* s ih)))
            (list (+ x (/ (- w dw) 2)) (+ y (/ (- h dh) 2)) dw dh #f))))

    ;; --- slides -----------------------------------------------------------

    (define (build-of el)
      (let ((b (jr el "build")))
        (and b (jr b "order")
             (list (jr b "order")
                   (let ((e (jr b "effect" "appear")))
                     (cond ((member e '("fade" "zoom")) 'fade)
                           ((member e '("fly-left" "fly-right" "fly-up" "fly-down")) (string->symbol e))
                           (else 'appear)))))))

    (define (shape-kind s)
      (cond ((member s '("rounded" "ellipse" "triangle" "arrow" "chevron")) (string->symbol s))
            (else 'rect)))

    (define table-pad-x 16)              ; as render.js
    (define table-pad-y 10)

    (define (add-element! slide design data-dir layout el)
      (let* ((r (resolve layout el))
             (x (list-ref r 0)) (y (list-ref r 1)) (w (list-ref r 2)) (h (list-ref r 3))
             (rot (list-ref r 4)) (style (list-ref r 5))
             (type (jr el "type"))
             (opacity (jr style "opacity"))
             (build (build-of el))
             (common (append (if build `((build . ,build)) '())
                             (if (= rot 0) '() `((rotation . ,rot))))))
        (cond
          ((equal? type "text")
           (let ((fill (hex design (jr style "fill"))))
             (slide-add-shape! slide (if fill 'rect 'text) (emu x) (emu y) (emu w) (emu h)
                               `(,@common
                                 ,@(if fill `((fill . ,fill)) '())
                                 ,@(if opacity `((fill-alpha . ,opacity)) '())
                                 (text . ,(paragraphs design (or (jr el "text") '(("paragraphs" . #()))) style))
                                 (anchor . ,(string->symbol (or (jr style "valign") "top")))))))
          ((equal? type "table")
           (let* ((table (jr el "table"))
                  (header? (eq? (jr table "header") #t))
                  (header-style (merge-style style '(("font" . "heading") ("color" . "on-accent"))))
                  (rows (vector->list (jr table "rows" #()))))
             ;; as render.js: header on the accent colour, banded rows,
             ;; text centred vertically
             (slide-add-table! slide (emu x) (emu y) (emu w) (emu h)
                               (let loop ((rows rows) (i 0) (acc '()))
                                 (if (null? rows)
                                     (reverse acc)
                                     (let ((fill (hex design (cond ((and header? (= i 0)) "accent")
                                                                   ((odd? (- i (if header? 1 0))) "light")
                                                                   (else "background"))))
                                           (st (if (and header? (= i 0)) header-style style)))
                                       (loop (cdr rows) (+ i 1)
                                             (cons (map (lambda (cell)
                                                          `((text . ,(paragraphs design cell st))
                                                            (fill . ,fill)
                                                            (anchor . middle)))
                                                        (vector->list (car rows)))
                                                   acc)))))
                               `(,@(if build `((build . ,build)) '())
                                 (header . ,header?)
                                 (margins . ,(map emu (list table-pad-x table-pad-y table-pad-x table-pad-y)))))))
          ((equal? type "shape")
           (let ((stroke (hex design (or (jr style "stroke") "none")))
                 (sw (or (jr style "strokeWidth") 0)))
             (slide-add-shape! slide (shape-kind (or (jr el "shape") "rect")) (emu x) (emu y) (emu w) (emu h)
                               `(,@common
                                 (fill . ,(hex design (or (jr style "fill") "accent")))
                                 ,@(if opacity `((fill-alpha . ,opacity)) '())
                                 ,@(if (and stroke (> sw 0)) `((line . ,stroke) (line-width . ,(emu sw))) '())))))
          ((equal? type "line")
           (slide-add-line! slide (emu x) (emu y) (emu w) (emu h)
                            `(,@(if build `((build . ,build)) '())
                              (color . ,(or (hex design (or (jr style "stroke") "text")) "000000"))
                              (width . ,(emu (or (jr style "strokeWidth") 4)))
                              (flip . ,(eq? (jr el "flip") #t)))))
          ((or (equal? type "image") (equal? type "video"))
           (let* ((video? (equal? type "video"))
                  (video-path (and video? (valid-sha? (jr el "asset")) (asset-file data-dir (jr el "asset"))))
                  (mp4? (and video-path (file-exists? video-path) (equal? (head-mime video-path) "video/mp4")))
                  (pic (picture-source data-dir (if video? (jr el "poster") (jr el "asset")) w h
                                       (equal? (jr el "fit") "cover"))))
             (when pic
               (let* ((f (fit x y w h (list-ref pic 2) (list-ref pic 3) (equal? (jr el "fit") "cover")))
                      (opts `(,@common
                              (key . ,(list-ref pic 4))
                              ,@(if (list-ref f 4) `((crop . ,(list-ref f 4))) '())
                              ,@(if opacity `((alpha . ,opacity)) '())
                              ,@(if (jr el "alt") `((description . ,(jr el "alt"))) '()))))
                 (if mp4?
                     (slide-add-video! slide video-path (car pic) (cadr pic)
                                       (emu (list-ref f 0)) (emu (list-ref f 1))
                                       (emu (list-ref f 2)) (emu (list-ref f 3))
                                       `((poster-key . ,(list-ref pic 4))
                                         (key . ,(jr el "asset"))
                                         ,@(without-key opts)))
                     (slide-add-picture! slide (car pic) (cadr pic)
                                         (emu (list-ref f 0)) (emu (list-ref f 1))
                                         (emu (list-ref f 2)) (emu (list-ref f 3)) opts))))))
          (else #f))))

    ;; Options without their key (the poster's key is a picture's).
    (define (without-key opts)
      (let loop ((os opts))
        (cond ((null? os) '())
              ((eq? (car (car os)) 'key) (loop (cdr os)))
              (else (cons (car os) (loop (cdr os)))))))

    (define (deck->pptx doc design-id title data-dir)
      "Syntax: (deck->pptx doc design-id title data-dir)
Library: (app export-pptx)
Description: The deck document as a PowerPoint file (bytevector)."
      (let ((design (find-design design-id))
            (p (make-presentation))
            (today (date->string (current-date) "~d.~m.~Y"))
            (auto-date? (equal? (jr (jr doc "footer" '()) "date") "auto")))
        (presentation-set-title! p title)
        (vector-for-each
         (lambda (s index)
           (unless (eq? (jr s "hidden") #t)
             (let ((slide (presentation-add-slide! p))
                   (layout (find-layout design (jr s "layout"))))
               (slide-set-background! slide (hex design (or (jr s "background") "background")))
               (let ((tr (jr s "transition")))
                 (when (and tr (not (equal? (jr tr "type") "none")))
                   (slide-set-transition! slide (string->symbol (jr tr "type")) (jr tr "duration" 600))))
               (when layout
                 (vector-for-each (lambda (d) (add-element! slide design data-dir #f d))
                                  (jr layout "decorations" #())))
               (for-each (lambda (f) (add-element! slide design data-dir #f (field-element f auto-date?)))
                         (footer-elements doc design index today))
               (vector-for-each (lambda (el) (add-element! slide design data-dir layout el))
                                (jr s "elements" #()))
               (let ((notes (jr s "notes")))
                 (when notes
                   (slide-set-notes! slide
                     (paragraphs design notes '(("size" . 24) ("color" . "#000000") ("font" . "body")))))))))
         (doc-slides doc)
         (let ((n (vector-length (doc-slides doc))))
           (let loop ((i (- n 1)) (acc '()))
             (if (< i 0) (list->vector acc) (loop (- i 1) (cons i acc))))))
        (presentation->bytevector p)))

    ;; A footer element whose number or automatic date is a PowerPoint
    ;; field (a fixed date stays text).
    (define (field-element f auto-date?)
      (let ((kind (cond ((equal? (jr f "field") "number") "slide-number")
                        ((and auto-date? (equal? (jr f "field") "date")) "date")
                        (else #f))))
        (if (not kind)
            f
            (map (lambda (p)
                   (if (equal? (car p) "text")
                       `("text" ("paragraphs" . #((("runs" . #((("text" . ,(text-of f))
                                                                ("field" . ,kind))))))))
                       p))
                 f))))

    (define (text-of f)
      (jr (vector-ref (jr (vector-ref (jr (jr f "text") "paragraphs") 0) "runs") 0) "text"))))
