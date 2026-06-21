## Negative test: unmatched ] in SQL.
## Expected: dokime compile error "unmatched ] in SQL string".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id FROM users] WHERE id = ?", 1'i64)

main()
