## Negative test: exec used with SELECT query.
## Expected: dokime compile error "exec requires command SQL with no result columns".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  exec(db, "SELECT id, name FROM users WHERE id = ?", 1'i64)

main()
