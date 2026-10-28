;; Usage: scm bin/seed-demo.scm [--config path] <username>
;;
;; Creates two demo decks for username, one per design ("Demo Folien" and
;; "Demo Kanton Zürich"), with every layout, lists, links, shapes, lines,
;; builds and notes: material for checking the renderer, the editor and
;; the exports by eye.

(import (scheme base)
        (scheme write)
        (scheme process-context)
        (scm module)
        (scm fs))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app config) (app db) (app users) (app model) (app decks))

(define (fail msg) (display msg (current-error-port)) (newline (current-error-port)) (exit 1))

(define args (cdr (command-line)))
(define config-args
  (if (and (pair? args) (string=? (car args) "--config") (pair? (cdr args)))
      (list (cadr args))
      '()))
(define rest-args (if (null? config-args) args (cddr args)))
(unless (and (pair? rest-args) (null? (cdr rest-args)))
  (fail "usage: scm bin/seed-demo.scm [--config path] <username>"))

(define cfg (load-config root config-args))
(define db
  (make-db (config-ref cfg 'db-host "127.0.0.1")
           (config-ref cfg 'db-port 5432)
           (config-ref cfg 'db-user "folien")
           (config-ref cfg 'db-password "")
           (config-ref cfg 'db-name "folien")
           1))
(migrate! db (resolve-path root "migrations"))

(define user (or (find-user-by-name db (car rest-args)) (fail "no such user")))

;; --- content helpers ------------------------------------------------

(define (run text . props) `(("text" . ,text) ,@props))
(define (para runs . props) `(,@props ("runs" . ,(list->vector runs))))
(define (rich . paras) `(("paragraphs" . ,(list->vector paras))))
(define (plain . lines) (apply rich (map (lambda (l) (para (list (run l)))) lines)))
(define (bullets . items)
  (apply rich (map (lambda (i)
                     (if (pair? i)
                         (para (list (run (car i))) '("list" . "bullet") `("level" . ,(cdr i)))
                         (para (list (run i)) '("list" . "bullet"))))
                   items)))

(define (with-texts slide alist)
  ;; Sets the text of the slide's placeholders by role.
  (map (lambda (p) (if (equal? (car p) "elements")
                       (cons "elements"
                             (vector-map
                              (lambda (el)
                                (let ((t (assoc (jref el "placeholder") alist)))
                                  (if t
                                      (map (lambda (q) (if (equal? (car q) "text") (cons "text" (cdr t)) q))
                                           el)
                                      el)))
                              (cdr p)))
                       p))
       slide))

(define (add slide key value) (append slide (list (cons key value))))

(define (add-elements slide . els)
  (map (lambda (p) (if (equal? (car p) "elements")
                       (cons "elements" (vector-append (cdr p) (list->vector els)))
                       p))
       slide))

(define (shape kind x y w h fill . more)
  `(("id" . ,(new-id)) ("type" . "shape") ("shape" . ,kind)
    ("x" . ,x) ("y" . ,y) ("w" . ,w) ("h" . ,h)
    ("style" . (("fill" . ,fill) ,@more))))

(define (demo-doc design title)
  (let ((s (lambda (layout) (new-slide design layout))))
    `(("format" . 1)
      ("slides"
       . ,(vector
           (with-texts (s "title")
             `(("title" . ,(plain title))
               ("subtitle" . ,(plain "Ein Rundgang durch alle Layouts"))))
           (add (with-texts (s "title-content")
                  `(("title" . ,(plain "Aufzählungen und Auszeichnungen"))
                    ("body" . ,(rich
                                (para (list (run "Text kann ") (run "fett" '("b" . #t)) (run ", ")
                                            (run "kursiv" '("i" . #t)) (run ", ")
                                            (run "unterstrichen" '("u" . #t)) (run " oder ")
                                            (run "farbig" '("color" . "accent")) (run " sein.")))
                                (para (list (run "Erster Punkt")) '("list" . "bullet"))
                                (para (list (run "Zweiter Punkt mit einem Link auf ")
                                            (run "zh.ch" '("link" . "https://www.zh.ch/")))
                                      '("list" . "bullet"))
                                (para (list (run "Eingerückter Unterpunkt")) '("list" . "bullet") '("level" . 1))
                                (para (list (run "Schritt eins")) '("list" . "number"))
                                (para (list (run "Schritt zwei")) '("list" . "number"))
                                (para (list (run "Schritt drei")) '("list" . "number"))))))
                "notes" (plain "Notizen erscheinen in der Referentenansicht."
                               "Sie können mehrere Absätze haben."))
           (with-texts (s "two-columns")
             `(("title" . ,(plain "Zwei Spalten"))
               ("left" . ,(bullets "Vorteile" '("schnell" . 1) '("einfach" . 1)))
               ("right" . ,(bullets "Nachteile" '("neu" . 1)))))
           (with-texts (s "section")
             `(("title" . ,(plain "Kapitel 2"))
               ("subtitle" . ,(plain "Formen und Aufbau"))))
           (add-elements
            (with-texts (s "title-only") `(("title" . ,(plain "Formen"))))
            (shape "rect" 120 320 360 240 "accent")
            (shape "rounded" 540 320 360 240 "accent2")
            (shape "ellipse" 960 320 360 240 "accent3")
            (shape "triangle" 1380 320 360 240 "light" '("stroke" . "accent") '("strokeWidth" . 6))
            (shape "arrow" 120 680 520 200 "accent")
            (shape "chevron" 700 680 400 200 "muted")
            `(("id" . ,(new-id)) ("type" . "line") ("x" . 1180) ("y" . 700) ("w" . 600) ("h" . 160)
              ("style" . (("stroke" . "text") ("strokeWidth" . 8))))
            `(("id" . ,(new-id)) ("type" . "text") ("x" . 120) ("y" . 920) ("w" . 1680) ("h" . 80)
              ("style" . (("size" . 36) ("color" . "muted") ("align" . "center")))
              ("text" . ,(plain "Ein freies Textfeld"))))
           (add-elements
            (with-texts (s "title-only") `(("title" . ,(plain "Schritt für Schritt"))))
            (add (shape "rounded" 120 320 520 400 "accent") "build" '(("order" . 1) ("effect" . "fade")))
            (add (shape "rounded" 700 320 520 400 "accent2") "build" '(("order" . 2) ("effect" . "fly-up")))
            (add (shape "rounded" 1280 320 520 400 "accent3") "build" '(("order" . 3) ("effect" . "zoom"))))
           (with-texts (s "image-caption")
             `(("title" . ,(plain "Bild mit Legende"))
               ("body" . ,(plain "Hier steht die Legende zum Bild."))))
           (with-texts (s "quote")
             `(("body" . ,(plain "«Die beste Folie ist eine einfache Folie.»"))
               ("subtitle" . ,(plain "Unbekannt"))))
           (add (s "blank") "hidden" #t))))))

(for-each
 (lambda (design title)
   (let* ((doc (demo-doc design title))
          (problem (validate-doc doc design)))
     (when problem (fail problem))
     (let ((id (create-deck! db (col user "id") title design)))
       (save-doc! db (col user "id") id 1 doc design)
       (display (string-append "created " title " (" id ")\n")))))
 '("folien" "zh")
 '("Demo Folien" "Demo Kanton Zürich"))
