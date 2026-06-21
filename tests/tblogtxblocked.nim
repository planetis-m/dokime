import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/blogtest.db")

  var tx = begin(db)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Bad", 1'i64)

  close(db)

try:
  main()
except ErrorCode as e:
  echo "ErrorCode: " & $e
  quit(1)
