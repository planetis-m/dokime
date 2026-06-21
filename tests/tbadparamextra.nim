## Negative test: parameter count mismatch (too many parameters).
## Expected: dokime compile error "expected N SQL parameter(s), got M".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id, name FROM users WHERE id = ?", 1'i64, 2'i64)

main()
