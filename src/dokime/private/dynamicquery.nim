## Parser and variant helpers for dokime optional SQL clauses.

import cacheio

const MaxOptionalParts* = 8

type
  ParamSpec* = object
    clauseIndex*: int

  SqlPart* = object
    text*: string
    isOptional*: bool
    clauseIndex*: int
    paramIndexes*: seq[int]

  ParsedSql* = object
    parts*: seq[SqlPart]
    params*: seq[ParamSpec]
    clauseCount*: int
    error*: string

func hasDynamicParts*(sql: ParsedSql): bool =
  result = sql.clauseCount > 0

func sqlSlice(sql: string; first, last: int): string =
  result = ""
  if first <= last:
    result = substr(sql, first, last)

func skipStringLiteral(sql: string; start: int): int =
  result = start + 1
  while result < sql.len:
    if sql[result] == '\'':
      if result + 1 < sql.len and sql[result + 1] == '\'':
        inc result, 2
      else:
        inc result
        return
    else:
      inc result

proc addPart(parsed: var ParsedSql; text: string; isOptional: bool;
    clauseIndex: int) =
  if text.len == 0:
    return

  let paramBase = parsed.params.len
  var paramIndexes: seq[int] = @[]
  var i = 0
  while i < text.len:
    if text[i] == '\'':
      i = text.skipStringLiteral(i)
    else:
      if text[i] == '?':
        let paramIndex = paramBase + paramIndexes.len
        paramIndexes.add paramIndex
        parsed.params.add ParamSpec(
          clauseIndex: if isOptional: clauseIndex else: -1
        )
      inc i

  if isOptional and paramIndexes.len != 1:
    parsed.error = "optional SQL blocks must contain exactly one ? parameter" &
      " outside string literals; found " & $paramIndexes.len
    return

  parsed.parts.add SqlPart(
    text: text,
    isOptional: isOptional,
    clauseIndex: clauseIndex,
    paramIndexes: paramIndexes
  )

func findOptionalClose(sql: string; start: int; error: var string): int =
  result = start + 1
  while result < sql.len:
    case sql[result]
    of '\'':
      result = sql.skipStringLiteral(result)
    of '[':
      error = "nested optional SQL blocks are not supported"
      return -1
    of ']':
      return
    else:
      inc result

  error = "unterminated optional SQL block"
  result = -1

proc parseDynamicSql*(sql: string): ParsedSql =
  result = ParsedSql(parts: @[], params: @[], clauseCount: 0, error: "")
  var
    i = 0
    textStart = 0

  while i < sql.len and result.error.len == 0:
    case sql[i]
    of '\'':
      i = sql.skipStringLiteral(i)
    of '[':
      result.addPart(sql.sqlSlice(textStart, i - 1), false, -1)

      let close = sql.findOptionalClose(i, result.error)
      if close < 0:
        return

      let clauseIndex = result.clauseCount
      result.addPart(sql.sqlSlice(i + 1, close - 1), true, clauseIndex)
      inc result.clauseCount
      i = close + 1
      textStart = i
    of ']':
      result.error = "unmatched ] in SQL string"
      return
    else:
      inc i

  if result.error.len == 0:
    result.addPart(sql.sqlSlice(textStart, sql.len - 1), false, -1)

  if result.clauseCount > MaxOptionalParts:
    result.error = "optional SQL blocks are limited to " & $MaxOptionalParts &
      " per query"

func variantCount*(sql: ParsedSql): int =
  result = 1 shl sql.clauseCount

func includesPart(mask: int; part: SqlPart): bool =
  result = not part.isOptional or (mask and (1 shl part.clauseIndex)) != 0

func renderVariant*(sql: ParsedSql; mask: int): string =
  result = ""
  for part in sql.parts:
    if mask.includesPart(part):
      result.add part.text

func variantParamCount*(sql: ParsedSql; mask: int): int =
  result = 0
  for spec in sql.params:
    if spec.clauseIndex < 0 or (mask and (1 shl spec.clauseIndex)) != 0:
      inc result

func sameColumns*(a, b: seq[ColumnMeta]): bool =
  if a.len != b.len:
    return false
  for i in 0..<a.len:
    if a[i].name != b[i].name:
      return false
    if a[i].kind != b[i].kind:
      return false
    if a[i].nullable != b[i].nullable:
      return false
  result = true
