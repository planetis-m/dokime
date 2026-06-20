## dokime — Compile-time validated SQL for Nimony.
##
## ```nim
## import dokime
## var db = openDatabase("mydb.sqlite")
## let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
## echo row.id     # int64
## echo row.name   # string
## ```

import std/opt
import dokime/private/dynamicruntime
import dokime/private/runtime

export opt, runtime

template query*(): untyped {.varargs, plugin: "dokime/private/plugins/queryone".}
  ## Compile-time validated SQL query that returns exactly one row.
  ##
  ## The SQL string is checked against your development database at compile time.
  ## Set `DOKIME_DATABASE_PATH` to point to that database.
  ##
  ## ```nim
  ## let row = query(db, "SELECT id, name FROM users WHERE id = ?", userId)
  ## echo row.id
  ## ```

template queryOne*(): untyped {.varargs, plugin: "dokime/private/plugins/queryone".}
  ## Alias for `query`.

template queryOpt*(): untyped {.varargs, plugin: "dokime/private/plugins/queryopt".}
  ## Compile-time validated SQL query that may return zero rows.
  ##
  ## Returns `Opt[tuple[...]]`.  Use when the absence of a matching row is
  ## expected and should not raise an error.
  ##
  ## ```nim
  ## let maybe = queryOpt(db, "SELECT name FROM users WHERE id = ?", uid)
  ## if maybe.isSome:
  ##   echo maybe.get.name
  ## ```

template rows*(): untyped {.varargs, plugin: "dokime/private/plugins/rows".}
  ## Compile-time validated SQL query that returns all matching rows.
  ##
  ## Returns a value that can be iterated with `for`:
  ##
  ## ```nim
  ## for row in rows(db, "SELECT id, name FROM users"):
  ##   echo row.id, " ", row.name
  ## ```

template exec*(): untyped {.varargs, plugin: "dokime/private/plugins/exec".}
  ## Compile-time validated SQL command with no result columns.
  ##
  ## Use for INSERT, UPDATE, DELETE, DDL, BEGIN, COMMIT, and ROLLBACK.
  ## Returns a `SqlExecResult` with `.changes` (rows affected) and
  ## `.lastInsertRowid` fields.
  ##
  ## ```nim
  ## let result = exec(db, "UPDATE users SET active = 1 WHERE id = ?", uid)
  ## echo result.changes
  ## ```
