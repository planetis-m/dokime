## Integration test: parameterized query with compile-time validation.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = openDatabase("tests/tphase5.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")

  let insert1 = exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Alice", 30'i64)
  assert insert1.changes == 1

  let insert2 = exec(db, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Bob", 25'i64)
  assert insert2.changes == 1
  closeDatabase(db)

  let runtimeDb = openDatabase("tests/tphase5.db")
  let userId = 1'i64
  let row = query(runtimeDb, "SELECT id, name, age FROM users WHERE id = ?", userId)

  echo "Query result:"
  echo "  id: " & $row.id
  echo "  name: " & row.name
  echo "  age: " & $row.age

  assert row.id == 1
  assert row.name == "Alice"
  assert row.age == 30
  closeDatabase(runtimeDb)
  echo "\nPhase 5 passed: parameterized query works end-to-end."

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
