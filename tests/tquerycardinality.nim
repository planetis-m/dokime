## query() and queryOpt() row cardinality behavior.

import std/[assertions, syncio]
import ".." / "src" / dokime

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

  # query() requires a row; verify it raises BadOperation when none found
  block:
    var raised = false
    try:
      discard query(db, "SELECT id, name FROM users WHERE id = ?", 2'i64)
    except ErrorCode as e:
      assert e == BadOperation
      raised = true
    assert raised, "query() should raise BadOperation when no row"

  closeDatabase(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
