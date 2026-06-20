## Shared implementation for dokime query template plugins.

import std/[envvars, opt]
import cacheio
import dynamicquery
import dynamicruntime
import plugins
import runtime
import ".." / sqlite3

type
  QueryMode* = enum
    qmOne = "query"
    qmOpt = "queryOpt"
    qmRows = "rows"
    qmExec = "exec"

  QueryInput = object
    dbExpr: NifCursor
    sql: string
    parsedSql: ParsedSql
    params: seq[NifCursor]
    hasSql: bool
    error: string
    errorAt: LineInfo

  Validation = object
    columns: seq[ColumnMeta]
    error: string

  QueryCheck = object
    validation: Validation
    expectedParams: int

proc toColumnKind(typeName: string): ColumnKind =
  case typeName
  of "INTEGER", "INT": ckInteger
  of "TEXT", "STRING": ckText
  of "REAL", "FLOAT", "DOUBLE": ckReal
  of "BLOB": ckBlob
  else: ckNull

proc emitValueType(t: var NifBuilder; col: ColumnMeta) =
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

# (tuple (kv NAME TYPE)*)
proc emitRowType(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupleT, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.emitValueType(col)

proc emitColumnExtractor(t: var NifBuilder; col: ColumnMeta) =
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

proc emitDefaultValue(t: var NifBuilder; col: ColumnMeta) =
  if col.nullable:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("default")
      t.emitValueType(col)
  else:
    case col.kind
    of ckInteger:
      t.addIntLit(0)
    of ckText, ckBlob, ckNull:
      t.addStrLit("")
    of ckReal:
      t.addFloatLit(0.0)

# (tuple (kv NAME DEFAULT_VALUE)*)
proc emitDefaultRow(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupX, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.emitDefaultValue(col)

# (tuple (kv NAME (call COLUMN_EXTRACTOR __dokime_stmt INDEX))*)
proc emitDecodedRow(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(TupX, NoLineInfo):
    for i, col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.withTree(CallX, NoLineInfo):
          t.emitColumnExtractor(col)
          t.addIdent("__dokime_stmt")
          t.addIntLit(i)

proc paramName(index: int): string =
  result = "__dokime_param_" & $index

proc emitParamLocals(t: var NifBuilder; input: QueryInput) =
  for i, paramCursor in input.params:
    t.withTree(LetS, NoLineInfo):
      t.addIdent(paramName(i))
      t.addEmptyNode3()
      t.addSubtree(paramCursor)

proc emitStaticPrepareAndBinds(t: var NifBuilder; input: QueryInput) =
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

proc emitOptionalPredicate(t: var NifBuilder; paramIndex: int) =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("isSome")
    t.addIdent(paramName(paramIndex))

# (asgn __dokime_variant (bitor int __dokime_variant BIT))
proc emitVariantBitAssign(t: var NifBuilder; bit: int) =
  t.withTree(AsgnS, NoLineInfo):
    t.addIdent("__dokime_variant")
    t.withTree(BitorX, NoLineInfo):
      t.addIdent("int")
      t.addIdent("__dokime_variant")
      t.addIntLit(bit)

proc emitVariantMask(t: var NifBuilder; input: QueryInput) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_variant")
    t.addEmptyNode3()
    t.addIntLit(0)

  for part in input.parsedSql.parts:
    if part.isOptional:
      let paramIndex = part.paramIndexes[0]
      t.withTree(IfS, NoLineInfo):
        t.withTree(ElifU, NoLineInfo):
          t.emitOptionalPredicate(paramIndex)
          t.withTree(StmtsS, NoLineInfo):
            t.emitVariantBitAssign(1 shl part.clauseIndex)

proc emitStmtVar(t: var NifBuilder) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("emptyStmt")

proc emitPrepareAssignment(t: var NifBuilder; input: QueryInput; sql: string) =
  t.withTree(AsgnS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.withTree(CallX, NoLineInfo):
      t.bindSym("prepareStmt")
      t.addSubtree(input.dbExpr)
      t.addStrLit(sql)
      t.addIntLit(sql.len)

proc emitBindForParam(t: var NifBuilder; paramIndex: int; spec: ParamSpec) =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("bindNextParam")
    t.addIdent("__dokime_stmt")
    t.addIdent("__dokime_bind")
    if spec.clauseIndex < 0:
      t.addIdent(paramName(paramIndex))
    else:
      t.withTree(CallX, NoLineInfo):
        t.bindSym("unsafeGet")
        t.addIdent(paramName(paramIndex))

proc emitVariantBody(t: var NifBuilder; input: QueryInput; mask: int) =
  let sql = input.parsedSql.renderVariant(mask)
  t.emitPrepareAssignment(input, sql)

  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_bind")
    t.addEmptyNode3()
    t.addIntLit(1)

  for i, spec in input.parsedSql.params:
    if spec.clauseIndex < 0 or (mask and (1 shl spec.clauseIndex)) != 0:
      t.emitBindForParam(i, spec)

# (eq int __dokime_variant MASK)
proc emitVariantPredicate(t: var NifBuilder; mask: int) =
  t.withTree(EqX, NoLineInfo):
    t.addIdent("int")
    t.addIdent("__dokime_variant")
    t.addIntLit(mask)

proc emitDynamicPrepareAndBinds(t: var NifBuilder; input: QueryInput) =
  t.emitParamLocals(input)
  t.emitVariantMask(input)
  t.emitStmtVar()

  t.withTree(IfS, NoLineInfo):
    for mask in 1..<input.parsedSql.variantCount:
      t.withTree(ElifU, NoLineInfo):
        t.emitVariantPredicate(mask)
        t.withTree(StmtsS, NoLineInfo):
          t.emitVariantBody(input, mask)
    t.withTree(ElseU, NoLineInfo):
      t.withTree(StmtsS, NoLineInfo):
        t.emitVariantBody(input, 0)

proc emitPrepareAndBinds(t: var NifBuilder; input: QueryInput) =
  if input.parsedSql.hasDynamicParts:
    t.emitDynamicPrepareAndBinds(input)
  else:
    t.emitStaticPrepareAndBinds(input)

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
  let rc = sqlite3_table_column_metadata(db, nil, tableName, originName,
      nil, nil, notNull, primaryKey, autoInc)
  if rc != SQLITE_OK:
    result = true
  else:
    result = notNull == 0 and primaryKey == 0

proc readSqlLiteral(node: NifCursor; sql: var string): bool =
  if node.kind == StringLit:
    sql = node.stringValue
    return true

  if node.kind == ParLe and node.exprKind == SufX:
    var child = firstChild(node)
    if child.hasMore and child.kind == StringLit:
      sql = child.stringValue
      result = true

proc validateSql(sql: string): CacheEntry =
  var dbPath = getEnv("DOKIME_DATABASE_PATH")
  if dbPath.len == 0:
    result = readCache(sql)
    return

  var db: sqlite3.DbConn = nil
  let rc = sqlite3_open_v2(toCString(dbPath), db, SQLITE_OPEN_READWRITE, nil)
  if rc != SQLITE_OK:
    let msg = if db != nil: fromCString(sqlite3_errmsg(db)) else: "open failed"
    return CacheEntry(error: "cannot open database: " & msg)

  var stmt: sqlite3.Stmt = nil
  var s = sql
  let prepRc = sqlite3_prepare_v2(db, toCString(s), sql.len.cint, stmt, nil)
  if prepRc != SQLITE_OK:
    let errMsg = fromCString(sqlite3_errmsg(db))
    discard sqlite3_close_v2(db)
    return CacheEntry(error: errMsg)

  let params = sqlite3_bind_parameter_count(stmt).int
  let count = sqlite3_column_count(stmt)
  var columns: seq[ColumnMeta] = @[]
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

  writeCache(sql, columns, params)
  result = CacheEntry(columns: columns, params: params)

proc validateVariants(parsed: ParsedSql): Validation =
  var expectedColumns: seq[ColumnMeta] = @[]

  for mask in 0..<parsed.variantCount:
    let sql = parsed.renderVariant(mask)
    let entry = validateSql(sql)
    if entry.error.len > 0:
      return Validation(error: entry.error & " in optional SQL variant " &
        $mask & ": " & sql)
    if entry.params != parsed.variantParamCount(mask):
      return Validation(error: "parameter count mismatch in optional SQL variant")

    if mask == 0:
      expectedColumns = entry.columns
    elif not sameColumns(expectedColumns, entry.columns):
      return Validation(error: "optional SQL variants must return the same columns")

  result = Validation(columns: expectedColumns)

proc parseQueryInput(inp: NifCursor; mode: QueryMode): QueryInput =
  result = QueryInput(dbExpr: inp, errorAt: inp.info)
  if inp.kind != ParLe or inp.stmtKind != StmtsS:
    result.error = "dokime: invalid plugin input"
    return

  var child = inp
  var argIndex = 0
  child.loopInto:
    case argIndex
    of 0:
      result.dbExpr = child
    of 1:
      var sql = ""
      if readSqlLiteral(child, sql):
        result.sql = sql
        result.hasSql = true
      else:
        result.error = "dokime: second argument must be a SQL string literal"
        result.errorAt = child.info
    else:
      result.params.add(child)
    skip child
    inc argIndex

  if result.error.len == 0 and not result.hasSql:
    result.error = "dokime: expected " & $mode & "(db, \"SQL\", params...)"
    result.errorAt = inp.info
  elif result.error.len == 0:
    let parsed = parseDynamicSql(result.sql)
    if parsed.error.len > 0:
      result.error = "dokime: " & parsed.error
    else:
      result.parsedSql = parsed

proc emitRowsResult(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("initRows")
    t.addIdent("__dokime_stmt")
    t.emitDefaultRow(columns)

proc emitRowVar(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_row")
    t.addEmptyNode3()
    t.emitDefaultRow(columns)

proc emitOptResultVar(t: var NifBuilder; columns: seq[ColumnMeta]) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_result")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.withTree(AtX, NoLineInfo):
        t.bindSym("none")
        t.emitRowType(columns)

proc emitStepVar(t: var NifBuilder) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_step")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("stepStmtCode")
      t.addIdent("__dokime_stmt")

proc emitDecodeIfRow(t: var NifBuilder; columns: seq[ColumnMeta]; mode: QueryMode) =
  t.withTree(IfS, NoLineInfo):
    t.withTree(ElifU, NoLineInfo):
      t.withTree(CallX, NoLineInfo):
        t.bindSym("stepReturnedRow")
        t.addIdent("__dokime_step")
      t.withTree(StmtsS, NoLineInfo):
        t.withTree(AsgnS, NoLineInfo):
          t.addIdent("__dokime_row")
          t.emitDecodedRow(columns)
        if mode == qmOpt:
          t.withTree(AsgnS, NoLineInfo):
            t.addIdent("__dokime_result")
            t.withTree(CallX, NoLineInfo):
              t.bindSym("some")
              t.addIdent("__dokime_row")

proc emitFinalizeVar(t: var NifBuilder) =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_finalize")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("finalizeStmtCode")
      t.addIdent("__dokime_stmt")

proc emitStepChecks(t: var NifBuilder) =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkStepCode")
    t.addIdent("__dokime_step")
  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkFinalizeCode")
    t.addIdent("__dokime_finalize")

proc emitOneOrOptResult(t: var NifBuilder; mode: QueryMode) =
  if mode == qmOne:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("requireStepRow")
      t.addIdent("__dokime_step")
    t.addIdent("__dokime_row")
  else:
    t.addIdent("__dokime_result")

proc emitOneOrOptQuery(t: var NifBuilder; columns: seq[ColumnMeta]; mode: QueryMode) =
  t.emitRowVar(columns)
  if mode == qmOpt:
    t.emitOptResultVar(columns)
  t.emitStepVar()
  t.emitDecodeIfRow(columns, mode)
  t.emitFinalizeVar()
  t.emitStepChecks()
  t.emitOneOrOptResult(mode)

proc emitRowResult(t: var NifBuilder; columns: seq[ColumnMeta]; mode: QueryMode) =
  case mode
  of qmRows:
    t.emitRowsResult(columns)
  of qmOne, qmOpt:
    t.emitOneOrOptQuery(columns, mode)
  of qmExec:
    discard

proc buildRowTree(input: QueryInput; columns: seq[ColumnMeta];
    mode: QueryMode): NifBuilder =
  result = createTree()
  result.withTree(BlockS, input.errorAt):
    result.addEmptyNode()
    result.withTree(StmtsS, input.errorAt):
      result.emitPrepareAndBinds(input)
      result.emitRowResult(columns, mode)

proc buildCommandTree(input: QueryInput): NifBuilder =
  result = createTree()
  result.withTree(BlockS, input.errorAt):
    result.addEmptyNode()
    result.withTree(StmtsS, input.errorAt):
      result.emitPrepareAndBinds(input)
      result.withTree(CallX, NoLineInfo):
        result.bindSym("execStmt")
        result.addSubtree(input.dbExpr)
        result.addIdent("__dokime_stmt")

proc validateQuery(query: QueryInput): QueryCheck =
  if query.parsedSql.hasDynamicParts:
    result = QueryCheck(
      validation: validateVariants(query.parsedSql),
      expectedParams: query.parsedSql.expectedParamCount
    )
  else:
    let cache = validateSql(query.sql)
    result = QueryCheck(
      validation: Validation(columns: cache.columns, error: cache.error),
      expectedParams: cache.params
    )

proc resultShapeError(mode: QueryMode; columns: seq[ColumnMeta]): string =
  if columns.len == 0:
    if mode == qmExec:
      result = ""
    else:
      result = "dokime: " & $mode &
        " requires row-returning SQL; use exec for command SQL"
  elif mode == qmExec:
    result = "dokime: exec requires command SQL with no result columns"
  else:
    result = ""

proc generate*(inp: NifCursor; mode: QueryMode): NifBuilder =
  let query = parseQueryInput(inp, mode)
  if query.error.len > 0:
    result = errorTree(query.error, query.errorAt)
  else:
    let check = validateQuery(query)
    let shapeError = resultShapeError(mode, check.validation.columns)
    if check.validation.error.len > 0:
      result = errorTree("dokime: " & check.validation.error, query.errorAt)
    elif check.expectedParams != query.params.len:
      result = errorTree("dokime: expected " & $check.expectedParams &
          " SQL parameter(s), got " & $query.params.len, query.errorAt)
    elif shapeError.len > 0:
      result = errorTree(shapeError, query.errorAt)
    elif mode == qmExec:
      result = buildCommandTree(query)
    else:
      result = buildRowTree(query, check.validation.columns, mode)
