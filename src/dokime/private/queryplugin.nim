## Shared implementation for dokime query template plugins.

import std/[envvars, opt]
import plugins
import runtime
import ".." / sqlite3

type
  QueryMode* = enum
    qmOne = "query"
    qmOpt = "queryOpt"
    qmRows = "rows"
    qmExec = "exec"

  ColumnKind = enum ckInteger, ckText, ckReal, ckBlob, ckNull

  ColumnMeta = object
    name: string
    kind: ColumnKind
    nullable: bool

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

proc addValueType(t: var NifBuilder; col: ColumnMeta) =
  if col.nullable:
    t.withTree(AtX, NoLineInfo):
      t.bindSym("Opt")
      case col.kind
      of ckInteger:
        t.addIdent("int64")
      of ckText, ckBlob, ckNull:
        t.addIdent("string")
      of ckReal:
        t.addIdent("float64")
  else:
    case col.kind
    of ckInteger:
      t.addIdent("int64")
    of ckText, ckBlob, ckNull:
      t.addIdent("string")
    of ckReal:
      t.addIdent("float64")

proc addRowType(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupleT, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.addValueType(col)

proc addColumnExtractor(t: var NifBuilder; col: ColumnMeta) =
  if col.nullable:
    case col.kind
    of ckInteger:
      t.bindSym("columnOptInt64")
    of ckText, ckBlob, ckNull:
      t.bindSym("columnOptString")
    of ckReal:
      t.bindSym("columnOptFloat64")
  else:
    case col.kind
    of ckInteger:
      t.bindSym("columnInt64")
    of ckText, ckBlob, ckNull:
      t.bindSym("columnString")
    of ckReal:
      t.bindSym("columnFloat64")

proc addDefaultValue(t: var NifBuilder; col: ColumnMeta) =
  if col.nullable:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("default")
      t.addValueType(col)
  else:
    case col.kind
    of ckInteger:
      t.addIntLit(0)
    of ckText, ckBlob, ckNull:
      t.addStrLit("")
    of ckReal:
      t.addFloatLit(0.0)

proc addDefaultRow(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupX, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.addDefaultValue(col)

proc addDecodedRow(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupX, NoLineInfo):
    for i, col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.withTree(CallX, NoLineInfo):
          t.addColumnExtractor(col)
          t.addIdent("__dokime_stmt")
          t.addIntLit(i)

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

proc inferNullable(db: sqlite3.DbConn; stmt: sqlite3.Stmt; col: int): bool =
  let tableName = sqlite3_column_table_name(stmt, col.cint)
  let originName = sqlite3_column_origin_name(stmt, col.cint)
  if tableName == nil:
    return true
  if originName == nil:
    return true

  var
    notNull: cint = 0
    primaryKey: cint = 0
    autoInc: cint = 0
  let rc = sqlite3_table_column_metadata(
    db,
    nil,
    tableName,
    originName,
    nil,
    nil,
    notNull,
    primaryKey,
    autoInc
  )
  if rc != SQLITE_OK:
    result = true
  else:
    result = not (notNull != 0 or primaryKey != 0)

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
            kind: toColumnKind(typeStr),
            nullable: inferNullable(db, stmt, i)
          )
        discard sqlite3_finalize(stmt)
      discard sqlite3_close_v2(db)

  result = (columns, params, errMsg)

proc parseQueryInput(inp: NifCursor; mode: QueryMode): QueryInput =
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
    result.error = "dokime: expected " & $mode & "(db, \"SQL\", params...)"
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
      case mode
      of qmRows:
        result.withTree(CallX, NoLineInfo):
          result.bindSym("initRows")
          result.addIdent("__dokime_stmt")
          result.addDefaultRow(columns)
      of qmOne, qmOpt:
        result.withTree(VarS, NoLineInfo):
          result.addIdent("__dokime_row")
          result.addEmptyNode3()
          result.addDefaultRow(columns)

        if mode == qmOpt:
          result.withTree(VarS, NoLineInfo):
            result.addIdent("__dokime_result")
            result.addEmptyNode3()
            result.withTree(CallX, NoLineInfo):
              result.withTree(AtX, NoLineInfo):
                result.bindSym("none")
                result.addRowType(columns)

        result.withTree(VarS, NoLineInfo):
          result.addIdent("__dokime_step")
          result.addEmptyNode3()
          result.withTree(CallX, NoLineInfo):
            result.bindSym("stepStmtCode")
            result.addIdent("__dokime_stmt")

        result.withTree(IfS, NoLineInfo):
          result.withTree(ElifU, NoLineInfo):
            result.withTree(CallX, NoLineInfo):
              result.bindSym("stepReturnedRow")
              result.addIdent("__dokime_step")
            result.withTree(StmtsS, NoLineInfo):
              result.withTree(AsgnS, NoLineInfo):
                result.addIdent("__dokime_row")
                result.addDecodedRow(columns)
              if mode == qmOpt:
                result.withTree(AsgnS, NoLineInfo):
                  result.addIdent("__dokime_result")
                  result.withTree(CallX, NoLineInfo):
                    result.bindSym("some")
                    result.addIdent("__dokime_row")

        result.withTree(VarS, NoLineInfo):
          result.addIdent("__dokime_finalize")
          result.addEmptyNode3()
          result.withTree(CallX, NoLineInfo):
            result.bindSym("finalizeStmtCode")
            result.addIdent("__dokime_stmt")

        result.withTree(CallX, NoLineInfo):
          result.bindSym("checkStepCode")
          result.addIdent("__dokime_step")
        result.withTree(CallX, NoLineInfo):
          result.bindSym("checkFinalizeCode")
          result.addIdent("__dokime_finalize")

        if mode == qmOne:
          result.withTree(CallX, NoLineInfo):
            result.bindSym("requireStepRow")
            result.addIdent("__dokime_step")
          result.addIdent("__dokime_row")
        else:
          result.addIdent("__dokime_result")
      of qmExec:
        discard

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
  let query = parseQueryInput(inp, mode)
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
    elif columns.len == 0 and mode == qmExec:
      result = buildCommandTree(query)
    elif columns.len == 0:
      result = errorTree(
        "dokime: " & $mode & " requires row-returning SQL; use exec for command SQL",
        query.errorAt
      )
    elif mode == qmExec:
      result = errorTree("dokime: exec requires command SQL with no result columns", query.errorAt)
    else:
      result = buildRowTree(query, columns, mode)
