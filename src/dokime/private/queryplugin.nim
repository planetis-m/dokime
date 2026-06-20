## Shared implementation for dokime query template plugins.
##
## Parses a `query`/`queryMaybe`/`queryAll`/`exec` invocation, validates the SQL
## (either against the live database via `sqlvalidate` or against the cached
## column metadata), and emits the corresponding NIF tree that prepares,
## binds, steps and decodes the statement at runtime.

import std / opt

import plugins
import cacheio, dynamicquery, dynamicruntime, runtime, sqlvalidate
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

  QueryCheck = object
    columns: seq[ColumnMeta]
    error: string
    expectedParams: int

# ---------------------------------------------------------------------------
# Column type emission
# ---------------------------------------------------------------------------

# int64 | string | float64
proc addAtomType(t: var NifBuilder; col: ColumnMeta)
    {.ensuresNif: addedExpr(t).} =
  case col.kind
  of ckInteger:
    t.addIdent("int64")
  of ckText, ckBlob, ckNull:
    t.addIdent("string")
  of ckReal:
    t.addIdent("float64")

# (at Opt TYPE) | TYPE
proc emitValueType(t: var NifBuilder; col: ColumnMeta)
    {.ensuresNif: addedAny(t).} =
  if col.nullable:
    t.withTree(AtX, NoLineInfo):
      t.bindSym("Opt")
      t.addAtomType(col)
  else:
    t.addAtomType(col)

# (tuple (kv NAME TYPE)*)
proc emitRowType(t: var NifBuilder; columns: seq[ColumnMeta])
    {.ensuresNif: addedStmt(t).} =
  t.withTree(TupleT, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.emitValueType(col)

# columnOptInt64 | columnInt64 | columnOptString | columnString | columnOptFloat64 | columnFloat64
proc emitColumnExtractor(t: var NifBuilder; col: ColumnMeta)
    {.ensuresNif: addedExpr(t).} =
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

# (call default TYPE) -- resolves to none for Opt[T], zero value for atoms.
proc emitDefaultValue(t: var NifBuilder; col: ColumnMeta)
    {.ensuresNif: addedExpr(t).} =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("default")
    t.emitValueType(col)

# (tuple (kv NAME DEFAULT_VALUE)*)
proc emitDefaultRow(t: var NifBuilder; columns: seq[ColumnMeta])
    {.ensuresNif: addedExpr(t).} =
  t.withTree(TupX, NoLineInfo):
    for col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.emitDefaultValue(col)

# (tuple (kv NAME (call COLUMN_EXTRACTOR __dokime_stmt INDEX))*)
proc emitDecodedRow(t: var NifBuilder; columns: seq[ColumnMeta])
    {.ensuresNif: addedExpr(t).} =
  t.withTree(TupX, NoLineInfo):
    for i, col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.withTree(CallX, NoLineInfo):
          t.emitColumnExtractor(col)
          t.addIdent("__dokime_stmt")
          t.addIntLit(i)

# ---------------------------------------------------------------------------
# Parameter and variant emission
# ---------------------------------------------------------------------------

proc paramName(index: int): string =
  result = "__dokime_param_" & $index

# (let __dokime_param_I . . PARAM)*
proc emitParamLocals(t: var NifBuilder; input: QueryInput) =
  for i, paramCursor in input.params:
    t.withTree(LetS, NoLineInfo):
      t.addIdent(paramName(i))
      t.addEmptyNode3()
      t.addSubtree(paramCursor)

# (var __dokime_stmt . . (call prepareStmt DB SQL SQL_LEN))
# (call bindParam __dokime_stmt (i+1) PARAM)*
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

# (asgn __dokime_variant (bitor int __dokime_variant BIT))
proc emitVariantBitAssign(t: var NifBuilder; bit: int)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(AsgnS, NoLineInfo):
    t.addIdent("__dokime_variant")
    t.withTree(BitorX, NoLineInfo):
      t.addIdent("int")
      t.addIdent("__dokime_variant")
      t.addIntLit(bit)

# (var __dokime_variant . . int 0)
# (if (elif (call isSome __dokime_param_I)
#          (stmts (asgn __dokime_variant (bitor ... BIT))))*
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
          t.withTree(CallX, NoLineInfo):
            t.bindSym("isSome")
            t.addIdent(paramName(paramIndex))
          t.withTree(StmtsS, NoLineInfo):
            t.emitVariantBitAssign(1 shl part.clauseIndex)

# (var __dokime_stmt . . (call emptyStmt))
proc emitStmtVar(t: var NifBuilder)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("emptyStmt")

# (asgn __dokime_stmt (call prepareStmt DB SQL SQL_LEN))
proc emitPrepareAssignment(t: var NifBuilder; input: QueryInput; sql: string)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(AsgnS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.withTree(CallX, NoLineInfo):
      t.bindSym("prepareStmt")
      t.addSubtree(input.dbExpr)
      t.addStrLit(sql)
      t.addIntLit(sql.len)

# (call bindNextParam __dokime_stmt __dokime_bind
#   (unsafeGet __dokime_param_I) | __dokime_param_I)
proc emitBindForParam(t: var NifBuilder; paramIndex: int; spec: ParamSpec)
    {.ensuresNif: addedStmt(t).} =
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

# (eq int __dokime_variant MASK)
proc emitVariantPredicate(t: var NifBuilder; mask: int)
    {.ensuresNif: addedExpr(t).} =
  t.withTree(EqX, NoLineInfo):
    t.addIdent("int")
    t.addIdent("__dokime_variant")
    t.addIntLit(mask)

# (stmts
#   (asgn __dokime_stmt (call prepareStmt DB SQL SQL_LEN))
#   (var __dokime_bind . . 1)
#   (call bindNextParam __dokime_stmt __dokime_bind ARG)*)
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

# (let __dokime_param_I . . PARAM)*
# (var __dokime_variant . . int 0)
# (if ...)
# (var __dokime_stmt . . (call emptyStmt))
# (if (elif (eq int __dokime_variant MASK) VARIANT_BODY)*
#     (else VARIANT_BODY))
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

# Dynamic or static prepare-and-binds depending on hasDynamicParts
proc emitPrepareAndBinds(t: var NifBuilder; input: QueryInput) =
  if input.parsedSql.hasDynamicParts:
    t.emitDynamicPrepareAndBinds(input)
  else:
    t.emitStaticPrepareAndBinds(input)

# ---------------------------------------------------------------------------
# Optional-variant validation
# ---------------------------------------------------------------------------

proc validateDynamicSql(parsed: ParsedSql): QueryCheck =
  var expectedColumns: seq[ColumnMeta] = @[]

  for mask in 0..<parsed.variantCount:
    let sql = parsed.renderVariant(mask)
    let entry = validateSql(sql)
    if entry.error.len > 0:
      return QueryCheck(error: entry.error & " in optional SQL variant " & $mask & ": " & sql)
    if entry.params != parsed.variantParamCount(mask):
      return QueryCheck(error: "parameter count mismatch in optional SQL variant")

    if mask == 0:
      expectedColumns = entry.columns
    elif not sameColumns(expectedColumns, entry.columns):
      return QueryCheck(error: "optional SQL variants must return the same columns")

  result = QueryCheck(columns: expectedColumns, expectedParams: parsed.params.len)

# ---------------------------------------------------------------------------
# Query input parsing
# ---------------------------------------------------------------------------

proc readSqlLiteral(node: NifCursor; sql: var string): bool =
  if node.kind == StringLit:
    sql = node.stringValue
    return true

  if node.kind == ParLe and node.exprKind == SufX:
    var child = firstChild(node)
    if child.hasMore and child.kind == StringLit:
      sql = child.stringValue
      result = true

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

# ---------------------------------------------------------------------------
# Result emission
# ---------------------------------------------------------------------------

# (call initRows __dokime_stmt (tuple (kv NAME DEFAULT)*))
proc emitRowsResult(t: var NifBuilder; columns: seq[ColumnMeta])
    {.ensuresNif: addedExpr(t).} =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("initRows")
    t.addIdent("__dokime_stmt")
    t.emitDefaultRow(columns)

# (var __dokime_row . . (tuple (kv NAME DEFAULT)*))
proc emitRowVar(t: var NifBuilder; columns: seq[ColumnMeta])
    {.ensuresNif: addedStmt(t).} =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_row")
    t.addEmptyNode3()
    t.emitDefaultRow(columns)

# (var __dokime_result . . (call none (at Opt ROW_TYPE)))
proc emitOptResultVar(t: var NifBuilder; columns: seq[ColumnMeta])
    {.ensuresNif: addedStmt(t).} =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_result")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.withTree(AtX, NoLineInfo):
        t.bindSym("none")
        t.emitRowType(columns)

# (var __dokime_step . . (call stepStmtCode __dokime_stmt))
proc emitStepVar(t: var NifBuilder)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_step")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("stepStmtCode")
      t.addIdent("__dokime_stmt")

# (if (elif (call stepReturnedRow __dokime_step)
#          (stmts (asgn __dokime_row DECODED_ROW)
#                 (asgn __dokime_result (call some __dokime_row))?)))
proc emitDecodeIfRow(t: var NifBuilder; columns: seq[ColumnMeta]; mode: QueryMode)
    {.ensuresNif: addedStmt(t).} =
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

# (var __dokime_finalize . . (call finalizeStmtCode __dokime_stmt))
proc emitFinalizeVar(t: var NifBuilder)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_finalize")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("finalizeStmtCode")
      t.addIdent("__dokime_stmt")

# (call checkStepCode __dokime_step)
# (call checkFinalizeCode __dokime_finalize)
proc emitStepChecks(t: var NifBuilder) =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkStepCode")
    t.addIdent("__dokime_step")
  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkFinalizeCode")
    t.addIdent("__dokime_finalize")

# (call requireStepRow __dokime_step) | __dokime_result
proc emitOneOrOptResult(t: var NifBuilder; mode: QueryMode)
    {.ensuresNif: addedAny(t).} =
  if mode == qmOne:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("requireStepRow")
      t.addIdent("__dokime_step")
    t.addIdent("__dokime_row")
  else:
    t.addIdent("__dokime_result")

# (var __dokime_row . . DEFAULT_ROW)
# (var __dokime_result . . (call none (at Opt ROW_TYPE)))?  -- qmOpt only
# (var __dokime_step . . (call stepStmtCode __dokime_stmt))
# (if (elif ...))
# (var __dokime_finalize . . (call finalizeStmtCode __dokime_stmt))
# (call checkStepCode __dokime_step)
# (call checkFinalizeCode __dokime_finalize)
# __dokime_row | __dokime_result
proc emitOneOrOptQuery(t: var NifBuilder; columns: seq[ColumnMeta]; mode: QueryMode) =
  t.emitRowVar(columns)
  if mode == qmOpt:
    t.emitOptResultVar(columns)
  t.emitStepVar()
  t.emitDecodeIfRow(columns, mode)
  t.emitFinalizeVar()
  t.emitStepChecks()
  t.emitOneOrOptResult(mode)

# ---------------------------------------------------------------------------
# Tree assembly and entry point
# ---------------------------------------------------------------------------

# (block
#   (stmts
#     PREPARE_AND_BINDS
#     (call initRows __dokime_stmt DEFAULT_ROW) | ONE_OR_OPT_QUERY))
proc buildRowTree(input: QueryInput; columns: seq[ColumnMeta];
    mode: QueryMode): NifBuilder =
  result = createTree()
  result.withTree(BlockS, input.errorAt):
    result.addEmptyNode()
    result.withTree(StmtsS, input.errorAt):
      result.emitPrepareAndBinds(input)
      case mode
      of qmRows:
        result.emitRowsResult(columns)
      of qmOne, qmOpt:
        result.emitOneOrOptQuery(columns, mode)
      of qmExec:
        discard

# (block
#   (stmts
#     PREPARE_AND_BINDS
#     (call execStmt DB __dokime_stmt)))
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
    result = validateDynamicSql(query.parsedSql)
  else:
    let cache = validateSql(query.sql)
    result = QueryCheck(
      columns: cache.columns,
      error: cache.error,
      expectedParams: cache.params)

proc resultShapeError(mode: QueryMode; columns: seq[ColumnMeta]): string =
  if columns.len == 0:
    if mode == qmExec:
      result = ""
    else:
      result = "dokime: " & $mode & " requires row-returning SQL; use exec for command SQL"
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
    let shapeError = resultShapeError(mode, check.columns)
    if check.error.len > 0:
      result = errorTree("dokime: " & check.error, query.errorAt)
    elif check.expectedParams != query.params.len:
      result = errorTree("dokime: expected " & $check.expectedParams &
          " SQL parameter(s), got " & $query.params.len, query.errorAt)
    elif shapeError.len > 0:
      result = errorTree(shapeError, query.errorAt)
    elif mode == qmExec:
      result = buildCommandTree(query)
    else:
      result = buildRowTree(query, check.columns, mode)
