## dokime — Compile-time validated SQL for Nimony.
##
## Usage:
##   import dokime
##   var db = openDatabase("mydb.sqlite")
##   let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
##   echo row.id  # int64
##   echo row.name  # string

import std/opt
import dokime/private/runtime

export opt, runtime

## Compile-time validated SQL query that requires at least one row.
##
## The SQL string is validated against your database at compile time.
## Set DOKIME_DATABASE_PATH to point to your development database.
##
## Example: query(db, "SELECT id, name FROM users WHERE id = ?", userId)
template query*(): untyped {.varargs, plugin: "dokime/private/plugins/queryone".}

## Compile-time validated SQL query that requires at least one row.
template queryOne*(): untyped {.varargs, plugin: "dokime/private/plugins/queryone".}

## Compile-time validated SQL query that returns Opt[row].
##
## Use for row-returning SQL where no row is an expected result.
template queryOpt*(): untyped {.varargs, plugin: "dokime/private/plugins/queryopt".}

## Compile-time validated SQL query that streams all returned rows.
template rows*(): untyped {.varargs, plugin: "dokime/private/plugins/rows".}

## Compile-time validated SQL command that returns execution metadata.
##
## Use for SQL that returns no result columns, such as INSERT, UPDATE, DELETE,
## DDL, BEGIN, COMMIT, and ROLLBACK.
template exec*(): untyped {.varargs, plugin: "dokime/private/plugins/exec".}
