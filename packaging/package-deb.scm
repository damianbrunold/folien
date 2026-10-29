;; Usage: scm packaging/package-deb.scm [--out <dir>] [--dabscm <dir>] [--allow-dirty]
;;
;; Builds folien_<version>_all.deb: a self-contained Debian package with
;; the app, the exact dabscm runtime (scm.jar) it was built with, the
;; systemd units (server, health probe, daily restart, nightly maintenance
;; and backup) and a default config. Installed with
;; `apt install ./folien_<version>_all.deb`; see deploy/debian/README.Debian.
;;
;; Pure Scheme (packaging/build-deb.sld, from dashboards): no dpkg-deb, tar
;; or gzip, only git and a dabscm build (../dabscm/scm-java/scm.jar, or
;; --dabscm). Identical bytes for the same commit.
;;
;; Installed layout:
;;   /opt/folien/app/...              bin (server and admin tools), src,
;;                                    migrations, static
;;   /opt/folien/bin/{scm,healthcheck}, lib/scm.jar, VERSION
;;   /usr/bin/folien-admin            runs app/bin/<script>.scm with
;;                                    FOLIEN_CONFIG=/etc/folien/config.scm
;;   /usr/lib/systemd/system/         the units from deploy/systemd/, with the
;;                                    packaged paths
;;   /usr/share/folien/config.default.scm   copied to /etc by postinst
;;   /usr/share/doc/folien/           README.Debian, copyright, nginx/Apache examples
;;   /var/lib/folien/                 data-dir: assets, backups (StateDirectory)
;;
;; Not packaged: the dev server, the demo seeder, tests, install.sh.

(import (scheme base)
        (scheme char)
        (scheme file)
        (scheme write)
        (scheme process-context)
        (scheme time)
        (srfi 1)
        (srfi 13)
        (scm crypto)
        (scm fs)
        (scm module)
        (scm system))

(define here (directory-name (absolute-path (car (command-line)))))
(define root (directory-name here))
(module-search-path! (cons here (module-search-path)))

(import (build deb) (build package))

(define pkg "folien")
(define maintainer "Damian Brunold <damian.brunold@bluewin.ch>")
(define services '("folien.service"))
(define timers '("folien-health.timer" "folien-restart.timer"
                 "folien-maintenance.timer" "folien-backup.timer"))
(define default-port 8090)

;; bin/ scripts that belong to development, not to a server
(define bin-exclude '("dev-server.scm" "seed-demo.scm" "init-config.scm"))
;; copied whole into /opt/folien/app
(define trees '("src" "migrations" "static"))

;; --- helpers ------------------------------------------------------------------

(define (say . parts) (for-each display parts) (newline))

(define (fail . parts)
  (for-each (lambda (p) (display p (current-error-port))) parts)
  (newline (current-error-port))
  (exit 1))

(define (in-root . parts) (apply join-path root parts))

(define (read-bytes path)
  (call-with-port (open-binary-input-file path)
    (lambda (in)
      (let ((out (open-output-bytevector)))
        (let loop ()
          (let ((chunk (read-bytevector 65536 in)))
            (unless (eof-object? chunk)
              (write-bytevector chunk out)
              (loop))))
        (get-output-bytevector out)))))

(define (write-bytes path bv)
  (call-with-port (open-binary-output-file path)
    (lambda (out) (write-bytevector bv out))))

(define (read-text path) (utf8->string (read-bytes path)))

;; Shell scripts and units must be LF-only even from a CRLF checkout.
(define (lf-only s)
  (list->string (remove (lambda (c) (char=? c #\return)) (string->list s))))

(define (replace-all s from to)
  (let loop ((i 0) (out '()))
    (let ((j (string-contains s from i)))
      (if j
          (loop (+ j (string-length from)) (cons to (cons (substring s i j) out)))
          (apply string-append (reverse (cons (substring s i (string-length s)) out)))))))

(define (substitute text pairs)
  (fold (lambda (kv acc) (replace-all acc (car kv) (cdr kv))) text pairs))

(define (git . args)
  (let ((r (run-program/capture (append (list "git" "-C" root) args))))
    (unless (and (pair? r) (eqv? (car r) 0))
      (fail "git failed: " args))
    (string-trim-both (cadr r))))

;; Recursive file list under dir, relative "/"-joined paths, sorted; skips
;; editor leftovers.
(define (skip-name? name)
  (or (string-suffix? "~" name)
      (string-prefix? ".#" name)
      (string=? name "__pycache__")))

(define (tree-files dir)
  (let walk ((rel ""))
    (let ((os (if (string=? rel "") dir (join-path dir rel)))
          (join (lambda (n) (if (string=? rel "") n (string-append rel "/" n)))))
      (append
       (filter-map (lambda (f) (and (not (skip-name? f)) (join f)))
                   (list-sort-strings (directory-files os)))
       (append-map (lambda (d) (if (skip-name? d) '() (walk (join d))))
                   (list-sort-strings (directory-directories os)))))))

(define (list-sort-strings l)
  (let insert ((l l) (out '()))
    (if (null? l)
        out
        (insert (cdr l)
                (let place ((o out))
                  (cond ((null? o) (list (car l)))
                        ((string<? (car l) (car o)) (cons (car l) o))
                        (else (cons (car o) (place (cdr o))))))))))

;; --- arguments ----------------------------------------------------------------

(define (usage)
  (display "Usage: scm packaging/package-deb.scm [--out <dir>] [--dabscm <dir>] [--allow-dirty]\n"
           (current-error-port))
  (exit 2))

(define-values (out-dir dabscm allow-dirty?)
  (let loop ((args (cdr (command-line)))
             (out (in-root "releases"))
             (dab (join-path (directory-name root) "dabscm"))
             (dirty #f))
    (cond ((null? args) (values out dab dirty))
          ((string=? (car args) "--allow-dirty") (loop (cdr args) out dab #t))
          ((and (string=? (car args) "--out") (pair? (cdr args)))
           (loop (cddr args) (absolute-path (cadr args)) dab dirty))
          ((and (string=? (car args) "--dabscm") (pair? (cdr args)))
           (loop (cddr args) out (absolute-path (cadr args)) dirty))
          (else (usage)))))

;; --- build ------------------------------------------------------------------------

(define dirty? (not (string=? (git "status" "--porcelain") "")))
(when (and dirty? (not allow-dirty?))
  (fail "package-deb: the working tree has uncommitted changes; "
        "commit them or pass --allow-dirty"))

(define hash (git "rev-parse" "--short=8" "HEAD"))
(define epoch (if dirty?
                  (exact (floor (current-second)))
                  (string->number (git "log" "-1" "--format=%ct"))))
(define version (deb-version epoch hash dirty?))

(define jar (join-path dabscm "scm-java" "scm.jar"))
(unless (file-exists? jar)
  (fail "scm.jar not found at " jar
        " (build dabscm first: cd ../dabscm && scm build-scm-java.scm, or pass --dabscm)"))
(define dabscm-version
  (let ((f (join-path dabscm "VERSION")))
    (if (file-exists? f) (string-trim-both (read-text f)) "unknown")))

(define subst
  `(("@PKG@" . ,pkg)
    ("@VERSION@" . ,version)
    ("@MAINTAINER@" . ,maintainer)
    ("@SERVICES@" . ,(string-join services " "))
    ("@TIMERS@" . ,(string-join timers " "))
    ("@DEFAULT_PORT@" . ,(number->string default-port))
    ("@SECRET_PLACEHOLDER@" . ,secret-placeholder)))

(define (template name)
  (lf-only (substitute (read-text (in-root "packaging" "templates" name)) subst)))

(define opt (string-append "opt/" pkg "/"))
(define app (string-append opt "app/"))
(define doc (string-append "usr/share/doc/" pkg "/"))

(define (text name mode s) (list name mode (string->utf8 s)))
(define (from-repo name mode path) (list name mode (read-bytes path)))

(define app-files
  (append
   (filter-map
    (lambda (f)
      (and (string-suffix? ".scm" f)
           (not (member f bin-exclude))
           (from-repo (string-append app "bin/" f) #o644 (in-root "bin" f))))
    (list-sort-strings (directory-files (in-root "bin"))))
   (append-map
    (lambda (tree)
      (map (lambda (f) (from-repo (string-append app tree "/" f) #o644 (in-root tree f)))
           (tree-files (in-root tree))))
    trees)
   (list (text (string-append app "config.example.scm") #o644
               (read-text (in-root "config.example.scm"))))))

;; The units of deploy/systemd/ are written for deploy/install.sh; in the
;; package the runtime and the app live elsewhere.
(define (packaged-unit text)
  (substitute text
              `(("/usr/local/bin/scm" . ,(string-append "/opt/" pkg "/bin/scm"))
                (,(string-append "WorkingDirectory=/opt/" pkg "\n")
                 . ,(string-append "WorkingDirectory=/opt/" pkg "/app\n"))
                (,(string-append "/opt/" pkg "/deploy/healthcheck.sh /etc/" pkg "/config.scm ")
                 . ,(string-append "/opt/" pkg "/bin/healthcheck ")))))

(define unit-files
  (map (lambda (u)
         (text (string-append "usr/lib/systemd/system/" u) #o644
               (packaged-unit (lf-only (read-text (in-root "deploy" "systemd" u))))))
       (filter (lambda (f) (or (string-suffix? ".service" f) (string-suffix? ".timer" f)))
               (list-sort-strings (directory-files (in-root "deploy" "systemd"))))))

(define copyright
  (string-append
   "Folien (" pkg ")\n\nCopyright (c) Damian Brunold.\n"
   "\n\nBundled third-party material:\n\n"
   "* The Inter typeface (/opt/" pkg "/app/static/fonts/), by The Inter Project\n"
   "  Authors, under the SIL Open Font License 1.1:\n\n"
   (read-text (in-root "static" "fonts" "Inter-LICENSE.txt"))
   "\n\n* Scheme runtime /opt/" pkg "/lib/scm.jar: dabscm " dabscm-version
   (let ((lic (join-path dabscm "LICENSE")))
     (if (file-exists? lic)
         (string-append ", under this licence:\n\n" (read-text lic))
         ".\n"))))

(define doc-files
  (list (from-repo (string-append doc "README.Debian") #o644
                   (in-root "deploy" "debian" "README.Debian"))
        (text (string-append doc "copyright") #o644 copyright)
        (from-repo (string-append doc "nginx.conf.example") #o644
                   (in-root "deploy" "nginx.conf.example"))
        (from-repo (string-append doc "apache2.conf.example") #o644
                   (in-root "deploy" "apache2.conf.example"))
        (from-repo (string-append doc "apache2-subpath.conf.example") #o644
                   (in-root "deploy" "apache2-subpath.conf.example"))))

(define runtime-files
  (list (from-repo (string-append opt "lib/scm.jar") #o644 jar)
        (text (string-append opt "bin/scm") #o755 (template "scm.in"))
        (text (string-append opt "bin/healthcheck") #o755 (template "healthcheck.in"))
        (text (string-append "usr/bin/" pkg "-admin") #o755 (template "admin.in"))
        (text (string-append opt "VERSION") #o644
              (string-append pkg " " version "\ncommit " hash
                             "\ndabscm " dabscm-version "\n"))
        (text (string-append "usr/share/" pkg "/config.default.scm") #o644
              (default-config-text (read-text (in-root "config.example.scm"))))))

(define data (append app-files unit-files doc-files runtime-files))

(define installed-kib
  (+ (fold (lambda (e acc)
             (+ acc (quotient (+ (bytevector-length (entry-content e)) 1023) 1024)))
           0 data)
     (- (length (add-parent-dirs data)) (length data))))

(define control
  (substitute (template "control.in")
              `(("@INSTALLED_SIZE@" . ,(number->string installed-kib)))))

(define md5sums
  (apply string-append
         (map (lambda (e)
                (string-append (md5-hash (entry-content e)) "  " (entry-name e) "\n"))
              data)))

(define control-entries
  (list (text "control" #o644 control)
        (text "md5sums" #o644 md5sums)
        (text "postinst" #o755 (template "postinst.in"))
        (text "prerm" #o755 (template "prerm.in"))
        (text "postrm" #o755 (template "postrm.in"))))

(unless (directory-exists? out-dir) (make-directory out-dir))
(define deb (join-path out-dir (string-append pkg "_" version "_all.deb")))
(say "package-deb " version)
(write-bytes deb (deb-bytevector control-entries data epoch))
(say "  " deb " (" (length data) " files, " installed-kib " KiB installed)")
