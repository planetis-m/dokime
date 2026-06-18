## Phase 1 test: SQLite FFI bindings.
##
## Verifies: open → create STRICT table → insert (bound params) →
## query → read columns → close.
##
## Compile: nimony c -r tests/tffi.nim

{.feature: "lenientnils".}

import std/syncio
import ".." / "src" / "dokime" / [sqlite3]

proc check(db: DbConn, code: cint, msg: string) =
  if code != SQLITE_OK:
    echo "FAIL: " & msg
    echo "  sqlite3 error: " & fromCString(sqlite3_errmsg(db))
    quit(1)

# ---- 1. Open in-memory database ----

var db: DbConn = nil
let rc = sqlite3_open_v2(
  cstring":memory:",
  db,
  cint(SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE),
  nil
)
check(db, rc, "sqlite3_open_v2")
echo "OK: database opened"

# ---- 2. Create STRICT table ----

let createSql = cstring(
  "CREATE TABLE users (id INTEGER NOT NULL, name TEXT NOT NULL, active INTEGER NOT NULL) STRICT"
)
let rc2 = sqlite3_exec(db, createSql, nil, nil, nil)
if rc2 != SQLITE_OK:
  echo "FAIL: create table: " & fromCString(sqlite3_errmsg(db))
  quit(1)
echo "OK: STRICT table created"

# ---- 3. Insert with bound parameters ----

var insertStmt: Stmt = nil
let insertSql = cstring("INSERT INTO users (id, name, active) VALUES (?, ?, ?)")
let rc3 = sqlite3_prepare_v2(db, insertSql, insertSql.len.cint, insertStmt, nil)
check(db, rc3, "prepare insert")

discard sqlite3_bind_int64(insertStmt, 1.cint, 42'i64)
let nameStr = cstring("Alice")
discard sqlite3_bind_text(insertStmt, 2.cint, nameStr, nameStr.len.cint, cast[pointer](-1))
discard sqlite3_bind_int64(insertStmt, 3.cint, 1'i64)

let stepRc = sqlite3_step(insertStmt)
if stepRc != SQLITE_DONE:
  echo "FAIL: insert step: " & fromCString(sqlite3_errmsg(db))
  quit(1)
echo "OK: row inserted"

discard sqlite3_finalize(insertStmt)

# ---- 4. Query the row back ----

var queryStmt: Stmt = nil
let querySql = cstring("SELECT id, name, active FROM users WHERE id = ?")
let rc4 = sqlite3_prepare_v2(db, querySql, querySql.len.cint, queryStmt, nil)
check(db, rc4, "prepare query")

discard sqlite3_bind_int64(queryStmt, 1.cint, 42'i64)

let queryStep = sqlite3_step(queryStmt)
if queryStep != SQLITE_ROW:
  echo "FAIL: expected SQLITE_ROW, got " & $queryStep
  quit(1)

# ---- 5. Read column values ----

let colCount = sqlite3_column_count(queryStmt)
if colCount != 3:
  echo "FAIL: expected 3 columns, got " & $colCount
  quit(1)

let idVal = sqlite3_column_int64(queryStmt, 0.cint)
let nameVal = fromCString(sqlite3_column_text(queryStmt, 1.cint))
let activeVal = sqlite3_column_int64(queryStmt, 2.cint)
let nameCol = fromCString(sqlite3_column_name(queryStmt, 0.cint))

# ---- 6. Verify ----

if idVal != 42:
  echo "FAIL: id = " & $idVal & ", expected 42"
  quit(1)

if nameVal != "Alice":
  echo "FAIL: name = " & nameVal & ", expected Alice"
  quit(1)

if activeVal != 1:
  echo "FAIL: active = " & $activeVal & ", expected 1"
  quit(1)

if nameCol != "id":
  echo "FAIL: column name = " & nameCol & ", expected id"
  quit(1)

echo "OK: query returned id=" & $idVal & " name=" & nameVal & " active=" & $activeVal

discard sqlite3_finalize(queryStmt)
discard sqlite3_close_v2(db)

echo ""
echo "All Phase 1 tests passed."
