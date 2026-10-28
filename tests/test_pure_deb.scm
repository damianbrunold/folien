;; Tests for packaging/build-package.sld: the package version and the
;; default config. Run: scm tests/test_pure_deb.scm

(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scm module)
        (scm fs)
        (scm io)
        (scm string)
        (scm test))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/packaging") (module-search-path)))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (build package) (app config))

(test-runner-factory scm-test-runner)
(test-begin "folien deb")

(test-equal "2026.10.17.125642+g1056360d" (deb-version 1792241802 "1056360d" #f))
(test-equal "2026.10.17.125642+g1056360d.dirty" (deb-version 1792241802 "1056360d" #t))

(let* ((text (default-config-text (read-file-string (string-append root "/config.example.scm"))))
       (tmp (mktemp '(prefix . "folien-deb-config"))))
  (call-with-output-file tmp (lambda (p) (write-string text p)))
  (let ((cfg (read-config tmp)))
    (test-equal "/var/lib/folien" (config-ref cfg 'data-dir #f))
    (test-equal #t (config-ref cfg 'secure-cookies? #f))
    (test-equal secret-placeholder (config-ref cfg 'session-secret #f))
    (test-equal "change-me" (config-ref cfg 'db-password #f)))
  (delete-file tmp))

(test-error (default-config-text "(define db-password \"x\")"))

(test-end "folien deb")
