## Phase 1 test: SQLite FFI bindings.
##
## Verifies: open → create STRICT table → insert (bound params) →
## query → read columns → close.
##
## Compile: nimony c -r tests/tffi.nim

import std/[assertions, syncio]
import ".." / "src" / "dokime" / sqlite3

proc check(db: DbConn, code: cint, msg: string) =
  assert code == SQLITE_OK, msg & ": " & fromCString(sqlite3_errmsg(db))

proc main() =
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
  check(db, rc2, "create table")
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
  assert stepRc == SQLITE_DONE, "insert step: " & fromCString(sqlite3_errmsg(db))
  echo "OK: row inserted"

  discard sqlite3_finalize(insertStmt)

  # ---- 4. Query the row back ----

  var queryStmt: Stmt = nil
  let querySql = cstring("SELECT id, name, active FROM users WHERE id = ?")
  let rc4 = sqlite3_prepare_v2(db, querySql, querySql.len.cint, queryStmt, nil)
  check(db, rc4, "prepare query")

  discard sqlite3_bind_int64(queryStmt, 1.cint, 42'i64)

  let queryStep = sqlite3_step(queryStmt)
  assert queryStep == SQLITE_ROW, "expected SQLITE_ROW, got " & $queryStep

  # ---- 5. Read column values ----

  let colCount = sqlite3_column_count(queryStmt)
  assert colCount == 3, "expected 3 columns, got " & $colCount

  let idVal = sqlite3_column_int64(queryStmt, 0.cint)
  let nameVal = fromCString(sqlite3_column_text(queryStmt, 1.cint))
  let activeVal = sqlite3_column_int64(queryStmt, 2.cint)
  let nameCol = fromCString(sqlite3_column_name(queryStmt, 0.cint))

  # ---- 6. Verify ----

  assert idVal == 42, "id = " & $idVal & ", expected 42"
  assert nameVal == "Alice", "name = " & nameVal & ", expected Alice"
  assert activeVal == 1, "active = " & $activeVal & ", expected 1"
  assert nameCol == "id", "column name = " & nameCol & ", expected id"

  echo "OK: query returned id=" & $idVal & " name=" & nameVal & " active=" & $activeVal

  discard sqlite3_finalize(queryStmt)
  discard sqlite3_close_v2(db)

  echo "\nAll Phase 1 tests passed."

main()
