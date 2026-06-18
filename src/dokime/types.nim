type
  SqlExecResult* = object
    ## Result for SQL statements that do not return columns.
    changes*: int64
    lastInsertRowid*: int64
