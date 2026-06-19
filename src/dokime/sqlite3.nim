## SQLite3 FFI bindings for Nimony.
##
## Uses dynlib loading to avoid C type mismatches between Nimony's
## generated types and sqlite3.h. Types are kept opaque.

when defined(windows):
  const SqliteLib = "sqlite3.dll"
elif defined(macosx):
  const SqliteLib = "libsqlite3.dylib"
else:
  const SqliteLib = "libsqlite3.so"

{.pragma: sql, cdecl, dynlib: SqliteLib.}

# ---- Opaque handle types ----

type
  Sqlite3Obj* = object
  Sqlite3Stmt* = object

  DbConn* = nil ptr Sqlite3Obj
  Stmt* = nil ptr Sqlite3Stmt

# ---- Result codes ----

const
  SQLITE_OK*: cint         = 0
  SQLITE_ERROR*: cint      = 1
  SQLITE_INTERNAL*: cint   = 2
  SQLITE_PERM*: cint       = 3
  SQLITE_ABORT*: cint      = 4
  SQLITE_BUSY*: cint       = 5
  SQLITE_LOCKED*: cint     = 6
  SQLITE_NOMEM*: cint      = 7
  SQLITE_READONLY*: cint   = 8
  SQLITE_INTERRUPT*: cint  = 9
  SQLITE_IOERR*: cint      = 10
  SQLITE_CORRUPT*: cint    = 11
  SQLITE_NOTFOUND*: cint   = 12
  SQLITE_FULL*: cint       = 13
  SQLITE_CANTOPEN*: cint   = 14
  SQLITE_PROTOCOL*: cint   = 15
  SQLITE_EMPTY*: cint      = 16
  SQLITE_SCHEMA*: cint     = 17
  SQLITE_TOOBIG*: cint     = 18
  SQLITE_CONSTRAINT*: cint = 19
  SQLITE_MISMATCH*: cint   = 20
  SQLITE_MISUSE*: cint     = 21
  SQLITE_NOLFS*: cint      = 22
  SQLITE_AUTH*: cint       = 23
  SQLITE_FORMAT*: cint     = 24
  SQLITE_RANGE*: cint      = 25
  SQLITE_NOTADB*: cint     = 26
  SQLITE_ROW*: cint        = 100
  SQLITE_DONE*: cint       = 101

# --- Fundamental datatypes (sqlite3_column_type) ---

const
  SQLITE_INTEGER*: cint = 1
  SQLITE_FLOAT*: cint   = 2
  SQLITE_TEXT*: cint    = 3
  SQLITE_BLOB*: cint    = 4
  SQLITE_NULL*: cint    = 5

# --- Open flags ---

const
  SQLITE_OPEN_READWRITE*: cint = 0x00000002
  SQLITE_OPEN_CREATE*: cint    = 0x00000004

# ---- Connection management ----

proc sqlite3_open_v2*(filename: cstring; ppDb: var DbConn; flags: cint;
    zVfs: nil cstring): cint {.sql, importc: "sqlite3_open_v2".}

proc sqlite3_close_v2*(db: DbConn): cint {.sql, importc: "sqlite3_close_v2".}

proc sqlite3_errmsg*(db: DbConn): nil cstring {.sql, importc: "sqlite3_errmsg".}

# ---- Simple execution (DDL, no params) ----

proc sqlite3_exec*(db: DbConn; sql: cstring; callback: nil pointer;
    callbackArg: nil pointer; errmsg: nil ptr cstring): cint {.sql,
    importc: "sqlite3_exec".}

# ---- Prepared statements ----

proc sqlite3_prepare_v2*(db: DbConn; zSql: cstring; nByte: cint;
    ppStmt: var Stmt; pzTail: nil ptr cstring): cint {.sql, importc: "sqlite3_prepare_v2".}

proc sqlite3_step*(s: Stmt): cint {.sql, importc: "sqlite3_step".}

proc sqlite3_finalize*(s: Stmt): cint {.sql, importc: "sqlite3_finalize".}

proc sqlite3_reset*(s: Stmt): cint {.sql, importc: "sqlite3_reset".}

proc sqlite3_stmt_readonly*(s: Stmt): cint {.sql, importc: "sqlite3_stmt_readonly".}

# ---- Parameter binding ----

proc sqlite3_bind_parameter_count*(s: Stmt): cint {.sql, importc: "sqlite3_bind_parameter_count".}

proc sqlite3_bind_int64*(s: Stmt, idx: cint, value: int64): cint {.sql, importc: "sqlite3_bind_int64".}

proc sqlite3_bind_text*(s: Stmt, idx: cint, text: cstring, n: cint,
    destructor: nil pointer): cint {.sql, importc: "sqlite3_bind_text".}

proc sqlite3_bind_double*(s: Stmt, idx: cint, value: float64): cint {.sql, importc: "sqlite3_bind_double".}

proc sqlite3_bind_null*(s: Stmt, idx: cint): cint {.sql, importc: "sqlite3_bind_null".}

# ---- Column metadata ----

proc sqlite3_column_count*(s: Stmt): cint {.sql, importc: "sqlite3_column_count".}

proc sqlite3_column_type*(s: Stmt, col: cint): cint {.sql, importc: "sqlite3_column_type".}

proc sqlite3_column_name*(s: Stmt, col: cint): nil cstring {.sql, importc: "sqlite3_column_name".}

proc sqlite3_column_decltype*(s: Stmt, col: cint): nil cstring {.sql, importc: "sqlite3_column_decltype".}

proc sqlite3_column_database_name*(s: Stmt, col: cint): nil cstring {.sql,
    importc: "sqlite3_column_database_name".}

proc sqlite3_column_table_name*(s: Stmt, col: cint): nil cstring {.sql, importc: "sqlite3_column_table_name".}

proc sqlite3_column_origin_name*(s: Stmt, col: cint): nil cstring {.sql,
    importc: "sqlite3_column_origin_name".}

proc sqlite3_table_column_metadata*(db: DbConn; dbName: nil cstring;
    tableName: cstring; columnName: cstring; dataType: nil ptr cstring;
    collSeq: nil ptr cstring; notNull: var cint; primaryKey: var cint;
    autoInc: var cint): cint {.sql, importc: "sqlite3_table_column_metadata".}

proc sqlite3_column_int64*(s: Stmt, col: cint): int64 {.sql, importc: "sqlite3_column_int64".}

proc sqlite3_column_text*(s: Stmt, col: cint): nil cstring {.sql, importc: "sqlite3_column_text".}

proc sqlite3_column_double*(s: Stmt, col: cint): float64 {.sql, importc: "sqlite3_column_double".}

# ---- Misc ----

proc sqlite3_changes*(db: DbConn): cint {.sql, importc: "sqlite3_changes".}

proc sqlite3_last_insert_rowid*(db: DbConn): int64 {.sql, importc: "sqlite3_last_insert_rowid".}
