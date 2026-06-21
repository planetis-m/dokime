## Negative test: parameter count mismatch (too few parameters).
## Expected: dokime compile error "expected N SQL parameter(s), got M".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id, name FROM users WHERE id = ? AND age = ?", 1'i64)

main()
