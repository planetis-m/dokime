## Verifies SQL line comments are stripped during normalization
## and do not break parsing or validation.

import std/[assertions, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/tnormalize.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, """
    CREATE TABLE IF NOT EXISTS users (
      id   INTEGER NOT NULL,
      name TEXT    NOT NULL,
      age  INTEGER NOT NULL
    ) STRICT
  """)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Alice", 30'i64)

  # -- line comment in the SQL
  let row1 = query(db, """
    SELECT id, name, age
    -- this is a comment
    FROM users WHERE id = ?
  """, 1'i64)
  assert row1.id == 1
  assert row1.name == "Alice"

  # -- line comment between keywords
  let row2 = query(db, """
    SELECT id, name
    -- another comment
    FROM users
    -- and one more
    WHERE id = ?
  """, 1'i64)
  assert row2.id == 1

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
