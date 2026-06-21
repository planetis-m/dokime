## Negative test: query used with INSERT.
## Expected: dokime compile error "query requires row-returning SQL; use exec for command SQL".

import ".." / "src" / dokime

proc main() =
  let db = connect("tests/validate.db")
  discard query(db, "INSERT INTO users (id, name, age) VALUES (?, ?, ?)", 1'i64, "Bob", 25'i64)

main()
