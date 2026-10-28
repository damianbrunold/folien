;; Tests for (app designs) and (app model): new documents are valid in
;; every design, and validate-doc catches what renderers and exporters
;; rely on. Run: scm tests/test_pure_model.scm

(import (scheme base)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm string)
        (scm test)
        (scm json simple))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app designs) (app model))

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
  (test-equal '("folien" "zh") (design-ids))
  (test-assert (find-design "zh"))
  (test-equal #f (find-design "nope"))
  (for-each
   (lambda (id)
     (let ((d (find-design id)))
       (test-assert (string-append id " has a title layout") (find-layout d "title"))
       (test-assert (string-append id " has a blank layout") (find-layout d "blank"))))
   (design-ids))
  ;; Both designs offer the same layouts, so a deck can switch designs.
  (let ((ids (lambda (d) (map (lambda (l) (jref l "id"))
                              (vector->list (jref (find-design d) "layouts"))))))
    (test-equal (ids "folien") (ids "zh")))
  (test-assert "designs serialize" (string? (json->string (list->vector designs)))))

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

(test-end "folien model")
