## nsql — Compile-time validated SQL for Nimony.
##
## Usage:
##   import nsql/nsql
##   var db = openDatabase("mydb.sqlite")
##   let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
##   echo row.id  # int64
##   echo row.name  # string

import nsql/sqlite3
import nsql/runtime

export sqlite3.DbConn, sqlite3.Stmt
export sqlite3.SQLITE_OK, sqlite3.SQLITE_ROW, sqlite3.SQLITE_DONE
export sqlite3.sqlite3_open_v2, sqlite3.sqlite3_close_v2, sqlite3.sqlite3_exec
export sqlite3.sqlite3_prepare_v2, sqlite3.sqlite3_step, sqlite3.sqlite3_finalize
export sqlite3.sqlite3_bind_int64, sqlite3.sqlite3_bind_text
export sqlite3.sqlite3_column_count, sqlite3.sqlite3_column_int64, sqlite3.sqlite3_column_text
export sqlite3.sqlite3_errmsg, sqlite3.sqlite3_changes, sqlite3.sqlite3_last_insert_rowid

export runtime.openDatabase, runtime.closeDatabase
export runtime.prepareStmt, runtime.finalizeStmt, runtime.stepStmt
export runtime.bindParam, runtime.bindInt64, runtime.bindText, runtime.bindFloat64
export runtime.columnInt64, runtime.columnString, runtime.columnFloat64
export runtime.execSql, runtime.lastInsertRowid, runtime.changes

## Compile-time validated SQL query.
##
## The SQL string is validated against your database at compile time.
## Set NSQL_DATABASE_PATH to point to your development database.
##
## Example: query(db, "SELECT id, name FROM users WHERE id = ?", userId)
template query*(): untyped {.varargs, plugin: "nsqlplug".}
