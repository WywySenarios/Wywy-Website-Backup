#!/usr/bin/env bats
# Tests for backup-master-database.sh — GREEN phase
#
# The script creates a full backup of the master-database service using
# pg_dumpall over TCP (no Docker dependency in the script itself —
# just like a real backup server connecting to a remote Postgres).
#
# IMPORTANT: pg_dumpall output format is NOT stable across PostgreSQL
# major versions. Assertions in this file (grep patterns, SQL content
# checks) are validated against PG 18's output. If the server version
# changes to a different major version, the expected patterns MUST be
# re-verified against the new server's pg_dumpall output. Within a
# single major version (e.g., all 18.x releases), the output format
# IS stable.
#
# Test environment:
#   1. Starts a postgres:18 Docker container (simulates master-database)
#   2. Seeds it with multiple databases, tables, and diverse data types
#   3. Installs postgresql-client if pg_dumpall is not available locally,
#      or extracts pg_dumpall 18 from the Docker image if the installed
#      version is incompatible with PG 18.
#   4. Runs the backup script locally (simulates the backup server)
#   5. Verifies the backup file is valid SQL and can be restored
# Every test will fail until the script is implemented in the GREEN phase.

# ---- file-level setup / teardown (runs once per file) -----------------------

setup_file() {
    # Install postgresql-client if pg_dumpall is not available
    if ! command -v pg_dumpall &>/dev/null; then
        echo "# Installing postgresql-client..." >&3
        apt-get update -qq && apt-get install -y -qq postgresql-client
    fi

    # Ensure the postgres:18 image is available
    if ! docker image inspect postgres:18 &>/dev/null; then
        echo "# Pulling postgres:18 Docker image..." >&3
        docker pull postgres:18
    fi

    # Ensure pg_dumpall version is compatible with PG 18 server.
    # The default Debian 13 packages ship pg_dumpall 17, which refuses to
    # dump from PG 18. We extract pg_dumpall 18 from the same Docker image
    # that the test uses as the database server.
    if ! command -v pg_dumpall &>/dev/null || ! pg_dumpall --version 2>/dev/null | grep -qE " 1[89]\."; then
        echo "# Extracting pg_dumpall from postgres:18 image..." >&3
        docker create --name wywy-pg18-extract postgres:18
        docker cp wywy-pg18-extract:/usr/lib/postgresql/18/bin/pg_dumpall /tmp/pg_dumpall
        docker cp wywy-pg18-extract:/usr/lib/postgresql/18/bin/pg_dump /tmp/pg_dump
        docker rm wywy-pg18-extract
        chmod +x /tmp/pg_dumpall /tmp/pg_dump
        export PATH="/tmp:$PATH"
    fi

    # Start the Postgres container representing master-database
    export PG_CONTAINER="wywy-test-master-db"
    export PG_PORT="25432"
    export PG_PASSWORD="testpass"
    export PG_USER="postgres"

    # Clean up any leftover container from a previous interrupted run
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true

    docker run -d \
        --name "$PG_CONTAINER" \
        -e POSTGRES_PASSWORD="$PG_PASSWORD" \
        -p "$PG_PORT:5432" \
        postgres:18

    # Wait for Postgres to accept connections
    echo "# Waiting for Postgres to be ready..." >&3
    timeout 60 bash -c "
        until pg_isready -h 127.0.0.1 -p $PG_PORT -U $PG_USER 2>/dev/null; do
            sleep 1
        done
    "

    echo "# Seeding test data..." >&3
    export PGPASSWORD="$PG_PASSWORD"

    # Create multiple databases with diverse schemas — simulating a real
    # master-database service that manages several logical databases.
    psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d postgres <<SQL
        CREATE ROLE test_reader WITH LOGIN PASSWORD 'readerpass' NOSUPERUSER;
        CREATE DATABASE appdb;
SQL

    psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d appdb <<SQL
        CREATE SCHEMA app;

        CREATE TABLE app.users (
            id       SERIAL PRIMARY KEY,
            username TEXT NOT NULL UNIQUE,
            email    TEXT,
            created_at TIMESTAMPTZ DEFAULT now()
        );

        CREATE TABLE app.sessions (
            id         SERIAL PRIMARY KEY,
            user_id    INT NOT NULL REFERENCES app.users(id),
            token      TEXT NOT NULL,
            expires_at TIMESTAMPTZ
        );

        CREATE TABLE app.settings (
            id    SERIAL PRIMARY KEY,
            key   TEXT NOT NULL UNIQUE,
            value JSONB
        );

        INSERT INTO app.users (username, email) VALUES
            ('alice', 'alice@test.com'),
            ('bob', 'bob@test.com'),
            ('charlie', 'charlie@test.com');

        INSERT INTO app.sessions (user_id, token, expires_at) VALUES
            (1, 'tok_alice_001', '2027-01-01 00:00:00+00'),
            (2, 'tok_bob_001', '2027-06-01 00:00:00+00'),
            (3, 'tok_char_001', '2027-12-31 23:59:59+00');

        INSERT INTO app.settings (key, value) VALUES
            ('site_name', '"Wywy"'),
            ('max_users', '10000'),
            ('features', '{"dark_mode": true, "beta": false}');
SQL

    psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d postgres <<SQL
        CREATE DATABASE analytics;
SQL

    psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d analytics <<SQL
        CREATE SCHEMA metrics;

        CREATE TABLE metrics.events (
            id         BIGSERIAL PRIMARY KEY,
            event_type TEXT NOT NULL,
            payload    JSONB,
            ip_address INET,
            created_at TIMESTAMPTZ DEFAULT now()
        );

        CREATE TABLE metrics.pageviews (
            id       BIGSERIAL PRIMARY KEY,
            path     TEXT NOT NULL,
            referrer TEXT,
            duration INTERVAL,
            created_at TIMESTAMPTZ DEFAULT now()
        );

        INSERT INTO metrics.events (event_type, payload, ip_address) VALUES
            ('pageview', '{"path": "/home", "title": "Home"}', '10.0.0.1'),
            ('pageview', '{"path": "/settings", "title": "Settings"}', '10.0.0.1'),
            ('click', '{"element": "button", "label": "Save"}', '10.0.0.2'),
            ('login', '{"method": "password"}', '10.0.0.3');

        INSERT INTO metrics.pageviews (path, referrer, duration) VALUES
            ('/home', 'https://google.com', '1 minute'::INTERVAL),
            ('/settings', '/home', '30 seconds'::INTERVAL);
SQL

    unset PGPASSWORD
}

teardown_file() {
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
}

# ---- per-test setup / teardown ----------------------------------------------

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # The backup script under test, relative to this test file
    SCRIPT="$BATS_TEST_DIRNAME/../backup-master-database.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"

    # Clean up the verify container if the restore test started it
    docker stop wywy-test-verify-pg 2>/dev/null || true
    docker rm   wywy-test-verify-pg 2>/dev/null || true
}

# ---- helpers ----------------------------------------------------------------

# Run the backup script, capturing status and output
run_backup() {
    run "$SCRIPT" "$@"
}

# Run backup with standard test flags and capture the backup file path.
# Fails the test if the backup fails or no .sql file is produced.
run_backup_and_get_file() {
    export DATABASE_PASSWORD="$PG_PASSWORD"
    run_backup -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$TEST_TMPDIR"
    if [ "$status" -ne 0 ]; then
        echo "Backup failed with status $status: $output" >&3
        return 1
    fi
    backup_file=$(ls "$TEST_TMPDIR"/*.sql 2>/dev/null | head -1)
    if [ -z "$backup_file" ]; then
        echo "No backup file found in $TEST_TMPDIR" >&3
        return 1
    fi
}

# File- & content-level checks that don't need a real database ---------------

@test "exits 1 with 'host' error when no host provided and no DATABASE_HOST env" {
    run_backup
    echo "status: $status"
    echo "output: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"host"* ]] || [[ "$output" == *"Host"* ]]
}

@test "exits 1 with clear error when pg_dumpall is not found" {
    # Temporarily hide pg_dumpall from PATH
    ORIG_PATH="$PATH"
    PATH=""
    run_backup -h 127.0.0.1
    echo "status: $status"
    echo "output: $output"
    PATH="$ORIG_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pg_dumpall"* ]] || [[ "$output" == *"not found"* ]]
}

# -- tests that exercise the real backup pipeline ----------------------------

@test "-h flag produces a non-empty .sql backup file" {
    export DATABASE_PASSWORD="$PG_PASSWORD"
    run_backup -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$TEST_TMPDIR"
    echo "status: $status"
    echo "output: $output"
    [ "$status" -eq 0 ]

    # Expect at least one .sql file in the output directory
    files=("$TEST_TMPDIR"/*.sql)
    echo "files: ${files[*]}"
    [ "${#files[@]}" -ge 1 ]
    [ -s "${files[0]}" ]
}

@test "backup file contains CREATE DATABASE statements for all databases" {
    run_backup_and_get_file

    echo "checking $backup_file ..."
    # PG 18's pg_dumpall outputs "CREATE DATABASE <name> WITH <options>;"
    # (not just "CREATE DATABASE <name>;"). Match the prefix flexibly.
    grep -Eq 'CREATE DATABASE "?appdb"?'     "$backup_file"
    grep -Eq 'CREATE DATABASE "?analytics"?' "$backup_file"
}

@test "backup file contains table schemas and column definitions" {
    run_backup_and_get_file

    # Note: PG 18's pg_dumpall outputs lowercase type names (text, jsonb, etc.)
    grep -q "CREATE TABLE.*users"     "$backup_file"
    grep -q "CREATE TABLE.*sessions"  "$backup_file"
    grep -q "CREATE TABLE.*settings"  "$backup_file"
    grep -q "CREATE TABLE.*events"    "$backup_file"
    grep -q "CREATE TABLE.*pageviews" "$backup_file"
    grep -q "username.*text"          "$backup_file"
    grep -q "payload.*jsonb"          "$backup_file"
}

@test "backup file contains the actual data rows" {
    run_backup_and_get_file

    # Check for INSERT statements with the seeded data
    grep -q "alice.*alice@test.com"   "$backup_file"
    grep -q "bob.*bob@test.com"       "$backup_file"
    grep -q "charlie.*charlie@test.com" "$backup_file"
    grep -q "tok_alice_001"            "$backup_file"
    grep -q "10.0.0.1"                 "$backup_file"
}

@test "backup includes global objects (roles)" {
    run_backup_and_get_file

    grep -q "test_reader" "$backup_file"
}

@test "DATABASE_HOST env var works as fallback when -h is omitted" {
    export DATABASE_HOST="127.0.0.1"
    export DATABASE_PORT="$PG_PORT"
    export DATABASE_USERNAME="$PG_USER"
    export DATABASE_PASSWORD="$PG_PASSWORD"

    run_backup -d "$TEST_TMPDIR"
    echo "status: $status"
    echo "output: $output"
    [ "$status" -eq 0 ]

    files=("$TEST_TMPDIR"/*.sql)
    [ "${#files[@]}" -ge 1 ]
    [ -s "${files[0]}" ]

    unset DATABASE_HOST DATABASE_PORT DATABASE_USERNAME DATABASE_PASSWORD
}

@test "-h flag overrides DATABASE_HOST env var" {
    export DATABASE_HOST="10.255.255.1"  # unreachable — would fail if used
    export DATABASE_PORT="$PG_PORT"
    export DATABASE_USERNAME="$PG_USER"
    export DATABASE_PASSWORD="$PG_PASSWORD"

    run_backup -h 127.0.0.1 -d "$TEST_TMPDIR"
    echo "status: $status"
    echo "output: $output"
    [ "$status" -eq 0 ]

    files=("$TEST_TMPDIR"/*.sql)
    [ "${#files[@]}" -ge 1 ]

    unset DATABASE_HOST DATABASE_PORT DATABASE_USERNAME DATABASE_PASSWORD
}

@test "-p flag connects to a non-default port" {
    export DATABASE_PASSWORD="$PG_PASSWORD"
    run_backup -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$TEST_TMPDIR"
    [ "$status" -eq 0 ]

    files=("$TEST_TMPDIR"/*.sql)
    [ "${#files[@]}" -ge 1 ]
}

@test "-d flag writes backup to a custom directory" {
    export DATABASE_PASSWORD="$PG_PASSWORD"
    CUSTOM_DIR="$TEST_TMPDIR/custom-location"
    run_backup -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$CUSTOM_DIR"
    [ "$status" -eq 0 ]

    [ -d "$CUSTOM_DIR" ]
    files=("$CUSTOM_DIR"/*.sql)
    [ "${#files[@]}" -ge 1 ]
    [ -s "${files[0]}" ]
}

@test "creates backup directory if it does not exist" {
    export DATABASE_PASSWORD="$PG_PASSWORD"
    NEW_DIR="$TEST_TMPDIR/brand-new-dir/nested"
    run_backup -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$NEW_DIR"
    [ "$status" -eq 0 ]

    [ -d "$NEW_DIR" ]
}

@test "non-zero pg_dumpall exit code is propagated" {
    # Connect to a port with nothing listening — pg_dumpall will fail
    run_backup -h 127.0.0.1 -p 1 -U "$PG_USER" -d "$TEST_TMPDIR"
    echo "status: $status"
    echo "output: $output"
    [ "$status" -ne 0 ]

    # No backup file should have been created
    shopt -s nullglob
    files=("$TEST_TMPDIR"/*.sql)
    shopt -u nullglob
    [ "${#files[@]}" -eq 0 ]
}

# -- full round-trip: backup → restore → verify data -------------------------

@test "full round-trip: backup can be restored to a clean Postgres and data matches" {
    # Step 1: Create the backup
    run_backup_and_get_file
    echo "# backup file: $backup_file" >&3

    # Step 2: Start a clean Postgres container to restore into
    # NOTE: Use trust auth to avoid password mismatch when the dump
    # contains ALTER ROLE postgres ... PASSWORD (pg_dumpall includes
    # the role password hash, which would override the verify
    # container's password and break subsequent \connect commands).
    VERIFY_PORT="25433"
    VERIFY_CONTAINER="wywy-test-verify-pg"

    docker run -d \
        --name "$VERIFY_CONTAINER" \
        -e POSTGRES_HOST_AUTH_METHOD=trust \
        -p "$VERIFY_PORT:5432" \
        postgres:18

    timeout 60 bash -c "
        until pg_isready -h 127.0.0.1 -p $VERIFY_PORT 2>/dev/null; do
            sleep 1
        done
    "

    # Step 3: Restore the backup
    psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -f "$backup_file"

    # Step 4: Verify data — appdb.users
    users_count=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d appdb -t -A -c \
        "SELECT count(*) FROM app.users;")
    [ "$users_count" = "3" ] || {
        echo "# Expected 3 users, got: $users_count" >&3
        false
    }

    # Verify specific user data made it through
    alice_email=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d appdb -t -A -c \
        "SELECT email FROM app.users WHERE username = 'alice';")
    [ "$alice_email" = "alice@test.com" ]

    # Verify sessions (FK constraint means users must restore first)
    sessions_count=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d appdb -t -A -c \
        "SELECT count(*) FROM app.sessions;")
    [ "$sessions_count" = "3" ]

    # Verify settings JSONB
    features=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d appdb -t -A -c \
        "SELECT value->>'dark_mode' FROM app.settings WHERE key = 'features';")
    [ "$features" = "true" ]

    # Step 5: Verify data — analytics.metrics
    events_count=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d analytics -t -A -c \
        "SELECT count(*) FROM metrics.events;")
    [ "$events_count" = "4" ]

    pageviews_count=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d analytics -t -A -c \
        "SELECT count(*) FROM metrics.pageviews;")
    [ "$pageviews_count" = "2" ]

    # Step 6: Verify global objects (roles) were restored
    reader_exists=$(psql -h 127.0.0.1 -p "$VERIFY_PORT" -U postgres -d postgres -t -A -c \
        "SELECT 1 FROM pg_roles WHERE rolname = 'test_reader';")
    [ "$reader_exists" = "1" ]

    unset PGPASSWORD
}
