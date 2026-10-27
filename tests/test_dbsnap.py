#!/usr/bin/env python3
"""Offline tests for scripts/dbsnap: URL parsing, the local-only guard and an
end-to-end SQLite snapshot/restore through the CLI. Nothing here connects to a
database server or to the network; listeners, DNS and Docker are faked.

    python3 tests/test_dbsnap.py
"""
import importlib.machinery, importlib.util, ipaddress, json, os, sqlite3, subprocess, sys, tempfile, types, unittest

sys.dont_write_bytecode = True
HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "dbsnap")
_loader = importlib.machinery.SourceFileLoader("dbsnap", HELPER)
_spec = importlib.util.spec_from_loader("dbsnap", _loader)
d = importlib.util.module_from_spec(_spec)
_loader.exec_module(d)

ME = os.getuid()
IP = ipaddress.ip_address


def spec(url, base="/nonexistent"):
    return d.parse_url(url, base)


class FakeDocker:
    def __init__(self, containers=(), ep="unix:///var/run/docker.sock"):
        self.ep, self._c, self.reason = ep, list(containers), ""

    def containers(self):
        return self._c

    def by_name(self, h):
        return next((c for c in self._c if h in c.names), None)

    def by_ip(self, ip):
        return next((c for c in self._c if ip in c.ips), None)

    def by_port(self, port):
        return next((c for c in self._c if port in c.ports), None)


def container(name, image, ips=(), ports=None, cid="ab" * 32):
    return types.SimpleNamespace(id=cid, name=name, image=image, engine=d.image_engine(image), env={},
                                 names={name}, ips={IP(i) for i in ips}, ports=ports or {})


def ctx(listeners=(), procs=None, dns=None, docker=None):
    """A Ctx whose view of the machine is entirely made up."""
    s = dict(d.DEFAULTS, docker=False)
    c = d.Ctx(s)
    c.listeners = lambda: [(IP(ip), port, uid, inode) for ip, port, uid, inode in listeners]
    c.socket_process = lambda inode: (procs or {}).get(inode)
    c.resolve = lambda h: (dns or {}).get(h)
    c.prefetch = lambda hosts: None
    c.docker = docker or FakeDocker([], ep=None)
    return c


USERS = {ME: "me", 0: "root", 70: "postgres", 971: "mysql", 1234: "someone"}


class GuardTest(unittest.TestCase):
    def setUp(self):
        self._username = d.username
        d.username = lambda uid: USERS.get(uid, str(uid))

    def tearDown(self):
        d.username = self._username

    def local(self, url, c):
        v = d.classify(spec(url), c)
        return v

    # --- plain cases
    def test_loopback_served_by_system_postgres(self):
        v = self.local("postgres://u:p@127.0.0.1:5432/app", ctx([("127.0.0.1", 5432, 70, "1")]))
        self.assertTrue(v["local"])
        self.assertEqual((v["via"], v["addr"]), ("tcp", "127.0.0.1"))

    def test_localhost_is_pinned_to_the_address_with_a_server(self):
        c = ctx([("127.0.0.1", 5432, 70, "1")], dns={"localhost": [IP("127.0.0.1"), IP("::1")]})
        v = self.local("postgres://u@localhost/app", c)
        self.assertTrue(v["local"])
        self.assertEqual(v["addr"], "127.0.0.1")

    def test_whole_127_8_is_loopback(self):
        v = self.local("postgres://u@127.0.0.2/app", ctx([("0.0.0.0", 5432, 70, "1")]))
        self.assertTrue(v["local"])

    def test_ipv4_mapped_loopback(self):
        v = self.local("postgres://u@[::ffff:127.0.0.1]:5432/app", ctx([("127.0.0.1", 5432, 70, "1")]))
        self.assertTrue(v["local"])

    def test_own_mariadb_process(self):
        c = ctx([("127.0.0.1", 3306, ME, "9")], procs={"9": (42, "mariadbd")})
        self.assertTrue(self.local("mysql://u:p@127.0.0.1:3306/app", c)["local"])

    def test_stopped_server_is_local_but_not_ready(self):
        v = self.local("postgres://u@127.0.0.1:5432/app", ctx([]))
        self.assertTrue(v["local"])
        self.assertFalse(v["listening"])

    # --- remote hosts
    def test_public_ip_literal(self):
        self.assertFalse(self.local("mysql://root:x@198.51.100.20:3306/db", ctx())["local"])
        self.assertFalse(self.local("postgresql://x:y@198.51.100.21:27923/db", ctx())["local"])

    def test_unspecified_and_lan_addresses(self):
        for h in ("0.0.0.0", "192.168.1.20", "10.0.0.5", "[::]", "[fe80::1]"):
            self.assertFalse(self.local(f"postgres://u@{h}:5432/app", ctx([("0.0.0.0", 5432, 70, "1")]))["local"], h)

    def test_hosted_providers_need_no_dns(self):
        calls = []
        c = ctx()
        c.resolve = lambda h: calls.append(h) or [IP("127.0.0.1")]
        for url in ("postgresql://postgres.abc:x@aws-0-us-west-1.pooler.supabase.com:6543/postgres?pgbouncer=true",
                    "postgresql://postgres:x@db.abcdefgh.supabase.co:5432/postgres",
                    "postgres://u:x@ep-cool-1.us-east-2.aws.neon.tech/neondb?sslmode=require",
                    "mysql://u:x@aws.connect.psdb.cloud/db?sslaccept=strict",
                    "postgres://u:x@mydb.abc123.eu-west-1.rds.amazonaws.com:5432/app"):
            self.assertFalse(self.local(url, c)["local"], url)
        self.assertEqual(calls, [])

    def test_name_resolving_to_a_public_address(self):
        c = ctx([("127.0.0.1", 5432, 70, "1")], dns={"db.example.com": [IP("203.0.113.7")]})
        self.assertFalse(self.local("postgres://u@db.example.com/app", c)["local"])

    def test_name_resolving_to_loopback_and_public_mix(self):
        c = ctx([("127.0.0.1", 5432, 70, "1")], dns={"sneaky.example": [IP("127.0.0.1"), IP("203.0.113.7")]})
        self.assertFalse(self.local("postgres://u@sneaky.example/app", c)["local"])

    def test_name_resolving_to_loopback_only(self):
        c = ctx([("127.0.0.1", 5432, 70, "1")], dns={"devbox.localhost": [IP("127.0.0.1")]})
        v = self.local("postgres://u@devbox.localhost/app", c)
        self.assertTrue(v["local"])
        self.assertEqual(v["addr"], "127.0.0.1")

    def test_unresolvable_name(self):
        self.assertFalse(self.local("postgres://u@db/app", ctx())["local"])

    def test_query_host_overrides_authority(self):
        c = ctx([("127.0.0.1", 5432, 70, "1")])
        self.assertFalse(self.local("postgresql:///app?host=db.abcd.supabase.co", c)["local"])
        self.assertFalse(self.local("postgresql://localhost/app?hostaddr=203.0.113.9", c)["local"])

    def test_multi_host_and_service_urls(self):
        c = ctx([("127.0.0.1", 5432, 70, "1")])
        self.assertFalse(self.local("postgres://u@127.0.0.1:5432,203.0.113.7:5432/app", c)["local"])
        self.assertFalse(self.local("postgres://u@127.0.0.1/app?service=prod", c)["local"])

    # --- tunnels and proxies on a loopback port
    def test_ssh_tunnel_is_refused(self):
        c = ctx([("127.0.0.1", 5433, ME, "7")], procs={"7": (99, "ssh")})
        v = self.local("postgres://u@127.0.0.1:5433/app", c)
        self.assertFalse(v["local"])
        self.assertIn("ssh", v["reason"])

    def test_other_proxies_are_refused(self):
        for comm in ("kubectl", "socat", "cloud-sql-proxy", "pgbouncer", "autossh", "python3"):
            c = ctx([("127.0.0.1", 6432, ME, "7")], procs={"7": (99, comm)}, dns={"localhost": [IP("127.0.0.1")]})
            self.assertFalse(self.local("postgres://u@localhost:6432/app", c)["local"], comm)

    def test_unidentifiable_own_listener_is_refused(self):
        self.assertFalse(self.local("postgres://u@127.0.0.1:5432/app", ctx([("127.0.0.1", 5432, ME, "7")]))["local"])

    def test_root_listener_without_container_is_refused(self):
        self.assertFalse(self.local("postgres://u@127.0.0.1:5432/app", ctx([("0.0.0.0", 5432, 0, "1")]))["local"])

    def test_listener_of_another_user_is_refused(self):
        self.assertFalse(self.local("postgres://u@127.0.0.1:5432/app", ctx([("127.0.0.1", 5432, 1234, "1")]))["local"])

    def test_wildcard_v6_listener_owned_by_ssh_wins_over_nothing(self):
        c = ctx([("::", 5432, ME, "7")], procs={"7": (99, "ssh")})
        self.assertFalse(self.local("postgres://u@127.0.0.1/app", c)["local"])

    # --- docker
    def test_published_port_of_a_database_container(self):
        dk = FakeDocker([container("pg", "postgres:16", ports={5433: 5432})])
        c = ctx([("0.0.0.0", 5433, 0, "1")], docker=dk)
        self.assertTrue(self.local("postgres://u@127.0.0.1:5433/app", c)["local"])

    def test_published_port_of_a_proxy_container_is_refused(self):
        dk = FakeDocker([container("proxy", "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2", ports={5433: 5432})])
        c = ctx([("0.0.0.0", 5433, 0, "1")], docker=dk)
        self.assertFalse(self.local("postgres://u@127.0.0.1:5433/app", c)["local"])

    def test_container_name_and_ip(self):
        dk = FakeDocker([container("db", "postgres:16-alpine", ips=["172.18.0.2"])])
        v = self.local("postgres://u:p@db:5432/app", ctx(docker=dk))
        self.assertEqual((v["local"], v["via"]), (True, "docker"))
        self.assertTrue(self.local("postgres://u:p@172.18.0.2:5432/app", ctx(docker=dk))["local"])
        self.assertFalse(self.local("postgres://u:p@172.18.0.9:5432/app", ctx(docker=dk))["local"])

    def test_container_with_wrong_engine_or_image(self):
        dk = FakeDocker([container("db", "mysql:8"), container("proxy", "alpine/socat")])
        self.assertFalse(self.local("postgres://u:p@db/app", ctx(docker=dk))["local"])
        self.assertFalse(self.local("postgres://u:p@proxy/app", ctx(docker=dk))["local"])

    def test_remote_docker_daemon_is_not_used(self):
        old = os.environ.get("DOCKER_HOST")
        try:
            for ep in ("tcp://203.0.113.5:2375", "ssh://me@buildbox"):
                os.environ["DOCKER_HOST"] = ep
                dk = d.Docker(True, ctx())
                self.assertIsNone(dk.ep, ep)
                self.assertIn("isn't this machine", dk.reason)
        finally:
            if old is None:
                os.environ.pop("DOCKER_HOST", None)
            else:
                os.environ["DOCKER_HOST"] = old

    def test_image_engines(self):
        self.assertEqual(d.image_engine("postgres:16"), "postgres")
        self.assertEqual(d.image_engine("supabase/postgres:15.1"), "postgres")
        self.assertEqual(d.image_engine("registry.local:5000/bitnami/postgresql@sha256:abc"), "postgres")
        self.assertEqual(d.image_engine("mariadb:11"), "mysql")
        self.assertEqual(d.image_engine("prom/mysqld-exporter"), "")
        self.assertEqual(d.image_engine("edoburu/pgbouncer"), "")

    # --- sockets
    def test_socket_must_be_a_database_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            import socket as so
            path = os.path.join(tmp, "mysql.sock")
            s = so.socket(so.AF_UNIX)
            s.bind(path)
            s.listen()
            try:
                c = ctx()
                c.unix_inode = lambda p: "5"
                c.socket_process = lambda i: (1, "ssh")
                self.assertFalse(d.classify(spec(f"mysql://u@localhost/app?socket={path}"), c)["local"])
                c.socket_process = lambda i: (1, "mariadbd")
                self.assertTrue(d.classify(spec(f"mysql://u@localhost/app?socket={path}"), c)["local"])
            finally:
                s.close()

    def test_sqlite_on_network_fs(self):
        sp = {"engine": "sqlite", "path": "/mnt/share/app.db", "db": "app.db", "port": 0, "host": ""}
        old = d.fs_type
        try:
            d.fs_type = lambda p: "fuse.sshfs"
            self.assertFalse(d.classify(sp, ctx())["local"])
            d.fs_type = lambda p: "btrfs"
            self.assertTrue(d.classify(sp, ctx())["local"])
        finally:
            d.fs_type = old

    # --- the last check before a tool runs
    def test_assert_local_refuses_a_tampered_target(self):
        t = {"id": "x:app", "local": True, "engine": "postgres", "db": "app", "port": 5432,
             "_conn": {"local": True, "via": "tcp", "addr": "203.0.113.7", "reason": ""}}
        with self.assertRaises(d.Fail):
            d.assert_local(t)
        t["_conn"]["addr"] = "127.0.0.1"
        d.assert_local(t)
        t["db"] = "host=203.0.113.7 dbname=app"
        with self.assertRaises(d.Fail):
            d.assert_local(t)


class ParseTest(unittest.TestCase):
    def test_bad_ports_raise_instead_of_crashing(self):
        with self.assertRaises(ValueError):
            spec("postgres://u:p@localhost:${DB_PORT}/app")
        with self.assertRaises(ValueError):
            spec("postgres://u:p@localhost:99999/app")

    def test_fields(self):
        s = spec("postgresql+asyncpg://us%40er:p%3Ass@LocalHost:5433/my_db?sslmode=disable")
        self.assertEqual((s["engine"], s["user"], s["password"], s["host"], s["port"], s["db"]),
                         ("postgres", "us@er", "p:ss", "localhost", 5433, "my_db"))
        self.assertEqual(spec("jdbc:mysql://h:3307/x")["port"], 3307)
        self.assertEqual(spec("postgresql://%2Frun%2Fpostgresql/app")["host"], "/run/postgresql")
        self.assertEqual(spec("postgres://[::1]:5432/app")["host"], "::1")
        self.assertEqual(spec("mysql://u@localhost/app?socket=/run/mysqld/mysqld.sock")["socket"], "/run/mysqld/mysqld.sock")
        self.assertIsNone(spec("redis://localhost:6379/0"))
        self.assertIsNone(spec("https://abc.supabase.co"))

    def test_sqlite_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "prisma"))
            db = os.path.join(tmp, "prisma", "dev.db")
            sqlite3.connect(db).execute("create table t(x)").connection.close()
            self.assertEqual(spec("file:./dev.db", tmp)["path"], os.path.realpath(db))
            self.assertEqual(spec(f"sqlite:///{db}", "/")["path"], os.path.realpath(db))
            self.assertIsNone(spec("file:./missing.db", tmp))
            self.assertIsNone(spec("sqlite::memory:", tmp))

    def test_env_parsing_and_expansion(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, ".env")
            with open(p, "w") as f:
                f.write("export DB_USER=app\nDB_PORT=5433 # comment\nDB_PASS='p$ss'\n"
                        "DATABASE_URL=\"postgres://${DB_USER}:${DB_PASS}@localhost:${DB_PORT}/shop\"\n"
                        "# DATABASE_URL=mysql://root:x@198.51.100.20/prod\n")
            env = d.parse_env(p)
            self.assertNotIn("# DATABASE_URL", env)
            url = d.expand(env["DATABASE_URL"][0], env)
            self.assertEqual(url, "postgres://app:p$ss@localhost:5433/shop")

    def test_clean_env(self):
        old = dict(os.environ)
        try:
            os.environ.update({"PGHOSTADDR": "203.0.113.1", "PGSERVICE": "prod", "MYSQL_HOST": "x", "DOCKER_HOST": "tcp://x"})
            env = d.clean_env({"PGPASSWORD": "pw"})
            for k in ("PGHOSTADDR", "PGSERVICE", "MYSQL_HOST", "DOCKER_HOST"):
                self.assertNotIn(k, env)
            self.assertEqual(env["PGPASSWORD"], "pw")
        finally:
            os.environ.clear()
            os.environ.update(old)

    def test_client_is_pinned_to_the_verified_address(self):
        t = {"engine": "postgres", "port": 5432, "_spec": {"user": "u", "password": "pw"},
             "_conn": {"via": "tcp", "addr": "127.0.0.1"}}
        if d.find_tool(["pg_dump"], d.DEFAULTS) and d.find_tool(["psql"], d.DEFAULTS):
            argv, env = d.tool_cmd(t, "dump", "app")
            self.assertEqual(argv[argv.index("-h") + 1], "127.0.0.1")
            self.assertEqual(argv[-2:], ["-d", "app"])
            self.assertNotIn("pw", " ".join(argv))
        t = {"engine": "mysql", "port": 3306, "_spec": {"user": "u", "password": "pw"},
             "_conn": {"via": "tcp", "addr": "127.0.0.1"}}
        if d.find_tool(["mariadb-dump", "mysqldump"], d.DEFAULTS):
            argv, env = d.tool_cmd(t, "dump", "app")
            self.assertEqual(argv[1], "--no-defaults")
            self.assertIn("--protocol=TCP", argv)
            self.assertEqual(env["MYSQL_PWD"], "pw")

    def test_docker_commands_keep_passwords_off_the_command_line(self):
        ep = "unix:///var/run/docker.sock"
        dk = types.SimpleNamespace(ep=ep, cmd=lambda *a: ["docker", "-H", ep, *a])
        for eng in ("postgres", "mysql"):
            t = {"engine": eng, "port": 5432, "_spec": {"user": "u", "password": "s3cr3t"},
                 "_conn": {"via": "docker", "addr": "ab" * 32}, "_docker": dk}
            for which in ("dump", "load"):
                argv, env = d.tool_cmd(t, which, "app")
                self.assertEqual(argv[:5], ["docker", "-H", ep, "exec", "-i"])
                self.assertNotIn("s3cr3t", " ".join(argv))
                self.assertIn("s3cr3t", env.values())


class CliSqliteTest(unittest.TestCase):
    """snapshot -> change -> restore -> copy -> prune -> delete, through the real CLI."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.proj = os.path.join(t, "projects", "shop")
        os.makedirs(os.path.join(self.proj, "prisma"))
        self.db = os.path.join(self.proj, "prisma", "dev.db")
        con = sqlite3.connect(self.db)
        con.executescript("create table items(id integer primary key, name text); insert into items(name) values ('a'), ('b');")
        con.close()
        with open(os.path.join(self.proj, ".env"), "w") as f:
            f.write("DATABASE_URL=file:./dev.db\nDIRECT_URL=postgres://x:s3cr3t-PW@203.0.113.50:5432/prod\n")
        self.conf = os.path.join(t, "dbsnap.json")
        with open(self.conf, "w") as f:
            json.dump({"roots": [os.path.join(t, "projects")], "docker": False, "localServers": False, "keep": 2}, f)
        # Own HOME: even the default settings never look at the real projects.
        self.env = dict(os.environ, HOME=t, DBSNAP_CONFIG=self.conf, DBSNAP_STORE=os.path.join(t, "store"),
                        OMARCHY_NO_NOTIFY="1", PYTHONDONTWRITEBYTECODE="1")

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args, ok=True):
        r = subprocess.run([sys.executable, HELPER, *args], env=self.env, capture_output=True, text=True, timeout=60)
        out = json.loads(r.stdout)
        if ok:
            self.assertEqual(r.returncode, 0, (args, r.stdout, r.stderr))
        else:
            self.assertNotEqual(r.returncode, 0, (args, r.stdout))
        return out

    def rows(self, path=None):
        con = sqlite3.connect(path or self.db)
        try:
            return [r[0] for r in con.execute("select name from items order by id")]
        finally:
            con.close()

    def test_round_trip(self):
        listing = self.cli("list")
        ids = {t["id"]: t for t in listing["targets"]}
        self.assertIn("shop:dev.db", ids)
        self.assertTrue(ids["shop:dev.db"]["ready"])
        remote = [t for t in listing["targets"] if not t["local"]]
        self.assertEqual(len(remote), 1)
        self.assertNotIn("s3cr3t", json.dumps(listing))  # passwords are never printed

        # remote targets are refused for every action
        self.assertIn("not on this machine", self.cli("snapshot", remote[0]["id"], ok=False)["error"])

        snap = self.cli("snapshot", "shop:dev.db", "before", "migration")["file"]
        self.assertTrue(snap.endswith("_before-migration.sqlite.gz"))
        con = sqlite3.connect(self.db)
        con.executescript("delete from items; create table extra(x); insert into items(name) values ('zzz');")
        con.close()

        self.assertIn("--yes", self.cli("restore", snap, ok=False)["error"])
        self.assertEqual(self.rows(), ["zzz"])
        res = self.cli("restore", snap, "--yes")
        self.assertEqual(self.rows(), ["a", "b"])
        con = sqlite3.connect(self.db)
        self.assertEqual(con.execute("select count(*) from sqlite_master where name='extra'").fetchone()[0], 0)
        con.close()
        self.assertTrue(os.path.exists(res["safety"]))

        copy = self.cli("restore", res["safety"], "--yes", "--copy")
        copy_path = copy["into"].replace("~", self.tmp.name, 1)
        self.assertEqual(self.rows(copy_path), ["zzz"])
        self.assertEqual(self.rows(), ["a", "b"])

        # keep=2: plain snapshots beyond the newest two go; the noted one stays
        for _ in range(3):
            self.cli("snapshot", "shop:dev.db")
        snaps = [s for s in self.cli("list")["snapshots"] if s["id"] == "shop:dev.db"]
        self.assertEqual(sum(1 for s in snaps if not s["kept"]), 2)
        self.assertEqual([s["note"] for s in snaps if s["kept"]], ["before migration"])

        # delete refuses anything outside the store
        self.assertIn("Not a dbsnap snapshot", self.cli("delete", self.db, ok=False)["error"])
        self.cli("delete", snap)
        self.assertFalse(os.path.exists(snap))

    def test_bad_env_and_settings_do_not_break_list(self):
        bad = os.path.join(self.tmp.name, "projects", "broken")
        os.makedirs(bad)
        with open(os.path.join(bad, ".env"), "w") as f:
            f.write("DATABASE_URL=postgres://u:p@localhost:${DB_PORT}/app\nDIRECT_URL=postgres://u@h1:5432,h2:5432/app\n")
        listing = self.cli("list")
        self.assertIn("shop:dev.db", [t["id"] for t in listing["targets"]])
        self.assertEqual(len(listing["errors"]), 1)
        self.assertIn("DB_PORT", listing["errors"][0])
        multi = [t for t in listing["targets"] if t["project"] == "broken"]
        self.assertEqual([t["local"] for t in multi], [False])
        with open(self.conf, "w") as f:
            f.write("{ not json")
        listing = self.cli("list")  # falls back to the defaults and says why
        self.assertIn("could not be read", listing["errors"][0])

    def test_check_never_needs_a_server(self):
        out = self.cli("check", "postgres://u:pw@198.51.100.7:5432/app")
        self.assertFalse(out["local"])
        self.assertIn("loopback", out["reason"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
