-- Schema for dokime compile-time validation examples.
-- Set DOKIME_DATABASE_PATH to this database, then run the examples.

CREATE TABLE IF NOT EXISTS users (
  id   INTEGER NOT NULL,
  name TEXT    NOT NULL,
  age  INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS accounts (
  id      INTEGER NOT NULL,
  name    TEXT    NOT NULL,
  balance INTEGER NOT NULL,
  note    TEXT
) STRICT;
