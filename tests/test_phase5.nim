## Phase 5: Integration test with parameterized query.
##
## This test verifies the full library: import nsql/nsql, use the query
## template with bind parameters, and get back a typed result.
##
## Run:
##   NSQL_DATABASE_PATH=tests/test_validate.db \
##   nimony c -r --path:src -o:tests/test_phase5 tests/test_phase5.nim

{.feature: "lenientnils".}

import std/syncio
import std/assertions
import nsql/nsql

# Set up test database with seed data
block setup:
  let db = openDatabase("tests/test_phase5.db")
  discard execSql(db, "DROP TABLE IF EXISTS users;")
  discard execSql(db,
    "CREATE TABLE users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT"
  )
  # Insert test data using raw FFI
  var stmt = prepareStmt(db, "INSERT INTO users VALUES (?, ?, ?)")
  discard bindInt64(stmt, 1, 1'i64)
  discard bindText(stmt, 2, "Alice")
  discard bindInt64(stmt, 3, 30'i64)
  discard stepStmt(stmt)
  finalizeStmt(stmt)

  var stmt2 = prepareStmt(db, "INSERT INTO users VALUES (?, ?, ?)")
  discard bindInt64(stmt2, 1, 2'i64)
  discard bindText(stmt2, 2, "Bob")
  discard bindInt64(stmt2, 3, 25'i64)
  discard stepStmt(stmt2)
  finalizeStmt(stmt2)
  closeDatabase(db)

# Also set up the validation database to match
block:
  discard execSql(
    openDatabase("tests/test_validate.db"),
    "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT;"
  )

# Open runtime connection
let db = openDatabase("tests/test_phase5.db")

# Parameterized query — validated at compile time, executed at runtime
let userId = 1'i64
let row = query(db, "SELECT id, name, age FROM users WHERE id = ?", userId)

echo "Query result:"
echo "  id: " & $row.id       # int64
echo "  name: " & row.name     # string
echo "  age: " & $row.age      # int64

# Verify values
assert row.id == 1
assert row.name == "Alice"
assert row.age == 30

closeDatabase(db)
echo ""
echo "Phase 5 passed: parameterized query works end-to-end."
