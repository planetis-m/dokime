## dokime — Compile-time validated SQL for Nimony.
##
## Usage:
##   import dokime
##   var db = openDatabase("mydb.sqlite")
##   let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
##   echo row.id  # int64
##   echo row.name  # string

import std / opt
import dokime/sqlite3
import dokime/types
import dokime/private/runtime

export types
export opt

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

## Compile-time validated SQL query that requires at least one row.
##
## The SQL string is validated against your database at compile time.
## Set DOKIME_DATABASE_PATH to point to your development database.
##
## Example: query(db, "SELECT id, name FROM users WHERE id = ?", userId)
template query*(): untyped {.varargs, plugin: "dokimeplugin".}

## Compile-time validated SQL query that requires at least one row.
template queryOne*(): untyped {.varargs, plugin: "dokimeplugin".}

## Compile-time validated SQL query that returns Opt[row].
##
## Use for row-returning SQL where no row is an expected result.
template queryOpt*(): untyped {.varargs, plugin: "dokimeoptplugin".}

## Compile-time validated SQL query that streams all returned rows.
template rows*(): untyped {.varargs, plugin: "dokimerowsplugin".}

## Compile-time validated SQL command that returns execution metadata.
##
## Use for SQL that returns no result columns, such as INSERT, UPDATE, DELETE,
## DDL, BEGIN, COMMIT, and ROLLBACK.
template exec*(): untyped {.varargs, plugin: "dokimeexecplugin".}
