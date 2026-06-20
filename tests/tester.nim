## Central test runner for dokime.
##
## Creates the validation database, compiles and runs each positive test with
## nimony, and verifies that negative tests fail to compile.
##
## Run from the project root:
##   nim c -r tests/tester.nim

import std/[assertions, os]

const ValidateDb = "tests/validate.db"
const ValidateCache = ".dokime"
const NimonyCache = "tests/.nimony-cache"

const Positive = [
  "tffi.nim",
  "tquickstart.nim",
  "tphase5.nim",
  "texecute.nim",
  "ttransactions.nim",
  "tdynamicclauses.nim",
  "tquerycardinality.nim",
  "tnullable.nim",
  "tnullableparams.nim",
  "trows.nim"
]

const Negative = [
  "tbadquery.nim",
  "tbadtable.nim",
  "ttransactioncopy.nim",
  "ttypemismatch.nim"
]

const OfflineOnly = [
  "tofflinecache.nim"
]

proc ensureValidateDb() =
  if fileExists(ValidateDb):
    return
  let schema = [
    "CREATE TABLE users (id INTEGER NOT NULL, name TEXT NOT NULL, age INTEGER NOT NULL) STRICT",
    "CREATE TABLE profiles (id INTEGER NOT NULL, name TEXT NOT NULL, nickname TEXT, score REAL) STRICT",
    "CREATE TABLE notes (id INTEGER NOT NULL, title TEXT NOT NULL, body TEXT, tag TEXT) STRICT"
  ]
  for stmt in schema:
    let rc = execShellCmd("sqlite3 " & ValidateDb & " '" & stmt & "'")
    assert rc == 0, "could not create validation database: " & stmt

proc runPositive(name: string) =
  echo "  [positive] " & name
  let cmd = "DOKIME_DATABASE_PATH=" & ValidateDb & " nimony --nimcache:" & NimonyCache &
    " --ff c -r tests/" & name
  assert execShellCmd(cmd) == 0, name & " should have compiled and run"

proc runPositiveOffline(name: string) =
  echo "  [offline] " & name
  let cmd = "DOKIME_DATABASE_PATH= nimony --nimcache:" & NimonyCache &
    " --ff c -r tests/" & name
  assert execShellCmd(cmd) == 0, name & " should have compiled and run offline"

proc runNegative(name: string) =
  echo "  [negative] " & name
  let cmd = "DOKIME_DATABASE_PATH=" & ValidateDb & " nimony --nimcache:" & NimonyCache &
    " --ff c tests/" & name
  assert execShellCmd(cmd) != 0, name & " should have failed to compile"

proc removeGeneratedDirs() =
  if dirExists(ValidateCache):
    removeDir(ValidateCache)
  if dirExists(NimonyCache):
    removeDir(NimonyCache)

proc main() =
  echo "Setting up validation database..."
  ensureValidateDb()
  removeGeneratedDirs()

  echo "Running positive tests..."
  for name in Positive:
    runPositive(name)

  echo "Running offline positive tests..."
  for name in Positive:
    runPositiveOffline(name)
  for name in OfflineOnly:
    runPositiveOffline(name)

  echo "Running negative tests..."
  for name in Negative:
    runNegative(name)

  removeGeneratedDirs()
  echo "\nAll " & $(Positive.len * 2 + OfflineOnly.len + Negative.len) & " tests passed."

main()
