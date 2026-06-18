## nsql validation and codegen plugin.
##
## Receives `(stmts dbExpr "SQL string" param1 param2 ...)` from a varargs
## template call. Validates SQL at compile time, then generates a block
## expression that prepares, binds, executes, and decodes the query.
##
{.feature: "lenientnils".}

import plugins
import std / [envvars, syncio]
import sqlite3

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

proc addPrepareStmtSql(t: var NifBuilder) =
  t.addIdent("prepareStmtSql")

proc addBindParam(t: var NifBuilder) =
  t.addIdent("bindParam")

proc addStepStmt(t: var NifBuilder) =
  t.addIdent("stepStmt")

proc addColumnExtractor(t: var NifBuilder; k: ColumnKind) =
  ## Emits the runtime helper symbol for extracting a column of this kind.
  case k
  of ckInteger:
    t.addIdent("columnInt64")
  of ckText, ckNull:
    t.addIdent("columnString")
  of ckReal:
    t.addIdent("columnFloat64")
  of ckBlob:
    t.addIdent("columnString")

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
    var db: sqlite3.DbConn = nil
    let rc = sqlite3_open_v2(
      toCString(dbPathMut),
      db,
      SQLITE_OPEN_READWRITE,
      nil
    )
    if rc != SQLITE_OK:
      let msg = if db != nil: fromCString(sqlite3_errmsg(db)) else: "open failed"
      errMsg = "cannot open database: " & msg
    else:
      var stmt: sqlite3.Stmt = nil
      let prepRc = sqlite3_prepare_v2(
        db,
        cast[cstring](readRawData(sql)),
        sql.len.cint,
        stmt,
        nil
      )
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
      # var __nsql_stmt = prepareStmtSql(db, "SQL", sqlLen)
      result.withTree(VarS, NoLineInfo):
        result.addIdent("__nsql_stmt")
        result.addDotToken()  # type (inferred)
        result.addDotToken()  # pragmas
        result.addDotToken()  # value type
        result.withTree(CallX, NoLineInfo):
          result.addPrepareStmtSql()
          result.addSubtree(dbExpr)
          result.addStrLit(sqlStr)
          result.addIntLit(sqlStr.len)

      # bindParam(__stmt, idx, param) for each parameter
      for i, paramCursor in params:
        result.withTree(CallX, NoLineInfo):
          result.addBindParam()
          result.addIdent("__nsql_stmt")
          result.addIntLit(i + 1)  # SQLite params are 1-based
          result.addSubtree(paramCursor)

      # discard stepStmt(__stmt)
      result.withTree(DiscardS, NoLineInfo):
        result.withTree(CallX, NoLineInfo):
          result.addStepStmt()
          result.addIdent("__nsql_stmt")

      # Result tuple: (kv name (call columnX __stmt idx))
      result.withTree(TupX, NoLineInfo):
        for i, col in columns:
          result.withTree(KvX, NoLineInfo):
            result.addIdent(col.name)
            result.withTree(CallX, NoLineInfo):
              result.addColumnExtractor(col.kind)
              result.addIdent("__nsql_stmt")
              result.addIntLit(i)

  saveTree(result)
