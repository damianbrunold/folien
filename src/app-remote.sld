;; (app remote) — messages between the windows presenting a deck: the
;; presentation, the presenter console and a remote control on another
;; device (a phone). Each listener is a WebSocket (GET .../socket, both
;; ways) or a server-sent event stream (GET /api/decks/<id>/events, with
;; POSTs to the same URL) and gets every message sent to its deck. The
;; messages are small JSON strings the
;; browsers interpret (see static/js/sync.js); positions in them are
;; absolute, so a message that reaches two windows does no harm.
;;
;; Every listener occupies one server thread while it is connected, so
;; the server's max-threads bounds how many presentations can be followed
;; at once.

(define-library (app remote)
  (import (scheme base)
          (srfi 18))
  (export subscribe!
          unsubscribe!
          publish!
          next-message
          listener-count)
  (begin

    ;; A queue of messages for one listener, with its own lock.
    (define-record-type listener
      (make-listener deck mutex cv queue)
      listener?
      (deck listener-deck)
      (mutex listener-mutex)
      (cv listener-cv)
      (queue listener-queue set-listener-queue!))

    ;; Messages beyond this are dropped (oldest first) for a listener that
    ;; does not keep up.
    (define max-queue 100)

    (define hub-mutex (make-mutex "remote-hub"))
    (define listeners '())          ; all current listeners

    (define (with-hub thunk)
      (dynamic-wind
        (lambda () (mutex-lock! hub-mutex))
        thunk
        (lambda () (mutex-unlock! hub-mutex))))

    (define (subscribe! deck-id)
      "Syntax: (subscribe! deck-id)
Library: (app remote)
Description: A new listener for the deck's messages."
      (let ((l (make-listener deck-id (make-mutex) (make-condition-variable) '())))
        (with-hub (lambda () (set! listeners (cons l listeners))))
        l))

    (define (unsubscribe! l)
      (with-hub (lambda () (set! listeners (filter-out l listeners)))))

    (define (filter-out x xs)
      (cond ((null? xs) '())
            ((eq? (car xs) x) (cdr xs))
            (else (cons (car xs) (filter-out x (cdr xs))))))

    (define (listener-count deck-id)
      (with-hub
       (lambda ()
         (let loop ((ls listeners) (n 0))
           (cond ((null? ls) n)
                 ((equal? (listener-deck (car ls)) deck-id) (loop (cdr ls) (+ n 1)))
                 (else (loop (cdr ls) n)))))))

    (define (drop-oldest q)
      (if (> (length q) max-queue) (cdr q) q))

    (define (publish! deck-id message)
      "Syntax: (publish! deck-id message)
Library: (app remote)
Description: Queues message (a string) for every listener of the deck
  and wakes them."
      (let ((targets (with-hub
                      (lambda ()
                        (let loop ((ls listeners) (acc '()))
                          (cond ((null? ls) acc)
                                ((equal? (listener-deck (car ls)) deck-id)
                                 (loop (cdr ls) (cons (car ls) acc)))
                                (else (loop (cdr ls) acc))))))))
        (for-each
         (lambda (l)
           (mutex-lock! (listener-mutex l))
           (set-listener-queue! l (drop-oldest (append (listener-queue l) (list message))))
           (condition-variable-broadcast! (listener-cv l))
           (mutex-unlock! (listener-mutex l)))
         targets)
        (length targets)))

    (define (next-message l timeout)
      "Syntax: (next-message listener timeout)
Library: (app remote)
Description: The listener's next message, waiting up to timeout seconds;
  #f if none came."
      (mutex-lock! (listener-mutex l))
      (let loop ()
        (let ((q (listener-queue l)))
          (if (pair? q)
              (begin
                (set-listener-queue! l (cdr q))
                (mutex-unlock! (listener-mutex l))
                (car q))
              ;; Waits (unlocked) until signalled or the timeout passes.
              (if (mutex-unlock! (listener-mutex l) (listener-cv l) timeout)
                  (begin (mutex-lock! (listener-mutex l)) (loop))
                  #f)))))))
