#!/usr/bin/env bash
set -euo pipefail
cd -- "${BASH_SOURCE[0]%/*}/.."
source lib/sql-lex.bash
sql_split "INSERT INTO t VALUES ('a;b'); INSERT INTO t VALUES (2)"
[[ ${#SQL_STATEMENTS[@]} == 2 ]]
sql_split $'/* outer ; /* inner ; */ */ INSERT INTO "t;" VALUES ($tag$a;b$tag$); -- tail;\n'
[[ ${#SQL_STATEMENTS[@]} == 1 ]]
sql_split "INSERT INTO t VALUES ('it''s;fine');"
[[ ${#SQL_STATEMENTS[@]} == 1 ]]
sql_split "INSERT INTO t VALUES (E'it\\'s;fine'); INSERT INTO t VALUES (3);"
[[ ${#SQL_STATEMENTS[@]} == 2 ]]
sql_split $'-- comment only;\n /* comment */ ;'
[[ ${#SQL_STATEMENTS[@]} == 0 ]]
if sql_split "INSERT INTO t VALUES ('bad)" 2>/dev/null; then exit 1; fi
if sql_split 'INSERT INTO t VALUES (1); \! echo bad' 2>/dev/null; then exit 1; fi
printf 'lexer tests passed\n'
