## Expression type inference: tests that heuristics match actual SQLite types.
##
## Exercises the inferExprKind and isKnownNotNull heuristics
## against a live SQLite database to verify compile-time type
## inference produces correct runtime results.

import std/[assertions, syncio, math]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/texprtypes.db")
  discard exec(db, "DROP TABLE IF EXISTS items")
  discard exec(db, """
    CREATE TABLE IF NOT EXISTS items (
      id    INTEGER NOT NULL,
      name  TEXT    NOT NULL,
      price REAL    NOT NULL,
      tag   TEXT,
      qty   INTEGER
    ) STRICT
  """)
  discard exec(db, "INSERT INTO items VALUES (?, ?, ?, ?, ?)",
    1'i64, "Widget", 9.99'f64, "gadget", 10'i64)
  discard exec(db, "INSERT INTO items VALUES (?, ?, ?, ?, ?)",
    2'i64, "Gadget", 14.50'f64, "gadget", 5'i64)
  discard exec(db, "INSERT INTO items VALUES (?, ?, ?, NULL, ?)",
    3'i64, "Doohickey", 2.75'f64, 0'i64)

  echo "1/27 count"
  let c = query(db, "SELECT count(*) FROM items")
  assert c[0] == 3'i64

  echo "2/27 exists"
  let e = query(db, "SELECT exists(SELECT 1 FROM items WHERE id = 1)")
  assert e[0] == 1'i64

  echo "3/27 random"
  let r = query(db, "SELECT random() FROM items LIMIT 1")
  assert r[0] != 0'i64

  echo "4/27 upper"
  let upperRow = query(db, "SELECT UPPER(name) FROM items WHERE id = 1")
  assert upperRow[0].unsafeGet == "WIDGET"

  echo "5/27 lower"
  let lowerRow = query(db, "SELECT LOWER(name) FROM items WHERE id = 1")
  assert lowerRow[0].unsafeGet == "widget"

  echo "6/27 trim"
  let trimRow = query(db, "SELECT TRIM(name) FROM items WHERE id = 1")
  assert trimRow[0].unsafeGet == "Widget"

  echo "7/27 substr"
  let substrRow = query(db, "SELECT SUBSTR(name, 1, 3) FROM items WHERE id = 1")
  assert substrRow[0].unsafeGet == "Wid"

  echo "8/27 replace"
  let replaceRow = query(db, "SELECT REPLACE(name, 'd', 'X') FROM items WHERE id = 1")
  assert replaceRow[0].unsafeGet == "WiXget"

  echo "9/27 hex"
  let hexRow = query(db, "SELECT HEX(255)")
  assert hexRow[0].unsafeGet == "323535"

  echo "10/27 date"
  let dateRow = query(db, "SELECT DATE('now')")
  assert dateRow[0].isSome

  echo "11/27 time"
  let timeRow = query(db, "SELECT TIME('now')")
  assert timeRow[0].isSome

  echo "12/27 datetime"
  let datetimeRow = query(db, "SELECT DATETIME('now')")
  assert datetimeRow[0].isSome

  echo "13/27 strftime"
  let strftimeRow = query(db, "SELECT STRFTIME('%Y', 'now')")
  assert strftimeRow[0].isSome

  echo "14/27 sqlite_version"
  let verRow = query(db, "SELECT SQLITE_VERSION()")
  assert verRow[0] != ""

  echo "15/27 char"
  let charRow = query(db, "SELECT CHAR(65)")
  assert charRow[0] == "A"

  echo "16/27 changes"
  let changesRow = query(db, "SELECT CHANGES()")
  assert changesRow[0] >= 0'i64

  echo "17/27 length"
  let lenRow = query(db, "SELECT LENGTH(name) FROM items WHERE id = 1")
  assert lenRow[0].unsafeGet == 6'i64

  echo "18/27 instr"
  let instrRow = query(db, "SELECT INSTR(name, 'dg') FROM items WHERE id = 1")
  assert instrRow[0].unsafeGet == 3'i64

  echo "19/27 unicode"
  let unicodeRow = query(db, "SELECT UNICODE(name) FROM items WHERE id = 1")
  assert unicodeRow[0].unsafeGet == 87'i64

  echo "20/27 sum (no heuristic, falls back to string)"
  let sumRow = query(db, "SELECT SUM(qty) FROM items")
  assert sumRow[0].unsafeGet == "15"

  echo "21/27 avg"
  let avgRow = query(db, "SELECT AVG(price) FROM items")
  assert avgRow[0].unsafeGet > 0.0'f64

  echo "22/27 total"
  let totalRow = query(db, "SELECT TOTAL(price) FROM items")
  assert totalRow[0].unsafeGet > 0.0'f64

  echo "23/27 round"
  let roundRow = query(db, "SELECT ROUND(price, 1) FROM items WHERE id = 1")
  assert roundRow[0].unsafeGet == 10.0'f64

  echo "24/27 group_concat"
  let gcRow = query(db, "SELECT GROUP_CONCAT(name) FROM items")
  assert gcRow[0].unsafeGet == "Widget,Gadget,Doohickey"

  echo "25/27 printf"
  let printfRow = query(db, "SELECT PRINTF('%s=%d', name, id) FROM items WHERE id = 1")
  assert printfRow[0].unsafeGet == "Widget=1"

  echo "26/27 format"
  let formatRow = query(db, "SELECT FORMAT('%s=%d', name, id) FROM items WHERE id = 1")
  assert formatRow[0].unsafeGet == "Widget=1"

  close(db)
  echo "All expression type inference tests passed."

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
