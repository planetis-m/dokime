## Verifies the README quick-start example compiles and runs.

import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/tquickstart.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 42'i64, "Alice", 30'i64)

  let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
  echo row.id
  echo row.name
  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
