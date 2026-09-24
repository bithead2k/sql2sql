#!/usr/bin/env bash
set -euo pipefail
cd -- "${BASH_SOURCE[0]%/*}/.."
count=0
check() {
    local input=$1 expected=$2 output
    shift 2
    output=$(./insert2select "$@" <<< "$input")
    [[ $output == *"$expected"* ]] || {
        printf 'FAIL: expected %s in\n%s\n' "$expected" "$output" >&2; exit 1;
    }
    ((count+=1))
}
reject() {
    local output
    if output=$(./insert2select "${@:2}" <<< "$1" 2>/dev/null); then
        printf 'FAIL: unexpectedly accepted %s\n' "$1" >&2; exit 1
    fi
    [[ -z $output ]] || { printf 'FAIL: partial stdout on failure\n' >&2; exit 1; }
    ((count+=1))
}
bash tests/lexer.bash
check "INSERT INTO people (id,name) VALUES (1,'Ada');" "name = 'Ada'"
check 'INSERT INTO t (a,b) VALUES (1,NULL),(2,3)' 'OR a = 2 AND b = 3'
check 'INSERT INTO "S"."Odd table" AS x ("A",b) VALUES (1,2) RETURNING x.*;' 'SELECT * FROM "S"."Odd table"'
check 'INSERT INTO t(a) OVERRIDING SYSTEM VALUE VALUES(1) ON CONFLICT(a) DO UPDATE SET a=excluded.a RETURNING *' 'a = 1'
check 'INSERT INTO t(a,b) VALUES(coalesce(NULL, 1), ARRAY[1,2]);' 'b = (ARRAY[1,2])'
check 'INSERT INTO t(a) VALUES($tag$a; b, c$tag$);' '= $tag$a; b, c$tag$'
check "INSERT INTO t(a) VALUES(E'it\\'s; fine');" "= E'it\\'s; fine'"
check '/* hi */ INSERT /* nested /* x */ */ INTO t(a) VALUES(1 /* comment */ + 2);' '(1 /* comment */ + 2)'
check 'WITH x AS (SELECT 1 AS a) INSERT INTO t(a) SELECT a FROM x RETURNING a;' 'WITH x AS (SELECT 1 AS a) SELECT'
check 'INSERT INTO t(a) SELECT 1 UNION ALL SELECT 2;' 'SELECT 1 UNION ALL SELECT 2'
check 'INSERT INTO t(a) (VALUES (1),(2));' '(VALUES (1),(2))'
check 'INSERT INTO t(a) VALUES (1),(2) LIMIT 1;' 'VALUES (1),(2) LIMIT 1'
check 'INSERT INTO t(a) TABLE other;' 'TABLE other'
check 'INSERT INTO t VALUES(1,2);' 'a = 1 AND b = 2' --columns a,b
check 'INSERT INTO t(a,b) VALUES(1,DEFAULT);' 'a = 1' --key a
check 'INSERT INTO t(a,b,c) VALUES(1,2,3);' 'a = 1 AND b = 2 OR c = 3' --key a,b --key c
check 'INSERT INTO t("A",b) VALUES(1,2);' '"A" = 1' --key '"A"'
check 'INSERT INTO t(A,b) VALUES(1,2);' 'A = 1' --key a
check 'INSERT INTO t(a,b) VALUES(1,2);' 'a = 1 OR b = 2' --match any
check 'INSERT INTO t(a,b) SELECT 1,2;' '"__insert2select_target".b = "__insert2select_source"."c1"' --key b
check 'INSERT INTO t(a) VALUES(1);INSERT INTO t(a) VALUES(2);' 'a = 2'
check 'INSERT INTO t VALUES(1);' '= ROW((ROW(1)::t).*)'
check "INSERT INTO t SELECT 1,'Ada';" '"__insert2select_source"::t'
check "INSERT INTO t (SELECT 1,'Ada');" "(SELECT 1,'Ada')"
check 'INSERT INTO t ((VALUES (1)));' '((VALUES (1)))'
check 'INSERT INTO db.public.t(a) VALUES(1);' 'FROM db.public.t'
check "INSERT INTO t(a,b) VALUES(NULL,'Ada');" "a = NULL AND b = 'Ada'"
check "INSERT INTO t(a,b) VALUES(NULL,'Ada');" "a IS NOT DISTINCT FROM NULL AND b IS NOT DISTINCT FROM 'Ada'" --handle-nulls
check 'INSERT INTO t(a) VALUES(NULLIF(1,1));' 'a IS NOT DISTINCT FROM (NULLIF(1,1))' -n
check 'INSERT INTO t(a) SELECT NULL::int;' '"__insert2select_target".a IS NOT DISTINCT FROM "__insert2select_source"."c0"' -n
check 'INSERT INTO t VALUES(NULL);' 'IS NOT DISTINCT FROM ROW((ROW(NULL)::t).*)' -n
check 'INSERT INTO t SELECT NULL::int;' 'IS NOT DISTINCT FROM ROW(("__insert2select_source"::t).*)' --handle-nulls
short=$(./insert2select -n <<< 'INSERT INTO t(a) VALUES(NULL);')
long=$(./insert2select --handle-nulls <<< 'INSERT INTO t(a) VALUES(NULL);')
[[ $short == "$long" ]]
[[ $short == $'SELECT * FROM t\nWHERE a IS NOT DISTINCT FROM NULL;' ]]
check 'INSERT INTO t(a,b) VALUES(FALSE OR TRUE,2);' 'a = (FALSE OR TRUE) AND b = 2'
check 'INSERT INTO t(a) VALUES((SELECT 1));' 'a = (SELECT 1);'
reject 'INSERT INTO t(a) DEFAULT VALUES;'
reject 'INSERT INTO t(a) VALUES(DEFAULT);'
reject 'INSERT INTO t(a) VALUES(1,2);'
reject 'INSERT INTO t(a) VALUES(1),;'
reject 'INSERT INTO t(a[1]) VALUES(1);'
reject 'INSERT INTO t(a) OVERRIDING USER VALUE VALUES(1);'
reject 'WITH x AS (DELETE FROM t RETURNING a) INSERT INTO t(a) SELECT a FROM x;'
reject 'INSERT INTO t(a) VALUES(1); DELETE FROM t;'
reject 'INSERT INTO t(a) VALUES(1); \! touch unsafe'
reject 'INSERT INTO t(a) VALUES(1);' --key missing
reject 'INSERT INTO t(a) VALUES(1);' --columns a,
# Explicit columns take precedence over --columns, so validate the option even
# when it is not used by a statement.
printf '%s conversion tests passed\n' "$count"
input="INSERT INTO people(id,name) VALUES(1,'Ada');"
from_stdin=$(./insert2select <<< "$input")
from_file=$(./insert2select <(printf '%s' "$input"))
[[ $from_stdin == "$from_file" ]]
if nul_output=$(printf 'INSERT INTO t(a) VALUES(1);\0' | ./insert2select 2>/dev/null); then
    printf 'FAIL: NUL input accepted\n' >&2; exit 1
fi
[[ -z $nul_output ]]
printf 'file/stdin and NUL-input tests passed\n'

if [[ ${1:-} == --integration ]]; then
    # Only temporary objects; all database work is rolled back.
    queries=''
    queries+=$(./insert2select <<'SQL'
INSERT INTO insert2select_people(id,name) VALUES(1,'Ada'),(2,NULL);
INSERT INTO insert2select_people(id,name) SELECT 1,'Ada';
WITH x(id,name) AS (VALUES (1,'Ada')) INSERT INTO insert2select_people(id,name) SELECT * FROM x;
INSERT INTO insert2select_people(id,name) VALUES(1,'Ada') ON CONFLICT(id) DO NOTHING RETURNING *;
INSERT INTO insert2select_people VALUES(1,'Ada');
INSERT INTO insert2select_people SELECT 1,'Ada';
SQL
)
    result=$(psql -X -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE insert2select_people(id integer PRIMARY KEY, name text);
INSERT INTO insert2select_people VALUES (1,'Ada'),(2,NULL),(3,'Other');
$queries
ROLLBACK;
SQL
)
    [[ $result == $'1|Ada\n1|Ada\n1|Ada\n1|Ada\n1|Ada\n1|Ada' ]] || {
        printf 'FAIL: database results:\n%s\n' "$result" >&2; exit 1;
    }
    query=$(./insert2select <<'SQL'
INSERT INTO insert2select_types(id, d, a, j) VALUES
('00000000-0000-0000-0000-000000000001', '2026-01-02', ARRAY[1,2], '{"a":1}');
SQL
)
    result=$(psql -X -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE insert2select_types(id uuid, d date, a int[], j jsonb);
INSERT INTO insert2select_types VALUES ('00000000-0000-0000-0000-000000000001','2026-01-02',ARRAY[1,2],'{"a":1}');
$query
ROLLBACK;
SQL
)
    [[ $result == '00000000-0000-0000-0000-000000000001|2026-01-02|{1,2}|{"a": 1}' ]]
    # Both modes must agree on non-NULL rows and differ on NULL comparisons,
    # including anonymous whole-row comparisons and query sources.
    for input in \
        'INSERT INTO insert2select_nulls(id,name) VALUES(NULLIF(1,1), '\''Ada'\'');' \
        'INSERT INTO insert2select_nulls(id,name) SELECT NULL::int, '\''Ada'\'';' \
        'INSERT INTO insert2select_nulls VALUES(NULL, '\''Ada'\'');' \
        'INSERT INTO insert2select_nulls SELECT NULL::int, '\''Ada'\'';'; do
        ordinary=$(./insert2select <<< "$input")
        null_safe=$(./insert2select -n <<< "$input")
        result=$(psql -X -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE insert2select_nulls(id integer, name text);
INSERT INTO insert2select_nulls VALUES(NULL,'Ada'),(1,'Ada'),(NULL,'Other');
SELECT 'equality';
$ordinary
SELECT 'null-safe';
$null_safe
ROLLBACK;
SQL
)
        [[ $result == $'equality\nnull-safe\n|Ada' ]] || {
            printf 'FAIL: NULL mode results:\n%s\n' "$result" >&2; exit 1;
        }
    done
    query=$(./insert2select <<< 'INSERT INTO insert2select_precedence(a,b) VALUES(FALSE OR TRUE,2),(FALSE,3);')
    result=$(psql -X -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE insert2select_precedence(a boolean, b integer);
INSERT INTO insert2select_precedence VALUES(false,2),(true,2),(true,3),(false,3);
$query
ROLLBACK;
SQL
)
    [[ $result == $'t|2\nf|3' ]] || { printf 'FAIL: predicate precedence\n' >&2; exit 1; }
    printf 'PostgreSQL integration tests passed\n'
fi
