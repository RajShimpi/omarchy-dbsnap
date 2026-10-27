# DB Snapshots

One-click snapshots of your projects' local databases before a risky
migration, and a restore that asks first and keeps a safety copy. Works with
PostgreSQL, MySQL/MariaDB and SQLite. Databases that live anywhere else are
listed so you can see them, but DB Snapshots never connects to them.

Plugin id: `techspawn.dbsnap`

## What it does

- **Bar:** a database icon. It turns into a clock while a snapshot or
  restore started from the panel is running.
- **Panel:** every local database it found, grouped under *Projects*,
  *Docker containers* and *Other databases on this machine*. Each card shows
  where the database is (`localhost:5432`, a socket, a container or a file)
  and which setting it came from. Its snapshots are listed underneath with
  age, note and size.
- **Snapshot** dumps the database into a compressed file. To label it, type a
  note first, e.g. "before payments migration". Press `n` to jump to the note
  box.
- **Restore** asks you to confirm, saves a *before restore* snapshot of the
  current data, then puts the snapshot back. See [Restoring](#restoring).
- **Restore into a new database** (the second button) creates
  `<name>_restored_<date>` next to the original and leaves the original
  alone. For SQLite it makes a new file.
- **Delete** needs two clicks.
- **Keeps the newest 10 per database.** After each snapshot, older ones are
  pruned. Snapshots with a note are never pruned. The number is a setting.
- If a snapshot's database can't be found right now (the project moved, the
  container is stopped), the snapshot is listed separately and can still be
  deleted.
- Problems appear on the card, for example a missing `pg_dump` or a stopped
  server. Settings that can't be read, like a malformed URL in an `.env`,
  are listed at the bottom.

With two monitors there are two bars. They share a lock, so only one
snapshot or restore runs at a time, and both panels show what is running.

## Safety: local databases only

Project `.env` files often point at staging or production databases. DB
Snapshots only dumps or restores a database that it can show is on this
machine:

- **A Unix socket** served by a PostgreSQL, MySQL or MariaDB server process,
  or owned by the system `postgres` or `mysql` user.
- **A loopback address** (`127.0.0.0/8` or `::1`). Host names are resolved
  and every address they resolve to must be loopback. The client tools then
  get the checked IP address, never the name, so DNS can't change the answer
  later. The program listening on the port must also be a database server:
  `postgres`, `mysqld` or `mariadbd`, the system database user, or Docker
  publishing a port of a PostgreSQL/MySQL/MariaDB container. An SSH tunnel
  (`ssh -L`), `kubectl port-forward`, `socat`, a cloud SQL proxy or PgBouncer
  on a local port can forward anywhere, so they are refused.
- **A container on the local Docker daemon**, found by name, Compose service
  name or container IP, that runs a PostgreSQL/MySQL/MariaDB image. Docker
  support switches itself off if `DOCKER_HOST` or the current Docker context
  points at `tcp://` or `ssh://`.
- **A SQLite file** on a local disk. Files on NFS, SMB, sshfs and similar
  are refused.

Everything else is listed under *not on this machine* with the reason, and
every action on it is refused. That includes other machines and LAN
addresses, hosted services (Supabase, Neon, PlanetScale, RDS and so on),
names that don't resolve, failover URLs with several hosts,
`pg_service.conf` entries, and URLs whose `?host=` or `hostaddr=` points
somewhere else.

The check runs again right before every snapshot and restore, and once more
on the exact address handed to the client tool. In addition:

- `PG*`, `MYSQL*` and `DOCKER_*` environment variables are removed before the
  client tools run, so `PGHOSTADDR` or `PGSERVICE` can't redirect them.
  `psql` ignores `~/.psqlrc`, and the MySQL tools ignore option files such as
  `~/.my.cnf`.
- Database and user names with unusual characters are never passed to the
  tools.
- Passwords reach the tools through `PGPASSWORD` and `MYSQL_PWD`, never on
  the command line, and are never printed or shown.

## Restoring

1. You confirm in a dialog. *Cancel* is selected, and `Esc` cancels.
2. A *before restore* snapshot of the current data is saved.
3. The snapshot goes back in:
   - **PostgreSQL:** in a single transaction. First everything that you can
     drop is dropped (tables, views, sequences, functions and types, but not
     extension objects), including anything created after the snapshot, such
     as tables from a newer migration. Then the snapshot is loaded. If
     anything fails, the whole restore is rolled back and the database is
     unchanged. If an app keeps a lock for more than 15 seconds the restore
     stops and nothing changes: stop the dev server and try again.
   - **MySQL/MariaDB:** the tables and views are dropped, then the snapshot
     is loaded. MySQL can't do this in one transaction, so if it fails
     halfway, the *before restore* snapshot holds your previous data.
   - **SQLite:** SQLite's backup API copies the snapshot into the file in one
     step.

Restoring into a new database needs permission to create databases
(`CREATEDB` in PostgreSQL, `CREATE` in MySQL).

## Install

```bash
omarchy plugin add https://github.com/RajShimpi/omarchy-dbsnap
omarchy bar put techspawn.dbsnap
```

You can also use **Install plugin** in the Omarchy menu with the repository
URL.

## Remove

```bash
omarchy plugin remove techspawn.dbsnap
```

Your snapshots stay in `~/.local/share/omarchy-dbsnap/`, one folder per
project and database. Removing the plugin doesn't touch them. To delete them
and the settings too:

```bash
rm -rf ~/.local/share/omarchy-dbsnap ~/.config/omarchy/dbsnap.json
```

## Settings

Click the pencil in the panel. The first time, this creates
`~/.config/omarchy/dbsnap.json` with the defaults and opens it in your
editor. The plugin never writes that file otherwise. Missing keys use these
defaults:

```json
{
  "roots": ["~/Projects", "~/projects", "~/Work", "~/work", "~/Code", "~/code", "~/src", "~/dev", "~/repos"],
  "depth": 4,
  "envFiles": [".env", ".env.local", ".env.development", ".env.development.local"],
  "targets": [],
  "docker": true,
  "localServers": true,
  "exclude": [],
  "keep": 10,
  "compression": 6,
  "notify": true,
  "toolDirs": []
}
```

| Key | Meaning |
| --- | --- |
| `roots` | Folders that hold your projects. Folders that don't exist are skipped. |
| `depth` | How many folder levels below a root to look for `.env` files. `4` reaches `~/Projects/company/apps/api/.env`. Hidden folders and folders such as `node_modules`, `vendor`, `dist` and `build` are skipped. |
| `envFiles` | File names to read in each folder, in this order. |
| `targets` | Extra databases, e.g. `[{"name": "billing", "url": "postgres://me@localhost:5432/billing"}]`. The local-only rule applies to them too. |
| `docker` | List the databases of running PostgreSQL/MySQL/MariaDB containers. |
| `localServers` | List databases on the local PostgreSQL server that you can open over its socket as yourself and that no project points at. |
| `exclude` | Hide databases by id (`project:database`), database name or project. |
| `keep` | Snapshots to keep per database. Older ones without a note are pruned after each snapshot. `0` keeps everything. |
| `compression` | gzip level, from `1` (fastest) to `9` (smallest). |
| `notify` | Notify when a snapshot or restore finishes or fails. |
| `toolDirs` | Extra folders to look in for `pg_dump`, `psql`, `mariadb-dump`, `mysqldump`, `mariadb` and `mysql`. Tools in `PATH` and in `~/.local/share/*/usr/bin` are found anyway. |

### Keyboard

When the panel is open:

- `n` jumps to the note box; `Enter` or `Esc` leaves it
- `j` / `k` scroll
- `r` refreshes
- `Esc` closes the panel, or the confirmation dialog when it is open

## How databases are found

- **`.env` files** in your project folders. Any variable named like
  `DATABASE_URL`, `DIRECT_URL`, `SHADOW_DATABASE_URL`, `POSTGRES_URL`,
  `MYSQL_URL`, `DB_URL` or `*_DATABASE_URL`, whose value is a `postgres://`,
  `postgresql://`, `mysql://`, `mariadb://`, `sqlite://` or Prisma `file:`
  URL. `${VAR}` references to the same file are filled in, and commented-out
  lines are ignored. Also: Laravel's `DB_CONNECTION` with `DB_HOST`,
  `DB_DATABASE` and so on, `PGHOST` with `PGDATABASE`, `POSTGRES_HOST` with
  `POSTGRES_DB`, and `MYSQL_HOST` with `MYSQL_DATABASE`. A Prisma
  `file:./dev.db` is looked up in `prisma/` first.
- **`targets`** in the settings file.
- **Docker:** running containers whose image is PostgreSQL, PostGIS,
  TimescaleDB, pgvector, MySQL, MariaDB or Percona. The database name comes
  from `POSTGRES_DB` / `POSTGRES_USER` or `MYSQL_DATABASE` /
  `MARIADB_DATABASE`. Dumps run inside the container with its own tools.
- **The local PostgreSQL server**, when `localServers` is on.

A database's id is `<project>:<database>`. The project is its folder relative
to the root, for example `shop/api:shop_dev`. Snapshots are saved in
`~/.local/share/omarchy-dbsnap/<project>/<database>/` as
`YYYYMMDD-HHMMSS[_note].sql.gz` (`.sqlite.gz` for SQLite) with a small `.json`
file next to each one that holds the note.

## Dependencies

You only need the tools for the kinds of database you have:

| For | Needs | Arch package |
| --- | --- | --- |
| PostgreSQL | `pg_dump` and `psql` | `postgresql-libs` |
| MySQL / MariaDB | `mariadb-dump` or `mysqldump`, and `mariadb` or `mysql` | `mariadb-clients` |
| SQLite | nothing: Python's built-in `sqlite3` module is used | |
| Docker databases | `docker`: the tools inside the container are used | `docker` |

For example: `omarchy pkg add postgresql-libs`. `pg_dump` must be at least
the server's major version; if it is older, the error shows on the card.

`scripts/dbsnap` is a Python 3 script that uses only the standard library.
It also uses `omarchy-notification-send`, `omarchy-launch-editor` and
`xdg-open`, which Omarchy already provides.

## Command line

`scripts/dbsnap` is what the panel runs. Other plugins and scripts can use it
too:

```
dbsnap list                        JSON: .targets, .snapshots, .running, .errors
dbsnap snapshot <id> [note]
dbsnap restore <file> --yes        add --copy, or --into <name>, for a new database
dbsnap delete <file>
dbsnap prune <id>
dbsnap check <url>                 is this URL local? (never connects)
dbsnap open [id]
dbsnap edit
```

Every command prints one JSON object, or `{"error": "..."}` when something
fails. `restore` refuses to run without `--yes`. Set `OMARCHY_NO_NOTIFY=1` to
print notifications instead of sending them. `DBSNAP_CONFIG` and
`DBSNAP_STORE` move the settings file and the snapshot folder; the tests use
them.

## Tests

```bash
python3 tests/test_dbsnap.py
```

The tests are offline. The local-only check runs against made-up listening
ports, DNS answers and containers, and a SQLite database goes through
snapshot, restore, restore into a copy, pruning and delete via the command
line.

## License

MIT. See [LICENSE](LICENSE).
