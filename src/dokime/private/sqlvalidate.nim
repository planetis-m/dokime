## SQL validation against a live SQLite database.
##
## Prepares a SQL statement with the development database pointed to by
## `DOKIME_DATABASE_PATH`, reads back column metadata (name, declared type and
## nullability) and mirrors the result to the offline cache so subsequent
## builds can validate without a database connection.

import std / [envvars, strutils]

import cacheio, dynamicquery
import ".." / sqlite3

func isLiteral(s: string): bool =
  let t = s.strip
  if t.len == 0:
    return false
  if t.startsWith("'") and t.endsWith("'"):
    return true
  var i = 0
  if t[i] == '-':
    inc i
  var dotSeen = false
  var hasDigit = false
  while i < t.len:
    case t[i]
    of '0'..'9':
      hasDigit = true
      inc i
    of '.':
      if dotSeen:
        return false
      dotSeen = true
      inc i
    else:
      return false
  result = hasDigit

func isKnownNotNull(colName: string): bool =
  let n = colName.toLowerAscii
  if n.startsWith("count(") or n.startsWith("exists(") or
     n.startsWith("typeof(") or n.startsWith("quote(") or
     n.startsWith("zeroblob(") or n.startsWith("randomblob(") or
     n.startsWith("random(") or n.startsWith("row_number(") or
     n.startsWith("rank(") or n.startsWith("dense_rank(") or
     n.startsWith("ntile(") or n.startsWith("percent_rank(") or
     n.startsWith("cume_dist("):
    result = true
  elif n == "current_date" or n == "current_time" or n == "current_timestamp":
    result = true
  elif isLiteral(colName):
    result = true
  else:
    result = false

proc toColumnKind(typeName: string; colName: string): ColumnKind =
  case typeName
  of "INTEGER", "INT": result = ckInteger
  of "TEXT", "STRING": result = ckText
  of "REAL", "FLOAT", "DOUBLE": result = ckReal
  of "BLOB": result = ckBlob
  else:
    let n = colName.toLowerAscii
    if n.startsWith("count(") or n.startsWith("exists(") or n.startsWith("random(") or
       n.startsWith("row_number(") or n.startsWith("rank(") or
       n.startsWith("dense_rank(") or n.startsWith("ntile("):
      result = ckInteger
    elif n.startsWith("percent_rank(") or n.startsWith("cume_dist("):
      result = ckReal
    elif n.startsWith("typeof(") or n.startsWith("quote("):
      result = ckText
    elif n.startsWith("zeroblob(") or n.startsWith("randomblob("):
      result = ckBlob
    elif n == "current_date" or n == "current_time" or n == "current_timestamp":
      result = ckText
    elif isLiteral(colName):
      if colName.strip.startsWith("'"):
        result = ckText
      else:
        result = ckInteger
    else:
      result = ckNull

proc inferNullable(db: sqlite3.DbConn; stmt: sqlite3.Stmt; col: int): bool =
  let tableName = sqlite3_column_table_name(stmt, col.cint)
  let originName = sqlite3_column_origin_name(stmt, col.cint)
  if tableName == nil:
    result = not isKnownNotNull(fromCString(sqlite3_column_name(stmt, col.cint)))
  elif originName == nil:
    result = not isKnownNotNull(fromCString(sqlite3_column_name(stmt, col.cint)))
  else:
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

proc validateSql*(sql: string): SqlMeta =
  var dbPath = getEnv("DOKIME_DATABASE_PATH")
  if dbPath.len == 0:
    result = readCache(sql)
    return

  var db: sqlite3.DbConn = nil
  let rc = sqlite3_open_v2(toCString(dbPath), db, SQLITE_OPEN_READWRITE, nil)
  if rc != SQLITE_OK:
    let msg =
      if db != nil: fromCString(sqlite3_errmsg(db))
      else: "open failed"
    return SqlMeta(error: "cannot open database: " & msg)

  var stmt: sqlite3.Stmt = nil
  var s = sql
  let prepRc = sqlite3_prepare_v2(db, toCString(s), sql.len.cint, stmt, nil)
  if prepRc != SQLITE_OK:
    let errMsg = fromCString(sqlite3_errmsg(db))
    discard sqlite3_close_v2(db)
    return SqlMeta(error: errMsg)

  let params = sqlite3_bind_parameter_count(stmt).int
  let count = sqlite3_column_count(stmt)
  var columns: seq[ColumnMeta] = @[]
  for i in 0..<count.int:
    let colName = fromCString(sqlite3_column_name(stmt, i.cint))
    let displayName =
      if isValidIdent(colName): colName else: "col_" & $i
    let decltype = sqlite3_column_decltype(stmt, i.cint)
    let typeStr = if decltype != nil: fromCString(decltype) else: ""
    columns.add ColumnMeta(
      name: displayName,
      kind: toColumnKind(typeStr, colName),
      nullable: inferNullable(db, stmt, i))
  discard sqlite3_finalize(stmt)
  discard sqlite3_close_v2(db)

  writeCache(sql, columns, params)
  result = SqlMeta(columns: columns, params: params)

func sameColumns(a, b: seq[ColumnMeta]): bool =
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

proc validateDynamicSql*(parsed: ParsedSql): SqlMeta =
  var expectedColumns: seq[ColumnMeta] = @[]

  for mask in 0..<parsed.variantCount:
    let sql = parsed.renderVariant(mask)
    let entry = validateSql(sql)
    if entry.error.len > 0:
      return SqlMeta(error: entry.error & " in optional SQL variant " & $mask & ": " & sql)
    if entry.params != parsed.variantParamCount(mask):
      return SqlMeta(error: "parameter count mismatch in optional SQL variant")

    if mask == 0:
      expectedColumns = entry.columns
    elif not sameColumns(expectedColumns, entry.columns):
      return SqlMeta(error: "optional SQL variants must return the same columns")

  result = SqlMeta(columns: expectedColumns, params: parsed.params.len)
