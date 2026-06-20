## Nullable parameter binding for exec().

import std/[assertions, opt, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/tnullableparams.db")
  discard exec(db, "DROP TABLE IF EXISTS notes")
  discard exec(db, "CREATE TABLE IF NOT EXISTS notes (id INTEGER NOT NULL, title TEXT NOT NULL, body TEXT, tag TEXT) STRICT")

  let body = none[string]()
  discard exec(db, "INSERT INTO notes VALUES (?, ?, ?, ?)", 1'i64, "First", body, some("draft"))

  let row = query(db, "SELECT body, tag FROM notes WHERE id = ?", 1'i64)
  assert row.body.isNone
  assert row.tag.isSome
  assert row.tag.unsafeGet == "draft"

  let clearTag = none[string]()
  discard exec(db, "UPDATE notes SET tag = ? WHERE id = ? [AND title = ?]", clearTag, 1'i64, some("First"))

  let updated = query(db, "SELECT tag FROM notes WHERE id = ?", 1'i64)
  assert updated.tag.isNone

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
