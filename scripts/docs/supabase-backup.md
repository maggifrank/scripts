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

Encrypted, the whole tarball becomes `<project>-<stamp>.tar.gz.age` and gains a
plaintext sidecar, `<project>-<stamp>.meta.json`, holding the ciphertext's
digest and the manifest — see [Encryption](#encryption).

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
  necessarily as any migration file claims. Projects that never enabled
  `pg_cron` have no `cron.job` at all; the section then says so and the run
  carries on, since a missing optional extension is not a failed backup.

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

## Encryption

Archives can be encrypted with [age](https://age-encryption.org), to a public
key whose private half never comes near this host.

Give a project one or more recipients and every archive from then on is written
as `<project>-<stamp>.tar.gz.age`:

```
/etc/supabase-backup-keys/<project>.recipients
```

One recipient per line — an `age1…` public key, or a line from an SSH `.pub`
file. Blank lines and `#` comments are ignored. That file existing and being
non-empty is the **only** switch. There is no second copy of the setting to
drift away from what the nightly run will actually do, and no state to
reconcile. Removing the file turns encryption off — though not silently, if the
project already has encrypted archives; see
[It will not quietly stop encrypting](#it-will-not-quietly-stop-encrypting).

Set it up with `supabase-backup-setup.sh` when adding a project, from the web
console, or by writing the file yourself.

### The host gets the key that locks, not the one that opens

`age` is asked to encrypt **to a recipient**, not with a passphrase. The
distinction is the whole point. A passphrase would have to live on this host to
run unattended, which would put the key next to the ciphertext and buy nothing.
A recipient is a public key: it encrypts, and it cannot decrypt.

So nothing here can read back what it just wrote, including this tool, the web
console, and anyone who takes the disk. Generate the key where you keep
secrets — not here:

```bash
age-keygen -o backup.key      # public key to paste in, private key to keep
```

**A lost key is a lost archive.** There is no recovery path and none can be
added afterwards. Give a project two or three recipients so a single lost key
is survivable.

### What this protects, and what it does not

It protects every archive that leaves this host or outlives it: a copy taken
offsite, a stolen or discarded disk, years of retained archives that stay
unreadable even to someone who compromises the host later.

It does **not** protect the project. To take a backup at all, this host must
hold a database password and a service key that bypasses RLS, in
`/etc/supabase-backup/<project>.conf`. Anyone who reaches those can read the
live project without touching an archive. Encryption at rest cannot fix that,
and no scheme that runs unattended can.

Two smaller exposures, stated plainly:

- **During a run** the backup exists in the clear, in
  `/var/backups/supabase/<project>/.work-<stamp>`, until it is tarred and
  encrypted. That directory is created `0700`, so nothing but root can enter
  it, and it is removed when the run ends.
- **The sidecar is plaintext.** `<project>-<stamp>.meta.json` carries the
  ciphertext's SHA-256 and the manifest — schema names, bucket names, per-table
  row counts. That is what lets the console inventory an archive and check it
  for damage without a key. Set `SIDECAR_MANIFEST=0` to withhold the manifest;
  the digest stays, because without it nothing can tell a damaged archive from
  a good one.

### It will not quietly stop encrypting

A recipients file that goes missing looks exactly like one that was never
there. So if a project has encrypted archives on disk and no recipients
configured, the run **fails** rather than writing a plaintext archive beside
them. Set `ALLOW_PLAINTEXT=1` in the project's `.conf` to say the downgrade is
deliberate — which is what turning encryption off from the console does for
you.

### Restoring one

`supabase-restore` lists encrypted archives with `needs a key` and asks for the
identity: a path to an identity file, or a pasted `AGE-SECRET-KEY-…`, which is
handed to `age` through a process substitution and never written to disk.
Before decrypting, the ciphertext is checked against the digest its own run
recorded — otherwise a damaged archive arrives as "could not decrypt", which
reads like the wrong key and sends you looking for a better one that does not
exist.

A restore asked for from the web console is refused for an encrypted archive.
The console holds no identity, by design, so there is nowhere it could have got
one; run `supabase-restore` at the terminal instead.

```bash
age -d -i backup.key <archive>.tar.gz.age | tar xz -C /tmp/restore   # by hand
```

## Layout

```
/opt/supabase-backup/           backup.sh, catalog.sql, restore, upgrade
  VERSION, installed.json       what this is, and the commit it came from
/etc/supabase-backup/<p>.conf   credentials, 0600, one per project
/etc/supabase-backup-keys/      age recipients, 0644, public keys only
  <p>.recipients
/var/backups/supabase/<p>/      archives, 0700
/var/lib/supabase-backup/       rollback/, what the last few upgrades replaced
/etc/systemd/system/supabase-backup@.{service,timer}
```

The two `/etc` directories are separate because their audiences are. One holds
a service key and is readable by root alone; the other holds public keys, which
are not secret and which the web console has to read to show what a project
encrypts to.

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

### Keeping it up to date

```bash
supabase-backup-upgrade --check     # what is running, what is published
supabase-backup-upgrade             # say what is available, then ask
```

It replaces code and nothing else: `/opt/supabase-backup`, the systemd units,
and the console's static files if the console is installed. No config, no
credential, no archive, and nothing about whether this host acts on a restore
request. What it replaces is copied to `/var/lib/supabase-backup/rollback/`
first, and put back if the console does not come up on the new code.

"Up to date" means the commit that last touched `scripts/supabase-backup` on
`main`, recorded here at install time and compared against what GitHub reports
now — `VERSION` is the name a human reads, the commit is what decides. It
refuses while a backup or a restore is running; `--force` overrides that.

Re-running `supabase-backup-setup.sh` also updates the code, and still works.
The difference is that it is an installer: it asks the questions an installer
asks, including which project to add.

The console has the same thing behind its gear icon — see
[the console's Upgrading section](supabase-backup-web.md#upgrading).

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
| `ALLOW_PLAINTEXT` | unset | Permit a plaintext archive beside encrypted ones |
| `SIDECAR_MANIFEST` | `1` | Publish the manifest beside an encrypted archive |

Use the **session** pooler (5432). Transaction mode (6543) does not hold a
session across statements and `pg_dump` fails partway. Percent-encode a
password containing `@ : / ? # [ ] %`.

## Restoring

```bash
supabase-restore              # pick an archive, answer four prompts
supabase-restore --dry-run    # everything except the writes
supabase-restore --list       # available archives
supabase-restore --reset      # clear a target, so a rehearsal can be repeated
```

It verifies the archive's checksums, loads everything in the right order, and
checks the restored row and object counts against the archive's own
`manifest.json` — not against a hardcoded list that could drift.

Three things it refuses to do:

- write when the target's two credentials name **different projects** — a
  mismatched pair writes one project's database while uploading another's files
- write to **any project configured on this host as a backup source**, so it
  cannot overwrite the thing it exists to protect
- continue past a target where any table lacks row level security

`--reset` drops every non-extension table, function and type in the target's
user schemas, removes its buckets, and deletes its auth users. It clears
storage over the API rather than by SQL: Supabase installs a `protect_delete()`
trigger that rejects `DELETE FROM storage.objects`, so a SQL-only reset aborts
there and silently skips everything after it.

### Doing it by hand

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
