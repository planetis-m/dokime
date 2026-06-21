import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/blogtest.db")
  discard exec(db, "DELETE FROM users WHERE id = 42")
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 42'i64, "Alice", 30'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 43'i64, "Bob", 25'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 44'i64, "Carol", 35'i64)

  let user = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
  echo user.id
  echo user.name

  let result = exec(db, "INSERT INTO users VALUES (?, ?, ?)", 99'i64, "Test", 25'i64)
  echo result.lastRowid
  echo result.changes

  let maybe = queryOpt(db, "SELECT id, name FROM users WHERE id = ?", 9999'i64)
  if maybe.isSome:
    echo maybe.unsafeGet.name
  else:
    echo "not found"

  for user in rows(db, "SELECT id, name FROM users"):
    echo user.name

  close(db)

try:
  main()
except ErrorCode as e:
  echo "ErrorCode: " & $e
  quit(1)
