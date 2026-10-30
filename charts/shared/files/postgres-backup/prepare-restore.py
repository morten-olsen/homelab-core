#!/usr/bin/env python3
"""Prepare globals for a fresh restore without changing the bootstrap identity."""

import json
import os
import sys
from pathlib import Path


def prepare(backup: Path, output: Path) -> None:
    if not (backup / "complete").is_file():
        raise ValueError("Backup generation is incomplete")
    role = json.loads((backup / "bootstrap-role.json").read_text())
    globals_sql = (backup / "globals.sql").read_text()
    # These exact native pg_dumpall statements must each occur once. Keep all
    # ALTER ROLE/password/settings and GRANT statements, including grantors.
    for statement in (
        f"DROP ROLE IF EXISTS {role['sqlIdentifier']};\n",
        f"CREATE ROLE {role['sqlIdentifier']};\n",
    ):
        if globals_sql.count(statement) != 1:
            raise ValueError("Expected exactly one bootstrap role statement")
        globals_sql = globals_sql.replace(statement, "", 1)

    literal = "'" + role["name"].replace("'", "''") + "'"
    guard = (
        "\\set ON_ERROR_STOP on\n"
        "SET standard_conforming_strings = on;\n"
        "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE oid = 10 AND rolname = "
        + literal
        + ") AS bootstrap_matches \\gset\n"
        "\\if :bootstrap_matches\n"
        "\\else\n"
        "DO $$ BEGIN RAISE EXCEPTION "
        "'Recovery bootstrap role must match the source at OID 10.'; END $$;\n"
        "\\endif\n"
    )
    # Do not overwrite an existing recovery artifact or print credential hashes.
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as target:
        target.write(guard)
        target.write(globals_sql)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: prepare-restore.py BACKUP_DIRECTORY OUTPUT_SQL")
    try:
        prepare(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
