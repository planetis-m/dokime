## Runtime helpers used only by generated optional-clause query code.

import std/opt

import runtime
import ".." / sqlite3

proc optionalParamPresent*[T](value: Opt[T]): bool {.raises: [].} =
  result = value.isSome

proc optionalParamValue*[T](value: Opt[T]): T {.raises.} =
  result = value.unsafeGet

proc includeVariantBit*(variant: var int; bit: int) {.raises: [].} =
  variant = variant or bit

proc variantSelected*(variant, expected: int): bool {.raises: [].} =
  result = variant == expected

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
