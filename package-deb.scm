;; Usage: scm package-deb.scm [--out <dir>] [--dabscm <dir>] [--allow-dirty]
;;                            [--native [--scmc <scmc>] [--target <triple>]]
;;
;; Builds releases/folien_<version>_all.deb (with --native:
;; folien_<version>_amd64.deb, the bin/ programs compiled by dabscm native,
;; no Java) with dabscm's (scm deb webapp): the app, the dabscm runtime it
;; was built with, the systemd units of deploy/systemd/ (server, health
;; probe, daily restart, nightly maintenance and backup) and a default
;; config. Installed with `apt install ./folien_<version>_all.deb`; see
;; deploy/debian/README.Debian. Identical bytes for the same commit.
;;
;; Not packaged: the dev server, the demo seeder, init-config (used by
;; deploy/install.sh), tests, install.sh.

(import (scheme base)
        (scheme file)
        (scheme process-context)
        (only (srfi 1) cons*)
        (only (srfi 13) string-trim-right)
        (scm deb webapp)
        (scm fs))

(define root (directory-name (absolute-path (car (command-line)))))

(define (read-lines path)
  (call-with-input-file path
    (lambda (in)
      (let loop ((acc '()))
        (let ((line (read-line in)))
          (if (eof-object? line)
              (reverse acc)
              (loop (cons (string-trim-right line #\return) acc))))))))

(webapp-deb-main
 `((pkg . "folien")
   (app-dir . ,root)
   (maintainer . "Damian Brunold <damian.brunold@bluewin.ch>")
   (summary . "Folien (presentations: edit, present, export)")
   (description
    "Creates, edits and presents slide decks in the browser: layouts in five"
    "designs (Folien, Kanton Zürich and Slab, some dark), text and code,"
    "shapes, images and videos, transitions and builds, a presenter console"
    "and a phone remote; exports as PDF, PowerPoint and self-contained zip"
    "bundles. A dabscm web application with its own Scheme runtime; needs"
    "PostgreSQL. With dabscm-fonts, PDFs set code in JetBrains Mono.")
   (trees "src" "migrations" "static")
   (bin-exclude "dev-server.scm" "seed-demo.scm" "init-config.scm")
   ;; session-secret keeps its REPLACE_WITH_BASE64_SECRET placeholder:
   ;; postinst puts the output of bin/gen-secret.scm there
   (config-settings ("data-dir" . "\"/var/lib/folien\"")
                    ("secure-cookies?" . "#t"))
   (setup-hints
    "set the database credentials and url-prefix (see /usr/share/doc/folien/README.Debian),"
    "create the first admin: sudo -u folien folien-admin seed-admin <name>")
   ;; bin/backup.scm runs pg_dump
   (depends "postgresql-client")
   (recommends "postgresql" "dabscm-fonts")
   (services "folien.service")
   (timers "folien-health.timer"
           "folien-restart.timer"
           "folien-maintenance.timer"
           "folien-backup.timer")
   (default-port . 8090)
   (copyright-notes
    "* The Inter typeface (/opt/folien/app/static/fonts/), by The Inter Project"
    "  Authors, under the SIL Open Font License 1.1:"
    ""
    ,@(read-lines (join-path root "static" "fonts" "Inter-LICENSE.txt"))))
 ;; releases/ in this repo unless --out says otherwise (a later --out wins)
 (cons* "--out" (join-path root "releases") (cdr (command-line))))
