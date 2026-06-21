## Negative test: optional blocks return different columns per variant.
## Expected: dokime compile error "optional SQL variants must return the same columns".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT 1 [, ?] FROM users", "val")

main()
