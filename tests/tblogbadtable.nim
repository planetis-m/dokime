import ".." / "src" / dokime

proc main() =
  let db = connect("tests/blogtest.db")
  discard query(db, "SELECT id FROM nonexistent_table WHERE id = ?", 1'i64)

main()
