## Phase 5: Integration test with parameterized query.
##
## This test verifies the full library: import dokime, use the query
## template with bind parameters, and get back a typed result.
##
## Run:
##   DOKIME_DATABASE_PATH=tests/tvalidate.db \
##   nimony c -r tests/tphase5.nim

import std/syncio
import std/assertions
import ".." / "src" / dokime

proc main() {.raises.} =
  # Set up test database with seed data
  let db = openDatabase("tests/tphase5.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")

  let insert1 = exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Alice", 30'i64)
  assert insert1.changes == 1

  let insert2 = exec(db, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Bob", 25'i64)
  assert insert2.changes == 1
  closeDatabase(db)

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
