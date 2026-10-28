;; (build deb) — pure-Scheme writers for the .deb container: USTAR tar,
;; ar, and the deb wrapper (debian-binary + control.tar.gz + data.tar.gz).
;; No native tar/ar/dpkg-deb, so packaging/package-deb.scm runs on Linux
;; and native Windows alike and produces identical bytes.
;;
;; Taken over from the SPLG build system (splg/buildsys), where the same
;; writer builds the platform's packages.
;;
;; Modes and owners never come from the filesystem: every entry carries an
;; explicit mode, uid/gid are 0 and uname/gname "root", and one mtime is
;; used for all entries (the commit time), so the output is reproducible.
;;
;; An entry is (name mode content): name is the archive path without the
;; "./" prefix (directories end in "/"), mode an integer (#o755), content a
;; bytevector (#f for a directory).

(define-library (build deb)
  (export tar-bytevector
          ar-bytevector
          deb-bytevector
          add-parent-dirs
          sort-entries
          entry-name entry-mode entry-content)
  (import (scheme base)
          (scheme char)
          (srfi 1)
          (srfi 13)
          (srfi 95)
          (scm archive))
  (begin

    (define (entry-name e)    (list-ref e 0))
    (define (entry-mode e)    (list-ref e 1))
    (define (entry-content e) (list-ref e 2))
    (define (dir-entry? e)    (string-suffix? "/" (entry-name e)))

    ;; --- low-level byte helpers ---------------------------------------------

    (define (poke-string! bv off s)
      (bytevector-copy! bv off (string->utf8 s)))

    (define (pad-left s n ch)
      (let ((len (string-length s)))
        (if (>= len n) s (string-append (make-string (- n len) ch) s))))

    (define (pad-right s n)
      (let ((len (string-length s)))
        (if (>= len n) s (string-append s (make-string (- n len) #\space)))))

    ;; width-1 zero-padded octal digits; the trailing byte stays NUL.
    (define (octal-field! bv off width n)
      (let ((s (number->string n 8)))
        (when (> (string-length s) (- width 1))
          (error "tar: value too large for header field" n))
        (poke-string! bv off (pad-left s (- width 1) #\0))))

    ;; --- tar (USTAR) --------------------------------------------------------

    ;; Split name into (prefix . suffix) at a "/" so the suffix fits in 100
    ;; and the prefix in 155 bytes; #f if impossible.
    (define (ustar-split name)
      (let loop ((i (- (string-length name) 1)))
        (cond ((< i 0) #f)
              ((char=? (string-ref name i) #\/)
               (let ((prefix (substring name 0 i))
                     (suffix (substring name (+ i 1) (string-length name))))
                 (if (and (> (string-length suffix) 0)
                          (<= (bytevector-length (string->utf8 suffix)) 100)
                          (<= (bytevector-length (string->utf8 prefix)) 155))
                     (cons prefix suffix)
                     (loop (- i 1)))))
              (else (loop (- i 1))))))

    (define (tar-header name mode size mtime typeflag)
      (let ((bv (make-bytevector 512 0)))
        (if (<= (bytevector-length (string->utf8 name)) 100)
            (poke-string! bv 0 name)
            (let ((split (ustar-split name)))
              (unless split
                (error "tar: path too long for USTAR" name))
              (poke-string! bv 345 (car split))
              (poke-string! bv 0 (cdr split))))
        (octal-field! bv 100 8 mode)
        (octal-field! bv 108 8 0)             ; uid
        (octal-field! bv 116 8 0)             ; gid
        (octal-field! bv 124 12 size)
        (octal-field! bv 136 12 mtime)
        (bytevector-u8-set! bv 156 (char->integer typeflag))
        (poke-string! bv 257 "ustar")         ; magic "ustar\0"
        (poke-string! bv 263 "00")            ; version
        (poke-string! bv 265 "root")          ; uname
        (poke-string! bv 297 "root")          ; gname
        ;; checksum: sum of all bytes with the field as spaces, written as
        ;; 6 octal digits + NUL + space.
        (bytevector-copy! bv 148 (make-bytevector 8 32))
        (let loop ((i 0) (sum 0))
          (if (< i 512)
              (loop (+ i 1) (+ sum (bytevector-u8-ref bv i)))
              (begin
                (poke-string! bv 148 (pad-left (number->string sum 8) 6 #\0))
                (bytevector-u8-set! bv 154 0)
                (bytevector-u8-set! bv 155 32))))
        bv))

    ;; entries -> uncompressed tar bytevector; names get the "./" prefix and
    ;; the archive starts with the "./" root directory, as dpkg-deb writes it.
    (define (tar-bytevector entries mtime)
      (let ((port (open-output-bytevector)))
        (write-bytevector (tar-header "./" #o755 0 mtime #\5) port)
        (for-each
          (lambda (e)
            (let ((name (string-append "./" (entry-name e))))
              (if (dir-entry? e)
                  (write-bytevector (tar-header name (entry-mode e) 0 mtime #\5) port)
                  (let* ((bytes (entry-content e))
                         (size (bytevector-length bytes))
                         (rem (modulo size 512)))
                    (write-bytevector (tar-header name (entry-mode e) size mtime #\0) port)
                    (write-bytevector bytes port)
                    (when (> rem 0)
                      (write-bytevector (make-bytevector (- 512 rem) 0) port))))))
          entries)
        (write-bytevector (make-bytevector 1024 0) port) ; end-of-archive
        (get-output-bytevector port)))

    ;; --- ar -----------------------------------------------------------------

    ;; members: ((name bytevector) ...). Common ar format as dpkg expects:
    ;; "!<arch>\n", 60-byte ASCII headers, data padded to an even length.
    (define (ar-bytevector members mtime)
      (let ((port (open-output-bytevector)))
        (write-bytevector (string->utf8 "!<arch>\n") port)
        (for-each
          (lambda (m)
            (let* ((name (car m))
                   (data (cadr m))
                   (size (bytevector-length data)))
              (when (> (string-length name) 15)
                (error "ar: member name too long" name))
              (write-bytevector
                (string->utf8
                  (string-append (pad-right (string-append name "/") 16)
                                 (pad-right (number->string mtime) 12)
                                 (pad-right "0" 6)          ; uid
                                 (pad-right "0" 6)          ; gid
                                 (pad-right "100644" 8)     ; mode (octal)
                                 (pad-right (number->string size) 10)
                                 "`\n"))
                port)
              (write-bytevector data port)
              (when (odd? size) (write-bytevector (bytevector 10) port))))
          members)
        (get-output-bytevector port)))

    ;; --- entries ------------------------------------------------------------

    (define (parent-dirs name)
      ;; "a/b/c" or "a/b/c/" -> ("a/" "a/b/")
      (let* ((trimmed (if (string-suffix? "/" name)
                          (substring name 0 (- (string-length name) 1))
                          name)))
        (let loop ((i 0) (acc '()))
          (cond ((>= i (string-length trimmed)) (reverse acc))
                ((char=? (string-ref trimmed i) #\/)
                 (loop (+ i 1) (cons (substring trimmed 0 (+ i 1)) acc)))
                (else (loop (+ i 1) acc))))))

    ;; Add an explicit 0755 entry for every missing parent directory.
    (define (add-parent-dirs entries)
      (let* ((have (map entry-name entries))
             (dirs (delete-duplicates
                     (append-map (lambda (e) (parent-dirs (entry-name e))) entries)))
             (missing (remove (lambda (d) (member d have)) dirs)))
        (append (map (lambda (d) (list d #o755 #f)) missing) entries)))

    ;; Sort by name so a directory precedes its contents and the order is
    ;; stable across hosts.
    (define (sort-entries entries)
      (sort entries (lambda (a b) (string<? (entry-name a) (entry-name b)))))

    ;; control-entries / data-entries: entry lists (parents are added here).
    (define (deb-bytevector control-entries data-entries mtime)
      (let ((control (tar-bytevector (sort-entries control-entries) mtime))
            (data (tar-bytevector (sort-entries (add-parent-dirs data-entries)) mtime)))
        (ar-bytevector
          (list (list "debian-binary" (string->utf8 "2.0\n"))
                (list "control.tar.gz" (gzip-compress control))
                (list "data.tar.gz" (gzip-compress data)))
          mtime)))))
