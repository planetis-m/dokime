## Nullable column test.
##
## Prepare the validation database first:
##   sqlite3 tests/tnullable_validate.db \
##     "CREATE TABLE profiles (id INTEGER NOT NULL, name TEXT NOT NULL, nickname TEXT, score REAL) STRICT"
##
## Run:
##   DOKIME_DATABASE_PATH=tests/tnullable_validate.db \
##   nimony c -r tests/tnullable.nim

import std/assertions
import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = openDatabase("tests/tnullable_runtime.db")
  discard exec(db, "DROP TABLE IF EXISTS profiles")
  discard exec(db, "CREATE TABLE IF NOT EXISTS profiles (id INTEGER NOT NULL, name TEXT NOT NULL, nickname TEXT, score REAL) STRICT")
  discard exec(db, "INSERT INTO profiles VALUES (?, ?, ?, ?)", 1'i64, "Alice", "Al", 9.5)
  discard exec(db, "INSERT INTO profiles VALUES (?, ?, NULL, NULL)", 2'i64, "Bob")

  let alice = query(db, "SELECT id, name, nickname, score FROM profiles WHERE id = ?", 1'i64)
  assert alice.id == 1
  assert alice.name == "Alice"
  assert alice.nickname.isSome
  assert alice.nickname.unsafeGet == "Al"
  assert alice.score.isSome
  assert alice.score.unsafeGet == 9.5

  let bob = query(db, "SELECT id, name, nickname, score FROM profiles WHERE id = ?", 2'i64)
  assert bob.id == 2
  assert bob.name == "Bob"
  assert bob.nickname.isNone
  assert bob.score.isNone

  closeDatabase(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
