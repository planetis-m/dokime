## Build a filtered user search with optional SQL clauses.
##
## Each `[AND ...]` block is bound to an `Opt[T]` parameter. At compile time,
## dokime validates every included/omitted variant against the schema; at
## runtime, the clause is emitted only when the option is `some`. No string
## concatenation, no SQL injection surface, no forgotten `?`.
##
## Run:
##   sqlite3 examples/dev.db < examples/schema.sql
##   DOKIME_DATABASE_PATH=examples/dev.db nimony --ff c -r examples/search_users.nim

import std/[opt, syncio]
import dokime

proc search(db: Database; minAge: Opt[int64]; nameLike: Opt[string]) {.raises.} =
  for u in rows(db, """
    SELECT id, name, age FROM users
    WHERE 1 = 1
      [AND age >= ?]
      [AND name LIKE ?]
    ORDER BY id
    """, minAge, nameLike):
    echo $u.id & "\t" & u.name & "\t" & $u.age

proc main() {.raises.} =
  let db = connect("examples/search_users.db")

  discard exec(db, "DROP TABLE IF EXISTS users")
  discard exec(db, """
    CREATE TABLE IF NOT EXISTS users (
      id   INTEGER NOT NULL,
      name TEXT    NOT NULL,
      age  INTEGER NOT NULL
    ) STRICT
  """)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 1'i64, "Ada Lovelace", 36'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 2'i64, "Grace Hopper", 40'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 3'i64, "Lin Torvalds", 29'i64)
  discard exec(db, "INSERT INTO users VALUES (?, ?, ?)", 4'i64, "Margaret Hamilton", 41'i64)

  echo "Everyone:"
  search(db, none[int64](), none[string]())

  echo "\nAge >= 40:"
  search(db, some(40'i64), none[string]())

  echo "\nName starts with 'A', any age:"
  search(db, none[int64](), some("A%"))

  echo "\nAge >= 35 AND name starts with 'a':"
  search(db, some(35'i64), some("a%"))

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected error: " & $e
  quit(1)
