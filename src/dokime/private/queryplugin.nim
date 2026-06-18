## Shared implementation for dokime query template plugins.

import plugins
import std / envvars
import runtime
import ".." / sqlite3

type
  QueryMode* = enum
    qmOne, qmOpt

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
  case k
  of ckInteger:
    t.bindSym("columnInt64")
  of ckText, ckNull:
    t.bindSym("columnString")
  of ckReal:
    t.bindSym("columnFloat64")
  of ckBlob:
    t.bindSym("columnString")

proc addDefaultValue(t: var NifBuilder; k: ColumnKind) =
  t.withTree(CallX, NoLineInfo):
    case k
    of ckInteger:
      t.bindSym("defaultInt64")
    of ckText, ckBlob, ckNull:
      t.bindSym("defaultString")
    of ckReal:
      t.bindSym("defaultFloat64")

proc addDefaultRow(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupX, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.addDefaultValue(col.kind)

proc addDecodedRow(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupX, NoLineInfo):
    for i, col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.withTree(CallX, NoLineInfo):
          t.addColumnExtractor(col.kind)
          t.addIdent("__dokime_stmt")
          t.addIntLit(i)

proc addFinalize(t: var NifBuilder) =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("finalizeStmt")
    t.addIdent("__dokime_stmt")

proc addPrepareAndBinds(t: var NifBuilder; input: QueryInput) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("prepareStmt")
      t.addSubtree(input.dbExpr)
      t.addStrLit(input.sql)
      t.addIntLit(input.sql.len)

  for i, paramCursor in input.params:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("bindParam")
      t.addIdent("__dokime_stmt")
      t.addIntLit(i + 1)
      t.addSubtree(paramCursor)

proc addRowResult(t: var NifBuilder; mode: QueryMode) =
  case mode
  of qmOne:
    t.addIdent("__dokime_row")
  of qmOpt:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("someRow")
      t.addIdent("__dokime_row")

proc addNoRowResult(t: var NifBuilder; mode: QueryMode) =
  t.withTree(CallX, NoLineInfo):
    case mode
    of qmOne:
      t.bindSym("missingRow")
    of qmOpt:
      t.bindSym("noneRow")
    t.addIdent("__dokime_row")

proc validateSql(sql: string): tuple[columns: seq[ColumnMeta], params: int, error: string] =
  var
    columns: seq[ColumnMeta] = @[]
    params = 0
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
      var s = sql
      let prepRc = sqlite3_prepare_v2(
        db,
        toCString(s),
        sql.len.cint,
        stmt,
        nil
      )
      if prepRc != SQLITE_OK:
        errMsg = fromCString(sqlite3_errmsg(db))
      else:
        params = sqlite3_bind_parameter_count(stmt).int
        let count = sqlite3_column_count(stmt)
        for i in 0..<count.int:
          let colName = fromCString(sqlite3_column_name(stmt, i.cint))
          let decltype = sqlite3_column_decltype(stmt, i.cint)
          let typeStr = if decltype != nil: fromCString(decltype) else: ""
          columns.add ColumnMeta(
            name: colName,
            declaredType: typeStr,
            kind: toColumnKind(typeStr)
          )
        discard sqlite3_finalize(stmt)
      discard sqlite3_close_v2(db)

  result = (columns, params, errMsg)

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

proc buildRowTree(
  input: QueryInput;
  columns: seq[ColumnMeta];
  mode: QueryMode
): NifBuilder =
  result = createTree()
  result.withTree(BlockS, input.errorAt):
    result.addEmptyNode()
    result.withTree(StmtsS, input.errorAt):
      result.addPrepareAndBinds(input)

      result.withTree(VarS, NoLineInfo):
        result.addIdent("__dokime_row")
        result.addEmptyNode3()
        result.addDefaultRow(columns)

      result.withTree(IfS, NoLineInfo):
        result.withTree(ElifU, NoLineInfo):
          result.withTree(CallX, NoLineInfo):
            result.bindSym("stepHasRow")
            result.addIdent("__dokime_stmt")
          result.withTree(StmtsS, NoLineInfo):
            result.withTree(AsgnS, NoLineInfo):
              result.addIdent("__dokime_row")
              result.addDecodedRow(columns)
            result.addFinalize()
            result.addRowResult(mode)
        result.withTree(ElseU, NoLineInfo):
          result.withTree(StmtsS, NoLineInfo):
            result.addFinalize()
            result.addNoRowResult(mode)

proc buildCommandTree(input: QueryInput): NifBuilder =
  result = createTree()
  result.withTree(BlockS, input.errorAt):
    result.addEmptyNode()
    result.withTree(StmtsS, input.errorAt):
      result.addPrepareAndBinds(input)

      result.withTree(CallX, NoLineInfo):
        result.bindSym("execStmt")
        result.addSubtree(input.dbExpr)
        result.addIdent("__dokime_stmt")

proc generate*(inp: NifCursor; mode: QueryMode): NifBuilder =
  let query = parseQueryInput(inp)
  if query.error.len > 0:
    result = errorTree(query.error, query.errorAt)
  else:
    let (columns, params, errMsg) = validateSql(query.sql)
    if errMsg.len > 0:
      result = errorTree("dokime: " & errMsg, query.errorAt)
    elif params != query.params.len:
      result = errorTree(
        "dokime: expected " & $params & " SQL parameter(s), got " & $query.params.len,
        query.errorAt
      )
    elif columns.len == 0 and mode == qmOpt:
      result = errorTree("dokime: queryOpt requires row-returning SQL", query.errorAt)
    elif columns.len == 0:
      result = buildCommandTree(query)
    else:
      result = buildRowTree(query, columns, mode)
