## Phase 5: Integration test with parameterized query.
##
## This test verifies the full library: import dokime, use the query
## template with bind parameters, and get back a typed result.
##
## Run:
##   DOKIME_DATABASE_PATH=tests/tvalidate.db \
##   nimony c -r tests/tphase5.nim

{.feature: "lenientnils".}

import std/syncio
import std/assertions
import ".." / "src" / [dokime]

proc main() {.raises.} =
  # Set up test database with seed data
  let db = openDatabase("tests/tphase5.db")
  execSql(db, "DROP TABLE IF EXISTS users;")
  execSql(db,
    "CREATE TABLE users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT"
  )
  # Insert test data using raw FFI
  var stmt = prepareStmt(db, "INSERT INTO users VALUES (?, ?, ?)")
  bindInt64(stmt, 1, 1'i64)
  bindText(stmt, 2, "Alice")
  bindInt64(stmt, 3, 30'i64)
  discard stepStmt(stmt)
  finalizeStmt(stmt)

  var stmt2 = prepareStmt(db, "INSERT INTO users VALUES (?, ?, ?)")
  bindInt64(stmt2, 1, 2'i64)
  bindText(stmt2, 2, "Bob")
  bindInt64(stmt2, 3, 25'i64)
  discard stepStmt(stmt2)
  finalizeStmt(stmt2)
  closeDatabase(db)

  # Also set up the validation database to match
  let validateDb = openDatabase("tests/tvalidate.db")
  execSql(
    validateDb,
    "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT;"
  )
  closeDatabase(validateDb)

  # Open runtime connection
  let runtimeDb = openDatabase("tests/tphase5.db")

  # Parameterized query — validated at compile time, executed at runtime
  let userId = 1'i64
  let row = query(runtimeDb, "SELECT id, name, age FROM users WHERE id = ?", userId)

  echo "Query result:"
  echo "  id: " & $row.id       # int64
  echo "  name: " & row.name     # string
  echo "  age: " & $row.age      # int64

  # Verify values
  assert row.id == 1
  assert row.name == "Alice"
  assert row.age == 30

  closeDatabase(runtimeDb)
  echo ""
  echo "Phase 5 passed: parameterized query works end-to-end."

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
