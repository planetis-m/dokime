# dokime — SQL the Compiler Checks for You

Most SQLite wrappers treat SQL as opaque strings. Dokime prepares every query against
your real database at compile time. Typo in a table name? Your build breaks. Wrong
column? Build breaks. It's a Nimony plugin, not an ORM.

## One example, end to end

Here's a personal expense tracker. It creates a schema, inserts rows, queries with
optional filters, uses transactions, and handles nullable columns. Every mistake you
could make is shown alongside the code that catches it.

```nim
import dokime

let db = connect("money.db")

# Schema: note is nullable (TEXT, no NOT NULL). Everything else is required.
discard exec(db, """
  CREATE TABLE IF NOT EXISTS expenses (
    id       INTEGER NOT NULL,
    category TEXT    NOT NULL,
    amount   REAL    NOT NULL,
    note     TEXT,
    date     TEXT    NOT NULL
  ) STRICT
""")

# exec() returns ExecResult with .lastRowid and .changes:
let r = exec(db, "INSERT INTO expenses VALUES (?, ?, ?, ?, ?)",
    1'i64, "food", 23.50, "lunch", "2025-06-01")
echo r.lastRowid   # 1

# exec() accepts Opt[T] params — none binds SQL NULL, some binds the value:
discard exec(db, "INSERT INTO expenses VALUES (?, ?, ?, ?, ?)",
    2'i64, "food", 12.00, none[string](), "2025-06-02")
discard exec(db, "INSERT INTO expenses VALUES (?, ?, ?, ?, ?)",
    3'i64, "transport", 5.50, "bus", "2025-06-03")
discard exec(db, "INSERT INTO expenses VALUES (?, ?, ?, ?, ?)",
    4'i64, "food", 45.00, "dinner with friends", "2025-06-04")


# ── If you typo the table name, you get a compile error ──
# query(db, "SELECT id FROM expenes WHERE id = ?", 1'i64)
# → Error: dokime: no such table: expenes

# ── A misspelled column also fails at compile time ──
# query(db, "SELECT id, full_name FROM expenses WHERE id = ?", 1'i64)
# → Error: dokime: no such column: full_name


# query() returns a tuple with fields named after your columns:
let dinner = query(db,
    "SELECT id, amount, note FROM expenses WHERE id = ?", 4'i64)
echo dinner.id        # 4       (int64 — type comes from the schema)
echo dinner.amount    # 45.0    (float64)
echo dinner.note.isSome        # true    (TEXT nullable → Opt[string])
echo dinner.note.unsafeGet     # "dinner with friends"


# ── Type mismatches are caught at compile time too ──
# let x: string = dinner.amount
# → Error: type mismatch: got: float64 but wanted: string


# query() requires at least one row — raises BadOperation if empty.
# Use queryOpt() when zero rows is expected:
let missing = queryOpt(db,
    "SELECT id, category FROM expenses WHERE id = ?", 42'i64)
echo missing.isNone   # true


# ── query() with no matching row raises at runtime ──
# query(db, "SELECT id FROM expenses WHERE id = ?", 999'i64)
# → ErrorCode: BadOperation


# Dynamic optional clauses: wrap in [...], pass Opt[T].
# Every combination of included/omitted clauses is validated at compile time.
let catFilter = some("food")
let minAmount = some(20.0)
for row in rows(db, """
  SELECT id, category, amount FROM expenses
  WHERE 1 = 1
    [AND category = ?]
    [AND amount >= ?]
  ORDER BY amount DESC
""", catFilter, minAmount):
  echo row.id, " ", row.amount   # 4 45.0, 1 23.5


# Transactions: use tx handle for queries, commit to persist.
# Using db directly during a tx raises BadOperation.
var tx = begin(db)
discard exec(tx, "INSERT INTO expenses VALUES (?, ?, ?, ?, ?)",
    5'i64, "food", 8.00, "coffee", "2025-06-05")
discard exec(tx, "INSERT INTO expenses VALUES (?, ?, ?, ?, ?)",
    6'i64, "food", 15.00, none[string](), "2025-06-05")
commit(tx)
# If tx goes out of scope without commit/rollback → destructor auto-rollback.


# ── Using db handle during an active tx ──
# var tx = begin(db)
# exec(db, "INSERT ...")   → ErrorCode: BadOperation


close(db)
```

## Setup

```bash
export DOKIME_DATABASE_PATH=dev.db
nimony c -r myapp.nim
```

First build caches validated query metadata to `.dokime/queries/`. CI builds without a
database:

```bash
DOKIME_DATABASE_PATH= nimony c -r myapp.nim
```

---

**What it is:** compile-time validation for SQLite queries via Nimony plugins.
Schema-driven types, named tuple fields, optional clauses, transactions with destructor
safety.

**What it isn't:** an ORM, a migration tool, multi-database, or compatible with the
stable Nim compiler. SQLite only, STRICT tables required.
