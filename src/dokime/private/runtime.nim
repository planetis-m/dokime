import ".." / sqlite3
import ".." / types

template sqliteTransient(): pointer =
  cast[pointer](-1)

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

proc prepareStmtBytes(
  db: sqlite3.DbConn;
  sql: cstring;
  sqlLen: int
): sqlite3.Stmt {.raises.} =
  var stmt: sqlite3.Stmt = nil
  let rc = sqlite3_prepare_v2(db, sql, sqlLen.cint, stmt, nil)
  checkSqlite(rc)
  result = stmt

template prepareStmt*(db: sqlite3.DbConn; sql: typed; sqlLen: int): sqlite3.Stmt =
  prepareStmtBytes(db, cstring(sql), sqlLen)

proc finalizeStmt*(stmt: sqlite3.Stmt) {.raises.} =
  checkSqlite(sqlite3_finalize(stmt))

proc stepStmt*(stmt: sqlite3.Stmt): cint {.raises.} =
  result = sqlite3_step(stmt)
  checkSqlite(result)

proc stmtReadOnly(stmt: sqlite3.Stmt): bool =
  result = sqlite3_stmt_readonly(stmt) != 0

proc bindInt64(stmt: sqlite3.Stmt; idx: int; value: int64) {.raises.} =
  checkSqlite(sqlite3_bind_int64(stmt, idx.cint, value))

proc bindText(stmt: sqlite3.Stmt; idx: int; value: string) {.raises.} =
  var v = value
  checkSqlite(sqlite3_bind_text(
    stmt,
    idx.cint,
    toCString(v),
    value.len.cint,
    sqliteTransient()
  ))

proc bindFloat64(stmt: sqlite3.Stmt; idx: int; value: float64) {.raises.} =
  checkSqlite(sqlite3_bind_double(stmt, idx.cint, value))

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: int64) {.raises.} =
  bindInt64(stmt, idx, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: string) {.raises.} =
  bindText(stmt, idx, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: float64) {.raises.} =
  bindFloat64(stmt, idx, value)

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

proc lastInsertRowid(db: sqlite3.DbConn): int64 =
  result = sqlite3_last_insert_rowid(db)

proc changes(db: sqlite3.DbConn): int64 =
  result = sqlite3_changes(db).int64

proc execStmt*(db: sqlite3.DbConn; stmt: sqlite3.Stmt): SqlExecResult {.raises.} =
  result = SqlExecResult(changes: 0, lastInsertRowid: 0)
  let readOnly = stmtReadOnly(stmt)
  var resultChanges: int64 = 0
  var resultLastInsertRowid: int64 = 0
  try:
    discard stepStmt(stmt)
    if readOnly:
      resultChanges = 0
    else:
      resultChanges = changes(db)
    resultLastInsertRowid = lastInsertRowid(db)
  finally:
    finalizeStmt(stmt)
  result = SqlExecResult(
    changes: resultChanges,
    lastInsertRowid: resultLastInsertRowid
  )
