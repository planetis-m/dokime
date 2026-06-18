## Negative test: type mismatch.
{.feature: "lenientnils".}

import std/syncio
import ".." / "src" / dokime

try:
  let db = openDatabase("tests/quickstart.db")
  let row = query(db, "SELECT id, name FROM users WHERE id = ?", 1'i64)
  let x: float64 = row.id
  echo x
except ErrorCode as e:
  echo "ERROR: " & $e
