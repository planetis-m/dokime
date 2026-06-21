import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/blogtest.db")
  discard exec(db, "DELETE FROM profiles WHERE id = 1")
  discard exec(db, "INSERT INTO profiles VALUES (?, ?, ?, ?)", 1'i64, "Alice", "Al", 9.5)
  discard exec(db, "INSERT INTO profiles VALUES (?, ?, NULL, NULL)", 2'i64, "Bob")

  let profile = query(db, "SELECT id, nickname FROM profiles WHERE id = ?", 1'i64)
  echo profile.id
  if profile.nickname.isSome:
    echo profile.nickname.unsafeGet
  else:
    echo "no nickname"

  let bob = query(db, "SELECT id, nickname FROM profiles WHERE id = ?", 2'i64)
  echo bob.id
  if bob.nickname.isSome:
    echo bob.nickname.unsafeGet
  else:
    echo "no nickname"

  close(db)

try:
  main()
except ErrorCode as e:
  echo "ErrorCode: " & $e
  quit(1)
