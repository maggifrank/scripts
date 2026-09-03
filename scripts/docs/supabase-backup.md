# Supabase backup

Nightly capture of a Supabase project into a single timestamped tarball, on any
Debian/Ubuntu host. One config file and one timer per project, so a host can
back up as many projects as you like.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

Choose **Supabase Backup**, or run `supabase-backup-setup.sh` directly. Run it
again to add another project.

## The idea

**An archive that needs a file from somewhere else is not a backup.**

It is tempting to treat an application's `migrations/` directory as the schema
and back up only the data. That fails in three ways: the repository may be
gone when you need it, it may be a version ahead of what production runs, and —
most often — the live database has drifted from what the migrations describe,
because somebody changed something in the dashboard.

So everything here is read from the running catalog. Postgres can describe
itself, and the tool asks it rather than trusting a file written months ago.

## What an archive contains

| File | Contents |
|---|---|
| `schema.sql` | Every user schema: tables, indexes, constraints, functions, RLS policies, **privileges**, and all data |
| `auth.sql` | `auth.users` and `auth.identities`, data only |
| `non-public.sql` | Objects `pg_dump` cannot see — see below |
| `files/<bucket>/…` | Every object in every storage bucket |
| `manifest.json` | Schemas, buckets, per-table row counts, object count, `pg_dump` version |
| `SHA256SUMS` | Checksums for everything above |
| `filelist.txt` | Every storage object path captured |

### What `pg_dump` cannot see

`pg_dump --schema=public` is blind to anything outside the schemas you name,
and several things an application depends on live outside them. `non-public.sql`
is generated from the catalog on every run:

- **Extensions** — from `pg_extension`
- **Triggers on platform tables** — a trigger on `auth.users` is invisible to a
  `public` dump even when the function it calls is in `public` and *is* dumped.
  Restore without it and the application serves existing users correctly, then
  silently fails for everyone who signs up afterwards.
- **Policies on `auth` and `storage` tables** — reconstructed from `pg_policy`
- **Bucket definitions** — from `storage.buckets`
- **Scheduled jobs** — from `cron.job`, exactly as they are, which is not
  necessarily as any migration file claims

Supabase's own objects are excluded, since they exist in every project already.
The rule for triggers is *"app-owned means the function lives in a user
schema"*, which distinguishes an application's trigger on `auth.users` from
`storage.protect_delete` without knowing anything about the application.

### Privileges are schema

The dump keeps `GRANT`/`REVOKE`. Column-level grants are an ordinary way to
make a column unwritable — `revoke update on t from authenticated` followed by
a grant on the specific editable columns — and a dump taken with
`--no-privileges` restores a database missing a control it was relying on,
with nothing to indicate anything is wrong. The roles involved (`anon`,
`authenticated`, `service_role`) exist in every Supabase project, so keeping
privileges costs no portability.

The run fails if the dump contains no privilege statements at all: a Supabase
schema always carries non-default ACLs, so zero means they were stripped rather
than genuinely absent.

## How it refuses to lie

A backup that fails loudly is worth more than one that quietly degrades. A run
aborts, writing nothing, if:

- no user schemas are found, or the dump contains no tables
- the dump contains no privilege statements
- any storage object downloads as zero bytes
- **`storage.objects` lists an object the bucket walk did not find**

That last check is the important one. The walk cannot reveal what it never
looked at, so its own output cannot prove completeness — but the database holds
an authoritative inventory of every object, and comparing against it catches a
walk that skipped an entire subtree.

Archives are written under a temporary name and renamed into place. Rename is
atomic within a filesystem, so a snapshot taken mid-run captures a whole
archive or none of it, never a truncated one that still looks valid.

## Layout

```
/opt/supabase-backup/           backup.sh, catalog.sql
/etc/supabase-backup/<p>.conf   credentials, 0600, one per project
/var/backups/supabase/<p>/      archives, 0700
/etc/systemd/system/supabase-backup@.{service,timer}
```

## Operating

```bash
systemctl start supabase-backup@<project>.service     # run now
journalctl -u supabase-backup@<project>.service       # what happened
systemctl list-timers 'supabase-backup@*'             # all projects
```

Verify an archive:

```bash
A=$(ls -1t /var/backups/supabase/<project>/*.tar.gz | head -1)
mkdir -p /tmp/v && tar xzf "$A" -C /tmp/v && cd /tmp/v
sha256sum -c SHA256SUMS && jq . manifest.json
```

Quote the path — with several archives present an unquoted glob makes `tar`
treat the second match as a member name and fail confusingly.

## Configuration

`/etc/supabase-backup/<project>.conf`, mode 0600. Read by the script itself
rather than by systemd's `EnvironmentFile=`, so the parser never has to cope
with whatever punctuation ends up in a database password.

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | — | Session pooler URI, **port 5432** |
| `SUPABASE_URL` | — | `https://<ref>.supabase.co` |
| `SUPABASE_SERVICE_KEY` | — | Service key; bypasses RLS |
| `BACKUP_DIR` | `/var/backups/supabase/<project>` | Where archives go |
| `KEEP_DAYS` | `30` | Prune older archives; `0` disables |
| `PLATFORM_SCHEMAS` | Supabase's own | Schemas treated as platform-owned |

Use the **session** pooler (5432). Transaction mode (6543) does not hold a
session across statements and `pg_dump` fails partway. Percent-encode a
password containing `@ : / ? # [ ] %`.

## Restoring

Load in this order. It matters:

```bash
psql "$TARGET" -f auth.sql          # 1. users first
psql "$TARGET" -f schema.sql        # 2. schema and data
psql "$TARGET" -f non-public.sql    # 3. triggers, policies, buckets, cron
```

Application tables have foreign keys to `auth.users(id)`. Loading `schema.sql`
first creates the structure successfully and then fails **every** `COPY` on a
constraint violation, leaving a project that looks complete and holds no data.

`non-public.sql` goes last because its triggers call functions that `schema.sql`
creates.

Expect one error from step 2: `schema "public" already exists`. Let it through.
Do **not** `drop schema public` to avoid it — Supabase preconfigures that schema
with grants and default privileges for `anon`, `authenticated` and
`service_role`, the dump does not recreate them, and dropping it strips the
application's ability to read its own tables in a way that only surfaces later
as confusing permission errors.

Then re-upload `files/<bucket>/…` through the Storage API, preserving paths, and
check the restored row counts against `manifest.json`.

## Not in the archive

Everything in the database is captured. Supabase's **control plane** is not, and
cannot be reached over SQL:

- auth providers, email templates, JWT secret, API settings
- project settings, edge functions
- Vault secret *values* (`vault.decrypted_secrets` is readable, but secrets are
  deliberately not written to disk)

A restored project needs those configured by hand. Write down which ones you
depend on before you need them.

## Rehearse it

An unrehearsed restore is an assumption, not a backup. Restore into a throwaway
project, point the application at it, and sign in. Reads alone are not enough —
a restore that drops privileges or policies passes every check that only looks
at rows.
