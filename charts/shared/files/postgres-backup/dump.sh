#!/usr/bin/env bash
set -euo pipefail
umask 007

BACKUP_ROOT=${BACKUP_ROOT:-/backup}
case "$BACKUP_ROOT" in
    /*) ;;
    *) printf '%s\n' 'BACKUP_ROOT must be an absolute directory.' >&2; exit 1 ;;
esac
cd "$BACKUP_ROOT"
if [[ $(pwd -P) == / ]]; then
    printf '%s\n' 'BACKUP_ROOT must not be the filesystem root.' >&2
    exit 1
fi

# A killed publish may leave the last complete generation under previous.
if [[ ! -e current && -f previous/complete ]]; then
    mv -- previous current
fi
if [[ -e previous && ! -f current/complete ]]; then
    printf '%s\n' 'Cannot discard previous without a complete current generation.' >&2
    exit 1
fi
rm -rf -- previous work
mkdir -- work work/databases

finish() {
    status=$?
    trap - EXIT
    if [[ $status -ne 0 && ! -e current && -f previous/complete ]]; then
        mv -- previous current || printf '%s\n' 'Previous complete generation remains in previous; publication recovery failed.' >&2
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# GRANTED BY treats the bootstrap superuser (OID 10) specially. Recovery must
# preserve its name at OID 10, rather than recreate it as an ordinary role.
psql --no-password --no-psqlrc --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 \
    --command="SELECT json_build_object('name', rolname, 'sqlIdentifier', quote_ident(rolname)) FROM pg_roles WHERE oid = 10" \
    > work/bootstrap-role.json
pg_dumpall --no-password --globals-only --clean --if-exists --file=work/globals.sql
psql --no-password --no-psqlrc --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 --field-separator=$'\t' --record-separator-zero \
    --command='SELECT oid, datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY oid' \
    > work/databases.list

while IFS= read -r -d '' record; do
    oid=${record%%$'\t'*}
    dbname=${record#*$'\t'}
    if [[ "$record" != *$'\t'* || ! "$oid" =~ ^[0-9]+$ || -z "$dbname" ]]; then
        printf '%s\n' 'Invalid database catalog record; refusing to publish.' >&2
        exit 1
    fi
    # PGDATABASE is literal: unlike --dbname, names containing '=' or a URI
    # prefix are not interpreted as connection strings.
    PGDATABASE="$dbname" pg_dump --no-password --format=directory \
        --compress=none --file="work/databases/$oid"
done < work/databases.list

# pg_dump creates owner-only archives regardless of umask. The read-only upload
# container uses the pod's fsGroup, without DAC-bypass capabilities.
chmod -R g+rX -- work

# Only complete generations can become current. The previous generation is
# retained across either rename failing, and recovered after an interrupted swap.
touch -- work/complete
if [[ -e current ]]; then
    mv -- current previous
fi
mv -- work current
rm -rf -- previous
printf '%s\n' 'Logical PostgreSQL generation completed.'
