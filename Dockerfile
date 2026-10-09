ARG PG_MAJOR=18
# The client tools must match the server's major version, so one image per major.
FROM postgres:${PG_MAJOR}-alpine

LABEL org.opencontainers.image.source="https://github.com/openxbond/pg-backup" \
      org.opencontainers.image.description="Scheduled pg_dump to restic (S3, R2, B2, ...) for PostgreSQL and TimescaleDB" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache restic tzdata

COPY backup.sh /usr/local/bin/pg-backup

USER postgres
ENTRYPOINT ["pg-backup"]
CMD ["run"]
