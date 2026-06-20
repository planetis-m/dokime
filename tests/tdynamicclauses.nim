## Dynamic optional SQL clause tests.

import std/[assertions, opt, syncio]
import ".." / "src" / dokime

proc main() {.raises.} =
  let db = connect("tests/tdynamicclauses.db")
  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT")
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Ada", 36'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Grace", 40'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 3'i64, "Lin", 29'i64)

  block optional_filter_included:
    let minAge = some(35'i64)
    let noName = none[string]()
    var names: seq[string] = @[]
    for user in rows(db, """
      SELECT id, name, age FROM users
      WHERE 1 = 1
        [AND age >= ?]
        [AND name = ?]
      ORDER BY id
      """, minAge, noName):
      names.add user.name
    assert names == @["Ada", "Grace"]

  block optional_filter_omitted:
    let noMinAge = none[int64]()
    let name = some("Lin")
    let user = query(db, """
      SELECT id, name FROM users
      WHERE 1 = 1
        [AND age >= ?]
        [AND name = ?]
      """, noMinAge, name)
    assert user.id == 3
    assert user.name == "Lin"

  block optional_where_clause:
    let name = some("Ada")
    let user = query(db, "SELECT id, name FROM users [WHERE name = ?]", name)
    assert user.id == 1

  block sql_literal_tokens_are_not_clause_syntax:
    let minAge = some(35'i64)
    var names: seq[string] = @[]
    for user in rows(db, """
      SELECT id, name FROM users
      WHERE '[' <> ']'
        [AND name <> '?' AND age >= ?]
      ORDER BY id
      """, minAge):
      names.add user.name
    assert names == @["Ada", "Grace"]

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected ErrorCode: " & $e
  quit(1)
