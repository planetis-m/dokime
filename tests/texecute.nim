## Command execution test: exec() supports non-row SQL.
##
## Run:
##   DOKIME_DATABASE_PATH=tests/tvalidate.db \
##   nimony c -r tests/texecute.nim

import std/assertions
import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = openDatabase("tests/texecute.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")

  let beginResult = exec(db, "BEGIN")
  assert beginResult.changes == 0

  let inserted = exec(db, "INSERT INTO users VALUES (?, ?, ?)", 10'i64, "Carol", 41'i64)
  assert inserted.changes == 1
  assert inserted.lastInsertRowid > 0

  let updated = exec(db, "UPDATE users SET age = ? WHERE id = ?", 42'i64, 10'i64)
  assert updated.changes == 1

  let row = query(db, "SELECT age FROM users WHERE id = ?", 10'i64)
  assert row.age == 42

  let deleted = exec(db, "DELETE FROM users WHERE id = ?", 10'i64)
  assert deleted.changes == 1

  let commitResult = exec(db, "COMMIT")
  assert commitResult.changes == 0
  closeDatabase(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
