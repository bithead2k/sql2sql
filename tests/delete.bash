#!/usr/bin/env bash
set -euo pipefail
cd -- "${BASH_SOURCE[0]%/*}/.."
count=0
check() {
    local input=$1 expected=$2 output
    shift 2
    output=$(./delete2select "$@" <<< "$input")
    [[ $output == "$expected" ]] || {
        printf 'FAIL\nExpected: %s\nActual:   %s\n' "$expected" "$output" >&2; exit 1;
    }
    ((count+=1))
}
check_quals() {
    local input=$1 expected=$2
    shift 2
    check "$input" "$expected" --select-quals "$@"
}
reject() {
    local output
    if output=$(./delete2select "${@:2}" <<< "$1" 2>/dev/null); then
        printf 'FAIL: accepted %s\n' "$1" >&2; exit 1
    fi
    [[ -z $output ]]
    ((count+=1))
}
check 'DELETE FROM people WHERE id = 1;' 'SELECT * FROM people WHERE id = 1;'
check 'DELETE FROM people p USING source s WHERE p.id=s.id;' 'SELECT p.* FROM people AS p, source s WHERE p.id=s.id;'
check 'DELETE FROM people WHERE id=NULL;' 'SELECT * FROM people WHERE id IS NOT DISTINCT FROM NULL;' -n
check 'DELETE FROM people WHERE id=1;' 'SELECT name FROM people WHERE id=1;' --columns name
check 'DELETE FROM people WHERE id=1 AND age=37;' 'SELECT * FROM people WHERE age = 37;' --key age
check_quals 'DELETE FROM people WHERE id = 1;' 'SELECT id FROM people WHERE id = 1;'
check_quals "DELETE FROM people WHERE id=1 AND name='Ada';" "SELECT id, name FROM people WHERE id=1 AND name='Ada';"
check_quals 'DELETE FROM people;' 'SELECT * FROM people;'
check_quals 'DELETE FROM people p;' 'SELECT p.* FROM people AS p;'
check_quals 'DELETE FROM people;' 'SELECT name, id FROM people;' --columns name,id
check_quals 'DELETE FROM people WHERE id=1;' 'SELECT name, id FROM people WHERE id=1;' --columns name,id
check_quals 'DELETE FROM ONLY s.people AS p WHERE p.id=1 RETURNING *;' 'SELECT p.id FROM ONLY s.people AS p WHERE p.id=1;'
check_quals 'DELETE FROM people * WHERE id=1;' 'SELECT id FROM people * WHERE id=1;'
check_quals 'DELETE FROM people WHERE id=NULL;' 'SELECT id FROM people WHERE id IS NOT DISTINCT FROM NULL;' -n
check_quals 'DELETE FROM people WHERE id=NULL;' 'SELECT id FROM people WHERE id IS NOT DISTINCT FROM NULL;' --handle-nulls
check_quals 'DELETE FROM people WHERE (id=1 OR name=$$Ada$$) AND age>=37;' 'SELECT id, name, age FROM people WHERE (id=1 OR name=$$Ada$$) AND age>=37;'
check_quals 'DELETE FROM people WHERE id BETWEEN 1 AND 3;' 'SELECT id FROM people WHERE id BETWEEN 1 AND 3;'
check_quals 'DELETE FROM people WHERE id IN (1,2);' 'SELECT id FROM people WHERE id IN (1,2);'
check_quals 'DELETE FROM people WHERE id=1 AND age=37;' 'SELECT id, age FROM people WHERE age = 37;' --key age
check_quals 'DELETE FROM people WHERE id=1 AND age=37;' 'SELECT id, age FROM people WHERE id = 1 OR age = 37;' --match any
check_quals 'DELETE FROM people p USING source s WHERE p.id=s.id;' 'SELECT p.id FROM people AS p, source s WHERE p.id=s.id;'
check_quals 'DELETE FROM people USING source;' 'SELECT people.* FROM people, source;'
check_quals 'WITH s AS (SELECT 1 AS id) DELETE FROM people USING s WHERE people.id=s.id;' 'WITH s AS (SELECT 1 AS id) SELECT people.id FROM people, s WHERE people.id=s.id;'
check_quals 'DELETE /* outer /* nested */ */ FROM "People" WHERE "ID"=1;' 'SELECT "ID" FROM "People" WHERE "ID"=1;'
check_quals 'DELETE FROM people WHERE name=$tag$a;b$tag$;' 'SELECT name FROM people WHERE name=$tag$a;b$tag$;'
check_quals 'DELETE FROM a WHERE id=1; DELETE FROM b WHERE id=2;' $'SELECT id FROM a WHERE id=1;\nSELECT id FROM b WHERE id=2;'
check_quals '-- comment only' ''
reject 'DELETE people WHERE id=1;'
reject 'DELETE FROM people WHERE CURRENT OF c;'
reject 'DELETE FROM people WHERE lower(name)=$$ada$$;'
check_quals 'DELETE FROM people WHERE id=1 OR id=2;' 'SELECT id FROM people WHERE id=1 OR id=2;'
reject 'DELETE FROM people WHERE id=;'
reject 'DELETE FROM people WHERE;'
reject 'DELETE FROM people USING;'
reject 'DELETE FROM people SET id=1;'
reject 'WITH s AS (DELETE FROM people RETURNING *) DELETE FROM people;'
reject 'DELETE FROM people; UPDATE people SET id=1;'
reject 'DELETE FROM people; \! echo unsafe'
reject 'DELETE FROM people;' --key id
reject 'DELETE FROM people WHERE age>37;' --match any
reject 'DELETE FROM people;' --columns 'name,'
input='DELETE FROM people WHERE id=1;'
[[ $(./delete2select <<< "$input") == "$(./delete2select <(printf '%s' "$input"))" ]]
if output=$(printf 'DELETE FROM people;\0' | ./delete2select 2>/dev/null); then exit 1; fi
[[ -z $output ]]
printf '%s delete conversion tests passed\n' "$count"

if [[ ${1:-} == --integration ]]; then
    query=$(./delete2select <<< 'DELETE FROM d2s_people WHERE id=1;')
    using_query=$(./delete2select <<< 'DELETE FROM d2s_people p USING d2s_source s WHERE p.id=s.id;')
    null_query=$(./delete2select -n <<< 'DELETE FROM d2s_people WHERE id=NULL;')
    quals_query=$(./delete2select --select-quals <<< 'DELETE FROM d2s_people WHERE id=1;')
    all_query=$(./delete2select <<< 'DELETE FROM d2s_people;')
    result=$(psql -X -qAt -v ON_ERROR_STOP=1 <<SQL
BEGIN;
CREATE TEMP TABLE d2s_people(id int, name text);
CREATE TEMP TABLE d2s_source(id int);
INSERT INTO d2s_people VALUES(1,'Ada'),(2,'Grace'),(NULL,'Unknown');
INSERT INTO d2s_source VALUES(2);
$query
$using_query
$null_query
$all_query
$quals_query
SELECT count(*) FROM d2s_people;
ROLLBACK;
SQL
)
    [[ $result == $'1|Ada\n2|Grace\n|Unknown\n1|Ada\n2|Grace\n|Unknown\n1\n3' ]] || {
        printf 'FAIL: delete SQL results\n%s\n' "$result" >&2; exit 1;
    }
    printf 'DELETE PostgreSQL integration tests passed\n'
fi
