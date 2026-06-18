## Negative test: verify compile-time SQL validation.

import std/syncio
import ".." / "src" / dokime

try:
  let db = openDatabase("tests/quickstart.db")
  let row = query(db, "SELECT id, nonexistent_column FROM users WHERE id = ?", 1'i64)
  echo row.nonexistent_column
except ErrorCode as e:
  echo "ERROR: " & $e
