#!/usr/bin/env bash
set -euo pipefail
cd -- "${BASH_SOURCE[0]%/*}/.."
count=0
check() {
    local input=$1 expected=$2 output
    shift 2
    output=$(./update2select "$@" <<< "$input")
    [[ $output == "$expected" ]] || {
        printf 'FAIL\nExpected: %s\nActual:   %s\n' "$expected" "$output" >&2; exit 1;
    }
    ((count+=1))
}
reject() {
    local output
    if output=$(./update2select "${@:2}" <<< "$1" 2>/dev/null); then
        printf 'FAIL: accepted %s\n' "$1" >&2; exit 1
    fi
    [[ -z $output ]]
    ((count+=1))
}
check "UPDATE people SET name = 'Ada', age = 37 WHERE id = 1;" \
    "SELECT id, name, age, 1 AS new_id, 'Ada' AS new_name, 37 AS new_age FROM people WHERE id = 1;"
check 'UPDATE t SET id=2 WHERE id=1;' 'SELECT id, 2 AS new_id FROM t WHERE id=1;'
check 'UPDATE t SET a=1,b=2;' 'SELECT a, b, 1 AS new_a, 2 AS new_b FROM t;'
check 'UPDATE ONLY s.t AS x SET a=2 WHERE x.id=1 RETURNING *;' \
    'SELECT x.id, x.a, 1 AS new_id, 2 AS new_a FROM ONLY s.t AS x WHERE x.id=1;'
check 'UPDATE t x SET a=2 WHERE x.id=1;' 'SELECT x.id, x.a, 1 AS new_id, 2 AS new_a FROM t AS x WHERE x.id=1;'
check 'UPDATE t SET (a,b)=ROW(1,2) WHERE id=3;' 'SELECT id, a, b, 3 AS new_id, 1 AS new_a, 2 AS new_b FROM t WHERE id=3;'
check 'UPDATE t SET (a,b)=(1,2) WHERE id=3;' 'SELECT id, a, b, 3 AS new_id, 1 AS new_a, 2 AS new_b FROM t WHERE id=3;'
check 'UPDATE t SET a=FALSE OR TRUE WHERE (id=1 OR other=2) AND n>=3;' \
    'SELECT id, other, n, a, 1 AS new_id, 2 AS new_other, FALSE OR TRUE AS new_a FROM t WHERE (id=1 OR other=2) AND n>=3;'
check 'UPDATE t SET a=1=1 WHERE id=NULL AND n>=3;' \
    'SELECT id, n, a, NULL AS new_id, 1=1 AS new_a FROM t WHERE id IS NOT DISTINCT FROM NULL AND n>=3;' -n
check 'UPDATE t SET a=NULL WHERE id=NULL;' \
    'SELECT id, a, NULL AS new_id, NULL AS new_a FROM t WHERE id IS NOT DISTINCT FROM NULL;' --handle-nulls
check 'UPDATE t SET a=1 WHERE id BETWEEN 1 AND 3 AND n=2;' \
    'SELECT id, n, a, 2 AS new_n, 1 AS new_a FROM t WHERE id BETWEEN 1 AND 3 AND n=2;'
check 'UPDATE t SET a=1 WHERE id=2 AND n=3;' \
    'SELECT id, n, a, 2 AS new_id, 3 AS new_n, 1 AS new_a FROM t WHERE id = 2 OR n = 3;' --match any
check 'UPDATE t SET a=1 WHERE id=2 AND n=3;' \
    'SELECT id, n, a, 2 AS new_id, 3 AS new_n, 1 AS new_a FROM t WHERE n = 3;' --key n
check 'UPDATE t SET a=1 WHERE id=2;' \
    'SELECT a, id, 1 AS new_a, 2 AS new_id FROM t WHERE id=2;' --columns a,id
check 'UPDATE t SET "Full Name"=$v$a; b$v$ WHERE "ID"=1;' \
    'SELECT "ID", "Full Name", 1 AS "new_ID", $v$a; b$v$ AS "new_Full Name" FROM t WHERE "ID"=1;'
check 'WITH s AS (SELECT 2 AS a) UPDATE t SET a=(SELECT a FROM s) WHERE id=1;' \
    'WITH s AS (SELECT 2 AS a) SELECT id, a, 1 AS new_id, (SELECT a FROM s) AS new_a FROM t WHERE id=1;'
check 'UPDATE t AS x SET a=s.a FROM source AS s WHERE x.id=s.id;' \
    'SELECT x.id, x.a, s.id AS new_id, s.a AS new_a FROM t AS x, source AS s WHERE x.id=s.id;'
reject 'UPDATE t SET a=DEFAULT WHERE id=1;'
reject 'UPDATE t SET a=1 WHERE id=1 OR id=2;'
reject 'UPDATE t SET a=1 WHERE lower(name)=$$ada$$;'
reject 'UPDATE t SET (a,b)=(SELECT a,b FROM s);'
reject 'UPDATE t SET a=1 WHERE CURRENT OF c;'
reject 'UPDATE t SET a=1; DELETE FROM t;'
reject 'UPDATE t SET a=1 WHERE id>1;' --match any
reject 'UPDATE t SET a=1 WHERE id=1;' --key absent
reject 'UPDATE t SET a=1,;'
reject 'UPDATE t SET a=1 WHERE id=;'
reject 'UPDATE t SET a[1]=1;'
reject 'WITH x AS (DELETE FROM t RETURNING *) UPDATE t SET a=1;'
input='UPDATE t SET a=1 WHERE id=2;'
[[ $(./update2select <<< "$input") == "$(./update2select <(printf '%s' "$input"))" ]]
[[ $(./update2select -n <<< "$input") == "$(./update2select --handle-nulls <<< "$input")" ]]
printf '%s update conversion tests passed\n' "$count"

if [[ ${1:-} == --integration ]]; then
    query=$(./update2select <<< "UPDATE u2s_people SET name = 'Ada', age = 37 WHERE id = 1;")
    from_query=$(./update2select <<< 'UPDATE u2s_people AS p SET age=s.age FROM u2s_source AS s WHERE p.id=s.id;')
    null_query=$(./update2select -n <<< "UPDATE u2s_people SET name='Null' WHERE id=NULL;")
    result=$(psql -X -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE u2s_people(id int, name text, age int);
CREATE TEMP TABLE u2s_source(id int, age int);
INSERT INTO u2s_people VALUES(1,'Grace',30),(2,'Other',20),(NULL,'Nobody',40);
INSERT INTO u2s_source VALUES(1,37);
$query
$from_query
$null_query
SELECT name,age FROM u2s_people WHERE id=1;
ROLLBACK;
SQL
)
    [[ $result == $'1|Grace|30|1|Ada|37\n1|30|1|37\n|Nobody||Null\nGrace|30' ]] || {
        printf 'FAIL: update SQL results\n%s\n' "$result" >&2; exit 1;
    }
    printf 'UPDATE PostgreSQL integration tests passed\n'
fi
