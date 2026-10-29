;; Tests for (app designs) and (app model): new documents are valid in
;; every design, and validate-doc catches what renderers and exporters
;; rely on. Run: scm tests/test_pure_model.scm

(import (scheme base)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm string)
        (scm test)
        (scheme inexact)
        (scm json simple))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app designs) (app model) (only (app publish) valid-slug? publication-doc))

(test-runner-factory scm-test-runner)
(test-begin "folien model")

(define (has? s part) (and (string? s) (string-contains-from s part 0) #t))

;; A copy of alist obj with key set to value (added if missing).
(define (put obj key value)
  (if (assoc key obj)
      (map (lambda (p) (if (equal? (car p) key) (cons key value) p)) obj)
      (append obj (list (cons key value)))))

(define (first-slide doc) (vector-ref (doc-slides doc) 0))
(define (with-slide doc slide) (put doc "slides" (vector slide)))
(define (with-element doc el)
  (with-slide doc (put (first-slide doc) "elements" (vector el))))

(test-group "designs"
  (test-equal '("folien" "folien-dark" "zh" "slab" "slab-dark") (design-ids))
  (test-assert (find-design "zh"))
  (test-equal #f (find-design "nope"))
  (for-each
   (lambda (id)
     (let ((d (find-design id)))
       (test-assert (string-append id " has a title layout") (find-layout d "title"))
       (test-assert (string-append id " has a blank layout") (find-layout d "blank"))))
   (design-ids))
  ;; All designs offer the same layouts, so a deck can switch designs.
  (let ((ids (lambda (d) (map (lambda (l) (jref l "id"))
                              (vector->list (jref (find-design d) "layouts"))))))
    (for-each (lambda (d) (test-equal d (ids "folien") (ids d))) (design-ids)))
  (test-assert "designs serialize" (string? (json->string (list->vector designs)))))

;; WCAG 2 contrast: text in each design stays readable (AA: 4.5:1 for
;; normal text) for the colour pairs the designs and tables use.
(define (luminance hex)
  (define (channel i)
    (let ((v (/ (string->number (substring hex i (+ i 2)) 16) 255.0)))
      (if (<= v 0.03928) (/ v 12.92) (expt (/ (+ v 0.055) 1.055) 2.4))))
  (+ (* 0.2126 (channel 1)) (* 0.7152 (channel 3)) (* 0.0722 (channel 5))))

(define (contrast a b)
  (let ((la (luminance a)) (lb (luminance b)))
    (/ (+ (max la lb) 0.05) (+ (min la lb) 0.05))))

(test-group "contrast (WCAG AA)"
  (for-each
   (lambda (id)
     (let ((colors (jref (find-design id) "colors")))
       (for-each
        (lambda (pair)
          (test-assert (string-append id ": " (car pair) " on " (cadr pair))
            (>= (contrast (jref colors (car pair)) (jref colors (cadr pair))) 4.5)))
        '(("text" "background") ("muted" "background") ("accent" "background")
          ("accent2" "background") ("accent3" "background")
          ("on-accent" "accent") ("on-accent" "accent2") ("on-accent" "accent3")
          ("text" "light") ("muted" "light")))))
   (design-ids)))

(test-group "new documents"
  (let ((doc (new-doc "folien" "Hallo")))
    (test-equal #f (validate-doc doc "folien"))
    (test-equal #f (validate-doc doc "zh"))
    (test-equal 1 (vector-length (doc-slides doc)))
    (test-assert (has? (json->string doc) "\"Hallo\""))
    ;; JSON round trip keeps it valid.
    (test-equal #f (validate-doc (json-parse (json->string doc)) "folien")))
  (test-assert (not (equal? (new-id) (new-id))))
  (test-equal 12 (string-length (new-id)))
  (for-each
   (lambda (layout)
     (let ((slide (new-slide "zh" (jref layout "id"))))
       (test-equal (jref layout "id")
                   #f
                   (validate-doc (with-slide (new-doc "zh" "x") slide) "zh"))))
   (vector->list (jref (find-design "zh") "layouts"))))

(test-group "rejected documents"
  (let* ((run-doc (lambda (run)
                    (with-element (new-doc "folien" "x")
                                  `(("id" . "t") ("type" . "text") ("x" . 0) ("y" . 0) ("w" . 10) ("h" . 10)
                                    ("text" . (("paragraphs" . #((("runs" . #(,run))))))))))))
    (test-equal #f (validate-doc (run-doc '(("text" . "x") ("code" . #t))) "folien"))
    (test-assert (has? (validate-doc (run-doc '(("text" . "x") ("code" . "yes"))) "folien")
                       "not a boolean")))
  (let ((doc (new-doc "folien" "x")))
    (test-assert (has? (validate-doc doc "nope") "unknown design"))
    (test-assert (has? (validate-doc '() "folien") "format"))
    (test-assert (has? (validate-doc (put doc "format" 2) "folien") "unsupported format"))
    (test-assert (has? (validate-doc (put doc "slides" #()) "folien") "slides"))
    (test-assert "unknown layout"
      (has? (validate-doc (with-slide doc (put (first-slide doc) "layout" "nope")) "folien")
            "slides[0].layout"))
    (test-assert "duplicate slide ids"
      (has? (validate-doc (put doc "slides" (vector (first-slide doc) (first-slide doc))) "folien")
            "duplicate"))
    (test-assert "free element needs geometry"
      (has? (validate-doc (with-element doc '(("id" . "a") ("type" . "shape"))) "folien")
            "elements[0].x: missing"))
    (test-equal "positioned shape is fine" #f
      (validate-doc (with-element doc '(("id" . "a") ("type" . "shape")
                                        ("x" . 10) ("y" . 10) ("w" . 100) ("h" . 50)
                                        ("style" . (("fill" . "accent")))))
                    "folien"))
    (test-assert "unknown type"
      (has? (validate-doc (with-element doc '(("id" . "a") ("type" . "iframe")
                                              ("x" . 0) ("y" . 0) ("w" . 1)))
                          "folien")
            "unknown type"))
    (test-assert "bad colour"
      (has? (validate-doc (with-element doc '(("id" . "a") ("type" . "shape")
                                              ("x" . 0) ("y" . 0) ("w" . 1)
                                              ("style" . (("fill" . "red")))))
                          "folien")
            "style.fill"))
    (test-assert "bad id"
      (has? (validate-doc (with-element doc '(("id" . "a b") ("type" . "text")
                                              ("placeholder" . "title")))
                          "folien")
            "bad id"))))

(test-group "tables"
  (define (cell t) `(("paragraphs" . #((("runs" . #((("text" . ,t)))))))))
  (define (doc-with-table table)
    (with-element (new-doc "folien" "x")
      `(("id" . "tb") ("type" . "table") ("x" . 0) ("y" . 0) ("w" . 600) ("h" . 200)
        ("table" . ,table))))
  (test-equal #f (validate-doc (doc-with-table `(("header" . #t) ("rows" . #(#(,(cell "a") ,(cell "b"))
                                                                            #(,(cell "1") ,(cell "2"))))))
                               "folien"))
  (test-assert (has? (validate-doc (doc-with-table `(("rows" . #(#(,(cell "a") ,(cell "b")) #(,(cell "1"))))))
                                   "folien")
                     "same number"))
  (test-assert (has? (validate-doc (doc-with-table '(("rows" . #()))) "folien") "1 to 50"))
  (test-assert (has? (validate-doc (doc-with-table `(("rows" . #(#((("paragraphs" . 1))))))) "folien")
                     "paragraphs"))
  (test-assert (has? (validate-doc (doc-with-table `(("rows" . #(#(,(cell "a")))) ("header" . "ja"))) "folien")
                     "header")))

(test-group "links in text"
  (define (doc-with-link link)
    (with-element (new-doc "folien" "x")
      `(("id" . "t") ("type" . "text") ("x" . 0) ("y" . 0) ("w" . 100)
        ("text" . (("paragraphs"
                    . #((("runs" . #((("text" . "hier") ("link" . ,link))))))))))))
  (test-equal #f (validate-doc (doc-with-link "https://www.zh.ch/") "folien"))
  (test-equal #f (validate-doc (doc-with-link "mailto:a@b.ch") "folien"))
  (test-equal #f (validate-doc (doc-with-link "#slide-abc") "folien"))
  (test-assert (has? (validate-doc (doc-with-link "javascript:alert(1)") "folien") "link"))
  (test-assert (has? (validate-doc (doc-with-link "JavaScript:alert(1)") "folien") "link"))
  (test-assert (has? (validate-doc (doc-with-link "data:text/html,x") "folien") "link")))

(test-group "footer"
  (let* ((d (new-doc "folien" "T"))
         (slide (lambda (id layout . more)
                  `(("id" . ,id) ("layout" . ,layout) ,@more ("elements" . #()))))
         (footed (put (put d "slides" (vector (first-slide d)
                                             (slide "a" "section" '("hidden" . #t))
                                             (slide "b" "blank")
                                             (slide "c" "blank" '("footer" . #f))))
                      "footer" '(("text" . "Fuss") ("number" . #t) ("date" . "auto"))))
         (fields (lambda (i) (map (lambda (e) (jref e "field"))
                                  (footer-elements footed (find-design "folien") i "01.11.2026"))))
         (texts (lambda (i) (map (lambda (e) (jref (vector-ref (jref (vector-ref (jref (jref e "text") "paragraphs") 0) "runs") 0) "text"))
                                 (footer-elements footed (find-design "folien") i "01.11.2026")))))
    (test-equal #f (validate-doc footed "folien"))
    (test-equal "not on title slides" '() (fields 0))
    (test-equal '("date" "text" "number") (fields 2))
    (test-equal '("01.11.2026" "Fuss" "2") (texts 2))
    (test-equal "a hidden slide shows the next number" "2" (list-ref (texts 1) 2))
    (test-equal "recoloured on dark layouts" "on-accent"
      (jref (jref (car (footer-elements footed (find-design "folien") 1 "")) "style") "color"))
    (test-equal "turned off per slide" '() (fields 3))
    (test-equal "1 2 2 3" (list 1 2 2 3) (map (lambda (i) (slide-number footed i)) '(0 1 2 3)))
    (test-assert (has? (validate-doc (put footed "footer" '(("date" . "today"))) "folien") "footer.date"))
    (test-assert (has? (validate-doc (put footed "footer" '(("number" . "ja"))) "folien") "footer.number"))
    (test-assert (has? (validate-doc (with-slide footed (slide "x" "blank" '("footer" . #t))) "folien")
                       "slides[0].footer"))))

(test-group "shared and published copies"
  (let* ((notes '(("paragraphs" . #((("runs" . #((("text" . "geheim")))))))))
         (doc `(("format" . 1)
                ("footer" . (("date" . "auto") ("text" . "Bern")))
                ("slides" . #((("id" . "a") ("layout" . "blank") ("notes" . ,notes) ("elements" . #()))
                              (("id" . "b") ("layout" . "blank") ("hidden" . #t) ("elements" . #()))
                              (("id" . "c") ("layout" . "blank") ("hidden" . #f) ("elements" . #()))))))
         (shared (shareable-doc doc))
         (published (publication-doc doc "29.10.2026")))
    (test-equal '("a" "c") (map (lambda (s) (jref s "id")) (vector->list (doc-slides shared))))
    (test-equal #f (jref (vector-ref (doc-slides shared) 0) "notes" #f))
    (test-equal "the footer stays" "auto" (jref (jref shared "footer") "date"))
    (test-equal "fixed" (jref (jref published "footer") "date"))
    (test-equal "29.10.2026" (jref (jref published "footer") "dateText"))
    (test-equal "Bern" (jref (jref published "footer") "text"))
    (test-equal 2 (vector-length (doc-slides published)))
    (test-equal #f (validate-doc published "folien"))
    ;; a fixed date stays as it is
    (let ((fixed (publication-doc (cons '("footer" . (("date" . "fixed") ("dateText" . "Mai"))) (cdr doc)) "1.1.2000")))
      (test-equal "Mai" (jref (jref fixed "footer") "dateText"))))
  (for-each (lambda (s) (test-assert s (valid-slug? s))) '("abc" "tagung-bern" "ki-2026" "a1b"))
  (for-each (lambda (s) (test-assert s (not (valid-slug? s))))
            (list "ab" "-abc" "abc-" "a--b" "Abc" "a b" "äbc" "a_b" (make-string 61 #\a) 'x)))

(test-end "folien model")
