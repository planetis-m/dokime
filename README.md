# dokime — SQL that won't compile if it's wrong

Every SQL string you pass to `query()`, `queryOpt()`, `rows()`, or `exec()` is
validated against your real database **during compilation**. If the table
doesn't exist, a column is misspelled, or the syntax is broken, you get a
compile error — not a runtime crash.

```nim
import dokime

let db = connect("myapp.db")
let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
echo row.id    # int64  — type comes from the schema, not a hand-written type
echo row.name  # string — column names become field names

let maybeRow = queryOpt(db, "SELECT id, name FROM users WHERE id = ?", 404'i64)
if maybeRow.isNone:
  echo "not found"
```

## Why try this?

- **Compile-time SQL validation.** Mistakes that would normally surface at
  3am in production are caught before the binary even exists.
- **Schema-driven types.** Return types are inferred from the database
  schema — no manual type definitions, no drift between code and schema.
- **Named tuple fields.** `row.id` and `row.name` come directly from the
  SQL column names. No positional indexing.
- **Result-shaped API.** Use `query()` / `queryOpt()` / `rows()` for SQL that
  returns columns, and `exec()` for SQL that returns only command metadata.
  Both paths are validated at compile time.
- **Zero-abstraction FFI.** Runtime helpers call libsqlite3 directly.
  No ORM, no query builder, no allocations you didn't ask for.

## Requirements

- **Nimony**
- SQLite ≥ 3.37 (for STRICT tables)
- libsqlite3 installed on the system

## Setup + Quick Start

1. **Create a development database** with your schema:

   ```bash
   sqlite3 dev.db "
     CREATE TABLE users (
       id   INTEGER NOT NULL,
       name TEXT    NOT NULL,
       age  INTEGER NOT NULL
     ) STRICT;
   "
   ```

2. **Set the environment variable** so the compiler knows which database to
   validate against:

   ```bash
   export DOKIME_DATABASE_PATH=dev.db
   ```

3. **Write your code:**

   ```nim
   # myapp.nim
   import dokime

   let db = connect("prod.db")
   let row = query(db, "SELECT id, name, age FROM users WHERE id = ?", 1'i64)
   echo row.name  # "Alice" (type: string)
   ```

4. **Compile and run:**

   ```bash
   nimony c -r myapp.nim
   ```

Online builds write validated query metadata to `.dokime/queries/`. Commit that
directory if you want CI or another machine to compile without a live
development database:

```bash
DOKIME_DATABASE_PATH= nimony c -r myapp.nim
```

## What gets caught at compile time

| Mistake                                | Result                           |
|----------------------------------------|----------------------------------|
| `SELECT ... FROM no_such_table`        | Compile error: `no such table`   |
| `SELECT wrong_column FROM users`       | Compile error: `no such column`  |
| `SELECT id FROM users`                 | Compile error (SQLite parser)    |
| Using `row.id` as a `string`           | Compile error: `type mismatch`   |

## Commands

Statements that do not return columns execute through `exec()` and return
`ExecResult`:

```nim
import std / syncio
import dokime

let db = connect("myapp.db")

discard exec(db, """
  CREATE TABLE IF NOT EXISTS counters (
    name  TEXT    NOT NULL,
    value INTEGER NOT NULL DEFAULT 0
  ) STRICT
""")

let inserted = exec(db, "INSERT INTO counters VALUES (?, ?)", "requests", 42'i64)
echo inserted.lastRowid
echo inserted.changes

let updated = exec(db, "UPDATE counters SET value = value + ? WHERE name = ?", 1'i64, "requests")
echo updated.changes
```

The split follows the result shape, not the first SQL keyword: use `exec()` when
SQLite reports no result columns; use `query()` or `rows()` for `INSERT ...
RETURNING`, `UPDATE ... RETURNING`, CTEs, and any other statement that returns
columns.

`exec()` also accepts `Opt[T]` parameters and binds `none` as SQL `NULL`.

## Transactions

Use `begin()` to create a transaction handle. The same compile-time
validated `query()`, `queryOpt()`, `rows()`, and `exec()` templates accept either
a database connection or an active transaction:

```nim
var tx = begin(db)
discard exec(tx, "INSERT INTO counters VALUES (?, ?)", "jobs", 1'i64)
let row = query(tx, "SELECT value FROM counters WHERE name = ?", "jobs")
echo row.value
commit(tx)
```

Call `rollback(tx)` to abort explicitly. If a transaction handle goes out of
scope while still active, its destructor rolls the transaction back. While a
transaction is active, use the transaction handle for queries; direct use of
the database handle raises `BadOperation`.

Savepoints are available with `savepoint(tx, name)`,
`rollback(tx, name)`, and `release(tx, name)`. Savepoint names are
validated as simple SQL identifiers before dokime builds the statement.

## Row Cardinality

Row-returning `query()` requires at least one row. If SQLite returns no row,
it raises `BadOperation` instead of decoding undefined column values.

Use `queryOpt()` when no row is an expected result:

```nim
let user = queryOpt(db, "SELECT id, name FROM users WHERE id = ?", userId)
if user.isSome:
  echo user.unsafeGet.name
```

`queryOne()` is also available as an explicit spelling for the required-row
path. Extra rows are not consumed yet; the current behavior is `fetch_one`
semantics.

## Streaming Rows

Use `rows()` when you want to iterate every returned row without allocating a
sequence first:

```nim
for user in rows(db, "SELECT id, name FROM users"):
  echo user.name
```

The returned rows use the same schema-driven named tuple fields as `query()`.

## Dynamic Optional Clauses

Wrap an optional SQL clause in square brackets and pass an `Opt[T]` for its
`?` parameter. Dokime validates every included/omitted variant at compile time,
then includes the clause at runtime only when the option is `some`.

```nim
let minAge = some(30'i64)
let name = none[string]()

for user in rows(db, """
SELECT id, name, age FROM users
WHERE 1 = 1
  [AND age >= ?]
  [AND name = ?]
ORDER BY id
""", minAge, name):
  echo user.name
```

Each optional block contains exactly one `?`. Required parameters outside
optional blocks continue to use plain values.

## Nullable Columns

Nullable result columns decode to `Opt[T]`:

```nim
let profile = query(db, "SELECT id, nickname FROM profiles WHERE id = ?", id)
if profile.nickname.isSome:
  echo profile.nickname.unsafeGet
```

When dokime can trace a selected column back to a table column, it uses the
schema nullability. Expressions and unknown origins are treated as nullable.

## API cheat sheet

| Proc / template                           | Purpose                              |
|-------------------------------------------|--------------------------------------|
| `query(db, sql, params...)`               | Required row from row-returning SQL  |
| `queryOne(db, sql, params...)`            | Explicit required-row spelling       |
| `queryOpt(db, sql, params...)`            | Optional row as `Opt[row]`           |
| `rows(db, sql, params...)`                | Streaming row iterator               |
| `exec(db, sql, params...)`                | No-column SQL as `ExecResult`        |
| `[SQL with ?]` + `Opt[T]` param           | Optional SQL clause                  |
| `begin(db)` → `Transaction`               | Start a SQLite transaction           |
| `commit(tx)`                              | Commit an active transaction         |
| `rollback(tx)`                            | Roll back an active transaction      |
| `savepoint(tx, name)`                     | Create a transaction savepoint       |
| `rollback(tx, name)`                      | Roll back to a savepoint             |
| `release(tx, name)`                       | Release a savepoint                  |
| `connect(path)` → `Database`              | Open or create a SQLite database     |
| `close(db)`                               | Close the connection                 |
| `ExecResult.changes` → `int64`            | Rows changed by a command statement  |
| `ExecResult.lastRowid` → `int64`          | Rowid from the command statement     |

## Tests

```bash
nim c -r tests/tester.nim
```

This creates the validation database automatically, compiles every test with
Nimony, and verifies that negative tests fail with the expected compile errors.

## Limitations

- SQLite only.
- `query()` and `queryOne()` use single-row fetch (`fetch_one` semantics);
  extra rows are not checked yet. Use `rows()` to stream many rows.
- Offline builds read previously validated query cache entries; there is not a
  dedicated `dokime prepare` command yet.
- STRICT tables required for reliable type inference.

## License

MIT. See [LICENSE](LICENSE).
