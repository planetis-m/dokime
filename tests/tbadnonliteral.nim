## Negative test: non-string literal as SQL (variable instead of literal).
## Expected: dokime compile error "second argument must be a SQL string literal".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  let sql = "SELECT id, name FROM users WHERE id = ?"
  discard query(db, sql, 1'i64)

main()
