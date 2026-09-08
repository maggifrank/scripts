# supabase-backup — releases

A version is `<major>.<minor>` and the commit is the patch level, so a release
that did not change `VERSION` is a patch and gets no entry here — its commit
message is the record, and the console shows those under "What's new".

An entry per version, newest first. `release-check` refuses a `VERSION` with no
entry, which is what keeps this file from drifting into fiction.

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
