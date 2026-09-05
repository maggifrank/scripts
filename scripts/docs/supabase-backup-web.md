# Supabase backup — web console

A browser view of what [supabase-backup](supabase-backup.md) has actually
produced on a host: every project, its archives and their manifests, the run
history, the next scheduled run, and a verify that re-checks an archive against
its own checksums and its own inventory. It can start a run, change its own
password and settings, set who a project's archives are encrypted to, and — if
the host was set up for it — ask for a restore.

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

## Registering a project

The console can add a project to the host, which means writing a root-owned
config containing a service key and enabling a timer. It does none of that
itself. It stays unprivileged and writes exactly one thing: a request file in a
spool directory it owns.

```
console (unprivileged, NoNewPrivileges=true)
  └─ writes /run/supabase-backup-web/register/<id>.json, mode 0600
       │
  supabase-backup-register.path  (DirectoryNotEmpty)
       ▼
supabase-backup-register.service  (root, oneshot)
  re-validates every field ─ the request came from a network-facing process
  → tests the database connection and the service key before writing anything
  → writes /etc/supabase-backup/<project>.conf, 0600
  → creates the archive directory 0750, readable by the console
  → enables supabase-backup@<project>.timer
  → shreds the request, writes a result the console polls
```

The request is destroyed as soon as the helper has read it, so a crash cannot
leave a service key sitting in `/run`. Nothing in it is trusted: the helper
checks the project name, that both credentials name the same project, that the
database is reachable, that `pg_dump` is new enough for the server, and that
the storage API accepts the key — and it refuses to overwrite a project that
already exists. A config is never written for a project that cannot be reached,
because that is just a timer that fails every night.

Registering here also gets the archive directory's group right from the start,
so a project added this way needs no re-run of the setup script.

### It will not do this over plain HTTP

A service key bypasses RLS on the entire project. It is a far bigger prize than
the console password, so the console refuses to accept one over a plain
connection from the network: `POST /api/register` is allowed only from
loopback, and the form is not even offered otherwise.

Loopback covers both supported paths — a TLS proxy on this host forwarding to
`127.0.0.1`, and an SSH tunnel:

```sh
ssh -N -L 8787:127.0.0.1:8787 root@<host>   # then http://localhost:8787
```

**The tunnel needs `AllowTcpForwarding yes` on the host's sshd, which hardened
hosts often turn off** — `lxc-hardening.sh` and `ubuntu-server-hardening.sh`
both do. Check with `sshd -T | grep allowtcpforwarding`. When it is `no` the
tunnel fails silently: `ssh -L` still opens the local port, connections through
it are simply closed, and the console logs nothing at all because no request
ever arrives. On such a host use a TLS proxy and `WEB_TRUSTED_PROXIES` instead;
that is the supported route, not a workaround.

A proxy on a *different* host must be named in `WEB_TRUSTED_PROXIES` and must
send `X-Forwarded-Proto: https`. That header is ignored from any other client,
so it cannot be used to talk your way past the check.

## Changing the console's own settings

The **Console settings** dialog — the gear in the header — edits `web.env`, the
password first of all, and the console can do neither half of that itself: it
cannot write the file that configures it, and it cannot restart itself. So it
asks, exactly the way it asks for a project to be registered.

```
console (unprivileged, /etc/supabase-backup-web is read-only to it)
  └─ writes /run/supabase-backup-web/settings/<id>.json, mode 0600
       │     a PBKDF2 digest, never a password — the console hashes first
  supabase-backup-reconfigure.path  (DirectoryNotEmpty)
       ▼
supabase-backup-reconfigure.service  (root, oneshot)
  re-validates every field ─ the request came from a network-facing process
  → rewrites only the keys it knows, keeping comments and every other line
  → restarts supabase-backup-web
  → puts the old file back if the console does not come up
  → writes a result the console polls
```

What the panel changes:

| Setting | Note |
|---|---|
| `WEB_USER` | changing it signs the browser out, like changing the password |
| `WEB_PASSWORD_HASH` | typed as a password, stored as a PBKDF2 digest |
| `WEB_BIND` | where it listens — see the rollback below |
| `WEB_STALE_HOURS` | when a project's newest archive counts as stale |
| `WEB_ALLOW_RUN` | offer "Run backup now" |
| `WEB_ALLOW_DOWNLOAD` | allow whole archives over HTTP |
| `WEB_ALLOW_REGISTER` | offer "Add a project" |
| `WEB_ALLOW_SETTINGS` | offer this panel at all — turning it off is one-way from here |

What it does not, and why:

- `WEB_ALLOW_ANONYMOUS` — a switch that turns authentication off has no
  business being reachable through the thing it authenticates.
- `WEB_TRUSTED_PROXIES` — it decides whose word to take for who a client is.
- `DATA_DIR`, `UNIT_PREFIX`, `WEB_RUN_COMMAND`, `WEB_SPOOL_DIR` — the shape of
  the installation, not a preference. Those are edited on the host by someone
  who is already root.

### The password

The console hashes it. The plaintext crosses the connection — as it already
does on every Basic auth request — and stops there: what goes into the spool
file is a `pbkdf2_sha256` digest at 600,000 iterations, so the password is
never in a file under `/run`, never in root's argv, and never in the journal.
The helper checks that what arrived really is a digest, because a plaintext
password written into `WEB_PASSWORD_HASH` would leave a file that looks
perfectly reasonable and rejects every login.

Minimum twelve characters, and the panel asks for the **current** one before it
will change anything. Basic auth alone does not prove anyone is there: a
browser resends a saved password all day, so without that box an unattended tab
would be a password change waiting to happen.

Saving restarts the console, which is what makes the new credentials take
effect — and immediately signs the browser out, since it is still holding the
old ones. The page says so and offers a reload. Nothing about
`server.py --hash` changes; it is still there, and still the way back in.

### Not over plain HTTP either

The same rule as [registering a project](#it-will-not-do-this-over-plain-http),
for a plainer reason: a password changed over a connection that shows it to the
network has not been changed. From a plain-HTTP connection the panel shows what
the settings are and refuses to change them. Reach the console over the TLS
proxy on this host or an SSH tunnel and it becomes a form.

### If the console will not start with the new settings

The helper restarts the console, then asks systemd three times over three
seconds whether it is actually running — `systemctl restart` returns as soon as
the process has been exec'd, and a console that rejects its own configuration
dies a moment later. If it is not up, the previous `web.env` goes back and the
console is restarted with it, and the panel says so.

That is what makes changing the listen address survivable. What it cannot save
you from is a *working* address you cannot reach: switch from `0.0.0.0` to
`127.0.0.1` while browsing from the LAN and the console comes up perfectly,
just not for you. The panel warns before saving that one; recovering it means
an SSH tunnel, or `web.env` on the host.

## Restoring an archive

Off unless the host says otherwise: `WEB_ALLOW_RESTORE=0` by default, and the
setup script asks before enabling `supabase-backup-restore.path`. Two switches
because they answer different questions — whether the console *offers* it, and
whether the host would *act* on a request at all.

The console never restores. `restore` does, as root, triggered by the same
spool pattern as everything else here: the identical script an operator runs by
hand, taking the same steps in the same order.

What made that script safe was a person answering its prompts. Those answers
are not dropped here, they are moved: a request has to name the archive, spell
out the target project ref by typing it, and carry a separate yes for each
question the script would have stopped on — a non-empty target, catalog errors,
a dry run or the real thing. Absent means no, so a request that simply omits a
question cannot bulldoze through it.

The root side re-checks every one, and re-derives the guard that matters most
from `/etc/supabase-backup/*.conf` — files the console cannot read: **it will
not write into a project this host backs up.** A restore that would overwrite a
backup source is refused there, whatever the request said.

A restore request carries the target's database password and service key, so
like registration it is refused over plain HTTP from the network.

**An encrypted archive cannot be restored from here at all.** Opening one needs
the age identity, and that is kept off this host on purpose — there is nothing
the console could ask for that would make it possible. So the button is not
offered on a `.tar.gz.age`, the reason is shown in its place, and a request
naming one is refused on both sides rather than failing halfway through.
`supabase-restore` at the terminal will ask for the key and restore it.

## Encrypting the archives

A project with an age recipients file gets its tarball encrypted to those
public keys — `<name>.tar.gz.age`, with a small plaintext sidecar so the
console can still say what is in an archive it cannot open.

**The identity that opens these archives is deliberately not on this host.**
Encrypting to a key the backup host also holds protects a stolen disk and
nothing else. Keeping the private half elsewhere means a host that is fully
compromised still yields no readable data — which is also why nothing here can
decrypt what it just wrote, and why a lost identity is a lost archive. Keep it
somewhere that outlives the host.

Recipients live in `/etc/supabase-backup-keys/<project>.recipients`, not in the
project's `.conf`: they are not secret, the two audiences differ, and the
console has to be able to read them to show what a project is encrypted to. A
non-empty file is the only switch — present means encrypt, absent means do not,
with no second copy of the setting to drift.

Setting them from the console goes the way everything else does: the console
writes a request, `supabase-backup-keys.service` validates each recipient by
making `age` itself accept it, and only then replaces the file. `age1…` public
keys and `ssh-ed25519`/`ssh-rsa` public keys are both accepted. Nothing in the
request is a secret, so unlike a registration it is not shredded.

Requires the `age` binary on the host; the setup script installs it, and says
so if it could not.

## What it deliberately does not do

- **Perform a restore itself.** It can ask for one, if the host was set up to
  allow it — see [Restoring an archive](#restoring-an-archive). The work is
  done by `restore` as root, and the guards are re-derived there from files
  this process cannot read.
- **Prune or delete.** `KEEP_DAYS` does that, on a schedule, with nobody
  clicking anything at 1 a.m.
- **Edit a project's configuration.** The per-project `.conf` files are edited
  on the host. This process cannot read one, never mind write one. Its own
  `web.env` is a different matter — see
  [Changing the console's own settings](#changing-the-consoles-own-settings).
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

## When the disk fills

The **Free space** card carries a forecast: how fast free space is going, and
the date it runs out on that trend.

**It is measured, not calculated.** A snapshot of the archive directory cannot
answer this. The archives show what arrives; they cannot show what the
retention prune took away, because what it took away is precisely what is no
longer there to count. A host whose footprint has been flat for a year and a
host filling steadily look identical in one `du`. So the console samples free
space hourly into `/var/lib/supabase-backup-web/space.jsonl` and fits a line
through what it actually saw.

**The sawtooth is the trap.** Free space on a backup host does not fall
smoothly — it drops a little every night and jumps back up whenever the prune
runs. A straight line through less than two of those cycles fits the falling
edge and confidently condemns a host that is perfectly stable. That is the one
mistake this card must not make, so whole cycles are averaged to a single point
each before anything is fitted. The cycle length is taken from the span the
retained archives cover, which is `KEEP_DAYS` measured rather than configured —
the console cannot read `KEEP_DAYS` itself, because it lives in a file holding
the project's database password.

What the card says, and what it is standing on:

| Line | Basis | Means |
|---|---|---|
| `full in 4 months` | two or more whole prune cycles | the real trend, sawtooth removed |
| `provisional · 12d short of 2 cycles` | a plain fit over the raw samples | may still be reading one falling edge as a trend |
| `full in 41 days at worst` | the rate archives arrive | no samples yet — what would happen if nothing were ever pruned |
| `not filling` | either fit, trend flat or rising | retention is holding, or nothing is growing |
| `trend: not enough history yet` | nothing | a fresh install with no archives |

The lead line turns amber under 60 days and red under 14. It is deliberately
not folded into the header pill: that pill is about whether the backups are
good, and a disk with three months left is not a backup that failed.

So a freshly installed console starts at `at worst`, moves to `provisional`
within three days, and gives a real answer after two retention periods — about
60 days on the default 30-day retention. It says which of those it is doing
rather than presenting all three as the same number.

## Exposure

The setup script asks. The default is `127.0.0.1:8787` — nothing new listens on
the network, and you reach it over a tunnel:

```sh
ssh -N -L 8787:127.0.0.1:8787 root@<host>     # then http://localhost:8787
```

That assumes the host permits TCP forwarding; see the warning under
[Registering a project](#it-will-not-do-this-over-plain-http) if it does not.

The alternative is `0.0.0.0:8787`, browsable directly at `http://<host>:8787`.
Basic auth over plain HTTP means the password crosses the network in the clear
on every request. On a trusted LAN that may be a fair trade; make it knowingly,
and put a TLS-terminating reverse proxy in front if anything less trusted
shares the network. Switching later is one line in `web.env` and a restart.

### Closing the plain-HTTP port

With a proxy in front, the console's own port is still open to the whole
network, and reaching it directly bypasses the TLS you just put there. Limit it
to the proxy and to loopback:

```sh
nft add rule inet filter input tcp dport 8787 iif lo accept
nft add rule inet filter input tcp dport 8787 ip saddr <proxy-address> accept
nft add rule inet filter input tcp dport 8787 reject with tcp reset
```

Use the address the proxy *connects from*, which is not necessarily the one it
listens on — a multi-homed proxy differs in both, and the wrong one fails
closed with no clue why. The console's own log tells you: a proxied request
appears as `<client> via <proxy>/<scheme>`.

Nothing else is filtered; every chain keeps its accept policy, so this is a lock
on one port rather than a firewall. Put the same three rules in
`/etc/nftables.conf` to survive a reboot, and check with `nft -c -f` first.

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
| `WEB_ALLOW_REGISTER` | `1` | Offer the "Add a project" form at all |
| `WEB_ALLOW_SETTINGS` | `1` | Offer the "Console settings" panel at all |
| `WEB_ALLOW_RESTORE` | `0` | Offer to ask the host for a restore |
| `WEB_ALLOW_ENCRYPTION` | `1` | Offer to set a project's age recipients |
| `KEYS_DIR` | `/etc/supabase-backup-keys` | Where the per-project recipients files live |
| `WEB_TRUSTED_PROXIES` | — | Comma-separated proxy addresses trusted to assert `X-Forwarded-Proto` |
| `WEB_SPOOL_DIR` | `/run/supabase-backup-web` | Spool shared with the privileged helpers |
| `WEB_STATE_DIR` | `/var/lib/supabase-backup-web` | Where the free-space history is kept |
| `WEB_SAMPLE_SECONDS` | `3600` | How often free space is sampled |
| `WEB_HISTORY_DAYS` | `90` | How much of that history is kept |
| `WEB_FORECAST_DAYS` | `30` | Window for the provisional fit, before two cycles exist |
| `WEB_FORECAST_MIN_DAYS` | `3` | History needed before any fit is attempted |

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
next page load; only `server.py` and `web.env` need a restart. The Settings
panel does that restart for you — that is the whole reason a change made there
takes a couple of seconds.

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

**The "Add a project" form is replaced by a notice.** You are connected over
plain HTTP from the network, and registering sends a service key. Reach the
console through the TLS proxy on this host or over an SSH tunnel. If the tunnel
opens but nothing reaches the console, check `sshd -T | grep allowtcpforwarding`
on the host — hardened hosts disable it.

**A registration stays "applying…" forever.** The helper is not running. Check
`systemctl status supabase-backup-register.path` — it must be enabled and
active — and `journalctl -u supabase-backup-register -n 30` for what happened
when it last fired. If the spool directory is missing, run
`systemd-tmpfiles --create /etc/tmpfiles.d/supabase-backup-web.conf`.

**The settings dialog shows a notice instead of a form.** One of three things,
and the notice says which: you are connected over plain HTTP from the network;
`WEB_ALLOW_SETTINGS=0`; or the helper is not installed, which means
`/run/supabase-backup-web/settings` does not exist. For the last one, re-run
`supabase-backup-web-setup.sh`, or:

```sh
systemd-tmpfiles --create /etc/tmpfiles.d/supabase-backup-web.conf
systemctl enable --now supabase-backup-reconfigure.path
```

**A settings save says the console did not come back.** It restarts as part of
saving, so a few seconds of silence is normal and the page waits it out. Past
that, either it is listening somewhere else now — you changed `WEB_BIND` to an
address that does not reach you — or it would not start, in which case the
helper has already put the old `web.env` back:

```sh
journalctl -u supabase-backup-reconfigure -n 30    # what the helper did
systemctl status supabase-backup-web
```

**Locked out: nobody knows the password.** The way in is the way it was set up
in the first place, on the host:

```sh
/opt/supabase-backup/web/server.py --hash          # prints a WEB_PASSWORD_HASH line
$EDITOR /etc/supabase-backup-web/web.env           # replace the line
systemctl restart supabase-backup-web
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
- A project can be added but not edited or removed from the console. Changing
  credentials or retiring a project is still done on the host.
- One account. The console has a single Basic auth user, and the Settings panel
  changes that one's name and password. There is no second account and no
  per-person audit trail beyond the journal — if several people use it, they
  share the password.
- The panel changes the console's own settings and nothing else. A project's
  retention and credentials live in files this process is deliberately unable
  to read, so `KEEP_DAYS` is still changed on the host.
- The console knows nothing about offsite copies. A green header means the
  local archives are good, not that anything offsite is.
- The free-space forecast is a straight line, and a straight line is wrong
  about anything that accelerates — a project whose data is growing
  exponentially will fill the disk sooner than the card says. It also measures
  the whole filesystem, so something else on the host filling it up shows here
  as a backup problem.
- The history only exists where the console is running. A console that is
  stopped for a month has a month-shaped hole, and one that has never run
  cannot say anything beyond the ceiling.
