## Negative test: optional block introduces a column error in one variant.
## Expected: dokime compile error "no such column in optional SQL variant N".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id FROM users WHERE 1=1 [AND nonexistent = ?]", 1'i64)

main()
