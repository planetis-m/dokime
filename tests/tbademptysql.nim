## Negative test: empty SQL string.
## Expected: dokime compile error "expected query(db, \"SQL\", params...)".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "")

main()
