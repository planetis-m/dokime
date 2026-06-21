## NOT NULL inference: unaliased count(*) + tuple[0] access.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/tnotnull.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Alice", 30'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Bob", 25'i64)

  let row = query(db, "SELECT count(*) FROM users")
  assert row[0] == 2

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
