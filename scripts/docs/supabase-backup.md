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

The paste accepts a whole SSH private key, not just a one-line age identity —
SSH public keys are accepted as recipients, so restoring with one has to work
without first copying the key onto the host.

A restore asked for from the web console works too: because the host holds no
identity, the console asks you for one, and it is used once and shredded rather
than kept. That is a real widening — the key passes through the browser and the
console for the length of the restore — and
[the console's docs](supabase-backup-web.md#restoring-an-encrypted-archive) set
out exactly what it costs. The terminal remains the narrower path.

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
/etc/supabase-backup-upgrade/   upgrade.env, whether the timer installs patches
/var/backups/supabase/<p>/      archives, 0700
/var/lib/supabase-backup/       rollback/, what the last few upgrades replaced
/etc/systemd/system/supabase-backup@.{service,timer}
```

The `/etc` directories are separate because their audiences are. One holds a
service key and is readable by root alone; one holds public keys, which are not
secret and which the web console has to read to show what a project encrypts
to; one holds a single line about how this host updates itself, which the
upgrade helper must be able to write while being sandboxed out of the other
two.

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

A version is `<major>.<minor>` and the commit is the patch level, so it reads
`1.0 · bfad114`. A release that did not change `VERSION` is a patch by
definition — which is what automatic updates key off, below.

### Checking on a schedule

`supabase-backup-upgrade-scheduled.timer` runs at **00:00 and 12:00**, clear of
the backup timer's 03:20, and `Persistent=true` so a host that was off at
midnight notices at boot instead of waiting for noon.

```bash
systemctl list-timers supabase-backup-upgrade-scheduled.timer
journalctl -u supabase-backup-upgrade-scheduled -n 50
```

By default it only checks — which on a host with no console means the journal
is where you find out, and on one with a console means the version panel is
already current when you open it.

```bash
supabase-backup-upgrade --auto patch    # let it install patches too
supabase-backup-upgrade --auto off      # back to checking only (the default)
```

That writes one key to `/etc/supabase-backup-upgrade/upgrade.env`. **Only ever
a patch**: a new commit against the version already running, with both commits
known. Anything that bumped `VERSION` is left alone, and so is the case where
the commit could not be read at all.

Worth being clear about what `patch` buys and costs. It means this host follows
`main` and a push reaches it within twelve hours unwatched. The rollback catches
a console that will not start; it does not catch a bug in `backup.sh` that runs
perfectly and backs up the wrong thing. Note also which way the default cuts:
*not* bumping `VERSION` is what makes a change auto-deployable, so remembering
to bump is what holds one back. Leaving it `off` keeps the checking, which is
the half with no downside.

Re-running `supabase-backup-setup.sh` also updates the code, and still works.
The difference is that it is an installer: it asks the questions an installer
asks, including which project to add.

The console has the same thing behind its gear icon, including a switch for the
automatic half — see [the console's Upgrading
section](supabase-backup-web.md#upgrading).

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

## Changing it

Hosts install straight from `main`, so **`main` is the release**. There is no
staging branch and no publish step: pushing is publishing.

### The routine change

Edit the files, commit, push. Leave `VERSION` alone and it is a patch — hosts
with `AUTO_UPGRADE=patch` install it within twelve hours, everyone else sees
**Upgrade** in the console. The commit subject is the record; that is what the
console shows under "What's new", so write it as something you would want to
read there.

### The one decision that matters

| Change | `VERSION` | On a host with auto-patch on |
|---|---|---|
| fix, tweak, refactor | leave it | installs itself within 12h |
| new feature or behaviour | `1.0` → `1.1` | **waits for you** |
| needs a person to do something on the host | `1.1` → `2.0` | waits for you |

Bumping is how a change says "look at me". Note which way that cuts: *not*
bumping is what makes something deploy itself, so the bump is the deliberate
act. When in doubt, bump — the cost is clicking a button, and the cost of the
other mistake is a change installing itself unwatched.

Bumping `VERSION` requires a `## <version>` entry in
[`CHANGELOG.md`](../supabase-backup/CHANGELOG.md), newest first. `release-check`
refuses otherwise. Patches get no entry: their commit message is the entry.

### Adding a file to the installation

The one that fails silently if you get it wrong.

1. Add it under `scripts/supabase-backup/`
2. **Add it to `CORE_FILES` or `WEB_FILES` in `upgrade`** — miss this and no
   host ever receives it, while every upgrade still reports success
3. Add it to whichever setup script installs it on a fresh host
4. If it is a `.path` or `.timer` that must be enabled, add it to the enable
   loop in `apply_body`
5. Bump the minor — a new file is not a patch

`release-check` catches step 2 in both directions: a file here that the payload
does not list, and a file the payload lists that is not here (which would make
every upgrade fail on the download). A file that genuinely should not ship goes
in that script's `NOT_INSTALLED` list, with a note saying why.

### Adding a `web.env` key

Five places, and missing one leaves the file and the behaviour disagreeing:
`web/web.env.example`, `server.py` (the `env_bool` line, `current_settings`,
`validate_settings`), `reconfigure` (note the deliberate rule that a *missing*
key must never read as "off"), `web/static/app.js`, and
`supabase-backup-web-setup.sh` so hosts that already have a `web.env` gain the
line.

### Adding a spool directory

`supabase-backup-web.tmpfiles`, `supabase-backup-web.service`'s
`ReadWritePaths`, the `.path` unit, and the enable loop in `apply_body`.

### An upgrade never deletes

It installs what the payload lists and nothing else. Remove a file from the
repository and it stays on every host that already has it, forever. Removing
something properly means a deliberate cleanup — an upgrade will not do it for
you, on purpose: a code path that deletes files on a backup host is not one to
add for tidiness.

### The checks

```bash
scripts/supabase-backup/release-check
```

Verifies that `VERSION` is `<major>.<minor>`, that `CHANGELOG.md` has an entry
for it, that the payload and the directory agree in both directions, and that
every script parses as what it claims to be.

It runs in three places, deliberately overlapping:

- **By hand**, before you push something you care about
- **A pre-commit hook**, once per clone: `git config core.hooksPath .githooks`.
  Fast, local, and skippable with `--no-verify`
- **GitHub Actions**, on every push and pull request. This one runs whoever
  committed and from wherever, and it is the one `main` is protected by

### `main` is protected

Hosts install from `main`, and with `AUTO_UPGRADE=patch` some of them install
without being asked. So `main` is not a branch you push to:

- direct pushes are refused
- changes land through a pull request
- the `check` status must be green before it can merge
- no bypass, including for you, and force-pushing and deletion are blocked

No approving review is required, so a pull request you opened is one you can
merge yourself as soon as CI is green — about twenty seconds.

```bash
git checkout -b fix-the-thing
# ... edit, commit ...
git push -u origin fix-the-thing
gh pr create --fill
gh pr merge --squash --delete-branch    # once the check is green
```

`--auto` is worth knowing about: `gh pr merge --auto --squash --delete-branch`
queues the merge for the moment the check passes, so you do not have to come
back to it.

If this is ever the wrong trade — a CI outage, something that has to land
now — the protection is one command away from being off, and putting it back
is the same command with `active`:

```bash
gh api -X PUT repos/maggifrank/scripts/rulesets/22563743 -f enforcement=disabled
```

That is deliberately not a bypass actor. A standing exemption is one nobody
notices using; a command you have to type is a decision you can see afterwards
in the audit log.

## Rehearse it

An unrehearsed restore is an assumption, not a backup. Restore into a throwaway
project, point the application at it, and sign in. Reads alone are not enough —
a restore that drops privileges or policies passes every check that only looks
at rows.
