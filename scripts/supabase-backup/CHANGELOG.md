# supabase-backup — releases

A version is `<major>.<minor>` and the commit is the patch level, so a release
that did not change `VERSION` is a patch and gets no entry here — its commit
message is the record, and the console shows those under "What's new".

An entry per version, newest first. `release-check` refuses a `VERSION` with no
entry, which is what keeps this file from drifting into fiction.

## 1.8 — 2026-09-09

Credentials can be rotated, and the console says what they can do.

- A project's database password and service key could only be changed by
  editing a root-owned file over SSH, which is why they were not changed. A
  credential nobody rotates has been exposed since the day it was made, and on
  a host that holds a service key that is the whole risk — bigger than the
  archives, which may well be encrypted.
- The console can now rotate them. Empty fields keep what is in force, so a
  rotation can be one credential rather than three re-typed ones. The new set
  is proved against Postgres and the storage API **before** anything is
  replaced, so a typo fails while someone is watching instead of at 03:20, and
  `BACKUP_DIR`, `KEEP_DAYS` and everything else in the file are kept.
- A rotation cannot repoint a project at a different one. That would keep this
  project's archive directory and history while backing up something else.
- The console still cannot read a credential — `/etc/supabase-backup` is out of
  its reach and stays that way. It carries new ones towards the helper and
  learns nothing.
- **Setup, registration and rotation now report what the database role can
  do**: `this role can write to 7 of 7 table(s) in public`. Nothing in a backup
  writes to the source — `catalog.sql` has no `INSERT`, `UPDATE`, `CREATE` or
  `DROP` in it — so a read-only role would mean a stolen credential could read
  the project but not destroy it. The docs carry the SQL.

## 1.7 — 2026-09-09

A restore no longer stops on the one error a managed target always gives.

- `ALTER DEFAULT PRIVILEGES FOR ROLE <r>` is refused unless the connection is a
  member of `<r>`. The session pooler connects as `postgres`, which on a
  managed project is not a superuser and does not own `supabase_admin`, so a
  dump carrying default privileges for such a role produced a wall of
  `permission denied to change default privileges` and the restore treated
  every one of them as fatal. It stopped **after** `schema.sql` had been
  applied in full — auth users, tables, rows, grants and policies all loaded —
  and before catalog objects and storage. The target was left half restored by
  a check, not by a failure.
- Those errors are now expected, counted and reported, not fatal. They decide
  what future objects those roles create inherit; they touch nothing being
  restored, and the target carries Supabase's own defaults for `anon`,
  `authenticated` and `service_role` already.
- Every other error loading `schema.sql` still stops the restore, including
  `relation ... already exists` — re-running into a target that is already
  loaded is still refused, and still should be.
- A failure now prints **all** of the unexpected errors, and names where to
  read them. A console-driven restore has its work directory removed on the way
  out, so the `full log: /tmp/supabase-restore-XXXXXX/schema.log` it used to
  offer was a path that no longer existed by the time anyone looked. It names
  the journal instead, which survives, and the console's own list is capped at
  ten with the remainder counted rather than silently dropped.

## 1.6 — 2026-09-09

An encrypted archive can be restored from the console.

- Until now it could not be restored from anywhere but a terminal, and only by
  someone willing to put the identity on the host. The console offered a
  sentence explaining why instead of a button, which was honest and not much
  use to whoever needed the backup.
- The restore form now asks for the identity when the archive is encrypted.
  The key comes from the browser at the moment it is needed and is used once:
  sent only over a connection the console already refuses to take secrets on
  unless it is loopback or TLS, written 0600 to tmpfs, shredded by the host as
  soon as it has been read, and handed to `age` through a process substitution
  so it never touches a disk. It is not stored, and nothing on the host can
  open an archive without someone supplying it again.
- **This is a deliberate widening.** The identity now passes through the
  browser and the console's memory for the length of a restore, which it never
  did before. That is the same path the target's database password and service
  key already take, and the alternative people were actually reaching for was
  copying a private key onto the host's disk, which is worse and permanent.
  The terminal remains the narrower option and the form says so.
- `supabase-restore` also accepts a pasted multi-line key now, so an SSH
  private key can be given without writing it to a file first. SSH public keys
  have always been accepted as recipients; restoring with one was not possible
  without copying the key to the host.
- A restore request carrying an identity for an archive that is not encrypted
  is refused rather than ignored.

## 1.5 — 2026-09-09

A major is now the one step nothing installs quietly.

- `AUTO_UPGRADE=minor` takes patches and minor releases and stops at a major —
  staying on a major and having everything within it. `patch` and `off` are
  unchanged.
- **No setting installs a major.** Not `patch`, not `minor`. The timer names it
  and leaves it, because a release that changes the first number is one that
  wants a person, and a setting able to wave it through would make bumping the
  major number mean nothing.
- The console says so where the decision is made: a red panel above the
  Upgrade button when the waiting release is a major, and a second confirmation
  that asks a different question from the first — whether the release notes
  have been read. One reflexive click gets through one dialog, not two.
- The automatic control is a three-way choice rather than a checkbox, since
  there are now three answers.

## 1.4 — 2026-09-09

Only changes you would actually install count as an upgrade.

- The check watched the whole `scripts/supabase-backup/` directory, so a commit
  touching only `release-check` — which never leaves the repository — announced
  an upgrade that downloaded thirty files and replaced none of them. With
  automatic patches on, a host did that to itself and called it an upgrade.
- Each commit newer than the installed one is now asked what it changed, and
  only the ones touching a file *this host installs* count. A host without the
  console is not told to upgrade because `app.js` moved. A commit whose answer
  cannot be fetched counts anyway: hiding a real change is the worse mistake.
- When nothing installable has changed, the available commit reported is the
  one already running — a panel that says "up to date" should not also show two
  different commits.
- What gets recorded is that same commit, so a later check compares like with
  like rather than treating every tooling commit as a version skipped.

## 1.3 — 2026-09-08

Every file in an upgrade now comes from one commit.

- Downloads were made from a branch URL, which is served from a cache that lags
  the API by minutes. That is not hypothetical: minutes after 1.2 was published
  the API reported its commit while the branch URL still served 1.1's VERSION
  and 1.1's code. Two silent ways it hurt — a payload fetched partway between
  two commits, every file passing its own checks; and "same version, new
  commit", which is the definition of a patch, so an automatic host would have
  installed a release that bumped its version precisely to avoid that.
- The commit is resolved first, and both the version and every file are then
  read from that commit's immutable URL. Where the API cannot say what the
  commit is there is nothing to pin to, and the upgrade says so rather than
  pretending.

## 1.2 — 2026-09-08

An upgrade finishes in one pass.

- An upgrade runs the script that was already installed, so it could only ever
  install the file list *that* script knew about. A release adding a file
  therefore landed incomplete — and then recorded a version whose files were
  not all there, so the host looked up to date and was not. When the script
  replaces itself it now hands over to the copy it just installed and lets it
  finish with its own list. Once only; a second release in a row cannot turn it
  into a loop.
- `/etc/supabase-backup-upgrade` is created by an `ExecStartPre=` with the `+`
  prefix, which runs before the sandbox is applied. The helper could always
  write into that directory but never create it, so on a host that had never
  run a setup script the console's **Install patches automatically** switch
  could only answer "could not write".
- An upgrade that replaced nothing no longer restarts the console. There was
  nothing new for it to run, and the restart cost a second of downtime to
  achieve it.

## 1.1 — 2026-09-08

Release notes, and something that checks them.

- The console shows **What's new** above the Upgrade button: the commit
  subjects you would be getting, read from the commits that touched this
  directory between the one installed and the one published. A patch never
  writes release notes, and its subject line is what it wrote instead.
- **Version history** below it, from this file, which arrives with an upgrade
  and so describes only versions a host already has.
- `release-check` refuses a release that would not install: a file here that
  the upgrade payload does not list (which no host would ever receive), a file
  listed but missing (which would fail every download), a `VERSION` that is not
  `<major>.<minor>`, or a bump with no entry here.
- It runs as a pre-commit hook and in GitHub Actions, because the convention
  was worth more than someone remembering it.

## 1.0 — 2026-09-06

The first version that has one. Everything before this was "whatever `main` had
that day", which was fine until there was more than one host.

- `supabase-backup-upgrade` replaces the code in place: staged, checked, and
  rolled back if the console will not start on it. Upgrading no longer means
  re-running an installer that asks installer questions.
- The console says what version it runs and what GitHub publishes, and can ask
  for the upgrade. It still installs nothing itself.
- `supabase-backup-upgrade-scheduled.timer` checks at 00:00 and 12:00, and can
  install patches on its own if you ask it to. Off by default.
- A record of what is installed, so "am I current" has an answer that does not
  depend on remembering.
