import std/[opt, strutils]

import ".." / sqlite3

type
  RowSet*[T: tuple] = object
    stmt: sqlite3.Stmt
    rowShape: T

  SqlExecResult* = object
    changes*: int64
    lastInsertRowid*: int64

  DatabaseObj = object
    conn: sqlite3.DbConn
    txActive: bool

  Transaction* = object
    db: Database
    active: bool

  Database* = ref DatabaseObj

template sqliteTransient(): pointer =
  cast[pointer](-1)

proc `=destroy`(db: DatabaseObj) {.raises: [].} =
  if db.conn != nil:
    if db.txActive:
      discard sqlite3_exec(db.conn, cstring("ROLLBACK"), nil, nil, nil)
    discard sqlite3_close_v2(db.conn)

proc `=destroy`(tx: Transaction) {.raises: [].} =
  if tx.db != nil and tx.active and tx.db.conn != nil:
    discard sqlite3_exec(tx.db.conn, cstring("ROLLBACK"), nil, nil, nil)
    tx.db.txActive = false

proc `=wasMoved`(tx: var Transaction) {.raises: [].} =
  tx.db = nil
  tx.active = false

proc `=copy`(dest: var Transaction; src: Transaction) {.error.}

proc sqliteErrorCode(rc: cint): ErrorCode {.raises: [].} =
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

proc execSql(db: sqlite3.DbConn; sql: cstring) {.raises.} =
  checkSqlite(sqlite3_exec(db, sql, nil, nil, nil))

proc requireOpenDatabase(db: Database): sqlite3.DbConn {.raises.} =
  if db == nil or db.conn == nil:
    raise BadOperation
  if db.txActive:
    raise BadOperation
  result = db.conn

proc requireActiveTransaction(tx: lent Transaction): sqlite3.DbConn {.raises.} =
  if tx.db == nil or tx.db.conn == nil or not tx.active:
    raise BadOperation
  result = tx.db.conn

proc validSavepointName(name: string): bool {.raises: [].} =
  if name.len == 0 or name.len > 63:
    return false

  if name[0] notin IdentStartChars:
    return false

  for ch in name:
    if ch notin IdentChars:
      return false

  result = true

proc savepointSql(name: string; keyword: string): string {.raises.} =
  if not validSavepointName(name):
    raise ValueError
  result = keyword & " " & name

proc isOpen*(db: Database): bool {.raises: [].} =
  result = db != nil and db.conn != nil

proc hasActiveTransaction*(db: Database): bool {.raises: [].} =
  result = db != nil and db.txActive

proc isActive*(tx: lent Transaction): bool {.raises: [].} =
  result = tx.db != nil and tx.db.conn != nil and tx.active

proc databaseHandle(db: sqlite3.DbConn): sqlite3.DbConn {.raises: [].} =
  result = db

proc databaseHandle(db: Database): sqlite3.DbConn {.raises.} =
  result = requireOpenDatabase(db)

proc databaseHandle(tx: lent Transaction): sqlite3.DbConn {.raises.} =
  result = requireActiveTransaction(tx)

proc openDatabaseCString(path: cstring): sqlite3.DbConn {.raises.} =
  var db: sqlite3.DbConn = nil
  let rc = sqlite3_open_v2(path, db, cint(SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE), nil)
  if rc != SQLITE_OK:
    if db != nil:
      discard sqlite3_close_v2(db)
    checkSqlite(rc)
  result = db

proc openRawDatabase*(path: sink string): sqlite3.DbConn {.raises.} =
  result = openDatabaseCString(toCString(path))

proc openDatabase*(path: sink string): Database {.raises.} =
  result = Database(conn: openDatabaseCString(toCString(path)), txActive: false)

proc closeDatabase*(db: sqlite3.DbConn) {.raises.} =
  checkSqlite(sqlite3_close_v2(db))

proc closeDatabase*(db: Database) {.raises.} =
  let conn = requireOpenDatabase(db)
  checkSqlite(sqlite3_close_v2(conn))
  db.conn = nil

proc beginTransaction*(db: Database): Transaction {.raises.} =
  let conn = requireOpenDatabase(db)
  execSql(conn, cstring("BEGIN"))
  db.txActive = true
  result = Transaction(db: db, active: true)

proc commit*(tx: var Transaction) {.raises.} =
  let conn = requireActiveTransaction(tx)
  execSql(conn, cstring("COMMIT"))
  tx.db.txActive = false
  tx.active = false

proc rollback*(tx: var Transaction) {.raises.} =
  let conn = requireActiveTransaction(tx)
  execSql(conn, cstring("ROLLBACK"))
  tx.db.txActive = false
  tx.active = false

proc rollbackIfActive*(tx: var Transaction) {.raises: [].} =
  if tx.db != nil and tx.db.conn != nil and tx.active:
    let rc = sqlite3_exec(tx.db.conn, cstring("ROLLBACK"), nil, nil, nil)
    if rc == SQLITE_OK:
      tx.db.txActive = false
      tx.active = false

proc savepoint*(tx: lent Transaction; name: string) {.raises.} =
  var sql = savepointSql(name, "SAVEPOINT")
  execSql(requireActiveTransaction(tx), toCString(sql))

proc releaseSavepoint*(tx: lent Transaction; name: string) {.raises.} =
  var sql = savepointSql(name, "RELEASE SAVEPOINT")
  execSql(requireActiveTransaction(tx), toCString(sql))

proc rollbackTo*(tx: lent Transaction; name: string) {.raises.} =
  var sql = savepointSql(name, "ROLLBACK TO SAVEPOINT")
  execSql(requireActiveTransaction(tx), toCString(sql))

proc prepareStmtBytes(db: sqlite3.DbConn; sql: cstring;
    sqlLen: int): sqlite3.Stmt {.raises.} =
  var stmt: sqlite3.Stmt = nil
  let rc = sqlite3_prepare_v2(db, sql, sqlLen.cint, stmt, nil)
  checkSqlite(rc)
  result = stmt

template prepareStmt*(target: untyped; sql: typed; sqlLen: int): untyped =
  prepareStmtBytes(databaseHandle(target), cstring(sql), sqlLen)

proc finalizeStmtCode*(stmt: sqlite3.Stmt): cint {.raises: [].} =
  result = sqlite3_finalize(stmt)

proc stepStmtCode*(stmt: sqlite3.Stmt): cint {.raises: [].} =
  result = sqlite3_step(stmt)

proc stepReturnedRow*(rc: cint): bool {.raises: [].} =
  result = rc == SQLITE_ROW

proc checkFinalizeCode*(rc: cint) {.raises.} =
  if rc != SQLITE_OK:
    checkSqlite(rc)

proc checkStepCode*(rc: cint) {.raises.} =
  if rc != SQLITE_ROW and rc != SQLITE_DONE:
    checkSqlite(rc)

proc requireStepRow*(rc: cint) {.raises.} =
  if rc != SQLITE_ROW:
    raise BadOperation

proc bindInt64(stmt: sqlite3.Stmt; idx: int; value: int64) {.raises.} =
  checkSqlite(sqlite3_bind_int64(stmt, idx.cint, value))

proc bindText(stmt: sqlite3.Stmt; idx: int; value: string) {.raises.} =
  var v = value
  checkSqlite(sqlite3_bind_text(stmt, idx.cint, toCString(v),
      value.len.cint, sqliteTransient()))

proc bindFloat64(stmt: sqlite3.Stmt; idx: int; value: float64) {.raises.} =
  checkSqlite(sqlite3_bind_double(stmt, idx.cint, value))

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: int64) {.raises.} =
  bindInt64(stmt, idx, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: string) {.raises.} =
  bindText(stmt, idx, value)

proc bindParam*(stmt: sqlite3.Stmt; idx: int; value: float64) {.raises.} =
  bindFloat64(stmt, idx, value)

proc columnInt64*(stmt: sqlite3.Stmt; col: int): int64 {.raises: [].} =
  result = sqlite3_column_int64(stmt, col.cint)

proc columnString*(stmt: sqlite3.Stmt; col: int): string {.raises: [].} =
  let cstr = sqlite3_column_text(stmt, col.cint)
  if cstr != nil:
    result = fromCString(cstr)
  else:
    result = ""

proc columnFloat64*(stmt: sqlite3.Stmt; col: int): float64 {.raises: [].} =
  result = sqlite3_column_double(stmt, col.cint)

proc columnOptInt64*(stmt: sqlite3.Stmt; col: int): Opt[int64] {.raises: [].} =
  if sqlite3_column_type(stmt, col.cint) == SQLITE_NULL:
    result = none[int64]()
  else:
    result = some(columnInt64(stmt, col))

proc columnOptString*(stmt: sqlite3.Stmt; col: int): Opt[string] {.raises: [].} =
  if sqlite3_column_type(stmt, col.cint) == SQLITE_NULL:
    result = none[string]()
  else:
    result = some(columnString(stmt, col))

proc columnOptFloat64*(stmt: sqlite3.Stmt; col: int): Opt[float64] {.raises: [].} =
  if sqlite3_column_type(stmt, col.cint) == SQLITE_NULL:
    result = none[float64]()
  else:
    result = some(columnFloat64(stmt, col))

proc initRows*[T: tuple](stmt: sqlite3.Stmt; rowShape: T): RowSet[T] {.raises: [].} =
  result = RowSet[T](stmt: stmt, rowShape: rowShape)

proc assignColumn(field: var int64; stmt: sqlite3.Stmt; col: int) {.raises: [].} =
  field = columnInt64(stmt, col)

proc assignColumn(field: var string; stmt: sqlite3.Stmt; col: int) {.raises: [].} =
  field = columnString(stmt, col)

proc assignColumn(field: var float64; stmt: sqlite3.Stmt; col: int) {.raises: [].} =
  field = columnFloat64(stmt, col)

proc assignColumn(field: var Opt[int64]; stmt: sqlite3.Stmt; col: int) {.raises: [].} =
  field = columnOptInt64(stmt, col)

proc assignColumn(field: var Opt[string]; stmt: sqlite3.Stmt; col: int) {.raises: [].} =
  field = columnOptString(stmt, col)

proc assignColumn(field: var Opt[float64]; stmt: sqlite3.Stmt; col: int) {.raises: [].} =
  field = columnOptFloat64(stmt, col)

proc decodeRow[T: tuple](rows: RowSet[T]): T {.raises: [].} =
  result = rows.rowShape
  var col = 0
  for _, field in fieldPairs(result):
    assignColumn(field, rows.stmt, col)
    inc col

iterator items*[T: tuple](rows: RowSet[T]): T {.sideEffect, raises.} =
  var
    stepRc = SQLITE_OK
    finalizeRc = SQLITE_OK
    exhausted = false
  try:
    while true:
      stepRc = stepStmtCode(rows.stmt)
      if stepRc == SQLITE_ROW:
        yield decodeRow(rows)
      else:
        exhausted = true
        break
  finally:
    finalizeRc = finalizeStmtCode(rows.stmt)
  if exhausted:
    checkStepCode(stepRc)
    checkFinalizeCode(finalizeRc)

proc execStmtForDb(db: sqlite3.DbConn; stmt: sqlite3.Stmt): SqlExecResult {.raises.} =
  result = SqlExecResult(changes: 0, lastInsertRowid: 0)
  let readOnly = sqlite3_stmt_readonly(stmt) != 0
  let stepRc = stepStmtCode(stmt)
  var
    resultChanges: int64 = 0
    resultLastInsertRowid: int64 = 0

  if stepRc == SQLITE_ROW or stepRc == SQLITE_DONE:
    if readOnly:
      resultChanges = 0
    else:
      resultChanges = sqlite3_changes(db).int64
    resultLastInsertRowid = sqlite3_last_insert_rowid(db)

  let finalizeRc = finalizeStmtCode(stmt)
  checkStepCode(stepRc)
  checkFinalizeCode(finalizeRc)

  result = SqlExecResult(
    changes: resultChanges,
    lastInsertRowid: resultLastInsertRowid
  )

template execStmt*(target: untyped; stmt: sqlite3.Stmt): untyped =
  execStmtForDb(databaseHandle(target), stmt)
