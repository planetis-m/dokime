## Negative test: using an int64 column as float64.
## Expected: type mismatch compile error.

import ".." / "src" / dokime

let db = openDatabase("tests/validate.db")
let row = query(db, "SELECT id, name FROM users WHERE id = ?", 1'i64)
let x: float64 = row.id
discard x
