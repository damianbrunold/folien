;; Tests for the web app that need no database: everything up to the point
;; where a valid session would be looked up. The pool connects lazily, so a
;; db handle for an unused port is fine here. tests/test_live_web.scm covers
;; the rest against a real database.
;; Run: scm tests/test_pure_web.scm

(import (scheme base)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm log)
        (scm string)
        (scm test)
        (scm crypto)
        (scm net http request)
        (scm net http response))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app db) (app web))

(test-runner-factory scm-test-runner)
(test-begin "folien web (no database)")

(define (app-with prefix)
  (make-app `((url-prefix . ,prefix)
              (static-dir . ,(string-append root "/static"))
              (data-dir . ,(mktempdir '(prefix . "folien-data")))
              (db . ,(make-db "127.0.0.1" 1 "nobody" "" "nothing" 1))
              (session-secret . ,(base64-encode (random-bytes 32)))
              (session-max-age . 3600)
              (secure-cookies? . #f))))

(define (send app method url cookie)
  (parameterize ((log-port (open-output-string)))
    (app (make-http-request method url
                            (if cookie (list (cons "Cookie" cookie)) '())
                            #f))))

(define (status r) (http-response-status r))
(define (location r) (http-response-header r "Location"))
(define (body r)
  (let ((b (http-response-body r)))
    (if (bytevector? b) (utf8->string b) b)))
(define (has? s part) (and (string? s) (string-contains-from s part 0) #t))

(define app (app-with ""))

(test-group "signed out"
  (test-equal "/login" (location (send app "GET" "/" #f)))
  (test-equal "/login" (location (send app "GET" "/admin" #f)))
  (test-equal "/login" (location (send app "POST" "/admin/users" #f)))
  (test-equal "/login" (location (send app "GET" "/admin" "folien_session=forged.x")))
  (test-equal 200 (status (send app "GET" "/login" #f)))
  (test-equal "ok\n" (body (send app "GET" "/healthz" #f)))
  (test-equal 200 (status (send app "GET" "/static/css/app.css" #f)))
  (test-equal "/login" (location (send app "GET" "/archive" #f)))
  (test-equal "/login" (location (send app "GET" "/trash" #f)))
  (test-equal "/login" (location (send app "POST" "/decks" #f)))
  (test-equal "/login" (location (send app "GET" "/decks/abc" #f)))
  (test-equal "/login" (location (send app "GET" "/decks/abc/edit" #f)))
  (test-equal "/login" (location (send app "POST" "/decks/abc/delete" #f))))

(test-group "the API answers 401, not a redirect"
  (test-equal 401 (status (send app "GET" "/api/decks/abc" #f)))
  (test-equal 401 (status (send app "PUT" "/api/decks/abc" #f)))
  (test-equal 401 (status (send app "GET" "/api/designs" #f)))
  (test-equal 401 (status (send app "POST" "/api/decks/abc/assets" #f)))
  (test-equal "/login" (location (send app "GET" (string-append "/api/decks/abc/assets/" (make-string 64 #\a)) #f)))
  (test-assert (has? (body (send app "GET" "/api/designs" #f)) "not signed in")))

(test-group "German interface"
  (test-assert (has? (body (send app "GET" "/login" #f)) "lang=\"de\""))
  (test-assert (has? (body (send app "GET" "/login" #f)) "Anmelden")))

(test-group "strict CSP holds"
  (let ((r (send app "GET" "/login" #f)))
    (test-assert (has? (http-response-header r "Content-Security-Policy") "style-src 'self'"))
    (test-assert "dropped files can be previewed"
      (has? (http-response-header r "Content-Security-Policy") "media-src 'self' blob:"))
    (test-assert "no inline script" (not (has? (body r) "<script>")))
    (test-assert "no style attribute" (not (has? (body r) " style=")))))

(test-group "url prefix"
  (let ((app (app-with "/team")))
    (test-equal "/team/login" (location (send app "GET" "/team/admin" #f)))
    (test-assert (has? (body (send app "GET" "/team/login" #f)) "action=\"/team/login\""))
    (test-equal 404 (status (send app "GET" "/login" #f)))))

(test-end "folien web (no database)")
