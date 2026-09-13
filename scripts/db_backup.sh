#!/usr/bin/env bash
# db_backup.sh
# dumps the postgres database, gzips it, writes it to /var/backups/db
# named db_backup_YYYYMMDD.sql.gz, and deletes anything older than the
# retention window

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

COMPOSE_DIR="${COMPOSE_DIR:-/home/trainee/infra-devops-assignment}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/db}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DB_SERVICE="${DB_SERVICE:-db}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$1"; }

cd "$COMPOSE_DIR"

# pull the db credentials out of .env rather than hardcoding them here
set -a
. ./.env
set +a

install -d -m 700 "$BACKUP_DIR"

STAMP="$(date +%Y%m%d)"
TARGET="${BACKUP_DIR}/db_backup_${STAMP}.sql.gz"

# write to a temp file first so a failed dump can't leave a half-written
# backup sitting there looking valid
TMP="$(mktemp "${TARGET}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

log "dumping database ${POSTGRES_DB}"

# -T means no tty. with a tty docker inserts carriage returns into the
# stream and the resulting dump is corrupt
if ! docker compose exec -T "$DB_SERVICE" \
        pg_dump --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        | gzip -9 > "$TMP"; then
    log "[ERROR] pg_dump failed, nothing written"
    exit 1
fi

# a dump that "succeeded" but produced almost nothing is still a failure
if [[ ! -s "$TMP" ]] || (( $(stat -c%s "$TMP") < 200 )); then
    log "[ERROR] dump is empty or truncated, refusing to keep it"
    exit 1
fi

mv "$TMP" "$TARGET"
trap - EXIT
chmod 600 "$TARGET"

log "wrote ${TARGET} ($(du -h "$TARGET" | cut -f1))"

# retention
removed=$(find "$BACKUP_DIR" -maxdepth 1 -name 'db_backup_*.sql.gz' -type f \
            -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
log "removed ${removed} backup(s) older than ${RETENTION_DAYS} days"

log "restore with:"
log "  gunzip -c ${TARGET} | docker compose exec -T ${DB_SERVICE} psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}"
