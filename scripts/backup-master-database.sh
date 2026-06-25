#!/bin/bash
# Full backup script for the master-database service.
# Invokes pg_dumpall to create a complete backup of all databases.
#
# Usage: backup-master-database.sh -h <host> [-p <port>] [-U <username>] [-d <directory>]
#
# Environment variables:
#   DATABASE_HOST      Database host (overridden by -h)
#   DATABASE_PORT      Database port (default: 5432)
#   DATABASE_USERNAME  Database user (default: postgres)
#   DATABASE_PASSWORD  Database password
#   BACKUP_DIR         Backup output directory (default: see -d)

set -euo pipefail

# Defaults from environment
host="${DATABASE_HOST:-}"
port="${DATABASE_PORT:-5432}"
username="${DATABASE_USERNAME:-postgres}"
backup_dir="${BACKUP_DIR:-/var/lib/Wywy-Website/backup/postgres_backups}"

# Parse flags: -h host, -p port, -U username, -d directory
while getopts "h:p:U:d:" opt; do
    case "$opt" in
        h) host="$OPTARG" ;;
        p) port="$OPTARG" ;;
        U) username="$OPTARG" ;;
        d) backup_dir="$OPTARG" ;;
        ?) exit 1 ;;
    esac
done

# Validate host is provided
if [[ -z "$host" ]]; then
    echo "Error: No database host specified. Use -h <host> or set DATABASE_HOST." >&2
    exit 1
fi

# Check pg_dumpall is available
if ! command -v pg_dumpall &>/dev/null; then
    echo "Error: pg_dumpall not found. Install postgresql-client." >&2
    exit 1
fi

# Set PGPASSWORD from DATABASE_PASSWORD env var if available
if [[ -n "${DATABASE_PASSWORD:-}" ]]; then
    export PGPASSWORD="$DATABASE_PASSWORD"
fi

# Create the backup directory (including parent directories)
mkdir -p "$backup_dir"

# Generate a timestamped filename
timestamp="$(date +%Y%m%d_%H%M%S)"
backup_file="${backup_dir}/master-database-full-${timestamp}.sql"

# Run pg_dumpall — this is the core of the backup.
# pg_dumpall connects over TCP (no Docker dependency) and writes a
# complete SQL dump including global objects, schemas, and data.
pg_dumpall -h "$host" -p "$port" -U "$username" -f "$backup_file"
