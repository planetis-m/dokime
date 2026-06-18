## dokime validation and codegen plugin.
##
## Receives `(stmts dbExpr "SQL string" param1 param2 ...)` from a varargs
## template call. Validates SQL at compile time, then generates a block
## expression that prepares, binds, executes, and decodes the query.
##

import plugins
import std / envvars
import dokime
import dokime/sqlite3

# ---- Column metadata ----

type
  ColumnKind = enum ckInteger, ckText, ckReal, ckBlob, ckNull

  ColumnMeta = object
    name: string
    declaredType: string
    kind: ColumnKind

  QueryInput = object
    dbExpr: NifCursor
    sql: string
    params: seq[NifCursor]
    bindCount: int
    hasSql: bool
    error: string
    errorAt: LineInfo

proc toColumnKind(typeName: string): ColumnKind =
  case typeName
  of "INTEGER", "INT": ckInteger
  of "TEXT", "STRING": ckText
  of "REAL", "FLOAT", "DOUBLE": ckReal
  of "BLOB": ckBlob
  else: ckNull

proc addColumnExtractor(t: var NifBuilder; k: ColumnKind) =
  ## Emits the runtime helper symbol for extracting a column of this kind.
  case k
  of ckInteger:
    t.bindSym("columnInt64")
  of ckText, ckNull:
    t.bindSym("columnString")
  of ckReal:
    t.bindSym("columnFloat64")
  of ckBlob:
    t.bindSym("columnString")

# ---- SQL validation ----

proc validateSql(sql: string): tuple[columns: seq[ColumnMeta], error: string] =
  var
    columns: seq[ColumnMeta] = @[]
    errMsg: string = ""

  var dbPath = getEnv("DOKIME_DATABASE_PATH")
  if dbPath.len == 0:
    errMsg = "DOKIME_DATABASE_PATH not set"
  else:
    var db: sqlite3.DbConn = nil
    let rc = sqlite3_open_v2(
      toCString(dbPath),
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

proc parseQueryInput(inp: NifCursor): QueryInput =
  result = QueryInput(
    dbExpr: inp,
    sql: "",
    params: @[],
    bindCount: 0,
    hasSql: false,
    error: "",
    errorAt: inp.info
  )
  if inp.kind != ParLe or inp.stmtKind != StmtsS:
    result.error = "dokime: invalid plugin input"
    return

  var child = inp
  child.loopInto:
    case result.bindCount
    of 0:
      result.dbExpr = child
    of 1:
      if child.kind == StringLit:
        result.sql = child.stringValue
        result.hasSql = true
      else:
        result.error = "dokime: second argument must be a SQL string literal"
        result.errorAt = child.info
    else:
      result.params.add(child)
    skip child
    inc result.bindCount

  if result.error.len == 0 and not result.hasSql:
    result.error = "dokime: expected query(db, \"SQL\", params...)"
    result.errorAt = inp.info

proc buildQueryTree(input: QueryInput; columns: seq[ColumnMeta]): NifBuilder =
  result = createTree()
  result.withTree(BlockS, input.errorAt):
    result.addEmptyNode()
    result.withTree(StmtsS, input.errorAt):
      result.withTree(VarS, NoLineInfo):
        result.addIdent("__dokime_stmt")
        result.addEmptyNode3()
        result.withTree(CallX, NoLineInfo):
          result.bindSym("prepareStmtSql")
          result.addSubtree(input.dbExpr)
          result.addStrLit(input.sql)
          result.addIntLit(input.sql.len)

      for i, paramCursor in input.params:
        result.withTree(CallX, NoLineInfo):
          result.bindSym("bindParam")
          result.addIdent("__dokime_stmt")
          result.addIntLit(i + 1)
          result.addSubtree(paramCursor)

      result.withTree(DiscardS, NoLineInfo):
        result.withTree(CallX, NoLineInfo):
          result.bindSym("stepStmt")
          result.addIdent("__dokime_stmt")

      result.withTree(TupX, NoLineInfo):
        for i, col in columns:
          result.withTree(KvX, NoLineInfo):
            result.addIdent(col.name)
            result.withTree(CallX, NoLineInfo):
              result.addColumnExtractor(col.kind)
              result.addIdent("__dokime_stmt")
              result.addIntLit(i)

proc generate(inp: NifCursor): NifBuilder =
  let query = parseQueryInput(inp)
  if query.error.len > 0:
    result = errorTree(query.error, query.errorAt)
  else:
    let (columns, errMsg) = validateSql(query.sql)
    if errMsg.len > 0:
      result = errorTree("dokime: " & errMsg, query.errorAt)
    else:
      result = buildQueryTree(query, columns)

let root = loadPluginInput()
saveTree generate(root)
