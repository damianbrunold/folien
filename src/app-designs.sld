;; (app designs) — the slide designs: theme tokens (colours, fonts) and the
;; layouts with their placeholders. Defined once here; the browser gets them
;; as JSON (/api/designs) for the renderer, and the PDF and PPTX exporters
;; read them directly.
;;
;; Everything is in JSON shape (alists with string keys, vectors for
;; arrays), in slide coordinates: a 16:9 slide is 1920 x 1080 units, origin
;; top left. Elements in a deck refer to colours and fonts by token
;; ("accent", "heading"), so switching a deck's design restyles it.
;;
;; A placeholder element in a deck names its role ("title", "body", ...)
;; and inherits geometry and text style from the slide's layout unless it
;; overrides them.
;;
;; The font tokens: "heading" and "body" for the layouts' text, "code"
;; for runs marked as code (the same monospaced family in every design).
;;
;; "footer" places the deck's footer fields (see "footer" in (app model)):
;; a box and text style each for the date, the footer text and the slide
;; number, on every layout. A layout's "footerColor" recolours them where
;; its background calls for it.

(define-library (app designs)
  (import (scheme base))
  (export designs
          design-ids
          find-design
          design-ref
          find-layout
          default-design-id)
  (begin

    (define default-design-id "folien")

    ;; --- building blocks ----------------------------------------------

    (define (box x y w h) `(("x" . ,x) ("y" . ,y) ("w" . ,w) ("h" . ,h)))

    ;; A text style: font token, size in slide units, colour token,
    ;; horizontal and vertical alignment.
    (define (text-style font size color align valign)
      `(("font" . ,font) ("size" . ,size) ("color" . ,color)
        ("align" . ,align) ("valign" . ,valign)))

    (define (placeholder role label geometry style)
      `(("role" . ,role) ("label" . ,label) ,@geometry ("style" . ,style)))

    (define (rect geometry fill)
      `(("type" . "shape") ("shape" . "rect") ,@geometry
        ("style" . (("fill" . ,fill) ("stroke" . "none")))))

    (define (layout id name decorations . placeholders)
      `(("id" . ,id)
        ("name" . ,name)
        ("decorations" . ,(list->vector decorations))
        ("placeholders" . ,(list->vector placeholders))))

    ;; A code block's style: the code font on the light tint, with padding.
    (define (code-style size)
      `(("font" . "code") ("size" . ,size) ("color" . "text") ("align" . "left")
        ("valign" . "top") ("fill" . "light") ("pad" . 36)))

    (define (with-footer-color color layout)
      (append layout `(("footerColor" . ,color))))

    ;; The footer fields along the bottom edge: date left, text centred,
    ;; number right, from x0 to the right margin.
    (define (footer-boxes x0 y size)
      (let ((style (lambda (align) (text-style "body" size "muted" align "middle")))
            (w (- 1920 x0 x0)))
        `(("date"   . (,@(box x0 y 400 50) ("style" . ,(style "left"))))
          ("text"   . (,@(box (+ x0 440) y (- w 880) 50) ("style" . ,(style "center"))))
          ("number" . (,@(box (- 1920 x0 400) y 400 50) ("style" . ,(style "right")))))))

    ;; --- design "folien": our own -------------------------------------
    ;; Light, calm, one blue accent; a thin accent bar under the title.

    (define folien-colors
      '(("background" . "#ffffff")
        ("text"       . "#1a1a1a")
        ("muted"      . "#5f6670")
        ("accent"     . "#2563eb")
        ("accent2"    . "#0f766e")
        ("accent3"    . "#c2410c")
        ("light"      . "#eef2ff")
        ("on-accent"  . "#ffffff")))

    ;; "folien-dark": the same layouts on slate. Accents are bright there, so
    ;; text on them is dark.
    (define folien-dark-colors
      '(("background" . "#0f172a")
        ("text"       . "#e5e7eb")
        ("muted"      . "#94a3b8")
        ("accent"     . "#60a5fa")
        ("accent2"    . "#2dd4bf")
        ("accent3"    . "#fb923c")
        ("light"      . "#1e293b")
        ("on-accent"  . "#0f172a")))

    (define code-font '("code" . (("family" . "JetBrains Mono") ("weight" . 400))))

    (define folien-fonts
      `(("heading" . (("family" . "Inter") ("weight" . 900)))
        ("body"    . (("family" . "Inter") ("weight" . 400)))
        ,code-font))

    (define (folien-title-bar) (rect (box 120 236 160 10) "accent"))

    (define folien-layouts
      (vector
       (layout "title" "Titelfolie"
         (list (rect (box 0 0 48 1080) "accent"))
         (placeholder "title" "Titel"
           (box 160 300 1600 300) (text-style "heading" 112 "text" "left" "bottom"))
         (placeholder "subtitle" "Untertitel"
           (box 160 640 1600 200) (text-style "body" 48 "muted" "left" "top")))
       (layout "title-content" "Titel und Inhalt"
         (list (folien-title-bar))
         (placeholder "title" "Titel"
           (box 120 80 1680 150) (text-style "heading" 72 "text" "left" "bottom"))
         (placeholder "body" "Text"
           (box 120 300 1680 680) (text-style "body" 44 "text" "left" "top")))
       (layout "title-code" "Titel und Code"
         (list (folien-title-bar))
         (placeholder "title" "Titel"
           (box 120 80 1680 150) (text-style "heading" 72 "text" "left" "bottom"))
         (placeholder "code" "Code"
           (box 120 300 1680 680) (code-style 32)))
       (layout "two-columns" "Zwei Spalten"
         (list (folien-title-bar))
         (placeholder "title" "Titel"
           (box 120 80 1680 150) (text-style "heading" 72 "text" "left" "bottom"))
         (placeholder "left" "Linke Spalte"
           (box 120 300 800 680) (text-style "body" 40 "text" "left" "top"))
         (placeholder "right" "Rechte Spalte"
           (box 1000 300 800 680) (text-style "body" 40 "text" "left" "top")))
       (with-footer-color "on-accent"
        (layout "section" "Kapitel"
         (list (rect (box 0 0 1920 1080) "accent"))
         (placeholder "title" "Kapiteltitel"
           (box 160 380 1600 220) (text-style "heading" 104 "on-accent" "left" "bottom"))
         (placeholder "subtitle" "Untertitel"
           (box 160 620 1600 160) (text-style "body" 44 "on-accent" "left" "top"))))
       (layout "image-caption" "Bild mit Legende"
         (list (folien-title-bar))
         (placeholder "title" "Titel"
           (box 120 80 1680 150) (text-style "heading" 72 "text" "left" "bottom"))
         (placeholder "image" "Bild"
           (box 120 290 1100 700) (text-style "body" 32 "muted" "center" "middle"))
         (placeholder "body" "Legende"
           (box 1280 290 520 700) (text-style "body" 36 "text" "left" "top")))
       (layout "quote" "Zitat"
         (list (rect (box 120 300 12 400) "accent"))
         (placeholder "body" "Zitat"
           (box 200 280 1520 360) (text-style "heading" 72 "text" "left" "middle"))
         (placeholder "subtitle" "Quelle"
           (box 200 680 1520 120) (text-style "body" 40 "muted" "left" "top")))
       (layout "title-only" "Nur Titel"
         (list (folien-title-bar))
         (placeholder "title" "Titel"
           (box 120 80 1680 150) (text-style "heading" 72 "text" "left" "bottom")))
       (layout "blank" "Leer" '())))

    ;; --- design "zh": Kanton Zürich CI --------------------------------
    ;; After the canton's web design system (see dashboards/docs/design.md):
    ;; Inter Regular and Black, black text on white, the accent blue
    ;; #0070B4, greys. The official logo is not bundled; a deck shows it
    ;; only once static/designs/zh/logo.svg exists (see README).

    (define zh-colors
      '(("background" . "#ffffff")
        ("text"       . "#000000")
        ("muted"      . "#666666")
        ("accent"     . "#0070b4")
        ("accent2"    . "#00407c")
        ("accent3"    . "#d93c1a")
        ("light"      . "#edf5fa")
        ("on-accent"  . "#ffffff")))

    (define zh-fonts
      `(("heading" . (("family" . "Inter") ("weight" . 900)))
        ("body"    . (("family" . "Inter") ("weight" . 400)))
        ,code-font))

    ;; A slim blue band at the top carries the canton's colour on every
    ;; content slide.
    (define (zh-band) (rect (box 0 0 1920 24) "accent"))

    (define zh-layouts
      (vector
       (layout "title" "Titelfolie"
         (list (rect (box 0 0 1920 540) "accent"))
         (placeholder "title" "Titel"
           (box 120 160 1680 340) (text-style "heading" 104 "on-accent" "left" "bottom"))
         (placeholder "subtitle" "Untertitel"
           (box 120 600 1680 220) (text-style "body" 48 "text" "left" "top")))
       (layout "title-content" "Titel und Inhalt"
         (list (zh-band))
         (placeholder "title" "Titel"
           (box 120 90 1680 150) (text-style "heading" 68 "text" "left" "bottom"))
         (placeholder "body" "Text"
           (box 120 290 1680 690) (text-style "body" 42 "text" "left" "top")))
       (layout "title-code" "Titel und Code"
         (list (zh-band))
         (placeholder "title" "Titel"
           (box 120 90 1680 150) (text-style "heading" 68 "text" "left" "bottom"))
         (placeholder "code" "Code"
           (box 120 290 1680 690) (code-style 32)))
       (layout "two-columns" "Zwei Spalten"
         (list (zh-band))
         (placeholder "title" "Titel"
           (box 120 90 1680 150) (text-style "heading" 68 "text" "left" "bottom"))
         (placeholder "left" "Linke Spalte"
           (box 120 290 800 690) (text-style "body" 40 "text" "left" "top"))
         (placeholder "right" "Rechte Spalte"
           (box 1000 290 800 690) (text-style "body" 40 "text" "left" "top")))
       (with-footer-color "on-accent"
        (layout "section" "Kapitel"
         (list (rect (box 0 0 1920 1080) "accent"))
         (placeholder "title" "Kapiteltitel"
           (box 120 380 1680 220) (text-style "heading" 104 "on-accent" "left" "bottom"))
         (placeholder "subtitle" "Untertitel"
           (box 120 620 1680 160) (text-style "body" 44 "on-accent" "left" "top"))))
       (layout "image-caption" "Bild mit Legende"
         (list (zh-band))
         (placeholder "title" "Titel"
           (box 120 90 1680 150) (text-style "heading" 68 "text" "left" "bottom"))
         (placeholder "image" "Bild"
           (box 120 290 1100 700) (text-style "body" 32 "muted" "center" "middle"))
         (placeholder "body" "Legende"
           (box 1280 290 520 700) (text-style "body" 36 "text" "left" "top")))
       (layout "quote" "Zitat"
         (list (zh-band))
         (placeholder "body" "Zitat"
           (box 120 280 1680 360) (text-style "heading" 72 "accent" "left" "middle"))
         (placeholder "subtitle" "Quelle"
           (box 120 680 1680 120) (text-style "body" 40 "muted" "left" "top")))
       (layout "title-only" "Nur Titel"
         (list (zh-band))
         (placeholder "title" "Titel"
           (box 120 90 1680 150) (text-style "heading" 68 "text" "left" "bottom")))
       (layout "blank" "Leer" '())))

    ;; --- designs "slab" and "slab-dark": for talks ---------------------
    ;; Roboto Slab, for technical and conference talks: plain, a ruler
    ;; under the title (a hairline with a short accent mark at its start),
    ;; "›" bullets, one warm accent. Light on paper white, dark on a
    ;; terminal black; the layouts are the same, only the hairline's colour
    ;; (rule) differs.

    (define slab-colors
      '(("background" . "#fbfaf7")
        ("text"       . "#1c1f24")
        ("muted"      . "#5f6672")
        ("accent"     . "#d03f22")
        ("accent2"    . "#1a64d6")
        ("accent3"    . "#8250df")
        ("light"      . "#ebe8e0")
        ("on-accent"  . "#ffffff")))

    (define slab-dark-colors
      '(("background" . "#15171c")
        ("text"       . "#e8e4da")
        ("muted"      . "#949dab")
        ("accent"     . "#ff7a59")
        ("accent2"    . "#6cb6ff")
        ("accent3"    . "#c4a5ff")
        ("light"      . "#262a31")
        ("on-accent"  . "#15171c")))

    (define slab-fonts
      `(("heading" . (("family" . "Roboto Slab") ("weight" . 700)))
        ("body"    . (("family" . "Roboto Slab") ("weight" . 400)))
        ,code-font))

    ;; The ruler at y, from the left margin across the slide.
    (define (slab-ruler y rule)
      (list (rect (box 120 y 1680 2) rule)
            (rect (box 120 (- y 2) 96 6) "accent")))

    (define (slab-layouts rule)
      (let ((ruler (slab-ruler 252 rule))
            (title (placeholder "title" "Titel"
                     (box 120 80 1680 150) (text-style "heading" 64 "text" "left" "bottom"))))
        (vector
         (layout "title" "Titelfolie"
           (cons (rect (box 120 140 28 28) "accent") (slab-ruler 652 rule))
           (placeholder "title" "Titel"
             (box 120 280 1680 330) (text-style "heading" 96 "text" "left" "bottom"))
           (placeholder "subtitle" "Untertitel"
             (box 120 700 1680 200) (text-style "body" 44 "muted" "left" "top")))
         (layout "title-content" "Titel und Inhalt"
           ruler
           title
           (placeholder "body" "Text"
             (box 120 300 1680 680) (text-style "body" 40 "text" "left" "top")))
         (layout "title-code" "Titel und Code"
           ruler
           title
           (placeholder "code" "Code"
             (box 120 300 1680 680) (code-style 32)))
         (layout "two-columns" "Zwei Spalten"
           (cons (rect (box 959 300 2 680) rule) ruler)
           title
           (placeholder "left" "Linke Spalte"
             (box 120 300 790 680) (text-style "body" 38 "text" "left" "top"))
           (placeholder "right" "Rechte Spalte"
             (box 1010 300 790 680) (text-style "body" 38 "text" "left" "top")))
         (with-footer-color "on-accent"
          (layout "section" "Kapitel"
           (list (rect (box 0 0 1920 1080) "accent")
                 (rect (box 120 300 28 28) "on-accent"))
           (placeholder "title" "Kapiteltitel"
             (box 120 380 1680 220) (text-style "heading" 96 "on-accent" "left" "bottom"))
           (placeholder "subtitle" "Untertitel"
             (box 120 620 1680 160) (text-style "body" 44 "on-accent" "left" "top"))))
         (layout "image-caption" "Bild mit Legende"
           ruler
           title
           (placeholder "image" "Bild"
             (box 120 300 1100 690) (text-style "body" 32 "muted" "center" "middle"))
           (placeholder "body" "Legende"
             (box 1280 300 520 690) (text-style "body" 34 "text" "left" "top")))
         (layout "quote" "Zitat"
           (list (rect (box 120 280 8 360) "accent"))
           (placeholder "body" "Zitat"
             (box 180 280 1560 360) (text-style "heading" 64 "text" "left" "middle"))
           (placeholder "subtitle" "Quelle"
             (box 180 680 1560 120) (text-style "body" 38 "muted" "left" "top")))
         (layout "title-only" "Nur Titel"
           ruler
           title)
         (layout "blank" "Leer" '()))))

    ;; --- registry -----------------------------------------------------

    ;; Text settings: the bullet character of lists, line height (times
    ;; the font size) and the space after a paragraph (times the font
    ;; size). The canton allows only dash lists ("Nur Strichlisten").
    (define (text-settings bullet . line-height)
      `(("bullet" . ,bullet)
        ("lineHeight" . ,(if (pair? line-height) (car line-height) 1.2))
        ("paraSpacing" . 0.35)))

    (define (make-design id name colors fonts text footer layouts)
      `(("id" . ,id)
        ("name" . ,name)
        ("size" . #(1920 1080))
        ("colors" . ,colors)
        ("fonts" . ,fonts)
        ("text" . ,text)
        ("footer" . ,footer)
        ("layouts" . ,layouts)))

    (define designs
      (list (make-design "folien" "Folien" folien-colors folien-fonts
                         (text-settings "•") (footer-boxes 120 1006 26) folien-layouts)
            (make-design "folien-dark" "Folien Dunkel" folien-dark-colors folien-fonts
                         (text-settings "•") (footer-boxes 120 1006 26) folien-layouts)
            (make-design "zh" "Kanton Zürich" zh-colors zh-fonts
                         (text-settings "–") (footer-boxes 120 1006 26) zh-layouts)
            (make-design "slab" "Slab" slab-colors slab-fonts
                         (text-settings "›" 1.25) (footer-boxes 120 1006 24)
                         (slab-layouts "#d9d5ca"))
            (make-design "slab-dark" "Slab Dunkel" slab-dark-colors slab-fonts
                         (text-settings "›" 1.25) (footer-boxes 120 1006 24)
                         (slab-layouts "#3a3f48"))))

    (define (design-ref design key)
      (cdr (assoc key design)))

    (define (design-ids)
      "Syntax: (design-ids)
Library: (app designs)
Description: The ids of all designs, default first."
      (map (lambda (d) (design-ref d "id")) designs))

    (define (find-design id)
      "Syntax: (find-design id)
Library: (app designs)
Description: The design with id, or #f."
      (let loop ((ds designs))
        (cond ((null? ds) #f)
              ((equal? (design-ref (car ds) "id") id) (car ds))
              (else (loop (cdr ds))))))

    (define (find-layout design id)
      "Syntax: (find-layout design id)
Library: (app designs)
Description: The layout with id in design, or #f."
      (let ((ls (design-ref design "layouts")))
        (let loop ((i 0))
          (cond ((= i (vector-length ls)) #f)
                ((equal? (design-ref (vector-ref ls i) "id") id) (vector-ref ls i))
                (else (loop (+ i 1)))))))))
