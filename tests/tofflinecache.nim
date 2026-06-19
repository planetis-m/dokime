## Verifies that a fresh module can compile from the offline cache.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = openDatabase("tests/tquickstart.db")
  let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
  assert row.id == 42
  assert row.name == "Alice"
  closeDatabase(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
