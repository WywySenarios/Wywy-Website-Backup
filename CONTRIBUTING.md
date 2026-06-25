# Contributing to Wywy-Website-Backup

## PostgreSQL version compatibility

### pg_dumpall output format stability

`pg_dumpall` output format is **not stable across PostgreSQL major versions**. The SQL text emitted by `pg_dumpall` can change between major releases (e.g., PG 17 → PG 18) in ways that affect test assertions:

- Type names may change case (`TEXT` → `text`, `JSONB` → `jsonb`)
- Statement syntax may change (e.g., `CREATE DATABASE <name>;` → `CREATE DATABASE <name> WITH ...;`)
- Role password hashes use different algorithms (e.g., `md5` → `SCRAM-SHA-256`)
- Dump headers and metadata comments may differ

**Within a single major version** (e.g., all PG 18.x releases), the output format **is stable**. No assertion changes are needed for minor version bumps.

### When upgrading PostgreSQL

When the managed server version changes to a new major version:

1. Update the test's Docker image tag from `postgres:18` to the new version.
2. Run a reference backup against a seed database and inspect the raw SQL output.
3. Update test assertions (grep patterns, expected strings) in `scripts/tests/test_backup_master_database.bats` to match the new output format.
4. Verify you can extract a compatible `pg_dumpall` binary from the new Docker image (see `setup_file` in the test file for the extraction logic).
5. Re-run the full test suite.
