## Offline cache I/O for dokime query plugins: binary encode/decode and file read/write.

import std/[dirs, hashes, os, syncio]

const
  CacheMagic* = "DKC1"
  CacheVersion* = 1'u32
  DefaultCacheRoot* = ".dokime"

type
  ColumnKind* = enum ckInteger, ckText, ckReal, ckBlob, ckNull

  ColumnMeta* = object
    name*: string
    kind*: ColumnKind
    nullable*: bool

  DecodeState = object
    data: string
    pos: int
    error: string

  CacheEntry* = object
    columns*: seq[ColumnMeta]
    params*: int
    error*: string

proc cacheQueriesDir(): string =
  result = DefaultCacheRoot / "queries"

proc cacheFileName(sql: string): string =
  result = $hash(sql) & ".dkc"

proc cacheFilePath(sql: string): string =
  result = cacheQueriesDir() / cacheFileName(sql)

proc addU8(data: var string; value: uint8) =
  data.add char(int(value))

proc addU32(data: var string; value: uint32) =
  data.add char(int(value and 0xff'u32))
  data.add char(int((value shr 8) and 0xff'u32))
  data.add char(int((value shr 16) and 0xff'u32))
  data.add char(int((value shr 24) and 0xff'u32))

proc addString(data: var string; value: string) =
  data.addU32 uint32(value.len)
  data.add value

proc needBytes(state: var DecodeState; count: int): bool =
  if state.error.len > 0:
    result = false
  elif state.pos + count > state.data.len:
    state.error = "cache file is truncated"
    result = false
  else:
    result = true

proc readU8(state: var DecodeState): uint8 =
  if not state.needBytes(1):
    return 0'u8
  result = uint8(ord(state.data[state.pos]))
  inc state.pos

proc readU32(state: var DecodeState): uint32 =
  if not state.needBytes(4):
    return 0'u32
  result =
    uint32(ord(state.data[state.pos])) or
    (uint32(ord(state.data[state.pos + 1])) shl 8) or
    (uint32(ord(state.data[state.pos + 2])) shl 16) or
    (uint32(ord(state.data[state.pos + 3])) shl 24)
  inc state.pos, 4

proc readString(state: var DecodeState): string =
  let n = int(state.readU32())
  if not state.needBytes(n):
    return
  result = substr(state.data, state.pos, state.pos + n - 1)
  inc state.pos, n

proc encodeCache*(sql: string; columns: seq[ColumnMeta]; params: int): string =
  result = CacheMagic
  result.addU32 CacheVersion
  result.addString sql
  result.addU32 uint32(params)
  result.addU32 uint32(columns.len)
  for col in columns:
    result.addString col.name
    result.addU8 uint8(ord(col.kind))
    result.addU8 if col.nullable: 1'u8 else: 0'u8

proc decodeCache*(data: string; expectedSql: string): CacheEntry =
  var state = DecodeState(data: data, pos: 0, error: "")
  if not state.needBytes(CacheMagic.len):
    return CacheEntry(error: state.error)
  for ch in CacheMagic:
    if state.data[state.pos] != ch:
      return CacheEntry(error: "cache file has invalid magic")
    inc state.pos

  let version = state.readU32()
  if state.error.len > 0:
    return CacheEntry(error: state.error)
  if version != CacheVersion:
    return CacheEntry(error: "unsupported cache version " & $version &
        " (expected " & $CacheVersion & ")")

  let cachedSql = state.readString()
  if cachedSql != expectedSql:
    return CacheEntry(error: "cache SQL does not match query text")

  let params = int(state.readU32())
  let columnCount = int(state.readU32())
  var columns: seq[ColumnMeta] = @[]

  for _ in 0..<columnCount:
    let name = state.readString()
    let kindValue = int(state.readU8())
    let nullable = state.readU8() != 0'u8
    if kindValue < ord(low(ColumnKind)) or kindValue > ord(high(ColumnKind)):
      return CacheEntry(error: "cache has invalid column kind")
    columns.add ColumnMeta(
      name: name,
      kind: cast[ColumnKind](kindValue),
      nullable: nullable
    )

  if state.error.len > 0:
    result = CacheEntry(error: state.error)
  elif state.pos != state.data.len:
    result = CacheEntry(error: "cache file has trailing bytes")
  else:
    result = CacheEntry(columns: columns, params: params)

proc writeCache*(sql: string; columns: seq[ColumnMeta]; params: int) =
  try:
    let dir = cacheQueriesDir()
    dirs.createDir(dirs.path(dir))
    writeFile(cacheFilePath(sql), encodeCache(sql, columns, params))
  except:
    discard

proc readCache*(sql: string): CacheEntry =
  let path = cacheFilePath(sql)
  if not fileExists(path):
    result = CacheEntry(
      error: "offline cache entry not found for this SQL; build once with DOKIME_DATABASE_PATH set")
  else:
    try:
      result = decodeCache(readFile(path), sql)
    except:
      result = CacheEntry(error: "cannot read offline cache entry")
