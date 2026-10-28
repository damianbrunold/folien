;; Tests for (app assets) that need no database: recognising file types.
;; Run: scm tests/test_pure_assets.scm

(import (scheme base)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm test))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app assets))

(test-runner-factory scm-test-runner)
(test-begin "folien assets")

(define (bv . parts)
  (apply bytevector-append
         (map (lambda (p) (if (string? p) (string->utf8 p) (apply bytevector p))) parts)))

(test-group "sniff-mime"
  (test-equal "image/png" (sniff-mime (bv '(#x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A 0 0))))
  (test-equal "image/jpeg" (sniff-mime (bv '(#xFF #xD8 #xFF #xE0))))
  (test-equal "image/gif" (sniff-mime (bv "GIF89a" '(1 0))))
  (test-equal "image/webp" (sniff-mime (bv "RIFF" '(0 0 0 0) "WEBPVP8 ")))
  (test-equal "video/mp4" (sniff-mime (bv '(0 0 0 24) "ftypisom")))
  (test-equal "video/webm" (sniff-mime (bv '(#x1A #x45 #xDF #xA3 1))))
  (test-equal "image/svg+xml" (sniff-mime (bv "<svg xmlns='http://www.w3.org/2000/svg'/>")))
  (test-equal "image/svg+xml"
    (sniff-mime (bv '(#xEF #xBB #xBF) "\n  <?xml version='1.0'?><!-- x --><SVG/>")))
  (test-equal #f (sniff-mime (bv "<html><body>no</body></html>")))
  (test-equal #f (sniff-mime (bv "%PDF-1.7")))
  (test-equal #f (sniff-mime (bv "RIFF" '(0 0 0 0) "WAVE")))
  (test-equal #f (sniff-mime (bytevector))))

(test-group "valid-sha?"
  (test-assert (valid-sha? (make-string 64 #\a)))
  (test-assert (not (valid-sha? (make-string 64 #\A))))
  (test-assert (not (valid-sha? "../etc/passwd")))
  (test-assert (not (valid-sha? (make-string 63 #\a)))))

(test-equal "/d/assets/ab/abcd" (asset-file "/d" "abcd"))

(test-end "folien assets")
