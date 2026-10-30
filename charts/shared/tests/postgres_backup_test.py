"""Optional real-container regression: python3 charts/shared/tests/postgres_backup_test.py.

Requires Docker with image-pull access; publishes no ports and uses no host binds.
All databases, passwords, networks and volumes below are disposable test fixtures.
"""

import json
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


SCRIPTS = Path(__file__).resolve().parents[1] / "files" / "postgres-backup"
POSTGRES = "ghcr.io/cloudnative-pg/postgresql:18-standard-trixie"
RESTIC = "restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76"
SPECIAL_DATABASE = "name= odd\tline\nend"
PASSWORD = "disposable-integration-repository-password"


def identifier(value):
    return '"' + value.replace('"', '""') + '"'


class PostgresBackupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("docker") is None:
            raise unittest.SkipTest("Docker CLI is unavailable; PostgreSQL backup integration skipped")
        try:
            result = subprocess.run(["docker", "info"], capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            raise unittest.SkipTest("Docker daemon is unavailable; PostgreSQL backup integration skipped")
        if result.returncode:
            raise unittest.SkipTest("Docker daemon is unavailable; PostgreSQL backup integration skipped")

    def run_command(self, args, data=None, success=True, timeout=300):
        result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
        if success and result.returncode:
            self.fail(f"Command {args[0]} failed ({result.returncode}): "
                      + result.stderr.decode(errors="replace")[-2000:])
        return result

    def docker(self, *args, **kwargs):
        return self.run_command(["docker", *args], **kwargs)

    def cleanup_fixtures(self):
        for name in reversed(self.containers):
            subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=60)
        for volume in self.volumes.values():
            subprocess.run(["docker", "volume", "rm", volume], capture_output=True, timeout=60)
        subprocess.run(["docker", "network", "rm", self.network], capture_output=True, timeout=60)

    def setUp(self):
        self.prefix = "postgres-backup-test-" + uuid.uuid4().hex
        self.network = self.prefix + "-network"
        self.containers = []
        self.volumes = {name: self.prefix + "-" + name for name in
                        ("source-data", "destination-data", "staging", "repository", "restore")}
        self.addCleanup(self.cleanup_fixtures)
        self.docker("pull", POSTGRES)
        self.docker("pull", RESTIC)
        self.docker("network", "create", "--internal", self.network)
        for volume in self.volumes.values():
            self.docker("volume", "create", volume)
        self.source = self.start_postgres("source")
        self.destination = self.start_postgres("destination")

    def temporary_container(self, image, options, command, data=None, success=True):
        name = self.prefix + "-run-" + str(len(self.containers))
        self.containers.append(name)
        return self.docker("run", "--rm", "-i", "--name", name, *options,
                           image, *command, data=data, success=success)

    def start_postgres(self, kind):
        mounts = ["-v", self.volumes[kind + "-data"] + ":/pgdata"]
        if kind == "source":
            mounts += ["-v", self.volumes["staging"] + ":/backup"]
        else:
            mounts += ["-v", self.volumes["restore"] + ":/restore:ro"]
        self.temporary_container(
            POSTGRES, ["--user", "0:0", "--entrypoint", "bash", *mounts],
            ["-ceu", "chown 26:102 /pgdata; " +
             ("chown 26:102 /backup; chmod 2770 /backup" if kind == "source" else "true")])
        name = self.prefix + "-" + kind
        self.containers.append(name)
        # Trust applies only inside this unique internal Docker network. Production
        # uses TLS/passwords; these fixtures deliberately have no published ports.
        startup = (
            "initdb -D /pgdata -U postgres --auth-local=trust --auth-host=trust >/dev/null; "
            "printf 'host all all 0.0.0.0/0 trust\\nhost all all ::/0 trust\\n' >> /pgdata/pg_hba.conf; "
            "exec postgres -D /pgdata -c listen_addresses='*'"
        )
        self.docker("run", "-d", "--name", name, "--network", self.network,
                    "--user", "26:102", "--cap-drop=ALL", "--entrypoint", "bash",
                    *mounts, POSTGRES, "-ceu", startup)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.docker("exec", name, "pg_isready", "-U", "postgres", "-d", "postgres",
                           success=False).returncode == 0:
                return name
            time.sleep(0.25)
        self.fail("Disposable PostgreSQL fixture did not become ready")

    def sql(self, container, statement, database="postgres", user="postgres", success=True):
        return self.docker("exec", "-i", "-e", "PGDATABASE=" + database,
                           container, "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-U", user,
                           data=statement.encode(), success=success)

    def dump(self, user="controller", success=True):
        return self.docker("exec", "-i", "--user", "26:102", "-e", "PGHOST=" + self.source,
                           "-e", "PGPORT=5432", "-e", "PGUSER=" + user,
                           "-e", "PGDATABASE=postgres", "-e", "PGSSLMODE=disable",
                           self.source, "bash", "-s", data=(SCRIPTS / "dump.sh").read_bytes(),
                           success=success)

    def restic(self, *command, password=PASSWORD, upload=False, success=True, data=None):
        options = ["--group-add", "102", "--network", self.network,
                   "-v", self.volumes["staging"] + ":/backup:ro",
                   "-v", self.volumes["repository"] + ":/mnt/backup",
                   "-v", self.volumes["restore"] + ":/restore",
                   "-e", "RESTIC_REPOSITORY=/mnt/backup/postgres-logical",
                   "-e", "RESTIC_PASSWORD=" + password]
        if upload:
            return self.temporary_container(
                RESTIC, ["--cap-drop=ALL", *options, "--entrypoint", "/bin/sh"], ["-s"],
                data=(SCRIPTS / "upload.sh").read_bytes(), success=success)
        return self.temporary_container(RESTIC, options, ["--no-cache", *command],
                                        data=data, success=success)

    def snapshots(self):
        return json.loads(self.restic("snapshots", "--json").stdout)

    def generation_hashes(self):
        return self.docker("exec", self.source, "bash", "-ceu",
                           "cd /backup; find current -type f -exec sha256sum {} + | sort").stdout

    def test_backup_restore_and_failures(self):
        self.sql(self.source, """
            CREATE ROLE controller SUPERUSER LOGIN;
            CREATE ROLE app_owner NOLOGIN;
            CREATE ROLE app_reader LOGIN;
            GRANT app_owner TO app_reader WITH INHERIT FALSE;
            CREATE SCHEMA app AUTHORIZATION app_owner;
            SET ROLE app_owner;
            CREATE TABLE app.payload (id bigserial PRIMARY KEY, payload text NOT NULL);
            INSERT INTO app.payload(payload) SELECT repeat(md5(i::text), 16)
                FROM generate_series(1, 16384) AS i;
            INSERT INTO app.payload(payload) VALUES (E'line one\\nline two\\tquote''');
            GRANT USAGE ON SCHEMA app TO app_reader;
            GRANT SELECT ON app.payload TO app_reader;
            GRANT USAGE ON SEQUENCE app.payload_id_seq TO app_reader;
            RESET ROLE;
            SELECT lo_from_bytea(12345, decode('000102ff7061796c6f6164', 'hex'));
            ALTER LARGE OBJECT 12345 OWNER TO app_owner;
            GRANT SELECT ON LARGE OBJECT 12345 TO app_reader;
        """)
        self.sql(self.source, "CREATE DATABASE " + identifier(SPECIAL_DATABASE) + " OWNER app_owner;")
        self.sql(self.source, "CREATE TABLE special_payload(value text); "
                 "INSERT INTO special_payload VALUES ('special database payload'); "
                 "ALTER TABLE special_payload OWNER TO app_owner;", database=SPECIAL_DATABASE)
        observations = """
            SELECT json_build_object(
                'rows', (SELECT count(*) FROM app.payload),
                'digest', (SELECT md5(string_agg(payload, '' ORDER BY id)) FROM app.payload),
                'owner', (SELECT tableowner FROM pg_tables WHERE schemaname='app' AND tablename='payload'),
                'sequence', (SELECT last_value FROM app.payload_id_seq),
                'large_object', encode(lo_get(12345), 'hex'),
                'large_object_owner', (SELECT pg_get_userbyid(lomowner) FROM pg_largeobject_metadata WHERE oid=12345),
                'grantor', (SELECT pg_get_userbyid(grantor) FROM pg_auth_members
                    WHERE roleid='app_owner'::regrole AND member='app_reader'::regrole),
                'inherit', (SELECT inherit_option FROM pg_auth_members
                    WHERE roleid='app_owner'::regrole AND member='app_reader'::regrole));
        """
        expected = json.loads(self.sql(self.source, observations).stdout)
        self.assertEqual(expected["grantor"], "postgres")
        self.assertFalse(expected["inherit"])
        self.dump()
        self.restic(upload=True)
        first = self.snapshots()
        self.assertEqual(len(first), 1)

        # An interrupted writer can leave unreferenced packs even when no
        # retained snapshot expires. Successful backups must reclaim them.
        packs_before = set(self.restic("list", "packs").stdout.splitlines())
        self.restic("backup", "--stdin", "--stdin-filename", "orphan-fixture",
                    data=random.Random(7).randbytes(1024 * 1024))
        orphan = next(item["id"] for item in self.snapshots() if item["id"] != first[0]["id"])
        orphan_packs = set(self.restic("list", "packs").stdout.splitlines()) - packs_before
        self.restic("forget", orphan)

        # Recreate archives rather than merely snapshot unchanged files. Native
        # dump timestamps may change, but most uncompressed data must deduplicate.
        self.dump()
        self.restic(upload=True)
        snapshots = self.snapshots()
        latest = max(snapshots, key=lambda item: item["time"])
        summary = latest["summary"]
        self.assertLess(summary["data_added"] / summary["total_bytes_processed"], 0.35)
        self.assertTrue(orphan_packs.isdisjoint(
            set(self.restic("list", "packs").stdout.splitlines())))

        before_failure = self.generation_hashes()
        self.assertNotEqual(self.dump(user="missing_backup_role", success=False).returncode, 0)
        self.assertEqual(self.generation_hashes(), before_failure)
        self.docker("exec", self.source, "bash", "-ceu", "test ! -e /backup/work/complete")
        ids = sorted(item["id"] for item in snapshots)
        self.assertNotEqual(self.restic(upload=True, password="wrong-fixture-password",
                                        success=False).returncode, 0)
        self.assertEqual(sorted(item["id"] for item in self.snapshots()), ids)

        # Recover from the encrypted repository into a separate volume, not from
        # the original staging archive or from the live server's data directory.
        self.restic("restore", latest["id"], "--target", "/restore")
        self.sql(self.destination, "CREATE ROLE homeit7_recovery_admin SUPERUSER LOGIN; "
                 "CREATE DATABASE recovery_control OWNER homeit7_recovery_admin;")
        with tempfile.TemporaryDirectory(prefix="postgres-backup-artifacts-") as temporary:
            backup = Path(temporary) / "current"
            self.docker("cp", self.destination + ":/restore/backup/current", str(backup))
            prepared = Path(temporary) / "prepared.sql"
            self.run_command([sys.executable, str(SCRIPTS / "prepare-restore.py"),
                              str(backup), str(prepared)])
            prepared_sql = prepared.read_bytes()
            self.sql(self.destination, "CREATE ROLE restore_guard_sentinel; "
                     "ALTER ROLE postgres RENAME TO incorrect_bootstrap;",
                     database="recovery_control", user="homeit7_recovery_admin")
            mismatched = self.docker(
                "exec", "-i", self.destination, "psql", "-X", "-U", "homeit7_recovery_admin",
                "-d", "recovery_control", data=prepared_sql, success=False)
            self.assertNotEqual(mismatched.returncode, 0)
            roles = self.sql(self.destination, "SELECT rolname FROM pg_roles ORDER BY rolname;",
                             database="recovery_control", user="homeit7_recovery_admin").stdout
            self.assertIn(b"restore_guard_sentinel", roles)
            self.assertNotIn(b"app_owner", roles)
            self.sql(self.destination, "ALTER ROLE incorrect_bootstrap RENAME TO postgres; "
                     "DROP ROLE restore_guard_sentinel;", database="recovery_control",
                     user="homeit7_recovery_admin")

            original_globals = (backup / "globals.sql").read_bytes()
            (backup / "globals.sql").write_bytes(original_globals + b"\nCREATE ROLE postgres;\n")
            refused_output = Path(temporary) / "ambiguous.sql"
            ambiguous = self.run_command(
                [sys.executable, str(SCRIPTS / "prepare-restore.py"), str(backup), str(refused_output)],
                success=False)
            self.assertNotEqual(ambiguous.returncode, 0)
            self.assertFalse(refused_output.exists())

            self.docker("exec", "-i", self.destination, "psql", "-X", "-v", "ON_ERROR_STOP=1",
                        "-U", "homeit7_recovery_admin", "-d", "recovery_control", data=prepared_sql)
            records = (backup / "databases.list").read_bytes().split(b"\0")
            names = []
            for record in records:
                if not record:
                    continue
                oid, name = record.split(b"\t", 1)
                self.assertTrue(oid.isdigit())
                names.append(name.decode())
                self.docker("exec", self.destination, "pg_restore", "--exit-on-error", "--clean",
                            "--if-exists", "--create", "--username=homeit7_recovery_admin",
                            "--dbname=recovery_control", "/restore/backup/current/databases/" + oid.decode())
            self.assertIn("postgres", names)
            self.assertIn(SPECIAL_DATABASE, names)

        self.assertEqual(json.loads(self.sql(self.destination, observations).stdout), expected)
        self.assertEqual(self.sql(self.destination, "SELECT value FROM special_payload;",
                                  database=SPECIAL_DATABASE).stdout.strip(), b"special database payload")
        self.assertEqual(self.sql(self.destination, "SELECT count(*) FROM app.payload;",
                                  user="app_reader").stdout.strip(), b"16385")
        self.assertEqual(self.sql(self.destination, "SELECT nextval('app.payload_id_seq');",
                                  user="app_reader").stdout.strip(), b"16386")
        self.assertEqual(self.sql(self.destination, "SELECT encode(lo_get(12345), 'hex');",
                                  user="app_reader").stdout.strip(), b"000102ff7061796c6f6164")
        denied = self.sql(self.destination, "INSERT INTO app.payload(payload) VALUES ('denied');",
                          user="app_reader", success=False)
        self.assertNotEqual(denied.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
