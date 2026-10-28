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

    (define folien-fonts
      '(("heading" . (("family" . "Inter") ("weight" . 900)))
        ("body"    . (("family" . "Inter") ("weight" . 400)))))

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
       (layout "two-columns" "Zwei Spalten"
         (list (folien-title-bar))
         (placeholder "title" "Titel"
           (box 120 80 1680 150) (text-style "heading" 72 "text" "left" "bottom"))
         (placeholder "left" "Linke Spalte"
           (box 120 300 800 680) (text-style "body" 40 "text" "left" "top"))
         (placeholder "right" "Rechte Spalte"
           (box 1000 300 800 680) (text-style "body" 40 "text" "left" "top")))
       (layout "section" "Kapitel"
         (list (rect (box 0 0 1920 1080) "accent"))
         (placeholder "title" "Kapiteltitel"
           (box 160 380 1600 220) (text-style "heading" 104 "on-accent" "left" "bottom"))
         (placeholder "subtitle" "Untertitel"
           (box 160 620 1600 160) (text-style "body" 44 "on-accent" "left" "top")))
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
      '(("heading" . (("family" . "Inter") ("weight" . 900)))
        ("body"    . (("family" . "Inter") ("weight" . 400)))))

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
       (layout "two-columns" "Zwei Spalten"
         (list (zh-band))
         (placeholder "title" "Titel"
           (box 120 90 1680 150) (text-style "heading" 68 "text" "left" "bottom"))
         (placeholder "left" "Linke Spalte"
           (box 120 290 800 690) (text-style "body" 40 "text" "left" "top"))
         (placeholder "right" "Rechte Spalte"
           (box 1000 290 800 690) (text-style "body" 40 "text" "left" "top")))
       (layout "section" "Kapitel"
         (list (rect (box 0 0 1920 1080) "accent"))
         (placeholder "title" "Kapiteltitel"
           (box 120 380 1680 220) (text-style "heading" 104 "on-accent" "left" "bottom"))
         (placeholder "subtitle" "Untertitel"
           (box 120 620 1680 160) (text-style "body" 44 "on-accent" "left" "top")))
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

    ;; --- registry -----------------------------------------------------

    (define (make-design id name colors fonts layouts)
      `(("id" . ,id)
        ("name" . ,name)
        ("size" . #(1920 1080))
        ("colors" . ,colors)
        ("fonts" . ,fonts)
        ("layouts" . ,layouts)))

    (define designs
      (list (make-design "folien" "Folien" folien-colors folien-fonts folien-layouts)
            (make-design "zh" "Kanton Zürich" zh-colors zh-fonts zh-layouts)))

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
