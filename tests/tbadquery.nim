## Negative test: query references a nonexistent column.
## Expected: dokime compile error "no such column".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id, nonexistent_column FROM users WHERE id = ?", 1'i64)

main()
