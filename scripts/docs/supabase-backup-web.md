# Supabase backup — web console

A browser view of what [supabase-backup](supabase-backup.md) has actually
produced on a host: every project, its archives and their manifests, the run
history, the next scheduled run, and a verify that re-checks an archive against
its own checksums and its own inventory. It can start a run.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

Choose **Supabase Backup Console**, or run `supabase-backup-web-setup.sh`
directly. Install the backup tool first — the console has nothing to show
otherwise.

## The idea

**A timer tells you a run happened. It does not tell you the archive is good.**

Everything here answers the second question. The archives are the evidence: one
exists only because a run passed every check it makes of itself and renamed the
file into place. So health is derived from the archive set first and from
systemd second — and unlike a unit's recorded state, an archive survives a
reboot.

Per project, the state means:

| State | What it means |
|---|---|
| `ok` | the newest archive is younger than `WEB_STALE_HOURS` |
| `running` | the unit is active, or a `.partial` is being written |
| `stale` | archives exist but the newest has aged out — a night was missed |
| `failed` | a run since the last boot ended with a non-success result |
| `never` | the directory is readable and empty |
| `unreadable` | the archive directory could not be read at all |

`never` and `unreadable` are separate on purpose. A permissions mistake would
otherwise show a calm, empty panel for a project whose backups are either fine
or gone, and you could not tell which. The header shows the worst state across
every project, so one project's failure is never hidden behind another's calm.

## What it deliberately does not do

- **Restore.** `supabase-restore` is interactive, destructive, needs the target
  project's credentials, and refuses to run against the project it backs up or
  against a pair of credentials naming two different projects. Those guards
  hold because a person is reading them while answering the prompts. A web
  button would keep the code and lose the setting.
- **Prune or delete.** `KEEP_DAYS` does that, on a schedule, with nobody
  clicking anything at 1 a.m.
- **Edit configuration.** The `.conf` files are edited on the host.
- **Read a project's credentials.** It runs as its own unprivileged user, its
  own config lives in `/etc/supabase-backup-web/`, and the unit adds
  `InaccessiblePaths=/etc/supabase-backup` on top of those files' 0600 modes.

## What "verify" actually checks

Verifying streams the tarball once and hashes as it goes. It writes nothing to
disk, so unlike extracting into `/tmp` it works on a host with less free space
than the archive. It checks four things:

1. every file listed in `SHA256SUMS` hashes to what the list says;
2. nothing else is in the tarball unaccounted for;
3. every path in `filelist.txt` is actually stored under `files/`;
4. `manifest.json`'s object count matches the number of objects present.

What it cannot check is whether the archive matches the project. Only the run
that wrote it could, and it does: `backup.sh` compares its storage walk against
`storage.objects` and refuses to finalise an archive that disagrees.
Verification here is about damage since then. It is also not a restore test.

## Exposure

The setup script asks. The default is `127.0.0.1:8787` — nothing new listens on
the network, and you reach it over a tunnel:

```sh
ssh -N -L 8787:127.0.0.1:8787 root@<host>     # then http://localhost:8787
```

The alternative is `0.0.0.0:8787`, browsable directly at `http://<host>:8787`.
Basic auth over plain HTTP means the password crosses the network in the clear
on every request. On a trusted LAN that may be a fair trade; make it knowingly,
and put a TLS-terminating reverse proxy in front if anything less trusted
shares the network. Switching later is one line in `web.env` and a restart.

There is no TLS in the server itself, on purpose — a certificate to renew is
exactly the kind of thing that quietly expires on a host nobody logs into.

## Configuration

`/etc/supabase-backup-web/web.env`, mode 0640 `root:supabase-backup-web`.

| Variable | Default | Meaning |
|---|---|---|
| `WEB_BIND` | `127.0.0.1:8787` | Listen address |
| `WEB_USER` | `admin` | Basic auth username |
| `WEB_PASSWORD_HASH` | — | PBKDF2 digest from `server.py --hash` |
| `WEB_ALLOW_ANONYMOUS` | `0` | Serve with no authentication at all |
| `WEB_ALLOW_RUN` | `1` | Show and honour "Run backup now" |
| `WEB_ALLOW_DOWNLOAD` | `0` | Allow downloading whole archives over HTTP |
| `WEB_STALE_HOURS` | `26` | Age at which a project's newest archive is stale |
| `DATA_DIR` | `/var/backups/supabase` | Where archives live |
| `UNIT_PREFIX` | `supabase-backup` | Template unit name |
| `WEB_RUN_COMMAND` | `systemctl start --no-block {unit}` | How a run is started |

It refuses to start with no password configured. That is not an oversight to
work around: `WEB_ALLOW_ANONYMOUS=1` exists for a host where something else is
already doing the authenticating, and it makes you say so.

## Operating it

```sh
systemctl status supabase-backup-web
journalctl -u supabase-backup-web -n 30
systemctl restart supabase-backup-web        # after editing web.env
```

Editing anything under `/opt/supabase-backup/web/static/` takes effect on the
next page load; only `server.py` and `web.env` need a restart.

## When it misbehaves

**A project shows `unreadable`.** Almost always a project added after the
console was installed: `supabase-backup-setup.sh` creates its archive directory
0700 root, which the console cannot read. Re-run
`supabase-backup-web-setup.sh`; it re-applies group access to every project
directory and is safe to run repeatedly.

**A project is missing entirely.** The console lists the union of directories
under `DATA_DIR` and `supabase-backup@*.timer` instances. A project with
neither does not exist as far as this is concerned.

**A project shows `never` or `unreadable` although its archives are fine.** Its
`.conf` sets `BACKUP_DIR` somewhere other than `/var/backups/supabase/<project>`.
The console cannot follow that: `BACKUP_DIR` lives in the same file as the
database password and the service key, and this process is deliberately unable
to read it. `supabase-backup-setup.sh` always writes the default location, so
this only happens to a hand-edited config. Either move the archives back, or
point the whole console elsewhere with `DATA_DIR` in `web.env`.

**It will not start: "refusing to start without authentication".**
`WEB_PASSWORD_HASH` is empty. Generate one with
`/opt/supabase-backup/web/server.py --hash`.

**The browser asks for a password over and over.** The username in `web.env` is
not the one you are typing, or the hash is not for the password you are typing.
Both are checked; neither is reported separately, on purpose.

There is one way to cause this that looks like nothing is wrong: setting
`WEB_PASSWORD_HASH` with a systemd `Environment=` line, in the unit or a
drop-in, instead of in `web.env`. systemd expands `$` in `Environment=` values
and a PBKDF2 hash is `$`-separated, so the process receives a mangled hash and
rejects every password in silence. `EnvironmentFile=` does no expansion, which
is why the hash lives in `web.env`. Check what the process actually got:

```sh
tr '\0' '\n' < /proc/$(systemctl show -p MainPID --value supabase-backup-web)/environ \
  | grep WEB_PASSWORD_HASH
```

**"Run backup now" fails with "Interactive authentication required".** The
polkit rule is missing, not matching, or polkit was not restarted after it was
written. It lives at `/etc/polkit-1/rules.d/50-supabase-backup-web.rules`.

**Recent runs is empty, but backups are clearly running.** Debian keeps the
journal in memory unless `/var/log/journal` exists, so it empties on reboot:

```sh
mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
```

## Known gaps

- No TLS, and Basic auth — see [Exposure](#exposure).
- Run history is only as deep as the journal, which is shallow by default.
- Adding a project needs a re-run of the setup script before the console can
  read it. It says `unreadable` until then rather than pretending it is fine.
- Archives are found at `DATA_DIR/<project>`, the layout
  `supabase-backup-setup.sh` creates. A `.conf` that overrides `BACKUP_DIR` is
  invisible to the console, because reading that file would mean reading the
  project's credentials.
- Verification proves an archive is intact and self-consistent. It does not
  prove it restores; only a rehearsal does that.
- The console knows nothing about offsite copies. A green header means the
  local archives are good, not that anything offsite is.
