#!/bin/sh
set -eu
umask 077

BACKUP_ROOT=${BACKUP_ROOT:-/backup}
RESTIC_HOST=${RESTIC_HOST:-postgres-cluster}
RETAIN_DAILY=${RETAIN_DAILY:-7}
RETAIN_WEEKLY=${RETAIN_WEEKLY:-4}
RETAIN_MONTHLY=${RETAIN_MONTHLY:-3}
cache_dir=${TMPDIR:-/tmp}/restic-cache
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
export RESTIC_REPOSITORY RESTIC_PASSWORD

case "$BACKUP_ROOT" in
    /*) ;;
    *) printf '%s\n' 'BACKUP_ROOT must be an absolute directory.' >&2; exit 1 ;;
esac
cd "$BACKUP_ROOT"
backup_path=$(pwd -P)/current
if [ ! -f "$backup_path/complete" ] || [ ! -f "$backup_path/globals.sql" ] || \
    [ ! -f "$backup_path/bootstrap-role.json" ] || \
    [ ! -f "$backup_path/databases.list" ] || [ ! -d "$backup_path/databases" ]; then
    printf '%s\n' 'No complete logical PostgreSQL generation; refusing upload.' >&2
    exit 1
fi

# Only local repositories are supported. Never reinterpret an access/decryption
# failure as an absent repository, or initialize over damaged repository data.
case "$RESTIC_REPOSITORY" in
    /) printf '%s\n' 'RESTIC_REPOSITORY must not be the filesystem root.' >&2; exit 1 ;;
    /*) ;;
    *) printf '%s\n' 'RESTIC_REPOSITORY must be a local absolute path.' >&2; exit 1 ;;
esac
if [ ! -e "$RESTIC_REPOSITORY/config" ] && [ ! -L "$RESTIC_REPOSITORY/config" ]; then
    if [ -e "$RESTIC_REPOSITORY" ] || [ -L "$RESTIC_REPOSITORY" ]; then
        if [ ! -d "$RESTIC_REPOSITORY" ] || [ ! -r "$RESTIC_REPOSITORY" ] || \
            [ ! -x "$RESTIC_REPOSITORY" ]; then
            printf '%s\n' 'Restic repository directory is inaccessible.' >&2
            exit 1
        fi
        for entry in "$RESTIC_REPOSITORY"/* "$RESTIC_REPOSITORY"/.[!.]* "$RESTIC_REPOSITORY"/..?*; do
            if [ -e "$entry" ] || [ -L "$entry" ]; then
                printf '%s\n' 'Restic config is absent from a nonempty repository; refusing initialization.' >&2
                exit 1
            fi
        done
    fi
    restic --cache-dir "$cache_dir" --quiet init
fi

# A stable host/path pair keeps parent selection and retention in one group.
# set -e prevents retention/pruning after a failed or incomplete snapshot.
restic --cache-dir "$cache_dir" --quiet backup --host "$RESTIC_HOST" "$backup_path"
restic --cache-dir "$cache_dir" --quiet forget --host "$RESTIC_HOST" --path "$backup_path" \
    --group-by host,paths --keep-daily "$RETAIN_DAILY" \
    --keep-weekly "$RETAIN_WEEKLY" --keep-monthly "$RETAIN_MONTHLY" --prune
printf '%s\n' 'Encrypted PostgreSQL snapshot and retention completed.'
