## Negative test: query references a nonexistent table.
## Expected: dokime compile error "no such table".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id, name FROM nonexistent WHERE id = ?", 1'i64)

main()
