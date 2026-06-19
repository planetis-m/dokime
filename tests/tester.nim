## Central test runner for dokime.
##
## Creates the validation database, compiles and runs each positive test with
## nimony, and verifies that negative tests fail to compile.
##
## Run from the project root:
##   nim c -r tests/tester.nim

import std/[assertions, os]

const ValidateDb = "tests/validate.db"

const Positive = [
  "tffi.nim",
  "tquickstart.nim",
  "tphase5.nim",
  "texecute.nim",
  "tquerycardinality.nim",
  "tnullable.nim",
  "trows.nim"
]

const Negative = [
  "tbadquery.nim",
  "tbadtable.nim",
  "ttypemismatch.nim"
]

proc ensureValidateDb() =
  if fileExists(ValidateDb):
    return
  let schema = [
    "CREATE TABLE users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT",
    "CREATE TABLE profiles (id INTEGER NOT NULL, name TEXT NOT NULL, nickname TEXT, score REAL) STRICT"
  ]
  for stmt in schema:
    let rc = execShellCmd("sqlite3 " & ValidateDb & " '" & stmt & "'")
    assert rc == 0, "could not create validation database: " & stmt

proc runPositive(name: string) =
  echo "  [positive] " & name
  let cmd = "DOKIME_DATABASE_PATH=" & ValidateDb & " nimony c -r tests/" & name
  assert execShellCmd(cmd) == 0, name & " should have compiled and run"

proc runNegative(name: string) =
  echo "  [negative] " & name
  let cmd = "DOKIME_DATABASE_PATH=" & ValidateDb & " nimony c tests/" & name
  assert execShellCmd(cmd) != 0, name & " should have failed to compile"

proc main() =
  echo "Setting up validation database..."
  ensureValidateDb()

  echo "Running positive tests..."
  for name in Positive:
    runPositive(name)

  echo "Running negative tests..."
  for name in Negative:
    runNegative(name)

  echo "\nAll " & $(Positive.len + Negative.len) & " tests passed."

main()
