## Move money between accounts with a compile-checked transaction.
##
## Every SQL string here is validated against the schema at build time. The
## returned rows are named tuples whose field names and types come from the
## columns — `row.balance` is an `int64` because `balance` is `INTEGER NOT NULL`;
## `row.note` is an `Opt[string]` because `note` is nullable. If you misspell a
## column or use the wrong type, the build fails.
##
## Run:
##   sqlite3 examples/dev.db < examples/schema.sql
##   DOKIME_DATABASE_PATH=examples/dev.db nimony --ff c -r examples/transfer.nim

import std/[opt, syncio]
import dokime

proc balance(db: Database; name: string): int64 {.raises.} =
  let row = query(db, "SELECT balance FROM accounts WHERE name = ?", name)
  result = row.balance

proc transfer(db: Database; fromName, toName: string; amount: int64) {.raises.} =
  var tx = begin(db)
  # If anything below raises, `tx` goes out of scope still active and its
  # destructor rolls the transaction back automatically.
  discard exec(tx, "UPDATE accounts SET balance = balance - ? WHERE name = ?", amount, fromName)
  discard exec(tx, "UPDATE accounts SET balance = balance + ? WHERE name = ?", amount, toName)
  commit(tx)

proc main() {.raises.} =
  let db = connect("examples/transfer.db")

  discard exec(db, "DROP TABLE IF EXISTS accounts")
  discard exec(db, """
    CREATE TABLE IF NOT EXISTS accounts (
      id      INTEGER NOT NULL,
      name    TEXT    NOT NULL,
      balance INTEGER NOT NULL,
      note    TEXT
    ) STRICT
  """)
  discard exec(db, "INSERT INTO accounts VALUES (?, ?, ?, NULL)", 1'i64, "checking", 1_000'i64)
  discard exec(db, "INSERT INTO accounts VALUES (?, ?, ?, ?)", 2'i64, "savings", 500'i64, "high-yield")

  echo "Before:"
  echo "  checking: " & $balance(db, "checking")
  echo "  savings:   " & $balance(db, "savings")

  transfer(db, "checking", "savings", 250'i64)

  echo "After transferring 250:"
  echo "  checking: " & $balance(db, "checking")
  echo "  savings:   " & $balance(db, "savings")

  # Optional row: queryOpt returns Opt instead of raising when nothing matches.
  let maybe = queryOpt(db, "SELECT id, note FROM accounts WHERE name = ?", "wallet")
  if maybe.isNone:
    echo "\nNo 'wallet' account — as expected."

  # Nullable column: `note` decodes to Opt[string], schema-driven.
  let checking = query(db, "SELECT name, note FROM accounts WHERE name = ?", "checking")
  echo "\nchecking note is NULL: " & $checking.note.isNone
  let savings = query(db, "SELECT name, note FROM accounts WHERE name = ?", "savings")
  echo "savings note: " & savings.note.unsafeGet

  close(db)

try:
  main()
except ErrorCode as e:
  echo "Unexpected error: " & $e
  quit(1)
