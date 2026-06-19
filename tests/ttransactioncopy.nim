## Transaction handles are intentionally non-copyable.

import std/syncio
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = openDatabase("tests/ttransactioncopy.db")
  var tx = beginTransaction(db)
  let copied = tx
  discard copied
  discard tx.isActive

try:
  main()
except ErrorCode:
  quit(1)
