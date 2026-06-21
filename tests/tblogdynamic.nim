import std/[opt, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/blogtest.db")

  let minAge = some(18'i64)
  let nameFilter = none[string]()

  for user in rows(db, """
    SELECT id, name, age FROM users
    WHERE 1 = 1
      [AND age >= ?]
      [AND name = ?]
    ORDER BY name
  """, minAge, nameFilter):
    echo user.name

  close(db)

try:
  main()
except ErrorCode as e:
  echo "ErrorCode: " & $e
  quit(1)
