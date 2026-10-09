#!/bin/sh
# pg-backup: stream `pg_dump -Fc` into restic, forget old snapshots, repeat.
# Configuration is environment only; see README.md.
set -eu
# Without pipefail a pg_dump that dies midway would still leave restic with a
# "successful" truncated snapshot. Not POSIX, but busybox ash (this image) has it.
# shellcheck disable=SC3040
set -o pipefail

: "${PGDATABASE:?PGDATABASE is required}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"

INTERVAL_MINUTES="${BACKUP_INTERVAL_MINUTES:-60}"
KEEP="${BACKUP_KEEP:---keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 6}"
CHECK="${BACKUP_CHECK:-true}"
PING_URL="${BACKUP_PING_URL:-}"
# restic groups snapshots by host for `forget`. A container's hostname changes
# on every recreate, so pin it: otherwise old snapshots would sit in a group
# that retention never touches again.
HOST="${BACKUP_HOST:-$PGDATABASE}"
TAG=pg_dump
FILE="$PGDATABASE.dump"

export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic}"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

ping() {
  [ -n "$PING_URL" ] || return 0
  wget -q -T 10 -O /dev/null "$PING_URL$1" || log "ping $PING_URL$1 failed"
}

init_repository() {
  restic cat config >/dev/null 2>&1 || restic init
}

# shellcheck disable=SC2086 # BACKUP_KEEP is a list of flags
backup() {
  pg_dump -Fc | restic backup --stdin --stdin-filename "$FILE" --host "$HOST" --tag "$TAG" &&
    restic forget --prune --host "$HOST" --tag "$TAG" $KEEP &&
    { [ "$CHECK" != true ] || restic check; }
}

backup_once() {
  if backup; then
    log "backup ok"
    ping ""
  else
    log "backup FAILED" >&2
    ping /fail
    return 1
  fi
}

# Restores a snapshot into the database named by the PG* variables. TimescaleDB
# hypertables only restore correctly between pre_restore and post_restore, so
# those run whenever the target database has the extension.
restore() {
  snapshot="${1:-latest}"
  timescale="$(psql -Atc "select 1 from pg_extension where extname = 'timescaledb'")"
  [ -z "$timescale" ] || psql -v ON_ERROR_STOP=1 -qc "select timescaledb_pre_restore()"
  restic dump --host "$HOST" --tag "$TAG" "$snapshot" "$FILE" | pg_restore -d "$PGDATABASE" --no-owner
  [ -z "$timescale" ] || psql -v ON_ERROR_STOP=1 -qc "select timescaledb_post_restore()"
  log "restored $snapshot"
}

case "${1:-run}" in
  run)
    init_repository
    trap 'exit 0' TERM INT
    while true; do
      backup_once || true
      # Backgrounded so the signal trap fires immediately instead of after the sleep.
      sleep $((INTERVAL_MINUTES * 60)) &
      wait $!
    done
    ;;
  once)
    init_repository
    backup_once
    ;;
  restore)
    shift
    restore "$@"
    ;;
  snapshots)
    restic snapshots --host "$HOST" --tag "$TAG"
    ;;
  *)
    echo "usage: pg-backup [run|once|restore [snapshot]|snapshots]" >&2
    exit 2
    ;;
esac
