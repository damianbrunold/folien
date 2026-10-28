;; (app db) — database access: a connection pool, thin query helpers,
;; transactions and the migration runner. Every query is parameterized
;; ($1, $2, ...); values are never spliced into SQL strings, so there is no
;; injection surface. Higher layers call db-rows / db-exec and never touch
;; the driver.
;;
;; A db handle is either the pool or, inside with-db-transaction, the one
;; connection the transaction runs on. The helpers accept both, so query
;; functions work the same in and out of a transaction.

(define-library (app db)
  (import (scheme base)
          (scm log)
          (scm database postgres)
          (rename (scm database migrations)
                  (run-migrations! pg-migrations-run!)))
  (export make-db with-db-transaction db-rows db-row db-scalar db-exec migrate!)
  (begin

    (define-record-type db
      (%make-db pool conn)
      db?
      (pool db-pool)
      (conn db-conn))

    (define (make-db host port user password database pool-size)
      "Syntax: (make-db host port user password database pool-size)
Library: (app db)
Description: A pooled database handle for the query helpers. Connections
  are opened on first use."
      (%make-db (make-pg-pool host port user password database pool-size) #f))

    (define (with-conn db proc)
      (if (db-conn db)
          (proc (db-conn db))
          (with-pg-pool-connection (db-pool db) proc)))

    (define (with-db-transaction db proc)
      "Syntax: (with-db-transaction db proc)
Library: (app db)
Description: Calls (proc tx) inside a transaction, where tx is a db handle
  for the transaction's connection. Commits when proc returns; rolls back
  and re-raises when it raises."
      (if (db-conn db)
          (proc db)                     ; already in one: join it
          (with-pg-pool-connection (db-pool db)
            (lambda (conn)
              (with-pg-transaction conn
                (lambda (conn) (proc (%make-db (db-pool db) conn))))))))

    (define (db-rows db sql . params)
      "Syntax: (db-rows db sql [param ...])
Library: (app db)
Description: Runs a parameterized query; returns the rows as a list of
  alists keyed by column name."
      (with-conn db
        (lambda (c) (pg-result->alist-list (apply pg-query c sql params)))))

    (define (db-row db sql . params)
      "Syntax: (db-row db sql [param ...])
Library: (app db)
Description: The first row alist of the query, or #f if it has none."
      (let ((rows (apply db-rows db sql params)))
        (and (pair? rows) (car rows))))

    (define (db-scalar db sql . params)
      "Syntax: (db-scalar db sql [param ...])
Library: (app db)
Description: The first column of the first row (a count, a RETURNING id),
  or #f if the query produced no rows."
      (let ((row (apply db-row db sql params)))
        (and row (cdr (car row)))))

    (define (db-exec db sql . params)
      "Syntax: (db-exec db sql [param ...])
Library: (app db)
Description: Runs a parameterized statement (INSERT/UPDATE/DELETE/DDL)."
      (with-conn db (lambda (c) (apply pg-exec c sql params))))

    (define (migrate! db dir)
      "Syntax: (migrate! db dir)
Library: (app db)
Description: Applies the pending .sql migrations in dir in lexical order,
  each in its own transaction, and records them in schema_migrations."
      (with-conn db
        (lambda (conn)
          (pg-migrations-run!
            (lambda (sql) (pg-exec conn sql))
            (lambda (sql) (pg-result-rows (pg-query conn sql)))
            dir
            `((log-proc ,(lambda (m) (log-info "migrate" m))))))))))
