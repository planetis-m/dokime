## Negative test: bad table name.
{.feature: "lenientnils".}

import std/syncio
import ".." / "src" / dokime

try:
  let db = openDatabase("tests/quickstart.db")
  let row = query(db, "SELECT id, name FROM nonexistent WHERE id = ?", 1'i64)
  echo row.name
except ErrorCode as e:
  echo "ERROR: " & $e
