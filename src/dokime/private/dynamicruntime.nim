## Runtime helpers used only by generated optional-clause query code.

import runtime
import ".." / sqlite3

proc emptyStmt*(): sqlite3.Stmt {.raises: [].} =
  result = nil

proc bindNextParam*(stmt: sqlite3.Stmt; idx: var int; value: int64) {.raises.} =
  bindParam(stmt, idx, value)
  inc idx

proc bindNextParam*(stmt: sqlite3.Stmt; idx: var int; value: string) {.raises.} =
  bindParam(stmt, idx, value)
  inc idx

proc bindNextParam*(stmt: sqlite3.Stmt; idx: var int; value: float64) {.raises.} =
  bindParam(stmt, idx, value)
  inc idx
