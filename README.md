# pg-backup

Scheduled logical backups for PostgreSQL and TimescaleDB, as one small container: `pg_dump -Fc` streams straight into [restic](https://restic.net), which encrypts on the client, deduplicates, and stores to any S3-compatible bucket (Cloudflare R2, AWS S3, Backblaze B2, MinIO, ...), a local path, or any other restic backend. Nothing is written to local disk.

- **Real `pg_dump`.** TimescaleDB hypertables and continuous aggregates only restore correctly from a genuine `pg_dump` wrapped in `timescaledb_pre_restore()` / `timescaledb_post_restore()`. `pg-backup restore` does that automatically when the target has the extension.
- **Fails loudly.** `pipefail` keeps a `pg_dump` that dies midway from being stored as a good snapshot. A missing variable stops the container at start. An optional heartbeat URL is pinged on success and at `<url>/fail` on failure, so a silently stopped backup shows up as a missed ping.
- **Retention built in.** `restic forget --prune` after every run, then `restic check`.
- **One image per PostgreSQL major** (client tools must match the server): `ghcr.io/openxbond/pg-backup:16`, `:17`, `:18` (`:latest` = 18), for amd64 and arm64.

## Usage

```yaml
services:
  backup:
    image: ghcr.io/openxbond/pg-backup:18
    restart: unless-stopped
    environment:
      PGHOST: db
      PGUSER: postgres
      PGPASSWORD: ${POSTGRES_PASSWORD}
      PGDATABASE: app
      RESTIC_REPOSITORY: s3:https://<account id>.r2.cloudflarestorage.com/<bucket>/app
      RESTIC_PASSWORD: ${BACKUP_PASSWORD}
      AWS_ACCESS_KEY_ID: ${S3_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${S3_SECRET_ACCESS_KEY}
    depends_on:
      db:
        condition: service_healthy
```

The repository is initialised on first start. **Keep `RESTIC_PASSWORD` somewhere other than the backup host**: without it the backups cannot be decrypted.

### Configuration

| Variable | Default | |
| --- | --- | --- |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE` | | Standard libpq variables; `PGDATABASE` is required |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` | | Required. Any restic backend and its credentials (`AWS_*`, `B2_*`, ...) work |
| `BACKUP_INTERVAL_MINUTES` | `60` | Time between backups |
| `BACKUP_KEEP` | `--keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 6` | Flags for `restic forget` |
| `BACKUP_CHECK` | `true` | Run `restic check` after each backup |
| `BACKUP_PING_URL` | | Pinged on success; `<url>/fail` on failure (healthchecks.io style) |
| `BACKUP_HOST` | `$PGDATABASE` | Snapshot host name. Fixed on purpose: restic applies retention per host, and a container hostname changes on every recreate |

### Commands

`docker run ... ghcr.io/openxbond/pg-backup:18 <command>`

| Command | |
| --- | --- |
| `run` (default) | Back up every `BACKUP_INTERVAL_MINUTES`, forever |
| `once` | One backup, then exit (for cron or Kubernetes CronJobs) |
| `snapshots` | List snapshots |
| `restore [snapshot]` | Restore `latest` (or a snapshot ID) into the database the `PG*` variables point at |

### Restoring

Point the `PG*` variables at an empty database (for TimescaleDB, one where the extension is installed, which the official image does on init) and run:

```sh
docker run --rm --network <network> --env-file backup.env ghcr.io/openxbond/pg-backup:18 restore
```

A backup only counts once restored: do it into a scratch container regularly and compare row counts. `test/smoke.sh` is that check in miniature.

## Development

```sh
docker build -t pg-backup:test .
sh test/smoke.sh pg-backup:test   # needs Docker; backs up and restores a TimescaleDB hypertable
```

## License

MIT
