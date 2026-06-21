## Negative test: nested optional blocks in SQL.
## Expected: dokime compile error "nested optional SQL blocks are not supported".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, """
    SELECT id FROM users WHERE 1 = 1
      [AND id = [AND name = ?]]
  """, 1'i64)

main()
