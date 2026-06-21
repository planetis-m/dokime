import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/blogtest.db")

  discard query(db, "SELECT id, name FROM users WHERE id = ?", 99999'i64)

  close(db)

try:
  main()
except ErrorCode as e:
  echo "ErrorCode: " & $e
  quit(1)
