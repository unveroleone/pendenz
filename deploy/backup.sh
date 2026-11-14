#!/bin/sh
# Snapshot the database, check it, and send it to the restic repository when one is configured.
set -eu
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
snapshot="/backups/pendenz-$stamp.db"
sqlite3 -readonly /data/pendenz.db ".timeout 30000" ".backup '$snapshot'"
# Make the copy one self-contained file, without the write-ahead log files of the live database.
sqlite3 "$snapshot" 'PRAGMA journal_mode=DELETE;' >/dev/null
result=$(sqlite3 -readonly "$snapshot" 'PRAGMA integrity_check;')
if [ "$result" != "ok" ]; then
    echo 'Backup integrity check failed.' >&2
    exit 1
fi
if [ -n "${RESTIC_REPOSITORY:-}" ]; then
    export RESTIC_CACHE_DIR=/tmp/restic-cache
    restic backup "$snapshot" --tag pendenz --host pendenz
    restic forget --tag pendenz --host pendenz --group-by host,tags --keep-within 30d --prune
fi
# Local snapshots are only a staging copy. Keep the newest seven.
ls -1t /backups/pendenz-*.db | tail -n +8 | xargs -r rm -f
echo "Backup created: $snapshot"
