## nsql validation and codegen plugin.
##
## Receives `(stmts dbExpr "SQL string" param1 param2 ...)` from a varargs
## template call. Validates SQL at compile time, then generates a block
## expression that prepares, binds, executes, and decodes the query.
##
## This file is self-contained — it inlines SQLite FFI bindings because
## the plugin is compiled with Nimony's internal library paths only.

{.feature: "lenientnils".}

import plugins
import std/syncio
import std/envvars

# ---- Inline SQLite3 FFI ----

{.passL: "-lsqlite3".}

when defined(windows):
  const SqliteLib = "sqlite3.dll"
elif defined(macosx):
  const SqliteLib = "libsqlite3.dylib"
else:
  const SqliteLib = "libsqlite3.so"

{.pragma: sql, cdecl, dynlib: SqliteLib.}

type
  Sqlite3Obj = object
  Sqlite3Stmt = object
  DbConn = ptr Sqlite3Obj
  Stmt = ptr Sqlite3Stmt

const
  SQLITE_OK: cint    = 0
  SQLITE_ROW: cint   = 100
  SQLITE_DONE: cint  = 101
  SQLITE_OPEN_READWRITE: cint = 2

proc sqlite3_open_v2(filename: cstring, ppDb: var DbConn, flags: cint, zVfs: cstring): cint {.sql, importc: "sqlite3_open_v2".}
proc sqlite3_close_v2(db: DbConn): cint {.sql, importc: "sqlite3_close_v2".}
proc sqlite3_errmsg(db: DbConn): cstring {.sql, importc: "sqlite3_errmsg".}
proc sqlite3_prepare_v2(db: DbConn, zSql: cstring, nByte: cint, ppStmt: var Stmt, pzTail: ptr cstring): cint {.sql, importc: "sqlite3_prepare_v2".}
proc sqlite3_step(s: Stmt): cint {.sql, importc: "sqlite3_step".}
proc sqlite3_finalize(s: Stmt): cint {.sql, importc: "sqlite3_finalize".}
proc sqlite3_column_count(s: Stmt): cint {.sql, importc: "sqlite3_column_count".}
proc sqlite3_column_decltype(s: Stmt, col: cint): cstring {.sql, importc: "sqlite3_column_decltype".}
proc sqlite3_column_name(s: Stmt, col: cint): cstring {.sql, importc: "sqlite3_column_name".}

# ---- Column metadata ----

type
  ColumnKind = enum ckInteger, ckText, ckReal, ckBlob, ckNull

  ColumnMeta = object
    name: string
    declaredType: string
    kind: ColumnKind

proc toColumnKind(typeName: string): ColumnKind =
  case typeName
  of "INTEGER", "INT": ckInteger
  of "TEXT", "STRING": ckText
  of "REAL", "FLOAT", "DOUBLE": ckReal
  of "BLOB": ckBlob
  else: ckNull

proc nimTypeFromKind(k: ColumnKind): string =
  case k
  of ckInteger: "int64"
  of ckText: "string"
  of ckReal: "float64"
  of ckBlob: "seq[byte]"
  of ckNull: "string"

proc columnExtractor(k: ColumnKind): string =
  ## Returns the runtime helper proc name for extracting a column of this kind.
  case k
  of ckInteger: "columnInt64"
  of ckText, ckNull: "columnString"
  of ckReal: "columnFloat64"
  of ckBlob: "columnString"

# ---- SQL validation ----

proc validateSql(sql: string): tuple[columns: seq[ColumnMeta], error: string] =
  var
    columns: seq[ColumnMeta] = @[]
    errMsg: string = ""

  let dbPath = getEnv("NSQL_DATABASE_PATH")
  if dbPath.len == 0:
    errMsg = "NSQL_DATABASE_PATH not set"
  else:
    var dbPathMut = dbPath
    var db: DbConn = nil
    let rc = sqlite3_open_v2(toCString(dbPathMut), db, SQLITE_OPEN_READWRITE, nil)
    if rc != SQLITE_OK:
      let msg = if db != nil: fromCString(sqlite3_errmsg(db)) else: "open failed"
      errMsg = "cannot open database: " & msg
    else:
      var stmt: Stmt = nil
      var sqlMut = sql
      let prepRc = sqlite3_prepare_v2(db, toCString(sqlMut), sqlMut.len.cint, stmt, nil)
      if prepRc != SQLITE_OK:
        errMsg = fromCString(sqlite3_errmsg(db))
      else:
        let stepRc = sqlite3_step(stmt)
        if stepRc != SQLITE_ROW and stepRc != SQLITE_DONE:
          errMsg = fromCString(sqlite3_errmsg(db))
        else:
          let count = sqlite3_column_count(stmt)
          for i in 0..<count.int:
            let colName = fromCString(sqlite3_column_name(stmt, i.cint))
            let decltype = sqlite3_column_decltype(stmt, i.cint)
            let typeStr = if decltype != nil: fromCString(decltype) else: ""
            columns.add ColumnMeta(name: colName, declaredType: typeStr, kind: toColumnKind(typeStr))
        discard sqlite3_finalize(stmt)
      discard sqlite3_close_v2(db)

  result = (columns, errMsg)

# ---- Count ? placeholders in SQL ----

proc countParams(sql: string): int =
  result = 0
  for ch in sql:
    if ch == '?':
      inc result

# ---- Plugin entry point ----

var inp = loadPluginInput()

# Input: (stmts dbExpr "SQL" param1 param2 ...)
var dbExpr: NifCursor
var sqlStr = ""
var params: seq[NifCursor] = @[]
var paramCount = 0

if inp.kind == ParLe and inp.stmtKind == StmtsS:
  var child = firstChild(inp)
  while child.hasMore:
    if paramCount == 0:
      dbExpr = child
    elif paramCount == 1:
      if child.kind == StringLit:
        sqlStr = child.stringValue
      else:
        saveTree(errorTree("nsql: second argument must be a SQL string literal"))
        quit(0)
    else:
      params.add(child)
    skip child
    inc paramCount

if sqlStr.len == 0:
  saveTree(errorTree("nsql: expected query(db, \"SQL\", params...)"))
  quit(0)

stderr.writeLine("nsql: validating: " & sqlStr)
stderr.writeLine("nsql: " & $(paramCount - 2) & " bind parameters")

let (columns, errMsg) = validateSql(sqlStr)

if errMsg.len > 0:
  stderr.writeLine("nsql: ERROR: " & errMsg)
  saveTree(errorTree("nsql: " & errMsg))
else:
  stderr.writeLine("nsql: OK, " & $columns.len & " columns")
  for col in columns:
    stderr.writeLine("  " & col.name & " : " & col.declaredType)

  # Generate: block:
  #   var __stmt = prepareStmt(db, "SQL")
  #   bindParam(__stmt, 1, param1)
  #   bindParam(__stmt, 2, param2)
  #   discard stepStmt(__stmt)
  #   (col0: columnX(__stmt, 0), col1: columnY(__stmt, 1), ...)

  var result = createTree()
  result.withTree(BlockS, NoLineInfo):
    result.addDotToken()  # unlabeled block
    result.withTree(StmtsS, NoLineInfo):
      # var __nsql_stmt = prepareStmt(db, "SQL")
      result.withTree(VarS, NoLineInfo):
        result.addIdent("__nsql_stmt")
        result.addDotToken()  # type (inferred)
        result.addDotToken()  # pragmas
        result.addDotToken()  # value type
        result.withTree(CallX, NoLineInfo):
          result.addIdent("prepareStmt")
          result.addSubtree(dbExpr)
          result.addStrLit(sqlStr)

      # bindParam(__stmt, idx, param) for each parameter
      for i, paramCursor in params:
        result.withTree(CallX, NoLineInfo):
          result.addIdent("bindParam")
          result.addIdent("__nsql_stmt")
          result.addIntLit(i + 1)  # SQLite params are 1-based
          result.addSubtree(paramCursor)

      # discard stepStmt(__stmt)
      result.withTree(DiscardS, NoLineInfo):
        result.withTree(CallX, NoLineInfo):
          result.addIdent("stepStmt")
          result.addIdent("__nsql_stmt")

      # Result tuple: (kv name (call columnX __stmt idx))
      result.withTree(TupX, NoLineInfo):
        for i, col in columns:
          result.withTree(KvX, NoLineInfo):
            result.addIdent(col.name)
            result.withTree(CallX, NoLineInfo):
              result.addIdent(columnExtractor(col.kind))
              result.addIdent("__nsql_stmt")
              result.addIntLit(i)

  saveTree(result)
