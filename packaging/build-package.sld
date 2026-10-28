;; (build package) — the pure parts of packaging/package-deb.scm, kept
;; apart so tests/test_pure_deb.scm can check them without building
;; anything. After dashboards/packaging.

(define-library (build package)
  (export deb-version
          default-config-text
          secret-placeholder)
  (import (scheme base)
          (srfi 13)
          (scm datetime))
  (begin

    ;; Version: <commit time UTC as YYYY.MM.DD.HHMMSS>+g<hash>, so a newer
    ;; commit always sorts higher; ".dirty" marks a test build from a tree
    ;; with uncommitted changes.
    (define (deb-version epoch hash dirty?)
      (let* ((iso (format-iso8601 epoch))
             (stamp (string-append (substring iso 0 4) "." (substring iso 5 7) "."
                                   (substring iso 8 10) "."
                                   (substring iso 11 13) (substring iso 14 16)
                                   (substring iso 17 19))))
        (string-append stamp "+g" hash (if dirty? ".dirty" ""))))

    ;; postinst replaces this with a fresh secret on first install
    ;; (config.example.scm carries it as session-secret).
    (define secret-placeholder "REPLACE_WITH_BASE64_SECRET")

    (define (replace-define text name old new)
      (let* ((from (string-append "(define " name " " old ")"))
             (i (string-contains text from)))
        (and i
             (string-append (substring text 0 i)
                            "(define " name " " new ")"
                            (substring text (+ i (string-length from)) (string-length text))))))

    ;; The installed /etc/folien/config.scm: config.example.scm with the
    ;; data in /var/lib/folien and cookies over HTTPS only. Errors when the
    ;; example drifted from what this and postinst rely on.
    (define (default-config-text example)
      (unless (string-contains example (string-append "(define session-secret \"" secret-placeholder "\")"))
        (error "config.example.scm: no session-secret placeholder"))
      (unless (string-contains example "(define db-password \"change-me\")")
        (error "config.example.scm: db-password is no longer \"change-me\"; postinst relies on it"))
      (let* ((t1 (or (replace-define example "data-dir" "\"var\"" "\"/var/lib/folien\"")
                     (error "config.example.scm: no (define data-dir \"var\")")))
             (t2 (or (replace-define t1 "secure-cookies?" "#f" "#t")
                     (error "config.example.scm: no (define secure-cookies? #f)"))))
        (string-append
         ";; Installed by the folien package as /etc/folien/config.scm on first\n"
         ";; install (session-secret generated); never overwritten afterwards.\n"
         ";; The service starts once db-password is no longer \"change-me\".\n\n"
         t2)))))
