#!/bin/sh
# End-to-end check against a throwaway TimescaleDB: back up, restore into a
# second database, compare rows. Usage: test/smoke.sh <image>
set -eu

IMAGE="${1:?usage: smoke.sh <image>}"
TS_IMAGE="${TIMESCALE_IMAGE:-timescale/timescaledb:2.30.1-pg18}"
NET=pgbackup-smoke
cleanup() { docker rm -f smoke-src smoke-dst >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; docker volume rm -f $NET-repo >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create $NET >/dev/null
docker volume create $NET-repo >/dev/null
# The image runs as the postgres user; a fresh named volume is root-owned.
docker run --rm -v $NET-repo:/repo --entrypoint chmod "$IMAGE" 777 /repo 2>/dev/null ||
  docker run --rm -u 0 -v $NET-repo:/repo --entrypoint chmod "$IMAGE" 777 /repo

start_db() {
  docker run -d --name "$1" --network $NET -e POSTGRES_PASSWORD=x -e POSTGRES_DB=app "$TS_IMAGE" >/dev/null
  # The entrypoint restarts the server once after init, so wait for it to stay up.
  ok=0
  for _ in $(seq 60); do
    if docker exec "$1" psql -U postgres -d app -Atc "select 1" >/dev/null 2>&1; then ok=$((ok + 1)); else ok=0; fi
    [ "$ok" -ge 3 ] && return 0
    sleep 2
  done
  echo "$1 did not become ready" >&2
  exit 1
}

tool() {
  docker run --rm --network $NET -v $NET-repo:/repo \
    -e PGHOST="$1" -e PGUSER=postgres -e PGPASSWORD=x -e PGDATABASE=app -e PGSSLMODE=prefer \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD=smoke \
    "$IMAGE" "$2"
}

start_db smoke-src
docker exec smoke-src psql -U postgres -d app -qc "
  create table events (at timestamptz not null, v int);
  select create_hypertable('events', 'at');
  insert into events select now() - (i || ' minutes')::interval, i from generate_series(1, 1000) i;"

tool smoke-src once
tool smoke-src snapshots | grep -q pg_dump

start_db smoke-dst
tool smoke-dst restore

rows="$(docker exec smoke-dst psql -U postgres -d app -Atc "select count(*) from events")"
hypertables="$(docker exec smoke-dst psql -U postgres -d app -Atc "select count(*) from timescaledb_information.hypertables")"
if [ "$rows" != 1000 ] || [ "$hypertables" != 1 ]; then
  echo "restore mismatch: rows=$rows hypertables=$hypertables" >&2
  exit 1
fi
echo "smoke ok: $rows rows, $hypertables hypertable"
