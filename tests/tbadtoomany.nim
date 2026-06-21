## Negative test: too many optional blocks (>8).
## Expected: dokime compile error "optional SQL blocks are limited to 8 per query".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, """
    SELECT id FROM users WHERE 1 = 1
      [AND age > ?]
      [AND age < ?]
      [AND id > ?]
      [AND id < ?]
      [AND name LIKE ?]
      [AND name NOT LIKE ?]
      [AND age = ?]
      [AND id = ?]
      [AND age <> ?]
  """, 10'i64, 20'i64, 1'i64, 100'i64, "a", "b", 15'i64, 50'i64, 30'i64)

main()
