# dokime — SQL that won't compile if it's wrong

Every SQL string you pass to `query()` is validated against your real database
**during compilation**. If the table doesn't exist, a column is misspelled, or
the syntax is broken, you get a compile error — not a runtime crash.

```nim
import dokime

let db = openDatabase("myapp.db")
let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
echo row.id    # int64  — type comes from the schema, not a hand-written type
echo row.name  # string — column names become field names
```

## Why try this?

- **Compile-time SQL validation.** Mistakes that would normally surface at
  3am in production are caught before the binary even exists.
- **Schema-driven types.** Return types are inferred from the database
  schema — no manual type definitions, no drift between code and schema.
- **Named tuple fields.** `row.id` and `row.name` come directly from the
  SQL column names. No positional indexing.
- **Zero-abstracton FFI.** Runtime helpers call libsqlite3 directly.
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

## Beyond `query()` — raw helpers

When you need inserts, schema migrations, or multi-step transactions,
use the lower-level API:

```nim
import std / syncio
import dokime

let db = openDatabase("myapp.db")

execSql(db, """
  CREATE TABLE IF NOT EXISTS counters (
    name  TEXT    NOT NULL,
    value INTEGER NOT NULL DEFAULT 0
  ) STRICT
""")

var stmt = prepareStmt(db, "INSERT INTO counters VALUES (?, ?)")
bindParam(stmt, 1, "requests")
bindParam(stmt, 2, 42'i64)
discard stepStmt(stmt)
finalizeStmt(stmt)

echo lastInsertRowid(db)   # rowid of the insert
echo changes(db)           # number of rows changed
```

## API cheat sheet

| Proc / template                           | Purpose                              |
|-------------------------------------------|--------------------------------------|
| `query(db, sql, params...)`               | Compile-time validated SELECT        |
| `openDatabase(path)` → `DbConn`           | Open or create a SQLite database     |
| `closeDatabase(db)`                       | Close the connection                 |
| `execSql(db, sql)`                        | Execute a statement, discard result  |
| `prepareStmt(db, sql)` → `Stmt`           | Prepare a statement manually         |
| `bindParam(stmt, idx, val)`               | Bind `int64`, `string`, or `float64` |
| `stepStmt(stmt)`                          | Execute and step (returns status)    |
| `finalizeStmt(stmt)`                      | Finalize a prepared statement        |
| `columnInt64(stmt, idx)` → `int64`        | Read an INTEGER column               |
| `columnString(stmt, idx)` → `string`      | Read a TEXT column                   |
| `columnFloat64(stmt, idx)` → `float64`    | Read a REAL column                   |
| `lastInsertRowid(db)` → `int64`           | Rowid of last insert                 |
| `changes(db)` → `int64`                   | Rows changed by last statement       |

## Run the tests

```bash
# FFI bindings (no compile-time validation)
nimony c -r tests/tffi.nim

# Full integration (compile-time validation + runtime)
DOKIME_DATABASE_PATH=tests/tvalidate.db nimony c -r tests/tphase5.nim
```

## Limitations

- SQLite only.
- Single-row fetch (`fetch_one` semantics).
- No `Option[T]` for nullable columns yet.
- `DOKIME_DATABASE_PATH` must be set at compile time (no offline schema cache).
- STRICT tables required for reliable type inference.

## Project layout

| File                       | Lines | Purpose                                     |
|----------------------------|-------|---------------------------------------------|
| `src/dokime.nim`           | 176   | Public API, runtime helpers, `query` template |
| `src/dokime/sqlite3.nim`   | 164   | SQLite3 FFI bindings (dynlib)               |
| `src/dokimeplugin.nim`     | 183   | Compile-time plugin (SQL validation + codegen) |
| **Total**                  | **523** |                                           |
