import ".." / "src" / dokime

proc main() =
  let db = connect("tests/blogtest.db")
  discard query(db, "SELECT id, full_name FROM users WHERE id = ?", 1'i64)

main()
