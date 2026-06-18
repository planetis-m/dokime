# nsql

Compile-time validated SQL for Nimony. SQLite only (for now).

## What It Does

Every SQL string passed to `query()` is validated against your database during compilation.
If the SQL is invalid, the binary is not produced.

```nim
import nsql

let db = openDatabase("myapp.db")

# This SQL is validated at compile time:
let row = query(db, "SELECT id, name FROM users WHERE id = ?", 42'i64)
echo row.id    # int64 — type inferred from schema
echo row.name  # string — type inferred from schema
```

## How It Works

1. **Compile time** (Nimony plugin): connects to `NSQL_DATABASE_PATH`, runs `sqlite3_prepare_v2`
   to validate SQL syntax, table/column names, and type compatibility. Extracts column metadata.
2. **Code generation**: generates a `(block ...)` expression that calls runtime helpers to
   prepare, bind, execute, and decode the query into a typed tuple.
3. **Runtime**: executes via libsqlite3 FFI. Returns a typed tuple with field names matching
   the SQL column names.

## Setup

1. Create a development database with your schema:
   ```bash
   sqlite3 dev.db "CREATE TABLE users (id INTEGER NOT NULL, name TEXT NOT NULL) STRICT;"
   ```

2. Set `NSQL_DATABASE_PATH` during compilation:
   ```bash
   export NSQL_DATABASE_PATH=dev.db
   nimony c -r myapp.nim
   ```

   When running directly from this source checkout, import the library with a
   source-relative import (the tests do this) and avoid `--path:src`, because
   Nimony currently gives plugin-bound symbols a different module suffix when
   the app and the plugin resolve `src/nsql.nim` through different path rules.

## Requirements

- Nimony (new Nim by Araq, experimental)
- SQLite 3.37+ (for STRICT tables)
- libsqlite3 (system-installed)

## Project Layout

| File | Lines | Purpose |
|---|---|---|
| `src/nsql.nim` | 138 | Public API, runtime helpers, and `query` template |
| `src/nsql/sqlite3.nim` | 139 | SQLite3 FFI bindings via dynlib |
| `src/nsqlplug.nim` | 192 | Compile-time plugin (validates SQL, generates NIF code) |
| **Total** | **469** | |

## Compile-Time Guarantees

| Mistake | Result |
|---|---|
| Table doesn't exist | Compile error: `no such table` |
| Column doesn't exist | Compile error: `no such column` |
| SQL syntax error | Compile error (SQLite's own parser message) |
| Wrong result type | Compile error: `type mismatch` |

## Limitations (v1)

- SQLite only (PostgreSQL is a future goal)
- Single-row fetch only (`fetch_one` semantics)
- No nullable column handling (`Option[T]` not yet generated)
- Requires `NSQL_DATABASE_PATH` set at compile time (no offline cache yet)
- STRICT tables required (for reliable type checking)
