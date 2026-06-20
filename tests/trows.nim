## Streaming row iteration.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/trows.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Alice", 30'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Bob", 25'i64)

  var count = 0
  var names = ""
  for user in rows(db, "SELECT id, name, age FROM users"):
    count = count + 1
    names = names & user.name

  assert count == 2, "expected 2 rows, got " & $count
  assert names == "AliceBob", "expected AliceBob, got " & names
  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
