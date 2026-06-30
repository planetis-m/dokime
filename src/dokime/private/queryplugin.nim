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
    error: string

  QuerySymbols = object
    stmt: SymId
    params: seq[SymId]
    variant: SymId
    binds: seq[SymId]
    row: SymId
    result: SymId
    step: SymId
    finalize: SymId

proc newQuerySymbols(paramCount, variantCount: int): QuerySymbols =
  result = QuerySymbols(params: @[], binds: @[])
  result.stmt = genSym()
  for _ in 0 ..< paramCount:
    result.params.add genSym()
  result.variant = genSym()
  for _ in 0 ..< variantCount:
    result.binds.add genSym()
  result.row = genSym()
  result.result = genSym()
  result.step = genSym()
  result.finalize = genSym()

proc addGeneratedDef(t: var NifBuilder; symbol: SymId) =
  t.addSymDef(symbol, NoLineInfo)

proc addGeneratedUse(t: var NifBuilder; symbol: SymId) =
  t.addSymUse(symbol, NoLineInfo)

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
proc emitDecodedRow(t: var NifBuilder; columns: seq[ColumnMeta];
    stmt: SymId)
    {.ensuresNif: addedExpr(t).} =
  t.withTree(TupX, NoLineInfo):
    for i, col in columns:
      t.withTree(KvX, NoLineInfo):
        t.addIdent(col.name)
        t.withTree(CallX, NoLineInfo):
          t.emitColumnExtractor(col)
          t.addGeneratedUse(stmt)
          t.addIntLit(i)

# ---------------------------------------------------------------------------
# Parameter and variant emission
# ---------------------------------------------------------------------------

# (let __dokime_param_I . . PARAM)*
proc emitParamLocals(t: var NifBuilder; input: QueryInput;
    symbols: QuerySymbols) =
  for i, paramCursor in input.params:
    t.withTree(LetS, NoLineInfo):
      t.addGeneratedDef(symbols.params[i])
      t.addEmptyNode3()
      t.addSubtree(paramCursor)

# (var __dokime_stmt . . (call prepareStmt DB SQL SQL_LEN))
# (call bindParam __dokime_stmt (i+1) PARAM)*
proc emitStaticPrepareAndBinds(t: var NifBuilder; input: QueryInput;
    symbols: QuerySymbols) =
  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.stmt)
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("prepareStmt")
      t.addSubtree(input.dbExpr)
      t.addStrLit(input.sql)
      t.addIntLit(input.sql.len)

  for i, paramCursor in input.params:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("bindParam")
      t.addGeneratedUse(symbols.stmt)
      t.addIntLit(i + 1)
      t.addSubtree(paramCursor)

# (var __dokime_variant . . int 0)
# (if (elif (call isSome __dokime_param_I)
#          (stmts (asgn __dokime_variant (bitor int __dokime_variant BIT))))*
proc emitVariantMask(t: var NifBuilder; input: QueryInput;
    symbols: QuerySymbols) =
  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.variant)
    t.addEmptyNode3()
    t.addIntLit(0)

  for part in input.parsedSql.parts:
    if part.isOptional:
      let paramIndex = part.paramIndex
      t.withTree(IfS, NoLineInfo):
        t.withTree(ElifU, NoLineInfo):
          t.withTree(CallX, NoLineInfo):
            t.bindSym("isSome")
            t.addGeneratedUse(symbols.params[paramIndex])
          t.withTree(StmtsS, NoLineInfo):
            # (asgn __dokime_variant (bitor int __dokime_variant BIT))
            t.withTree(AsgnS, NoLineInfo):
              t.addGeneratedUse(symbols.variant)
              t.withTree(BitorX, NoLineInfo):
                t.addIdent("int")
                t.addGeneratedUse(symbols.variant)
                t.addIntLit(1 shl part.clauseIndex)

# (call bindNextParam __dokime_stmt __dokime_bind
#   (unsafeGet __dokime_param_I) | __dokime_param_I)
proc emitBindForParam(t: var NifBuilder; paramIndex: int; clauseIndex: int;
    bindSymId: SymId; symbols: QuerySymbols)
    {.ensuresNif: addedStmt(t).} =
  t.withTree(CallX, NoLineInfo):
    t.bindSym("bindNextParam")
    t.addGeneratedUse(symbols.stmt)
    t.addGeneratedUse(bindSymId)
    if clauseIndex < 0:
      t.addGeneratedUse(symbols.params[paramIndex])
    else:
      t.withTree(CallX, NoLineInfo):
        t.bindSym("unsafeGet")
        t.addGeneratedUse(symbols.params[paramIndex])

# (stmts
#   (asgn __dokime_stmt (call prepareStmt DB SQL SQL_LEN))
#   (var __dokime_bind . . 1)
#   (call bindNextParam __dokime_stmt __dokime_bind ARG)*)
proc emitVariantBody(t: var NifBuilder; input: QueryInput; mask: int;
    symbols: QuerySymbols) =
  let sql = input.parsedSql.renderVariant(mask)
  t.withTree(AsgnS, NoLineInfo):
    t.addGeneratedUse(symbols.stmt)
    t.withTree(CallX, NoLineInfo):
      t.bindSym("prepareStmt")
      t.addSubtree(input.dbExpr)
      t.addStrLit(sql)
      t.addIntLit(sql.len)

  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.binds[mask])
    t.addEmptyNode3()
    t.addIntLit(1)

  for i, clauseIndex in input.parsedSql.params:
    if clauseIndex < 0 or mask.clauseActive(clauseIndex):
      t.emitBindForParam(i, clauseIndex, symbols.binds[mask], symbols)

# (let __dokime_param_I . . PARAM)*
# (var __dokime_variant . . int 0)
# (if ...)
# (var __dokime_stmt . . (call emptyStmt))
# (if (elif (eq int __dokime_variant MASK) VARIANT_BODY)*
#     (else VARIANT_BODY))
proc emitDynamicPrepareAndBinds(t: var NifBuilder; input: QueryInput;
    symbols: QuerySymbols) =
  t.emitParamLocals(input, symbols)
  t.emitVariantMask(input, symbols)

  # (var __dokime_stmt . . (call emptyStmt))
  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.stmt)
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("emptyStmt")

  t.withTree(IfS, NoLineInfo):
    for mask in 1..<input.parsedSql.variantCount:
      t.withTree(ElifU, NoLineInfo):
        # (eq int __dokime_variant MASK)
        t.withTree(EqX, NoLineInfo):
          t.addIdent("int")
          t.addGeneratedUse(symbols.variant)
          t.addIntLit(mask)
        t.withTree(StmtsS, NoLineInfo):
          t.emitVariantBody(input, mask, symbols)
    t.withTree(ElseU, NoLineInfo):
      t.withTree(StmtsS, NoLineInfo):
        t.emitVariantBody(input, 0, symbols)

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
proc emitSingleOrOptRow(t: var NifBuilder; columns: seq[ColumnMeta];
    mode: QueryMode; symbols: QuerySymbols) =
  # (var __dokime_row . . DEFAULT_ROW)
  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.row)
    t.addEmptyNode3()
    t.emitDefaultRow(columns)

  if mode == qmOpt:
    # (var __dokime_result . . (call none (at Opt ROW_TYPE)))
    t.withTree(VarS, NoLineInfo):
      t.addGeneratedDef(symbols.result)
      t.addEmptyNode3()
      t.withTree(CallX, NoLineInfo):
        t.withTree(AtX, NoLineInfo):
          t.bindSym("none")
          t.emitRowType(columns)

  # (var __dokime_step . . (call stepStmtCode __dokime_stmt))
  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.step)
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("stepStmtCode")
      t.addGeneratedUse(symbols.stmt)

  t.withTree(IfS, NoLineInfo):
    t.withTree(ElifU, NoLineInfo):
      t.withTree(CallX, NoLineInfo):
        t.bindSym("stepReturnedRow")
        t.addGeneratedUse(symbols.step)
      t.withTree(StmtsS, NoLineInfo):
        t.withTree(AsgnS, NoLineInfo):
          t.addGeneratedUse(symbols.row)
          t.emitDecodedRow(columns, symbols.stmt)
        if mode == qmOpt:
          t.withTree(AsgnS, NoLineInfo):
            t.addGeneratedUse(symbols.result)
            t.withTree(CallX, NoLineInfo):
              t.bindSym("some")
              t.addGeneratedUse(symbols.row)

  # (var __dokime_finalize . . (call finalizeStmtCode __dokime_stmt))
  t.withTree(VarS, NoLineInfo):
    t.addGeneratedDef(symbols.finalize)
    t.addEmptyNode3()
    t.withTree(CallX, NoLineInfo):
      t.bindSym("finalizeStmtCode")
      t.addGeneratedUse(symbols.stmt)

  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkStepCode")
    t.addGeneratedUse(symbols.step)
  t.withTree(CallX, NoLineInfo):
    t.bindSym("checkFinalizeCode")
    t.addGeneratedUse(symbols.finalize)

  if mode == qmOne:
    t.withTree(CallX, NoLineInfo):
      t.bindSym("requireStepRow")
      t.addGeneratedUse(symbols.step)
    t.addGeneratedUse(symbols.row)
  else:
    t.addGeneratedUse(symbols.result)

# Walks the `(db, "SQL", params...)` argument list and produces a QueryInput.
# Sets `.error` on failure.
proc parseQueryInput(inp: NifCursor; mode: QueryMode): QueryInput =
  var dbExpr: NifCursor
  var sql = ""
  var params: seq[NifCursor] = @[]
  var argIndex = 0
  var child = inp
  while child.hasMore:
    case argIndex
    of 0: dbExpr = child
    of 1:
      if child.kind == StrLit:
        sql = child.stringValue
      else:
        var inner = firstChild(child)
        sql = inner.stringValue
    else:
      params.add(child)
    skip child
    inc argIndex

  if sql.len == 0:
    result = QueryInput(error: "dokime: expected " & $mode & "(db, \"SQL\", params...)")
  else:
    result = QueryInput(dbExpr: dbExpr, sql: sql, parsedSql: parseDynamicSql(sql), params: params)
    if result.parsedSql.error.len > 0:
      result.error = "dokime: " & result.parsedSql.error

# Runs the compile-time SQL validation appropriate for static or dynamic queries
# and returns the validated column/parameter metadata with `.error` set on failure.
proc validateQuery(query: QueryInput): SqlMeta =
  result =
    if query.parsedSql.hasDynamicParts:
      validateDynamicSql(query.parsedSql)
    else:
      validateSql(query.sql)
  if result.error.len > 0:
    result.error = "dokime: " & result.error
  elif result.params != query.params.len:
    result.error = "dokime: expected " & $result.params & " SQL parameter(s), got " &
        $query.params.len

# (block
#   (stmts
#     PREPARE_AND_BINDS
#     (call initRows __dokime_stmt DEFAULT_ROW)))            -- qmRows
#   ...or SINGLE_OR_OPT_ROW expansion                        -- qmOne, qmOpt
#   ...or (call execStmt DB __dokime_stmt))                  -- qmExec
proc buildTree(query: QueryInput; columns: seq[ColumnMeta];
    mode: QueryMode; info: LineInfo): NifBuilder =
  let symbols = newQuerySymbols(query.params.len, query.parsedSql.variantCount)
  result = createTree()
  result.withTree(BlockS, info):
    result.addEmptyNode()
    result.withTree(StmtsS, info):
      if query.parsedSql.hasDynamicParts:
        result.emitDynamicPrepareAndBinds(query, symbols)
      else:
        result.emitStaticPrepareAndBinds(query, symbols)
      case mode
      of qmRows:
        # (call initRows __dokime_stmt DEFAULT_ROW)
        result.withTree(CallX, NoLineInfo):
          result.bindSym("initRows")
          result.addGeneratedUse(symbols.stmt)
          result.emitDefaultRow(columns)
      of qmOne, qmOpt:
        result.emitSingleOrOptRow(columns, mode, symbols)
      of qmExec:
        result.withTree(CallX, NoLineInfo):
          result.bindSym("execStmt")
          result.addSubtree(query.dbExpr)
          result.addGeneratedUse(symbols.stmt)

proc generate*(inp: NifCursor; mode: QueryMode): NifBuilder =
  let query = parseQueryInput(inp, mode)
  if query.error.len > 0:
    result = errorTree(query.error, inp.info)
  else:
    let meta = validateQuery(query)
    if meta.error.len > 0:
      result = errorTree(meta.error, inp.info)
    elif mode == qmExec and meta.columns.len > 0:
      result = errorTree("dokime: exec requires command SQL with no result columns", inp.info)
    elif mode != qmExec and meta.columns.len == 0:
      result = errorTree(
          "dokime: " & $mode & " requires row-returning SQL; use exec for command SQL", inp.info)
    else:
      result = buildTree(query, meta.columns, mode, inp.info)
