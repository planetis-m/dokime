## Parser and variant helpers for dokime optional SQL clauses.

import cacheio

const MaxOptionalParts* = 8

type
  ParamSpec* = object
    optionalPart*: int

  SqlPart* = object
    text*: string
    optional*: bool
    optionalIndex*: int
    paramIndexes*: seq[int]

  ParsedSql* = object
    parts*: seq[SqlPart]
    params*: seq[ParamSpec]
    optionalCount*: int
    error*: string

func hasDynamicParts*(sql: ParsedSql): bool =
  result = sql.optionalCount > 0

func expectedParamCount*(sql: ParsedSql): int =
  result = sql.params.len

func sqlSlice(sql: string; first, last: int): string =
  result = ""
  if first <= last:
    result = substr(sql, first, last)

proc addPart(parsed: var ParsedSql; text: string; optional: bool;
    optionalIndex: int) =
  if text.len == 0:
    return

  let paramBase = parsed.params.len
  var paramIndexes: seq[int] = @[]
  for ch in text:
    if ch == '?':
      paramIndexes.add paramBase + paramIndexes.len
      parsed.params.add ParamSpec(
        optionalPart: if optional: optionalIndex else: -1
      )

  if optional and paramIndexes.len != 1:
    parsed.error = "optional SQL blocks must contain exactly one ? parameter"
    return

  parsed.parts.add SqlPart(
    text: text,
    optional: optional,
    optionalIndex: optionalIndex,
    paramIndexes: paramIndexes
  )

proc parseDynamicSql*(sql: string): ParsedSql =
  result = ParsedSql(parts: @[], params: @[], optionalCount: 0, error: "")
  var
    i = 0
    textStart = 0

  while i < sql.len and result.error.len == 0:
    case sql[i]
    of '[':
      result.addPart(sql.sqlSlice(textStart, i - 1), false, -1)

      var close = i + 1
      while close < sql.len and sql[close] != ']':
        if sql[close] == '[':
          result.error = "nested optional SQL blocks are not supported"
          return
        inc close

      if close >= sql.len:
        result.error = "unterminated optional SQL block"
        return

      let optionalIndex = result.optionalCount
      result.addPart(sql.sqlSlice(i + 1, close - 1), true, optionalIndex)
      inc result.optionalCount
      i = close + 1
      textStart = i
    of ']':
      result.error = "unmatched ] in SQL string"
      return
    else:
      inc i

  if result.error.len == 0:
    result.addPart(sql.sqlSlice(textStart, sql.len - 1), false, -1)

  if result.optionalCount > MaxOptionalParts:
    result.error = "optional SQL blocks are limited to " & $MaxOptionalParts &
      " per query"

func variantCount*(sql: ParsedSql): int =
  result = 1 shl sql.optionalCount

func includesPart(mask: int; part: SqlPart): bool =
  result = not part.optional or (mask and (1 shl part.optionalIndex)) != 0

func renderVariant*(sql: ParsedSql; mask: int): string =
  result = ""
  for part in sql.parts:
    if mask.includesPart(part):
      result.add part.text

func variantParamCount*(sql: ParsedSql; mask: int): int =
  result = 0
  for spec in sql.params:
    if spec.optionalPart < 0 or (mask and (1 shl spec.optionalPart)) != 0:
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
