## dokime — Compile-time validated SQL for Nimony.
##
## Usage:
##   import dokime
##   var db = openDatabase("mydb.sqlite")
##   let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
##   echo row.id  # int64
##   echo row.name  # string

import dokime/sqlite3

template sqliteTransient(): pointer =
  cast[pointer](-1)

proc stringBytes(s: string): cstring {.inline.} =
  cast[cstring](readRawData(s))

proc sqliteErrorCode(rc: cint): ErrorCode =
  case rc
  of SQLITE_OK, SQLITE_ROW, SQLITE_DONE:
    result = Success
  of SQLITE_BUSY:
    result = BusyError
  of SQLITE_LOCKED:
    result = LockedError
  of SQLITE_NOMEM:
    result = OutOfMemError
  of SQLITE_READONLY:
    result = ReadonlyProtection
  of SQLITE_INTERRUPT:
    result = InterruptedError
  of SQLITE_IOERR, SQLITE_CANTOPEN, SQLITE_NOLFS:
    result = IOError
  of SQLITE_CORRUPT, SQLITE_NOTADB:
    result = DiskCorruption
  of SQLITE_FULL:
    result = DiskFullError
  of SQLITE_PERM, SQLITE_AUTH:
    result = PermissionDenied
  of SQLITE_NOTFOUND:
    result = NameNotFound
  of SQLITE_TOOBIG:
    result = ContentTooLong
  of SQLITE_RANGE, SQLITE_MISUSE, SQLITE_MISMATCH:
    result = ValueError
  of SQLITE_ABORT:
    result = AbortedOperation
  of SQLITE_PROTOCOL:
    result = ProtocolError
  of SQLITE_CONSTRAINT:
    result = BadOperation
  of SQLITE_SCHEMA, SQLITE_ERROR, SQLITE_INTERNAL, SQLITE_EMPTY, SQLITE_FORMAT:
    result = Failure
  else:
    result = Failure

proc checkSqlite(rc: cint) {.raises.} =
  let err = sqliteErrorCode(rc)
  if err != Success:
    raise err

# ---- Connection management ----

proc openDatabaseCString(path: cstring): sqlite3.DbConn {.raises.} =
  var db: sqlite3.DbConn = nil
  let rc = sqlite3_open_v2(
    path,
    db,
    cint(SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE),
    nil
  )
  if rc != SQLITE_OK:
    if db != nil:
      discard sqlite3_close_v2(db)
    checkSqlite(rc)
  result = db

proc openDatabase*(path: sink string): sqlite3.DbConn {.raises.} =
  # SQLite's filename API is NUL-terminated only, so dynamic strings need one
  # owned cstring boundary. Length-counted SQL/text paths avoid this.
  result = openDatabaseCString(toCString(path))

proc closeDatabase*(db: sqlite3.DbConn) {.raises.} =
  checkSqlite(sqlite3_close_v2(db))

# ---- Statement lifecycle ----

proc prepareStmtBytes(
  db: sqlite3.DbConn;
  sql: cstring;
  sqlLen: int
): sqlite3.Stmt {.raises.} =
  var stmt: sqlite3.Stmt = nil
  let rc = sqlite3_prepare_v2(db, sql, sqlLen.cint, stmt, nil)
  checkSqlite(rc)
  result = stmt

template prepareStmtSql*(db: sqlite3.DbConn; sql: typed; sqlLen: int): sqlite3.Stmt =
  prepareStmtBytes(db, cstring(sql), sqlLen)

proc prepareStmt*(db: sqlite3.DbConn; sql: string): sqlite3.Stmt {.raises.} =
  result = prepareStmtBytes(db, stringBytes(sql), sql.len)

proc finalizeStmt*(stmt: sqlite3.Stmt) {.raises.} =
  checkSqlite(sqlite3_finalize(stmt))

proc stepStmt*(stmt: sqlite3.Stmt): cint {.raises.} =
  result = sqlite3_step(stmt)
  checkSqlite(result)

# ---- Parameter binding ----

proc bindInt64*(stmt: sqlite3.Stmt; idx: int; value: int64) {.raises.} =
  checkSqlite(sqlite3_bind_int64(stmt, idx.cint, value))

proc bindText*(stmt: sqlite3.Stmt; idx: int; value: string) {.raises.} =
  checkSqlite(sqlite3_bind_text(
    stmt,
    idx.cint,
    stringBytes(value),
    value.len.cint,
    sqliteTransient()
  ))

proc bindFloat64*(stmt: sqlite3.Stmt; idx: int; value: float64) {.raises.} =
  checkSqlite(sqlite3_bind_double(stmt, idx.cint, value))

# ---- Overloaded bindParam — the plugin generates calls to these ----
# The compiler picks the right overload based on the argument type at the call site.

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: int64) {.raises.} =
  bindInt64(stmt, idx, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: string) {.raises.} =
  bindText(stmt, idx, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: float64) {.raises.} =
  bindFloat64(stmt, idx, value)

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

proc execSql*(db: sqlite3.DbConn; sql: string) {.raises.} =
  let stmt = prepareStmt(db, sql)
  try:
    discard stepStmt(stmt)
  finally:
    finalizeStmt(stmt)

proc lastInsertRowid*(db: sqlite3.DbConn): int64 =
  result = sqlite3_last_insert_rowid(db)

proc changes*(db: sqlite3.DbConn): int64 =
  result = sqlite3_changes(db).int64

## Compile-time validated SQL query.
##
## The SQL string is validated against your database at compile time.
## Set DOKIME_DATABASE_PATH to point to your development database.
##
## Example: query(db, "SELECT id, name FROM users WHERE id = ?", userId)
template query*(): untyped {.varargs, plugin: "dokimeplugin".}
