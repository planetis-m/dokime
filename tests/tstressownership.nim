## Stress the Transaction/Database ownership model at its weak points.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc dbSetup(): Database {.raises.} =
  result = connect("tests/tstressownership.db")
  discard exec(result, "DROP TABLE IF EXISTS users")
  discard exec(result, """
    CREATE TABLE IF NOT EXISTS users (
      id   INTEGER NOT NULL,
      name TEXT    NOT NULL,
      age  INTEGER NOT NULL
    ) STRICT
  """)

proc test_doubleBegin(db: Database) {.raises.} =
  var tx = begin(db)
  var caught = false
  try:
    discard begin(db)
  except:
    caught = true
  assert(caught, "double begin must raise")
  rollback(tx)

proc test_closeWhileTxActive(db: Database) {.raises.} =
  let db2 = connect("tests/tstressownership_close.db")
  var tx = begin(db2)
  var caught = false
  try:
    close(db2)
  except:
    caught = true
  assert(caught, "close while tx active must raise")
  commit(tx)
  close(db2)

proc test_rollbackGuard(db: Database) {.raises.} =
  var tx = begin(db)
  rollback(tx)
  assert(not tx.isActive, "isActive false after rollback")
  var caught = false
  try:
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 0'i64, "nope", 0'i64)
  except:
    caught = true
  assert(caught, "use after rollback must raise")

proc test_commitThenNewBegin(db: Database) {.raises.} =
  block firstTx:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "kept", 0'i64)
    commit(tx)
    assert(not tx.isActive, "isActive false after commit")
  block secondTx:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "also", 0'i64)
    commit(tx)
  assert(query(db, "SELECT name FROM users WHERE id = ?", 1'i64).name == "kept",
         "first committed row must survive")
  assert(query(db, "SELECT name FROM users WHERE id = ?", 2'i64).name == "also",
         "second committed row must survive")

proc test_rollbackThenNewBegin(db: Database) {.raises.} =
  block firstTx:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 3'i64, "gone", 0'i64)
    rollback(tx)
    assert(not tx.isActive, "isActive false after rollback")
  block secondTx:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 4'i64, "here", 0'i64)
    commit(tx)
  var missing = false
  try:
    discard query(db, "SELECT id FROM users WHERE id = ?", 3'i64)
  except:
    missing = true
  assert(missing, "row 3 must have been rolled back")
  assert(query(db, "SELECT name FROM users WHERE id = ?", 4'i64).name == "here",
         "row 4 must survive")

proc test_savepointOnCommittedTx(db: Database) {.raises.} =
  var tx = begin(db)
  discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 6'i64, "safe", 0'i64)
  commit(tx)
  block trySp:
    var caught = false
    try:
      savepoint(tx, "sp")
    except:
      caught = true
    assert(caught, "savepoint on committed tx must raise")
  block tryRel:
    var caught = false
    try:
      release(tx, "sp")
    except:
      caught = true
    assert(caught, "release on committed tx must raise")
  block tryRb:
    var caught = false
    try:
      rollback(tx, "sp")
    except:
      caught = true
    assert(caught, "rollback savepoint on committed tx must raise")
  assert(query(db, "SELECT name FROM users WHERE id = ?", 6'i64).name == "safe",
         "committed row must survive savepoint rejections")

proc test_destructorNoOpAfterCommit(db: Database) {.raises.} =
  block committed:
    var tx = begin(db)
    discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 7'i64, "vanishes", 0'i64)
    commit(tx)
  var tx = begin(db)
  discard exec(tx, "INSERT INTO users VALUES (?, ?, ?)", 8'i64, "fresh", 0'i64)
  commit(tx)
  assert(query(db, "SELECT name FROM users WHERE id = ?", 8'i64).name == "fresh",
         "new begin after committed tx destructor must work")

proc main() {.raises.} =
  let db = dbSetup()
  test_doubleBegin(db)
  test_closeWhileTxActive(db)
  test_rollbackGuard(db)
  test_commitThenNewBegin(db)
  test_rollbackThenNewBegin(db)
  test_savepointOnCommittedTx(db)
  test_destructorNoOpAfterCommit(db)
  close(db)
  echo "All ownership stress tests passed."

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
