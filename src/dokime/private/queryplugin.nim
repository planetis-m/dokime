## Shared implementation for dokime query template plugins.
##
## Parses a `query`/`queryMaybe`/`queryAll`/`exec` invocation, validates the SQL
## (either against the live database via `sqlvalidate` or against the cached
## column metadata), and emits the corresponding NIF tree that prepares,
## binds, steps and decodes the statement at runtime.

import std / opt

import plugins
import cacheio, dynamicquery, runtime, sqlvalidate
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

# (var __dokime_variant . . int 0)
# (if (elif (call isSome __dokime_param_I)
#          (stmts (asgn __dokime_variant (bitor int __dokime_variant BIT))))*
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
            # (asgn __dokime_variant (bitor int __dokime_variant BIT))
            t.withTree(AsgnS, NoLineInfo):
              t.addIdent("__dokime_variant")
              t.withTree(BitorX, NoLineInfo):
                t.addIdent("int")
                t.addIdent("__dokime_variant")
                t.addIntLit(1 shl part.clauseIndex)

# (call bindNextParam __dokime_stmt __dokime_bind
#   (unsafeGet __dokime_param_I) | __dokime_param_I)
proc emitBindForParam(t: var NifBuilder; paramIndex: int; clauseIndex: int)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("bindNextParam")
    t.addIdent("__dokime_stmt")
    t.addIdent("__dokime_bind")
    if clauseIndex < 0:
      t.addIdent(paramName(paramIndex))
    else:
      t.withTree(CallX, NoLineInfo):
        t.bindSym("unsafeGet")
        t.addIdent(paramName(paramIndex))

# (stmts
#   (asgn __dokime_stmt (call prepareStmt DB SQL SQL_LEN))
#   (var __dokime_bind . . 1)
#   (call bindNextParam __dokime_stmt __dokime_bind ARG)*)
proc emitVariantBody(t: var NifBuilder; input: QueryInput; mask: int) =
  let sql = input.parsedSql.renderVariant(mask)
  t.withTree(AsgnS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.withTree(CallX, NoLineInfo):
      t.bindSym("prepareStmt")
      t.addSubtree(input.dbExpr)
      t.addStrLit(sql)
      t.addIntLit(sql.len)

  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_bind")
    t.addEmptyNode3()
    t.addIntLit(1)

  for i, clauseIndex in input.parsedSql.params:
    if clauseIndex < 0 or mask.clauseActive(clauseIndex):
      t.emitBindForParam(i, clauseIndex)

# (let __dokime_param_I . . PARAM)*
# (var __dokime_variant . . int 0)
# (if ...)
# (var __dokime_stmt . . (call emptyStmt))
# (if (elif (eq int __dokime_variant MASK) VARIANT_BODY)*
#     (else VARIANT_BODY))
proc emitDynamicPrepareAndBinds(t: var NifBuilder; input: QueryInput) =
  t.emitParamLocals(input)
  t.emitVariantMask(input)

  # (var __dokime_stmt . . (call emptyStmt))
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_stmt")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("emptyStmt")

  t.withTree(IfS, NoLineInfo):
    for mask in 1..<input.parsedSql.variantCount:
      t.withTree(ElifU, NoLineInfo):
        # (eq int __dokime_variant MASK)
        t.withTree(EqX, NoLineInfo):
          t.addIdent("int")
          t.addIdent("__dokime_variant")
          t.addIntLit(mask)
        t.withTree(StmtsS, NoLineInfo):
          t.emitVariantBody(input, mask)
    t.withTree(ElseU, NoLineInfo):
      t.withTree(StmtsS, NoLineInfo):
        t.emitVariantBody(input, 0)

# ---------------------------------------------------------------------------
# Query runtime expansion
# ---------------------------------------------------------------------------

# Emits the runtime expansion of a single-row or optional-row query:
#
#   (var __dokime_row . . (tuple (kv NAME DEFAULT)*))
#   (var __dokime_result . . (call none (at Opt ROW_TYPE)))?   -- qmOpt only
#   (var __dokime_step . . (call stepStmtCode __dokime_stmt))
#   (if (elif (call stepReturnedRow __dokime_step)
#            (stmts (asgn __dokime_row DECODED_ROW)
#                   (asgn __dokime_result (call some __dokime_row))?)))
#   (var __dokime_finalize . . (call finalizeStmtCode __dokime_stmt))
#   (call checkStepCode __dokime_step)
#   (call checkFinalizeCode __dokime_finalize)
#   (call requireStepRow __dokime_step) __dokime_row          -- qmOne
#   __dokime_result                                           -- qmOpt
proc emitSingleOrOptRow(t: var NifBuilder; columns: seq[ColumnMeta]; mode: QueryMode) =
  # (var __dokime_row . . DEFAULT_ROW)
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_row")
    t.addEmptyNode3()
    t.emitDefaultRow(columns)

  if mode == qmOpt:
    # (var __dokime_result . . (call none (at Opt ROW_TYPE)))
    t.withTree(VarS, NoLineInfo):
      t.addIdent("__dokime_result")
      t.addEmptyNode3()
      t.withTree(CallX, NoLineInfo):
        t.withTree(AtX, NoLineInfo):
          t.bindSym("none")
          t.emitRowType(columns)

  # (var __dokime_step . . (call stepStmtCode __dokime_stmt))
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_step")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("stepStmtCode")
      t.addIdent("__dokime_stmt")

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
  t.withTree(VarS, NoLineInfo):
    t.addIdent("__dokime_finalize")
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("finalizeStmtCode")
      t.addIdent("__dokime_stmt")

  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkStepCode")
    t.addIdent("__dokime_step")
  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkFinalizeCode")
    t.addIdent("__dokime_finalize")

  if mode == qmOne:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("requireStepRow")
      t.addIdent("__dokime_step")
    t.addIdent("__dokime_row")
  else:
    t.addIdent("__dokime_result")

# Walks the `(db, "SQL", params...)` argument list and produces a QueryInput.
# Returns "" on success or a diagnostic message on failure.
proc parseQueryInput(inp: NifCursor; mode: QueryMode): tuple[query: QueryInput, error: string] =
  var dbExpr: NifCursor
  var sql = ""
  var params: seq[NifCursor] = @[]
  var argIndex = 0
  var child = inp
  child.loopInto:
    case argIndex
    of 0: dbExpr = child
    of 1:
      if child.kind == StringLit:
        sql = child.stringValue
      else:
        var inner = firstChild(child)
        sql = inner.stringValue
    else:
      params.add(child)
    skip child
    inc argIndex

  if sql.len == 0:
    result = (QueryInput(), "dokime: expected " & $mode & "(db, \"SQL\", params...)")
  else:
    let parsed = parseDynamicSql(sql)
    if parsed.error.len > 0:
      result = (QueryInput(), "dokime: " & parsed.error)
    else:
      result = (QueryInput(dbExpr: dbExpr, sql: sql, parsedSql: parsed, params: params), "")

# Runs the compile-time SQL validation appropriate for static or dynamic queries
# and returns either the validated column/parameter metadata or an error message.
proc validateQuery(query: QueryInput): tuple[meta: SqlMeta, error: string] =
  let check =
    if query.parsedSql.hasDynamicParts:
      validateDynamicSql(query.parsedSql)
    else:
      validateSql(query.sql)
  if check.error.len > 0:
    result = (SqlMeta(), "dokime: " & check.error)
  elif check.params != query.params.len:
    result = (SqlMeta(),
      "dokime: expected " & $check.params & " SQL parameter(s), got " & $query.params.len)
  else:
    result = (check, "")

# (block
#   (stmts
#     PREPARE_AND_BINDS
#     (call initRows __dokime_stmt DEFAULT_ROW)))            -- qmRows
#   ...or SINGLE_OR_OPT_ROW expansion                        -- qmOne, qmOpt
#   ...or (call execStmt DB __dokime_stmt))                  -- qmExec
proc buildTree(query: QueryInput; columns: seq[ColumnMeta];
    mode: QueryMode; info: LineInfo): NifBuilder =
  result = createTree()
  result.withTree(BlockS, info):
    result.addEmptyNode()
    result.withTree(StmtsS, info):
      if query.parsedSql.hasDynamicParts:
        result.emitDynamicPrepareAndBinds(query)
      else:
        result.emitStaticPrepareAndBinds(query)
      case mode
      of qmRows:
        # (call initRows __dokime_stmt DEFAULT_ROW)
        result.withTree(CallX, NoLineInfo):
          result.bindSym("initRows")
          result.addIdent("__dokime_stmt")
          result.emitDefaultRow(columns)
      of qmOne, qmOpt:
        result.emitSingleOrOptRow(columns, mode)
      of qmExec:
        result.withTree(CallX, NoLineInfo):
          result.bindSym("execStmt")
          result.addSubtree(query.dbExpr)
          result.addIdent("__dokime_stmt")

proc generate*(inp: NifCursor; mode: QueryMode): NifBuilder =
  let (query, parseErr) = parseQueryInput(inp, mode)
  if parseErr.len > 0:
    result = errorTree(parseErr, inp.info)
  else:
    let (meta, validateErr) = validateQuery(query)
    if validateErr.len > 0:
      result = errorTree(validateErr, inp.info)
    elif mode == qmExec and meta.columns.len > 0:
      result = errorTree("dokime: exec requires command SQL with no result columns", inp.info)
    elif mode != qmExec and meta.columns.len == 0:
      result = errorTree(
          "dokime: " & $mode & " requires row-returning SQL; use exec for command SQL", inp.info)
    else:
      result = buildTree(query, meta.columns, mode, inp.info)
