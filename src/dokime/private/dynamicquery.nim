## Parser and variant helpers for dokime optional SQL clauses.

import cacheio

const MaxOptionalParts* = 8

type
  SqlPart* = object
    text*: string
    isOptional*: bool
    clauseIndex*: int
    paramIndexes*: seq[int]

  ParsedSql* = object
    parts*: seq[SqlPart]
    params*: seq[int]
    clauseCount*: int
    error*: string

func hasDynamicParts*(sql: ParsedSql): bool =
  result = sql.clauseCount > 0

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
        parsed.params.add(if isOptional: clauseIndex else: -1)
      inc i

  if isOptional and paramIndexes.len != 1:
    parsed.error = "optional SQL blocks must contain exactly one ? parameter" &
      " outside string literals; found " & $paramIndexes.len
    return

  parsed.parts.add SqlPart(
    text: text,
    isOptional: isOptional,
    clauseIndex: clauseIndex,
    paramIndexes: paramIndexes)

func findOptionalClose(sql: string; start: int): (int, string) =
  var pos = start + 1
  while pos < sql.len:
    case sql[pos]
    of '\'':
      pos = sql.skipStringLiteral(pos)
    of '[':
      return (-1, "nested optional SQL blocks are not supported")
    of ']':
      return (pos, "")
    else:
      inc pos

  return (-1, "unterminated optional SQL block")

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
      result.addPart(substr(sql, textStart, i - 1), false, -1)

      let (close, err) = sql.findOptionalClose(i)
      if err.len > 0:
        result.error = err
        return

      let clauseIndex = result.clauseCount
      result.addPart(substr(sql, i + 1, close - 1), true, clauseIndex)
      inc result.clauseCount
      i = close + 1
      textStart = i
    of ']':
      result.error = "unmatched ] in SQL string"
      return
    else:
      inc i

  if result.error.len == 0:
    result.addPart(substr(sql, textStart, sql.len - 1), false, -1)

  if result.clauseCount > MaxOptionalParts:
    result.error = "optional SQL blocks are limited to " & $MaxOptionalParts & " per query"

func variantCount*(sql: ParsedSql): int =
  result = 1 shl sql.clauseCount

func clauseActive*(mask: int; clauseIndex: int): bool =
  result = (mask and (1 shl clauseIndex)) != 0

func includesPart(mask: int; part: SqlPart): bool =
  result = not part.isOptional or mask.clauseActive(part.clauseIndex)

func renderVariant*(sql: ParsedSql; mask: int): string =
  result = ""
  for part in sql.parts:
    if mask.includesPart(part):
      result.add part.text

func variantParamCount*(sql: ParsedSql; mask: int): int =
  result = 0
  for clauseIndex in sql.params:
    if clauseIndex < 0 or mask.clauseActive(clauseIndex):
      inc result
