## nsql — Compile-time validated SQL for Nimony.
##
## Usage:
##   import nsql/nsql
##   var db = openDatabase("mydb.sqlite")
##   let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
##   echo row.id  # int64
##   echo row.name  # string

import sqlite3

template sqliteTransient(): pointer =
  cast[pointer](-1)

proc stringBytes(s: string): cstring {.inline.} =
  cast[cstring](readRawData(s))

# ---- Connection management ----

proc openDatabaseCString(path: cstring): sqlite3.DbConn =
  var db: sqlite3.DbConn = nil
  let rc = sqlite3_open_v2(
    path,
    db,
    cint(SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE),
    nil
  )
  if rc != SQLITE_OK:
    # Can't use exceptions yet (Nimony), so write to stderr and quit
    # TODO: proper error handling
    discard sqlite3_close_v2(db)
    db = nil
  result = db

proc openDatabase*(path: string): sqlite3.DbConn =
  # SQLite's filename API is NUL-terminated only, so dynamic strings need one
  # materialized cstring boundary. Length-counted SQL/text paths avoid this.
  var pathMut = path
  result = openDatabaseCString(toCString(pathMut))

proc closeDatabase*(db: sqlite3.DbConn) =
  discard sqlite3_close_v2(db)

# ---- Statement lifecycle ----

proc prepareStmtBytes(db: sqlite3.DbConn; sql: cstring; sqlLen: int): sqlite3.Stmt =
  var stmt: sqlite3.Stmt = nil
  let rc = sqlite3_prepare_v2(db, sql, sqlLen.cint, stmt, nil)
  if rc != SQLITE_OK:
    stmt = nil
  result = stmt

template prepareStmtSql*(db: sqlite3.DbConn; sql: typed; sqlLen: int): sqlite3.Stmt =
  prepareStmtBytes(db, cstring(sql), sqlLen)

proc prepareStmt*(db: sqlite3.DbConn; sql: string): sqlite3.Stmt =
  result = prepareStmtBytes(db, stringBytes(sql), sql.len)

proc finalizeStmt*(stmt: sqlite3.Stmt) =
  discard sqlite3_finalize(stmt)

proc stepStmt*(stmt: sqlite3.Stmt): cint =
  result = sqlite3_step(stmt)

# ---- Parameter binding ----

proc bindInt64*(stmt: sqlite3.Stmt; idx: int; value: int64): bool =
  result = sqlite3_bind_int64(stmt, idx.cint, value) == SQLITE_OK

proc bindText*(stmt: sqlite3.Stmt; idx: int; value: string): bool =
  result = sqlite3_bind_text(
    stmt,
    idx.cint,
    stringBytes(value),
    value.len.cint,
    sqliteTransient()
  ) == SQLITE_OK

proc bindFloat64*(stmt: sqlite3.Stmt; idx: int; value: float64): bool =
  result = sqlite3_bind_double(stmt, idx.cint, value) == SQLITE_OK

# ---- Overloaded bindParam — the plugin generates calls to these ----
# The compiler picks the right overload based on the argument type at the call site.

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: int64) =
  discard sqlite3_bind_int64(stmt, idx.cint, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: string) =
  discard sqlite3_bind_text(
    stmt,
    idx.cint,
    stringBytes(value),
    value.len.cint,
    sqliteTransient()
  )

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: float64) =
  discard sqlite3_bind_double(stmt, idx.cint, value)

# ---- Column value extraction ----

proc columnInt64*(stmt: sqlite3.Stmt; col: int): int64 =
  result = sqlite3_column_int64(stmt, col.cint)

proc columnString*(stmt: sqlite3.Stmt; col: int): string =
  let cstr = sqlite3_column_text(stmt, col.cint)
  if cstr != nil:
    result = fromCString(cstr)
  else:
    result = ""

proc columnFloat64*(stmt: sqlite3.Stmt; col: int): float64 =
  result = sqlite3_column_double(stmt, col.cint)

# ---- Misc ----

proc execSql*(db: sqlite3.DbConn; sql: string): bool =
  let stmt = prepareStmt(db, sql)
  if stmt == nil:
    return false

  let rc = sqlite3_step(stmt)
  discard sqlite3_finalize(stmt)
  result = rc == SQLITE_DONE or rc == SQLITE_ROW

proc lastInsertRowid*(db: sqlite3.DbConn): int64 =
  result = sqlite3_last_insert_rowid(db)

proc changes*(db: sqlite3.DbConn): int64 =
  result = sqlite3_changes(db).int64

## Compile-time validated SQL query.
##
## The SQL string is validated against your database at compile time.
## Set NSQL_DATABASE_PATH to point to your development database.
##
## Example: query(db, "SELECT id, name FROM users WHERE id = ?", userId)
template query*(): untyped {.varargs, plugin: "nsqlplug".}
