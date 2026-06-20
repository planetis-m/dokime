## Transaction tests: commit, rollback, cleanup guard, savepoints, and queries.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc missingUser(db: Database; id: int64) {.raises.} =
  discard query(db, "SELECT id FROM users WHERE id = ?", id)

proc assertMissing(db: Database; id: int64) {.raises.} =
  var raised = false
  try:
    missingUser(db, id)
  except ErrorCode as e:
    assert e == BadOperation
    raised = true
  assert raised

proc assertDatabaseBlocked(db: Database) {.raises.} =
  var raised = false
  try:
    discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 99'i64, "Blocked", 1'i64)
  except ErrorCode as e:
    assert e == BadOperation
    raised = true
  assert raised

proc main() {.raises.} =
  let db = connect("tests/ttransactions.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")

  block commit_persists:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Ada", 36'i64)
    let row = query(tx, "SELECT name FROM users WHERE id = ?", 1'i64)
    assert row.name == "Ada"
    commit(tx)
    assert not tx.isActive
    let committed = query(db, "SELECT name FROM users WHERE id = ?", 1'i64)
    assert committed.name == "Ada"

  block explicit_rollback_discards:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Grace", 40'i64)
    assertDatabaseBlocked(db)
    rollback(tx)
    assertMissing(db, 2'i64)

  block destructor_rollback_discards:
    block:
      var tx = begin(db)
      discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 3'i64, "Lin", 29'i64)
    assertMissing(db, 3'i64)

  block savepoint_rollback:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 4'i64, "Edsger", 42'i64)
    savepoint(tx, "after_edsger")
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 5'i64, "Barbara", 38'i64)
    rollbackTo(tx, "after_edsger")
    release(tx, "after_edsger")
    commit(tx)
    let saved = query(db, "SELECT id FROM users WHERE id = ?", 4'i64)
    assert saved.id == 4
    assertMissing(db, 5'i64)

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
