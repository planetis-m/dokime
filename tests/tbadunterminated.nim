## Negative test: unterminated optional block.
## Expected: dokime compile error "unterminated optional SQL block".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id FROM users WHERE [id = ?", 1'i64)

main()
