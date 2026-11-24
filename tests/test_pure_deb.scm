;; Packaging test: builds the real package with package-deb.scm (dabscm's
;; (scm deb webapp)) into a temporary directory and checks what went in.
;; The tar/ar/deb writer itself is tested in dabscm. Skipped when there is
;; no dabscm build at ../dabscm/scm-java/scm.jar.
;;
;; Run: scm tests/test_pure_deb.scm

(import (scheme base)
        (scheme file)
        (scheme process-context)
        (scheme write)
        (srfi 1)
        (srfi 13)
        (scm archive)
        (scm fs)
        (scm module)
        (scm system)
        (scm test))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app config))

(define jar (join-path (directory-name root) "dabscm" "scm-java" "scm.jar"))

(define (read-file-bytes path)
  (call-with-port (open-binary-input-file path)
    (lambda (in) (read-bytevector (file-size path) in))))

;; bytes -> string without UTF-8 decoding errors: non-ASCII bytes become "?"
(define (latin bv)
  (let ((out (make-bytevector (bytevector-length bv))))
    (let loop ((i 0))
      (when (< i (bytevector-length bv))
        (let ((b (bytevector-u8-ref bv i)))
          (bytevector-u8-set! out i (if (< b 128) b 63)))
        (loop (+ i 1))))
    (utf8->string out)))

;; ar members of a .deb: ((name . bytes) ...)
(define (ar-members bv)
  (let loop ((off 8) (acc '()))
    (if (>= off (bytevector-length bv))
        (reverse acc)
        (let* ((head (utf8->string (bytevector-copy bv off (+ off 60))))
               (name (string-trim-right
                      (substring head 0 16)
                      (lambda (c) (or (char=? c #\space) (char=? c #\/)))))
               (size (string->number (string-trim-both
                                      (substring head 48 58))))
               (data (bytevector-copy bv (+ off 60) (+ off 60 size))))
          (loop (+ off 60 size (if (odd? size) 1 0))
                (cons (cons name data) acc))))))

;; the text of the tar entry named name in the uncompressed tar bytes, or #f
(define (tar-entry tar name)
  (let loop ((off 0))
    (and (< (+ off 512) (bytevector-length tar))
         (let* ((head (bytevector-copy tar off (+ off 512)))
                (n (string-trim-right (latin (bytevector-copy head 0 100))
                                      #\null))
                (size (or (string->number
                           (string-trim-both
                            (latin (bytevector-copy head 124 136))
                            (lambda (c)
                              (or (char=? c #\null) (char=? c #\space))))
                           8)
                          0)))
           (cond ((string=? n "") #f)
                 ((string=? n name)
                  (utf8->string (bytevector-copy tar
                                                 (+ off 512)
                                                 (+ off 512 size))))
                 (else (loop (+ off
                                512
                                (* 512 (quotient (+ size 511) 512))))))))))

(define units
  '("folien-backup.service" "folien-backup.timer" "folien-health.service"
    "folien-health.timer" "folien-maintenance.service"
    "folien-maintenance.timer" "folien-restart.service" "folien-restart.timer"
    "folien.service"))

(test-runner-factory scm-test-runner)
(test-begin "folien deb")

(if (not (file-exists? jar))
    (begin
      (display "  test_pure_deb: skipped, no ")
      (display jar)
      (newline))
    (let* ((tmp (mktempdir '(prefix . "folien-deb-")))
           (r (run-program/capture (list "java" "-jar" jar
                                         (join-path root "package-deb.scm")
                                         "--allow-dirty"
                                         "--out"
                                         tmp)))
           (debs (filter (lambda (f) (string-suffix? ".deb" f))
                         (directory-files tmp))))
      (test-equal "package-deb.scm succeeds" 0 (car r))
      (test-equal "one package" 1 (length debs))
      (when (= (length debs) 1)
        (let* ((members (ar-members (read-file-bytes
                                     (join-path tmp (car debs)))))
               (data-tar (gzip-decompress (cdr (assoc "data.tar.gz" members))))
               (data (latin data-tar))
               (control (latin (gzip-decompress
                                (cdr (assoc "control.tar.gz" members)))))
               (has? (lambda (s) (and (string-contains data s) #t)))
               (unit (lambda (u)
                       (tar-entry data-tar
                                  (string-append "./usr/lib/systemd/system/"
                                                 u)))))
          (test-assert "named folien_..._all.deb"
                       (and (string-prefix? "folien_" (car debs))
                            (string-suffix? "_all.deb" (car debs))))
          (test-assert "server and admin tools"
                       (and (has? "./opt/folien/app/bin/server.scm")
                            (has? "./opt/folien/app/bin/seed-admin.scm")
                            (has? "./opt/folien/app/bin/backup.scm")
                            (has? "./opt/folien/app/bin/gen-secret.scm")))
          (test-assert "no dev server, demo seeder or init-config"
                       (not (or (has? "./opt/folien/app/bin/dev-server.scm")
                                (has? "./opt/folien/app/bin/seed-demo.scm")
                                (has?
                                 "./opt/folien/app/bin/init-config.scm"))))
          (test-assert "src, migrations, static"
                       (and (has? "./opt/folien/app/src/app-config.sld")
                            (has? "./opt/folien/app/migrations/")
                            (has? "./opt/folien/app/static/fonts/")))
          (test-assert "runtime" (has? "./opt/folien/lib/scm.jar"))
          (test-equal "all units" units (filter unit units))
          (let ((server (or (unit "folien.service") "")))
            (test-assert "server unit: packaged runtime and app"
                         (and (string-contains
                               server
                               "ExecStart=/opt/folien/bin/scm bin/server.scm /etc/folien/config.scm")
                              (string-contains
                               server
                               "WorkingDirectory=/opt/folien/app\n")
                              #t)))
          (test-assert "health unit: packaged probe"
                       (and (string-contains
                             (or (unit "folien-health.service") "")
                             "ExecStart=/opt/folien/bin/healthcheck folien.service")
                            #t))
          ;; the admin tools find /etc/folien/config.scm through this stub
          (let ((stub (tar-entry data-tar "./opt/folien/app/config.scm")))
            (test-assert "config stub loads /etc/folien/config.scm"
                         (and stub
                              (string-contains
                               stub
                               "(load \"/etc/folien/config.scm\")")
                              #t)))
          (let ((text (tar-entry data-tar
                                 "./usr/share/folien/config.default.scm"))
                (f (mktemp '(prefix . "folien-deb-config"))))
            (call-with-output-file f
              (lambda (p) (write-string (or text "") p)))
            (let ((cfg (read-config f)))
              (test-equal "default config: data-dir"
                          "/var/lib/folien"
                          (config-ref cfg 'data-dir #f))
              (test-equal "default config: secure cookies"
                          #t
                          (config-ref cfg 'secure-cookies? #f))
              (test-equal "default config: secret placeholder"
                          "REPLACE_WITH_BASE64_SECRET"
                          (config-ref cfg 'session-secret #f))
              (test-equal "default config: db-password to fill in"
                          "change-me"
                          (config-ref cfg 'db-password #f)))
            (delete-file f))
          (test-assert "copyright: Inter typeface and the runtime"
                       (and (has? "The Inter typeface")
                            (has? "SIL Open Font License")
                            (has?
                             "Scheme runtime /opt/folien/lib/scm.jar: dabscm ")))
          (test-assert "README.Debian and proxy examples"
                       (and (has? "./usr/share/doc/folien/README.Debian")
                            (has? "./usr/share/doc/folien/nginx.conf.example")
                            (has?
                             "./usr/share/doc/folien/apache2.conf.example")
                            (has?
                             "./usr/share/doc/folien/apache2-subpath.conf.example")))
          (test-assert "health probe port" (has? "${port:-8090}"))
          (test-assert "control"
                       (and (string-contains control "Package: folien")
                            (string-contains control "postgresql-client")
                            (string-contains control "dabscm-fonts")
                            (string-contains control
                                             "SERVICES=\"folien.service\"")
                            #t))))
      (delete-directory tmp)))

(test-end "folien deb")
