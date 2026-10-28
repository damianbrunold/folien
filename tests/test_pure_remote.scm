;; Tests for (app remote): the message hub behind the event streams.
;; Run: scm tests/test_pure_remote.scm

(import (scheme base)
        (scheme process-context)
        (srfi 18)
        (scm module)
        (scm fs)
        (scm test))

(define root
  (directory-name (directory-name (absolute-path (car (command-line))))))
(module-search-path! (cons (string-append root "/src") (module-search-path)))

(import (app remote))

(test-runner-factory scm-test-runner)
(test-begin "folien remote")

(test-group "messages reach the listeners of their deck"
  (let ((a (subscribe! "d1"))
        (b (subscribe! "d1"))
        (c (subscribe! "d2")))
    (test-equal 2 (listener-count "d1"))
    (test-equal 2 (publish! "d1" "one"))
    (publish! "d1" "two")
    (test-equal "one" (next-message a 1))
    (test-equal "two" (next-message a 1))
    (test-equal "one" (next-message b 1))
    (test-equal #f (next-message c 0.1))
    (unsubscribe! a)
    (unsubscribe! b)
    (unsubscribe! c)
    (test-equal 0 (listener-count "d1"))
    (test-equal 0 (publish! "d1" "nobody"))))

(test-group "a waiting listener wakes up"
  (let* ((l (subscribe! "d3"))
         (t (make-thread (lambda () (next-message l 5)))))
    (thread-start! t)
    (thread-sleep! 0.2)
    (publish! "d3" "hello")
    (test-equal "hello" (thread-join! t))
    (unsubscribe! l)))

(test-group "a listener that does not keep up loses the oldest"
  (let ((l (subscribe! "d4")))
    (do ((i 0 (+ i 1))) ((= i 150))
      (publish! "d4" (number->string i)))
    (test-equal "50" (next-message l 1))   ; 50..149 kept
    (unsubscribe! l)))

(test-end "folien remote")
