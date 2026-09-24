# Changelog

## .01 — 2026-09-24

Initial release of the offline, pure Bash SQL conversion utilities:

- `insert2select`: generate matching SELECT predicates from INSERT statements.
- `update2select`: preview current columns alongside WHERE and SET values.
- `delete2select`: preview matching rows, with optional WHERE-column projection.
- File/stdin input, equality by default, and opt-in null-safe comparisons.
- Conversion tests and PostgreSQL integration tests.
- `codex.sh` to resume the development conversation on the originating machine.

See README.md for supported SQL forms, options, and limitations.
