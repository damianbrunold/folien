;; (app jsbundle) — ES modules as one classic script.
;;
;; Browsers do not load ES modules from files (file:// pages), so the
;; offline player of a bundle gets the presentation code as one plain
;; script. The modules of static/js are simple enough to transform line
;; by line: their imports are `import { a, b } from "./x.js";` (possibly
;; over several lines) or `import * as ns from "./x.js";`, their exports
;; `export function | async function | class | const | let name`. Each
;; module becomes a function returning its exports, run in dependency
;; order (the caller lists the files so) inside one strict IIFE.

(define-library (app jsbundle)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (scm string))
  (export bundle-modules)
  (begin

    (define (string-prefix? p s)
      (and (>= (string-length s) (string-length p))
           (string=? (substring s 0 (string-length p)) p)))

    (define (trim-left s)
      (let loop ((i 0))
        (if (and (< i (string-length s)) (char-whitespace? (string-ref s i)))
            (loop (+ i 1))
            (substring s i (string-length s)))))

    (define (index-of s part from)
      (string-contains-from s part from))

    (define (read-text path)
      (call-with-input-file path
        (lambda (p)
          (let loop ((acc '()))
            (let ((l (read-line p)))
              (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

    ;; "./render.js" -> "render.js"
    (define (module-name spec)
      (if (string-prefix? "./" spec) (substring spec 2 (string-length spec)) spec))

    ;; The quoted module of an import statement's text.
    (define (import-source text)
      (let* ((i (index-of text "from" 0))
             (q1 (and i (index-of text "\"" i)))
             (q2 (and q1 (index-of text "\"" (+ q1 1)))))
        (and q2 (module-name (substring text (+ q1 1) q2)))))

    ;; The replacement of an import statement.
    (define (import->js text)
      (let ((src (import-source text))
            (star (index-of text "* as " 0)))
        (cond
          ((not src) (error "jsbundle: cannot read import" text))
          (star
           (let* ((start (+ star 5))
                  (end (let loop ((i start))
                         (if (or (= i (string-length text))
                                 (char-whitespace? (string-ref text i)))
                             i
                             (loop (+ i 1))))))
             (string-append "const " (substring text start end) " = __import(\"" src "\");")))
          (else
           (let* ((open (index-of text "{" 0))
                  (close (index-of text "}" 0))
                  (names (string-replace-all (substring text (+ open 1) close) " as " ": ")))
             (string-append "const {" names "} = __import(\"" src "\");"))))))

    (define export-forms
      '(("export async function " . "async function ")
        ("export function " . "function ")
        ("export class " . "class ")
        ("export const " . "const ")
        ("export let " . "let ")))

    ;; The name declared after a keyword prefix.
    (define (declared-name rest)
      (let loop ((i 0))
        (if (or (= i (string-length rest))
                (memv (string-ref rest i) '(#\( #\space #\= #\{ #\;)))
            (substring rest 0 i)
            (loop (+ i 1)))))

    ;; Transforms one module: (lines . exported-names).
    (define (transform lines)
      (let loop ((ls lines) (out '()) (names '()) (pending #f))
        (cond
          ((null? ls)
           (when pending (error "jsbundle: unfinished import" pending))
           (cons (reverse out) (reverse names)))
          (pending
           (let ((text (string-append pending " " (trim-left (car ls)))))
             (if (index-of text "from \"" 0)
                 (loop (cdr ls) (cons (import->js text) out) names #f)
                 (loop (cdr ls) out names text))))
          ((string-prefix? "import " (car ls))
           (if (index-of (car ls) "from \"" 0)
               (loop (cdr ls) (cons (import->js (car ls)) out) names #f)
               (loop (cdr ls) out names (car ls))))
          (else
           (let ((form (let find ((fs export-forms))
                         (cond ((null? fs) #f)
                               ((string-prefix? (car (car fs)) (car ls)) (car fs))
                               (else (find (cdr fs)))))))
             (if form
                 (let* ((rest (substring (car ls) (string-length (car form)) (string-length (car ls))))
                        (name (declared-name rest)))
                   (loop (cdr ls) (cons (string-append (cdr form) rest) out)
                         (cons name names) #f))
                 (loop (cdr ls) (cons (car ls) out) names #f)))))))

    (define (join lines)
      (let loop ((ls lines) (acc '()))
        (if (null? ls)
            (apply string-append (reverse acc))
            (loop (cdr ls) (cons "\n" (cons (car ls) acc))))))

    (define (bundle-modules dir files)
      "Syntax: (bundle-modules dir files)
Library: (app jsbundle)
Description: The ES modules files (names in dir, dependencies first) as
  one classic script (a string): the last module is the entry point."
      (string-append
       "// Built from static/js by src/app-jsbundle.sld (folien).\n"
       "(function () {\n\"use strict\";\nconst __modules = {};\n"
       "function __import(name) {\n"
       "  if (!(name in __modules)) throw new Error(\"module not bundled: \" + name);\n"
       "  return __modules[name];\n}\n"
       (apply string-append
              (map (lambda (f)
                     (let* ((t (transform (read-text (string-append dir "/" f))))
                            (names (cdr t)))
                       (string-append
                        "\n// --- " f " ---\n"
                        "__modules[\"" f "\"] = (function () {\n"
                        (join (car t))
                        "return {"
                        (let loop ((ns names) (acc ""))
                          (cond ((null? ns) acc)
                                ((string=? acc "") (loop (cdr ns) (car ns)))
                                (else (loop (cdr ns) (string-append acc ", " (car ns))))))
                        "};\n})();\n")))
                   files))
       "})();\n"))))
