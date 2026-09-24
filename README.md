# sql2sql

Version **.01** (Git tag `v0.01`). See [CHANGELOG.md](CHANGELOG.md).

Offline, pure Bash SQL conversion utilities: `insert2select` finds matching
INSERT data; `update2select` previews current columns alongside UPDATE values;
`delete2select` previews DELETE matches.

## insert2select

A pure Bash command-line tool that turns PostgreSQL INSERT statements into
SELECT statements for finding matching, potentially conflicting data. Conversion
is offline: no database connection, existing rows, SQL execution, Python, or other
runtime programs are needed. Requires Bash 4.3 or later.

```bash
./insert2select inserts.sql > checks.sql
./insert2select < inserts.sql
printf "%s\n" "INSERT INTO people(id,name) VALUES(1,'Ada');" | ./insert2select
```

The last example produces:

```sql
SELECT * FROM people
WHERE id = 1 AND name = 'Ada';
```

Run the output against the database you want to inspect. Comparisons use `=` by
default, including literal NULLs; `column = NULL` does not match rows. Use
`--handle-nulls` (or `-n`) to generate `IS NOT DISTINCT FROM` for all comparisons,
so NULL matches NULL, including NULLs produced by expressions or SELECT sources:

```bash
echo "INSERT INTO people(id,name) VALUES(NULL,'Ada');" | ./insert2select -n
```

```sql
SELECT * FROM people
WHERE id IS NOT DISTINCT FROM NULL AND name IS NOT DISTINCT FROM 'Ada';
```

All supplied columns
are matched with AND by default; rows from a multi-row INSERT are alternatives
joined with OR. Each input statement produces one SELECT. Duplicate input rows
do not multiply matching database rows. Omitted columns are not matched.

## Conflict keys

An all-column match finds matching data. It can miss a uniqueness conflict if a
key matches but another supplied value differs. To inspect a particular key:

```bash
./insert2select --key id inserts.sql
./insert2select --key tenant_id,email inserts.sql
./insert2select --key id --key tenant_id,email inserts.sql
```

Columns within a key are ANDed; repeated keys are ORed. Alternatively,
`--match any` matches any supplied column. The default is `--match all`.
Key options apply to every INSERT in the input and must be present in each
statement's column list. Keys are explicit; the program does not infer database
constraints or use `ON CONFLICT` targets to change the chosen matching columns.

INSERTs without column names use PostgreSQL's table row type to match the full
row when the query is run, so no local schema is needed. If the INSERT omits
trailing columns, or you want `--key`/`--match any`, provide the relevant column
order explicitly:

```bash
echo "INSERT INTO people VALUES(1,'Ada');" | ./insert2select --columns id,name
```

Quote SQL identifiers as needed, including in options:
`--key '"Tenant ID",email'`. `--columns` is used only when the INSERT has no
explicit column list. `-` reads stdin; `--` ends option parsing.

## SQL handling

The converter handles multiple statements, multi-row VALUES, expressions,
subqueries, read-only WITH clauses, INSERT ... SELECT / TABLE, parenthesized
query sources, VALUES with ordering/limits, qualified and quoted table names,
target aliases, and OVERRIDING SYSTEM VALUE. It recognizes nested block comments,
line comments, escaped strings, quoted identifiers, and dollar-quoted strings;
semicolons and commas inside those constructs do not split statements or rows.
Input must use `standard_conforming_strings=on` (PostgreSQL's default); use
`E'...'` for backslash escapes.

`ON CONFLICT` and `RETURNING` are omitted: the output searches for the input
values, not the result of running an INSERT or its conflict action. SELECT
sources are preserved in an EXISTS subquery and matched by column position.
The source tables/functions must exist when the generated query is run.
Expressions are evaluated then, so volatile expressions such as `random()` or
`nextval()` cannot reproduce a past or future INSERT's particular result.

## Limits of offline conversion

**This is not a converter for every legal PostgreSQL INSERT.** That guarantee
cannot be made from INSERT text alone with no target schema. In particular:

* Without a column list, row-type matching requires values for every table
  column. For omitted trailing columns, use `--columns` to name the supplied
  positions; their names cannot be inferred offline.
* `DEFAULT VALUES`, and `DEFAULT` in a matching column, require table metadata
  and are rejected. DEFAULT in an unselected VALUES column is allowed with
  `--key`.
* Composite-field/array-element target assignments, OVERRIDING USER VALUE, and
  data-modifying WITH prefixes are rejected.
* Predicates use PostgreSQL equality rather than INSERT assignment coercion.
  Columns need a suitable equality operator (for example, `json` has none).
  SELECT sources may need explicit casts where an INSERT's target context would
  otherwise resolve an unknown literal or assignment cast. Type definitions,
  collations, generated columns, defaults, triggers, expression/partial unique
  indexes, exclusion constraints, and row security cannot be inferred offline.
* With `--handle-nulls`, NULL matches NULL to surface potential matches,
  including NULLS NOT DISTINCT keys; this does not imply a conflict on a normal
  NULLS DISTINCT unique key.

The program is a lexical/structural converter, not a complete PostgreSQL syntax
validator. PostgreSQL validates generated queries when they are run. Treat
input SQL as trusted: preserved expressions can call functions with side effects.
Conversion itself never runs SQL. psql backslash commands and NUL bytes are
rejected. On any conversion failure, stdout is empty and the exit status is
nonzero. Comments-only input produces no output.

## Tests

```bash
bash tests/test.bash
bash tests/test.bash --integration  # psql; honors normal PG* connection settings
```

Integration tests use temporary tables inside rolled-back transactions.

## update2select

```bash
./update2select updates.sql > previews.sql
./update2select -n < updates.sql
echo "UPDATE people SET name = 'Ada', age = 37 WHERE id = 1;" | ./update2select
```

The example produces:

```sql
SELECT id, name, age, 1 AS new_id, 'Ada' AS new_name, 37 AS new_age FROM people WHERE id = 1;
```

Current target columns referenced on the left of WHERE predicates come first,
followed by SET target columns, without duplicates. Then `new_` columns show
WHERE equality values and SET expressions. If both specify the same column,
SET takes precedence for its `new_` expression. A WHERE comparison value is
shown for context; it does not mean the UPDATE assigns that column.
Non-equality predicates contribute their current column without inventing a
new value. An UPDATE without WHERE previews all rows.

The utility preserves the target table, ONLY/inheritance marker, alias, read-only
WITH prefix, FROM tables and WHERE logic. RETURNING is omitted. FROM joins can
produce multiple preview rows when multiple source rows match. No UPDATE is
executed; expressions are evaluated when the generated SELECT runs.

It accepts the same option names as `insert2select`:

* `-n`, `--handle-nulls`: replace standalone WHERE `=` operators with
  `IS NOT DISTINCT FROM`. SET expressions and other comparison operators stay
  unchanged. Without this option, WHERE is preserved verbatim.
* `--columns LIST`: explicitly choose/order the projected current columns and
  corresponding `new_` values from the inferred WHERE/SET columns.
* `--key LIST`: select WHERE equality columns; repeated keys are alternatives.
* `--match all|any`: `all` preserves the original WHERE; `any` joins its equality
  predicates with OR. `--key` and `--match any` require a WHERE consisting of
  ANDed column equalities and otherwise fail explicitly. They change which rows
  the preview returns.
* `-h`, `--help`, a file argument, `-` for stdin, and `--` work as in
  `insert2select`. Failures produce no partial SQL on stdout.

UPDATE conversion currently supports scalar SET expressions, scalar subqueries,
and explicit tuple assignments such as `SET (a,b) = ROW(1,2)`. WHERE projection
inference requires predicates with target-table columns on their left, including
qualified/quoted identifiers, nested AND/OR/NOT groups, and BETWEEN. It does not
infer columns from arbitrary function calls or subqueries on the left.
Repeated equality predicates giving different values to the same column are
rejected because they cannot share a single `new_` value. DEFAULT assignments,
field/array assignment targets, multi-column subquery assignments, data-modifying
WITH prefixes, and WHERE CURRENT OF are also rejected. This is a structural
converter, not a complete PostgreSQL parser or simulation of triggers/defaults.

```bash
bash tests/update.bash
bash tests/update.bash --integration
```

## delete2select

```bash
./delete2select deletes.sql > previews.sql
./delete2select -n < deletes.sql
echo 'DELETE FROM people WHERE id = 1;' | ./delete2select
```

The example produces:

```sql
SELECT * FROM people WHERE id = 1;
```

The default projection is `*`, without `new_` values. Use `--select-quals` to
project only the current WHERE columns:

```bash
echo 'DELETE FROM people WHERE id = 1;' | ./delete2select --select-quals
# SELECT id FROM people WHERE id = 1;
```

Without WHERE, `--select-quals` falls back to `*`. An alias or USING clause
qualifies `*` to select only target-table columns. An explicit `--columns` list
takes precedence over both the default and `--select-quals`.

The same CLI options are available. `-n`/`--handle-nulls` rewrites WHERE equality
operators; `--key` and `--match any` select/recombine ANDed equalities.
`--columns` chooses and orders projected target columns, including additional
columns not mentioned in WHERE. Their existence is checked by PostgreSQL when
the SELECT runs. `--match all` preserves the original WHERE by default.

DELETE's target, ONLY/inheritance marker, alias and read-only WITH prefix are
preserved. USING becomes additional FROM items; joins can produce duplicate
preview rows when multiple source rows match. RETURNING is omitted. The same
WHERE inference limits as `update2select` apply, including rejection of
WHERE CURRENT OF, function/array expressions on the left of predicates,
non-target-table columns on the left. Repeated columns are projected once,
including predicates such as `id = 1 OR id = 2`.
Data-modifying WITH queries are rejected. No DELETE is executed, and conversion
errors emit no partial SQL.

```bash
bash tests/delete.bash
bash tests/delete.bash --integration
```
