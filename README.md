# dokime — SQL that won't compile if it's wrong

Every SQL string you pass to `query()`, `queryOpt()`, `rows()`, or `exec()` is
validated against your real database **during compilation**. If the table
doesn't exist, a column is misspelled, or the syntax is broken, you get a
compile error — not a runtime crash.

```nim
import dokime

let db = openDatabase("myapp.db")
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

- **Nimony** (experimental Nim compiler by Araq)
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

   let db = openDatabase("prod.db")
   let row = query(db, "SELECT id, name, age FROM users WHERE id = ?", 1'i64)
   echo row.name  # "Alice" (type: string)
   ```

4. **Compile and run:**

   ```bash
   nimony c -r myapp.nim
   ```

## What gets caught at compile time

| Mistake                                | Result                           |
|----------------------------------------|----------------------------------|
| `SELECT ... FROM no_such_table`        | Compile error: `no such table`   |
| `SELECT wrong_column FROM users`       | Compile error: `no such column`  |
| `SELEC id FROM users`                  | Compile error (SQLite parser)    |
| Using `row.id` as a `string`           | Compile error: `type mismatch`   |

## Commands

Statements that do not return columns execute through `exec()` and return
`SqlExecResult`:

```nim
import std / syncio
import dokime

let db = openDatabase("myapp.db")

discard exec(db, """
  CREATE TABLE IF NOT EXISTS counters (
    name  TEXT    NOT NULL,
    value INTEGER NOT NULL DEFAULT 0
  ) STRICT
""")

let inserted = exec(db, "INSERT INTO counters VALUES (?, ?)", "requests", 42'i64)
echo inserted.lastInsertRowid
echo inserted.changes

let updated = exec(db, "UPDATE counters SET value = value + ? WHERE name = ?", 1'i64, "requests")
echo updated.changes
```

The split follows the result shape, not the first SQL keyword: use `exec()` when
SQLite reports no result columns; use `query()` or `rows()` for `INSERT ...
RETURNING`, `UPDATE ... RETURNING`, CTEs, and any other statement that returns
columns.

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
| `exec(db, sql, params...)`                | No-column SQL as `SqlExecResult`     |
| `openDatabase(path)` → `DbConn`           | Open or create a SQLite database     |
| `closeDatabase(db)`                       | Close the connection                 |
| `SqlExecResult.changes` → `int64`         | Rows changed by a command statement  |
| `SqlExecResult.lastInsertRowid` → `int64` | Rowid from the command statement     |

## Run the tests

```bash
# FFI bindings (no compile-time validation)
nimony c -r tests/tffi.nim

# Full integration (compile-time validation + runtime)
DOKIME_DATABASE_PATH=tests/tvalidate.db nimony c -r tests/tphase5.nim

# Command statements through exec()
DOKIME_DATABASE_PATH=tests/tvalidate.db nimony c -r tests/texecute.nim

# Required/optional row cardinality
DOKIME_DATABASE_PATH=tests/tvalidate.db nimony c -r tests/tquerycardinality.nim

# Nullable column decoding
DOKIME_DATABASE_PATH=tests/tnullable_validate.db nimony c -r tests/tnullable.nim

# Streaming row iteration
DOKIME_DATABASE_PATH=tests/tvalidate.db nimony c -r tests/trows.nim
```

## Limitations

- SQLite only.
- `query()` and `queryOne()` use single-row fetch (`fetch_one` semantics);
  extra rows are not checked yet. Use `rows()` to stream many rows.
- `DOKIME_DATABASE_PATH` must be set at compile time (no offline schema cache).
- STRICT tables required for reliable type inference.

## Project layout

| File                         | Purpose                                      |
|------------------------------|----------------------------------------------|
| `src/dokime.nim`             | Public API templates                         |
| `src/dokime/types.nim`       | Public result types                          |
| `src/dokime/sqlite3.nim`     | SQLite3 FFI bindings (dynlib)                |
| `src/dokime/private/runtime.nim` | Private runtime used by generated code   |
| `src/dokimeplugin.nim`       | Compile-time plugin (SQL validation + codegen) |
| `src/dokimeoptplugin.nim`    | Optional-row query plugin                    |
| `src/dokimerowsplugin.nim`   | Streaming row query plugin                   |
| `src/dokimeexecplugin.nim`   | Command execution plugin                     |
