## Negative test: optional block with no parameters.
## Expected: dokime compile error "optional SQL blocks must contain exactly one ? parameter".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "SELECT id FROM users WHERE [id = 42]", 1'i64)

main()
