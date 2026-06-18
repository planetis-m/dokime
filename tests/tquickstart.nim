## Quick-start test: verify the README example works.
##
## Run:
##   DOKIME_DATABASE_PATH=tests/quickstart.db nimony c -r tests/tquickstart.nim
{.feature: "lenientnils".}

import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = openDatabase("tests/quickstart.db")
  let row = query(db, "SELECT id, name, age FROM users WHERE id = ?", 1'i64)
  echo row.name

try:
  main()
except ErrorCode as e:
  echo "ERROR: " & $e
  quit(1)
