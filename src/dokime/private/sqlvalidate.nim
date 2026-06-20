## SQL validation against a live SQLite database.
##
## Prepares a SQL statement with the development database pointed to by
## `DOKIME_DATABASE_PATH`, reads back column metadata (name, declared type and
## nullability) and mirrors the result to the offline cache so subsequent
## builds can validate without a database connection.

import std / envvars

import cacheio
import ".." / sqlite3

proc toColumnKind*(typeName: string): ColumnKind =
  case typeName
  of "INTEGER", "INT": ckInteger
  of "TEXT", "STRING": ckText
  of "REAL", "FLOAT", "DOUBLE": ckReal
  of "BLOB": ckBlob
  else: ckNull

proc inferNullable*(db: sqlite3.DbConn; stmt: sqlite3.Stmt; col: int): bool =
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

proc validateSql*(sql: string): CacheEntry =
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
