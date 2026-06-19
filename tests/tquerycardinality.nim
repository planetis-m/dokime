## query() and queryOpt() row cardinality behavior.
##
## Run:
##   DOKIME_DATABASE_PATH=tests/tvalidate.db \
##   nimony c -r tests/tquerycardinality.nim

import std/assertions
import std/syncio
import ".." / "src" / dokime
import ".." / "src" / "dokime" / sqlite3

proc missingQuery(db: sqlite3.DbConn) {.raises.} =
  discard query(db, "SELECT id, name FROM users WHERE id = ?", 2'i64)

proc expectMissingRaises(db: sqlite3.DbConn) {.raises.} =
  var raised = false
  try:
    missingQuery(db)
  except ErrorCode as e:
    assert e == BadOperation
    raised = true

  assert raised

proc main() {.raises.} =
  let db = openDatabase("tests/tquerycardinality.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Alice", 30'i64)

  let existing = queryOpt(db, "SELECT id, name FROM users WHERE id = ?", 1'i64)
  assert existing.isSome
  assert existing.unsafeGet.id == 1
  assert existing.unsafeGet.name == "Alice"

  let missing = queryOpt(db, "SELECT id, name FROM users WHERE id = ?", 2'i64)
  assert missing.isNone

  expectMissingRaises(db)
  closeDatabase(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
