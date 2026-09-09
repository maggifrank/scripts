#!/usr/bin/env python3
"""
supabase-backup-web - a web console for a supabase-backup host.

It answers the question a timer cannot: did last night's backup work, and is
what it wrote any good? For every project on the host it shows the archives
with their manifests, the run history, when the next run is due, and it can
verify an archive against its own checksums and its own inventory.

It can also ask for a restore, if the host has been configured to allow it
(WEB_ALLOW_RESTORE, off by default). It does not perform one: `restore` does,
as root, triggered by a spool directory - the same script, the same steps, the
same guards. What made those guards hold was that a person answered for them,
so the request has to answer for them too, in advance and in full: which
archive, the target ref typed out, and a yes to each question the script would
otherwise have asked. The root side re-checks every one and refuses the rest.

Python standard library only, matching backup.sh's posture: no pip, no
virtualenv, no container, nothing that needs keeping up to date.

  server.py            serve; configuration comes from the environment
  server.py --hash     print a WEB_PASSWORD_HASH line and exit

Configuration lives in /etc/supabase-backup-web/web.env. That is a different file
from the per-project .conf files on purpose: this process never needs a
database password or a service key, so it must not be able to read one.

It cannot write that file either. The settings page changes it the same way
registering a project writes a config: by leaving a request for a root helper.
Upgrading goes the same way and for a stronger reason - /opt is read-only to
this process, so it can say what version is running and ask for a newer one,
and root does the installing.

The one thing it keeps for itself is an hourly free-space sample, under
/var/lib/supabase-backup-web. Nothing else here needs history - health is read
off files that are still on disk - but "when does this disk fill" cannot be
answered from a single snapshot, so it is measured rather than guessed.
"""

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────────

def env(name, default=None):
    v = os.environ.get(name)
    return default if v is None or v == "" else v

def env_bool(name, default):
    return env(name, "1" if default else "0").strip().lower() in ("1", "true", "yes", "on")

DATA_DIR       = Path(env("DATA_DIR", "/var/backups/supabase"))
BIND           = env("WEB_BIND", "127.0.0.1:8787")
UNIT_PREFIX    = env("UNIT_PREFIX", "supabase-backup")
WEB_USER       = env("WEB_USER", "admin")
PASSWORD_HASH  = env("WEB_PASSWORD_HASH", "")
ALLOW_ANON     = env_bool("WEB_ALLOW_ANONYMOUS", False)
ALLOW_RUN      = env_bool("WEB_ALLOW_RUN", True)
ALLOW_DOWNLOAD = env_bool("WEB_ALLOW_DOWNLOAD", False)
STALE_HOURS    = float(env("WEB_STALE_HOURS", "26"))

# Plain systemctl by default: an unprivileged start goes through polkit, so
# nothing has to be setuid and the unit keeps NoNewPrivileges=true. {unit} is
# substituted with the instance being started.
RUN_COMMAND = env("WEB_RUN_COMMAND", "systemctl start --no-block {unit}")

STATIC_DIR = Path(__file__).resolve().parent / "static"

# Registering a project is the one thing here that writes anything, and the
# only thing that handles a credential. The console still writes nothing
# privileged: it drops a request in a spool directory it owns, and a root
# oneshot triggered by a .path unit validates and applies it. See
# scripts/supabase-backup/register.
SPOOL_DIR      = Path(env("WEB_SPOOL_DIR", "/run/supabase-backup-web"))
REGISTER_DIR   = SPOOL_DIR / "register"
RESULT_DIR     = SPOOL_DIR / "results"
ALLOW_REGISTER = env_bool("WEB_ALLOW_REGISTER", True)

# Changing the console's own settings goes the same way, for the same reason:
# this process cannot write its own configuration and cannot restart itself. It
# leaves a request; supabase-backup-reconfigure.service edits web.env and
# restarts the unit. The helper takes no path from the request - it edits the
# file it was built to edit - and never receives a plaintext password.
SETTINGS_DIR   = SPOOL_DIR / "settings"
ALLOW_SETTINGS = env_bool("WEB_ALLOW_SETTINGS", True)
# Shown on the settings page so it can name the file. Never sent to the helper.
WEB_ENV_PATH   = env("WEB_ENV_PATH", "/etc/supabase-backup-web/web.env")
WEB_UNIT       = env("WEB_UNIT", "supabase-backup-web.service")
# The other half of that spool: a restore request. Off unless the host says
# otherwise - a restore writes into a live project and cannot be taken back,
# and a console that can do it by default is not the default anyone chose.
RESTORE_DIR    = SPOOL_DIR / "restore"
ALLOW_RESTORE  = env_bool("WEB_ALLOW_RESTORE", False)

# Free-space history. systemd makes STATE_DIR and hands it over owned by this
# user; nothing else on the host reads it, and it holds no secret - only how
# much room was left, and when.
STATE_DIR         = Path(env("WEB_STATE_DIR", "/var/lib/supabase-backup-web"))
SPACE_FILE        = STATE_DIR / "space.jsonl"
SAMPLE_SECONDS    = float(env("WEB_SAMPLE_SECONDS", "3600"))
# Kept so a person can read the history back. The forecast only ever looks at
# the window below.
HISTORY_DAYS      = float(env("WEB_HISTORY_DAYS", "90"))
# One default retention period: short enough to follow a change in the trend,
# long enough to hold a whole arrive-and-prune cycle rather than half of one.
FORECAST_DAYS     = float(env("WEB_FORECAST_DAYS", "30"))
# Under this there is no baseline for a straight line to mean anything. One
# nightly run and one prune are two steps, not a trend.
FORECAST_MIN_DAYS = float(env("WEB_FORECAST_MIN_DAYS", "3"))

# Encryption. The keys a project's archives are encrypted to are age
# recipients - public keys - so they sit in their own directory and this
# process reads them directly. It could not read them from /etc/supabase-backup
# even if they were there: that path holds service keys and the unit puts it
# out of reach. Deciding what they are still needs root, and goes through the
# spool like every other privileged thing here.
KEYS_DIR         = Path(env("KEYS_DIR", "/etc/supabase-backup-keys"))
ENCRYPTION_DIR   = SPOOL_DIR / "encryption"
ALLOW_ENCRYPTION = env_bool("WEB_ALLOW_ENCRYPTION", True)

# Rotating a project's credentials. The console cannot read the ones in force -
# /etc/supabase-backup is out of its reach and stays that way - so this only
# ever carries new ones towards the helper that can. Rotation was an SSH
# session and a text editor before this, which is why it did not happen, and a
# credential that is never rotated has been exposed since the day it was made.
CREDENTIALS_DIR   = SPOOL_DIR / "credentials"
ALLOW_CREDENTIALS = env_bool("WEB_ALLOW_CREDENTIALS", True)

# Upgrading. The console cannot replace the code it is running - /opt is
# read-only to it - so this goes through the spool like everything else
# privileged here: it asks, and supabase-backup-upgrade.service downloads and
# installs as root. The one thing the console does for itself is the check,
# which needs no privilege at all: `upgrade --check` reads a file under /opt
# and asks GitHub what it publishes. Running the same script the helper runs
# means there is one answer to "what version is this", not two.
UPGRADE_DIR     = SPOOL_DIR / "upgrade"
ALLOW_UPGRADE   = env_bool("WEB_ALLOW_UPGRADE", True)
UPGRADE_SCRIPT  = Path(env("WEB_UPGRADE_SCRIPT", "/opt/supabase-backup/upgrade"))
UPGRADE_UNIT    = env("WEB_UPGRADE_UNIT", f"{UNIT_PREFIX}-upgrade.service")
# The check goes to the network, and the settings panel asks on every open, so
# `upgrade` caches its answer. Its own default lives under
# /var/lib/supabase-backup, which is root's; this process has exactly one
# writable directory on a real disk, and this is it.
UPGRADE_CACHE   = Path(env("WEB_UPGRADE_CACHE", str(STATE_DIR / "upgrade-check.json")))
# Release notes for the versions this host has. What is *ahead* of it comes
# from the commit list in the check instead: this file only ever describes
# what is installed, which is the honest thing for it to describe.
CHANGELOG_FILE  = Path(env("WEB_CHANGELOG", "/opt/supabase-backup/CHANGELOG.md"))
CHANGELOG_MAX   = 256 * 1024

# A proxy terminating TLS on another host, trusted to speak for the client.
TRUSTED_PROXIES = {h.strip() for h in env("WEB_TRUSTED_PROXIES", "").split(",") if h.strip()}
# How long a request may sit unread before the console stops calling it
# progress. Generous: the helpers test a database connection and a service key,
# which is seconds, not minutes.
STALL_SECONDS = float(env("WEB_STALL_SECONDS", "120"))
SPOOL_UNITS = {
    "register":   "supabase-backup-register",
    "restore":    "supabase-backup-restore",
    "settings":   "supabase-backup-settings",
    "encryption": "supabase-backup-keys",
    "upgrade":    "supabase-backup-upgrade",
}
MAX_BODY = 64 * 1024
LOOPBACK = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}

# A project name is a directory under DATA_DIR and a systemd instance name.
# Constraining it to this shape is what makes every path and unit name below
# safe to build by interpolation: no traversal and no escaping are expressible.
#
# Deliberately wider than supabase-backup-setup.sh's own rule (lowercase, digits,
# - and _). Matching that exactly would be stricter, but this list is how an
# operator finds out what is on the host: a directory made by hand, or by some
# older version of the tool, should show up and be judged - not be silently
# omitted from a page whose whole job is to say what is there.
PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
STAMP_RE = r"\d{8}T\d{6}Z"

PBKDF2_ITERATIONS = 600_000


# ── Password hashing ───────────────────────────────────────────────────────
# Basic auth, because it needs no session store, no cookies and no JavaScript.
# web.env holds only a PBKDF2 digest, so a leaked config file does not hand
# over the console.

def hash_password(password, iterations=PBKDF2_ITERATIONS, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return f"pbkdf2_sha256${iterations}${salt.hex()}${dk.hex()}"


def check_password(password, encoded):
    try:
        algo, iterations, salt_hex, dk_hex = encoded.split("$")
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), bytes.fromhex(salt_hex), int(iterations))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(dk.hex(), dk_hex)


# ── Time helpers ───────────────────────────────────────────────────────────

def iso(epoch):
    if not epoch:
        return None
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp_to_epoch(stamp):
    """'20260903T112733Z' - the stamp backup.sh puts in an archive name."""
    try:
        return datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(
            tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def parse_systemd_time(value):
    """systemd hands timestamps back in two different shapes.

    Under --timestamp=unix most come back as '@1788462966'. Some ignore that
    option entirely - a timer's NextElapseUSecRealtime is always formatted, as
    'Fri 2026-09-04 03:28:29 UTC' - so both have to be handled. Parsing both
    also means no dependency on the systemd version.

    An empty value means "this has not happened", which is not a time.
    """
    value = (value or "").strip()
    if not value or value == "n/a":
        return None
    if value.startswith("@"):
        try:
            return float(value[1:])
        except ValueError:
            return None
    parts = value.split()
    if len(parts) < 3:
        return None
    try:
        naive = datetime.strptime(f"{parts[1]} {parts[2]}", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    if (parts[3] if len(parts) > 3 else "") in ("UTC", "GMT", "Z"):
        return naive.replace(tzinfo=timezone.utc).timestamp()
    # Any other abbreviation is the host's own local time, and this process
    # runs on that host, so reading it as local is the right interpretation.
    return naive.timestamp()


# ── systemd ────────────────────────────────────────────────────────────────

def unit_for(project, kind):
    return f"{UNIT_PREFIX}@{project}.{kind}"


def run_cmd(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def systemctl_show(unit, properties):
    """`systemctl show` as a dict, or None where there is no systemd at all.

    A missing systemd is not worth crashing over: it is what running this on a
    workstation looks like, and every panel that depends on it can say so.
    """
    args = ["systemctl", "show", "--timestamp=unix", unit]
    args += [f"--property={p}" for p in properties]
    out = run_cmd(args, timeout=10)
    if out is None or out.returncode != 0:
        return None
    result = {}
    for line in out.stdout.splitlines():
        key, _, value = line.partition("=")
        if key:
            result[key] = value
    return result


def service_state(project):
    props = systemctl_show(unit_for(project, "service"), [
        "LoadState", "ActiveState", "SubState", "Result",
        "ExecMainStartTimestamp", "ExecMainExitTimestamp", "ExecMainStatus",
    ])
    if props is None:
        return {"available": False}
    active = props.get("ActiveState", "unknown")
    started = parse_systemd_time(props.get("ExecMainStartTimestamp"))
    exited = parse_systemd_time(props.get("ExecMainExitTimestamp"))
    return {
        "available": True,
        "loaded": props.get("LoadState") == "loaded",
        "active_state": active,
        "sub_state": props.get("SubState"),
        "result": props.get("Result"),
        "running": active in ("activating", "active", "reloading"),
        "started_at": iso(started),
        "finished_at": iso(exited),
        "duration_s": round(exited - started, 1) if started and exited and exited >= started else None,
    }


def timer_state(project):
    props = systemctl_show(unit_for(project, "timer"), [
        "LoadState", "ActiveState", "UnitFileState",
        "NextElapseUSecRealtime", "LastTriggerUSec",
    ])
    if props is None:
        return {"available": False}
    # Despite the names these are not microsecond counts: systemctl renders
    # them as timestamps, and NextElapseUSecRealtime ignores --timestamp=unix.
    return {
        "available": True,
        "loaded": props.get("LoadState") == "loaded",
        "active": props.get("ActiveState") == "active",
        "enabled": props.get("UnitFileState") in ("enabled", "enabled-runtime"),
        "next_run": iso(parse_systemd_time(props.get("NextElapseUSecRealtime"))),
        "last_trigger": iso(parse_systemd_time(props.get("LastTriggerUSec"))),
    }


def journal_runs(project, limit=10, max_lines=4000):
    """Recent runs, reconstructed from the journal and grouped by invocation.

    Only as deep as the journal goes. Debian keeps it in memory unless
    /var/log/journal exists, so after a reboot this can be empty while every
    archive is still there. The archives, not this, are the record of what
    succeeded.
    """
    out = run_cmd([
        "journalctl", "-u", unit_for(project, "service"), "-n", str(max_lines),
        "-o", "json", "--no-pager",
        "--output-fields=MESSAGE,_SYSTEMD_INVOCATION_ID,__REALTIME_TIMESTAMP,PRIORITY",
    ])
    if out is None:
        return {"available": False, "runs": []}
    if out.returncode != 0:
        return {"available": False, "runs": [], "error": out.stderr.strip()[:300]}

    runs, order, loose = {}, [], []
    for line in out.stdout.splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        message = rec.get("MESSAGE")
        if isinstance(message, list):        # journald hands back bytes as ints
            message = bytes(message).decode("utf-8", "replace")
        if not isinstance(message, str):
            continue
        try:
            ts = int(rec.get("__REALTIME_TIMESTAMP", 0)) / 1e6
        except (TypeError, ValueError):
            ts = 0
        try:
            priority = int(rec.get("PRIORITY", 6))
        except (TypeError, ValueError):
            priority = 6
        entry = {"t": iso(ts), "m": message, "err": priority <= 3}

        inv = rec.get("_SYSTEMD_INVOCATION_ID")
        if not inv:
            # systemd's own lines about the unit - "Starting...", "Finished...",
            # "Failed with result ..." - are logged by PID 1, not by the script,
            # and carry no invocation id. Grouping them by that id invented a
            # phantom run holding every one of them. Set them aside and attach
            # each to the run it actually belongs to, below: "Failed with
            # result" is sometimes the only evidence a run died.
            loose.append((ts, entry))
            continue

        if inv not in runs:
            runs[inv] = {"id": inv, "started": ts, "ended": ts, "lines": []}
            order.append(inv)
        run = runs[inv]
        run["ended"] = max(run["ended"], ts)
        run["started"] = min(run["started"], ts) if run["started"] else ts
        run["lines"].append(entry)

    # Attach each stray line to the run it sits inside, or to one starting just
    # after it ("Starting..." precedes the script's first output). Anything that
    # matches no run is bookkeeping from a run the journal no longer holds, and
    # is dropped rather than shown as a run of its own.
    GRACE = 120.0
    for ts, entry in loose:
        best = None
        for inv in order:
            run = runs[inv]
            if run["started"] - GRACE <= ts <= run["ended"] + GRACE:
                distance = 0 if run["started"] <= ts <= run["ended"] else min(
                    abs(ts - run["started"]), abs(ts - run["ended"]))
                if best is None or distance < best[0]:
                    best = (distance, inv)
        if best is not None:
            run = runs[best[1]]
            run["lines"].append(entry)
            run["ended"] = max(run["ended"], ts)
            run["started"] = min(run["started"], ts)

    for run in runs.values():
        run["lines"].sort(key=lambda l: l["t"] or "")

    result = []
    for inv in order[-limit:]:
        run = runs[inv]
        text = "\n".join(l["m"] for l in run["lines"])
        # backup.sh says "backup <name> complete" as its very last act and
        # nothing else prints it. Anything short of that did not finish. Its
        # log() prefixes every line with a UTC HH:MM:SS, so the marker sits at
        # the end of a line, never at the start of one.
        if re.search(r"backup \S+ complete\s*$", text, re.M):
            outcome = "success"
        elif "ERROR:" in text or "Failed with result" in text or "Main process exited" in text:
            outcome = "failed"
        else:
            outcome = "unknown"
        result.append({
            "id": run["id"],
            "started_at": iso(run["started"]),
            "ended_at": iso(run["ended"]),
            "duration_s": round(run["ended"] - run["started"], 1),
            "outcome": outcome,
            "lines": run["lines"],
        })
    result.reverse()
    return {"available": True, "runs": result}


# ── Projects and archives ──────────────────────────────────────────────────

def discover_projects():
    """Every project this host backs up, from two independent sources.

    A directory under DATA_DIR is the ground truth for "has archives"; a
    supabase-backup@<project>.timer is the ground truth for "is scheduled".
    Taking the union means a project configured but not yet run still appears -
    and so does one whose timer was removed but whose archives remain, rather
    than quietly vanishing from the console.

    Neither source is /etc/supabase-backup: those files hold service keys and
    database passwords, and this process has no business reading them.
    """
    found, error = set(), None
    try:
        for entry in os.scandir(DATA_DIR):
            if entry.is_dir() and PROJECT_RE.match(entry.name):
                found.add(entry.name)
    except OSError as exc:
        error = str(exc)

    out = run_cmd(["systemctl", "list-units", "--all", "--plain", "--no-legend",
                   "--no-pager", f"{UNIT_PREFIX}@*.timer"])
    if out is not None and out.returncode == 0:
        for line in out.stdout.splitlines():
            unit = line.split()[0] if line.split() else ""
            match = re.fullmatch(rf"{re.escape(UNIT_PREFIX)}@(.+)\.timer", unit)
            if match and PROJECT_RE.match(match.group(1)):
                found.add(match.group(1))
    return sorted(found), error


def project_dir(project):
    return DATA_DIR / project if PROJECT_RE.match(project or "") else None


AGE_RECIPIENT_RE = re.compile(r"^age1[023456789acdefghjklmnpqrstuvwxyz]{58}$")
SSH_RECIPIENT_RE = re.compile(r"^ssh-(ed25519|rsa) [A-Za-z0-9+/]+={0,3}( \S.{0,200})?$")


def project_encryption(project):
    """What a project's archives are being encrypted to, right now.

    The recipients file is the only switch backup.sh has: present and non-empty
    means encrypt, absent means do not. Reading the same file is what keeps
    this panel honest - there is no second copy of the setting here to drift
    away from what the nightly run will actually do.

    'unreadable' is kept apart from 'off' for the same reason the archive
    states are: a directory this process cannot see would otherwise be reported
    as a project with encryption switched off, which is a much calmer thing
    than not knowing.
    """
    if not PROJECT_RE.match(project or ""):
        return {"enabled": False, "recipients": [], "error": "invalid project name"}
    path = KEYS_DIR / f"{project}.recipients"
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {"enabled": False, "recipients": [], "path": str(path), "error": None}
    except OSError as exc:
        return {"enabled": False, "recipients": [], "path": str(path),
                "error": f"cannot read {path}: {exc}"}
    recipients = [line.strip() for line in text.splitlines()
                  if line.strip() and not line.lstrip().startswith("#")]
    return {"enabled": bool(recipients), "recipients": recipients,
            "path": str(path), "error": None}


def sidecar_path(path):
    """The plaintext metadata written beside an encrypted archive.

    <project>-<stamp>.tar.gz.age is accompanied by <project>-<stamp>.meta.json.
    It is what lets a reader holding no key still say what an archive contains
    and whether it is damaged.
    """
    name = path.name
    for suffix in (".tar.gz.age", ".tar.gz"):
        if name.endswith(suffix):
            return path.with_name(name[:-len(suffix)] + ".meta.json")
    return None


def read_sidecar(path):
    """The sidecar for an archive, or None if there is not one to read."""
    meta = sidecar_path(path)
    if meta is None:
        return None, None
    try:
        return json.loads(meta.read_text()), None
    except FileNotFoundError:
        return None, "no sidecar was written beside it"
    except (OSError, ValueError) as exc:
        return None, f"{type(exc).__name__}: {exc}"


def list_archives(project):
    directory = project_dir(project)
    if directory is None:
        return {"error": "invalid project name", "archives": [], "partials": []}
    archive_re = re.compile(rf"^{re.escape(project)}-({STAMP_RE})\.tar\.gz(\.age)?$")
    partial_re = re.compile(rf"^{re.escape(project)}-({STAMP_RE})\.tar\.gz(\.age)?\.partial$")
    archives, partials = [], []
    try:
        entries = list(os.scandir(directory))
    except OSError as exc:
        return {"error": str(exc), "archives": [], "partials": []}
    for entry in entries:
        if not entry.is_file():
            continue
        match = archive_re.match(entry.name)
        if match:
            st = entry.stat()
            row = {
                "name": entry.name,
                "stamp": match.group(1),
                "captured_at": iso(stamp_to_epoch(match.group(1))),
                "written_at": iso(st.st_mtime),
                "bytes": st.st_size,
                "encrypted": bool(match.group(2)),
            }
            if row["encrypted"]:
                # Which keys open this one, which is not necessarily which keys
                # open the newest: a rotation leaves both on disk, and the
                # difference is exactly what someone restoring needs to know.
                meta, error = read_sidecar(directory / entry.name)
                row["recipients"] = (meta or {}).get("encryption", {}).get("recipients", [])
                row["sidecar_error"] = error
            archives.append(row)
        elif partial_re.match(entry.name):
            # backup.sh writes under .partial and renames on success, so one of
            # these is a run happening now or the debris of a failed one.
            partials.append({"name": entry.name, "bytes": entry.stat().st_size})
    archives.sort(key=lambda a: a["stamp"], reverse=True)
    return {"archives": archives, "partials": partials}


def archive_path(project, name):
    directory = project_dir(project)
    if directory is None:
        return None
    if not re.fullmatch(rf"{re.escape(project)}-{STAMP_RE}\.tar\.gz(\.age)?", name):
        return None
    path = directory / name
    return path if path.is_file() else None


def tar_name(name):
    """`tar -czf ... -C "$WORK" .` stores members as './manifest.json'."""
    return name[2:] if name.startswith("./") else name


_manifest_cache = {}

def read_manifest(path):
    if path.name.endswith(".age"):
        # There is no reading it out of the tarball: that is the point. What
        # the run published beside it is all there is, and if it published
        # nothing then this console knows nothing, and says so.
        meta, error = read_sidecar(path)
        if error:
            return {"error": f"this archive is encrypted, and {error}"}
        manifest = meta.get("manifest")
        if manifest is None:
            return {"error": "this archive is encrypted and was written without publishing "
                             "its manifest (SIDECAR_MANIFEST=0). Only whoever holds the "
                             "identity can say what is in it."}
        return manifest
    st = path.stat()
    key = (str(path), st.st_size, st.st_mtime)
    if key in _manifest_cache:
        return _manifest_cache[key]
    manifest = None
    try:
        with tarfile.open(path, "r:gz") as tf:
            for member in tf:
                if member.isfile() and tar_name(member.name) == "manifest.json":
                    manifest = json.loads(tf.extractfile(member).read(1 << 20).decode("utf-8"))
                    break
    except (OSError, tarfile.TarError, ValueError) as exc:
        manifest = {"error": f"{type(exc).__name__}: {exc}"}
    _manifest_cache.clear()          # one archive is read at a time; stay small
    _manifest_cache[key] = manifest
    return manifest


def verify_encrypted(path):
    """Check an encrypted archive without being able to read it.

    Everything the plaintext check relies on lives inside the tarball, and the
    tarball is ciphertext here. What remains is the digest the run recorded of
    exactly these bytes, so the question this answers is narrower and worth
    stating exactly: the archive on disk is bit-for-bit what was written, or it
    is not.

    That catches the thing verification is actually for - a disk that rotted, a
    copy that truncated, a file that changed. It cannot catch a tarball that
    was already wrong when it was encrypted, and neither could reading it: the
    run that wrote it is the only thing positioned to check that, and it does,
    against storage.objects, before it encrypts anything.
    """
    meta, error = read_sidecar(path)
    if error:
        return {"ok": False, "encrypted": True,
                "fatal": f"{error}, so there is nothing to check these bytes against. "
                         "The archive may be perfectly good; this console cannot tell."}

    expected = (meta.get("sha256") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        return {"ok": False, "encrypted": True,
                "fatal": "the sidecar carries no usable sha256 for this archive"}

    digest = hashlib.sha256()
    header = b""
    size = 0
    try:
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(1 << 20)
                if not chunk:
                    break
                if not header:
                    header = chunk[:64]
                digest.update(chunk)
                size += len(chunk)
    except OSError as exc:
        return {"ok": False, "encrypted": True, "fatal": f"cannot read archive: {exc}"}

    actual = digest.hexdigest()
    sha_ok = hmac.compare_digest(actual, expected)
    # Cheap, and it separates "these bytes are not what was written" from "this
    # is not an age file at all" - which is what a half-finished copy or a
    # plaintext archive wearing the wrong name looks like.
    header_ok = header.startswith(b"age-encryption.org/v1")
    expected_bytes = meta.get("bytes")
    size_ok = expected_bytes is None or int(expected_bytes) == size

    return {
        "ok": sha_ok and header_ok and size_ok,
        "encrypted": True,
        "sha256_ok": sha_ok,
        "header_ok": header_ok,
        "size_ok": size_ok,
        "expected_sha256": expected,
        "actual_sha256": actual,
        "bytes": size,
        "expected_bytes": expected_bytes,
        "recipients": (meta.get("encryption") or {}).get("recipients", []),
        "manifest": meta.get("manifest"),
        # The plaintext verifier's vocabulary, empty. Nothing here can populate
        # these, and a reader that expects them should see that plainly rather
        # than an absence it has to interpret.
        "checked": 0,
        "mismatched": [],
        "missing": [],
        "unlisted": [],
        "filelist_orphans": [],
        "files_in_archive": None,
        "counts_agree": None,
    }


def verify_archive(path):
    """Re-check an archive against its own SHA256SUMS, filelist and manifest.

    Streams the tarball once and hashes as it goes: nothing is written to disk,
    so this is safe on a host with less free space than the archive - unlike
    extracting it into /tmp first.

    It checks that the archive is intact and internally consistent. It cannot
    check it against the project, because only the run that wrote it could:
    backup.sh compares its storage walk against storage.objects and refuses to
    finalise an archive that disagrees.
    """
    if path.name.endswith(".age"):
        return verify_encrypted(path)

    sums_text = None
    digests, keep = {}, {}
    files_seen = []
    try:
        with tarfile.open(path, "r|gz") as tf:
            for member in tf:
                if not member.isfile():
                    continue
                name = tar_name(member.name)
                fh = tf.extractfile(member)
                if fh is None:
                    continue
                if name == "SHA256SUMS":
                    sums_text = fh.read(1 << 22).decode("utf-8", "replace")
                    continue
                digest = hashlib.sha256()
                buffered = bytearray() if (name in ("filelist.txt", "manifest.json")
                                           and member.size < (1 << 22)) else None
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk:
                        break
                    digest.update(chunk)
                    if buffered is not None:
                        buffered += chunk
                if buffered is not None:
                    keep[name] = bytes(buffered)
                digests[name] = digest.hexdigest()
                if name.startswith("files/"):
                    files_seen.append(name[len("files/"):])
    except (OSError, tarfile.TarError) as exc:
        return {"ok": False, "fatal": f"cannot read archive: {exc}"}

    if sums_text is None:
        return {"ok": False, "fatal": "archive has no SHA256SUMS"}

    checked, mismatched, missing = 0, [], []
    listed = set()
    for line in sums_text.splitlines():
        expected, _, name = line.partition("  ")
        name = tar_name(name.strip())
        if not expected or not name:
            continue
        listed.add(name)
        actual = digests.get(name)
        if actual is None:
            missing.append(name)
        elif not hmac.compare_digest(actual, expected.strip()):
            mismatched.append(name)
        else:
            checked += 1
    # backup.sh writes the manifest before taking the checksums, so every
    # member is covered and anything unlisted means the tar and the sums
    # disagree about what this archive is.
    unlisted = sorted(set(digests) - listed)

    # The archive audits itself: every path the storage walk recorded has to be
    # present as a file, and the manifest's count has to match what is here.
    filelist = keep.get("filelist.txt", b"").decode("utf-8", "replace")
    wanted = [p.strip() for p in filelist.splitlines() if p.strip()]
    have = set(files_seen)
    orphans = [p for p in wanted if p not in have]

    manifest, manifest_error = None, None
    try:
        manifest = json.loads(keep.get("manifest.json", b"{}").decode("utf-8"))
    except ValueError as exc:
        manifest_error = str(exc)

    counts_agree = None
    if manifest and "storage_objects" in manifest:
        counts_agree = int(manifest["storage_objects"]) == len(files_seen)

    ok = (not mismatched and not missing and not unlisted and not orphans
          and manifest_error is None and counts_agree is not False)
    return {
        "ok": ok,
        "checked": checked,
        "mismatched": mismatched,
        "missing": missing,
        "unlisted": unlisted,
        "files_in_archive": len(files_seen),
        "files_in_filelist": len(wanted),
        "filelist_orphans": orphans[:50],
        "manifest": manifest,
        "manifest_error": manifest_error,
        "counts_agree": counts_agree,
    }


# ── Free space ─────────────────────────────────────────────────────────────
# "When does this disk fill?" has no answer in a single snapshot. The archives
# on disk show what arrives; they cannot show what the retention prune takes
# away, because what it took away is precisely what is no longer there to
# count. A host whose footprint has been flat for a year and a host filling
# steadily look identical in one `du`.
#
# So free space is sampled on a clock and the forecast is fitted to what was
# actually observed - with one correction that matters more than the fit does.
# Free space here is a sawtooth: down a little every night, back up whenever
# the prune runs. A straight line through less than two of those cycles reads
# the falling edge as the trend and condemns a perfectly stable host, which is
# the one mistake this card must not make. So whole cycles are averaged away
# before anything is fitted, and until two of them exist the console says which
# weaker ground it is standing on rather than quietly standing on it.

# Past this, a projection stops being a forecast and becomes arithmetic about a
# host that will have been rebuilt twice over.
FOREVER_DAYS = 1825


def disk_usage():
    try:
        u = shutil.disk_usage(DATA_DIR)
    except OSError:
        return None
    return {"total": u.total, "used": u.used, "free": u.free}


def archive_history(projects):
    """(epoch, bytes) for every archive on the host, oldest first."""
    written = []
    for project in projects:
        for a in list_archives(project).get("archives", []):
            epoch = stamp_to_epoch(a["stamp"])
            if epoch:
                written.append((epoch, a["bytes"]))
    written.sort()
    return written


def arrival_rate(written):
    """Bytes of archive written per day, and the span that rests on.

    Every archive written inside the span the retained set covers is still
    there - pruning only ever takes from the far end - so this rate is exact
    for that span. It is a ceiling on what the backups can cost, not a
    forecast: it counts what arrives and knows nothing of what leaves.
    """
    if len(written) < 2:
        return None, None
    span_days = (written[-1][0] - written[0][0]) / 86400
    if span_days < 1:
        return None, None
    # The oldest archive was written before this span opened, so its bytes did
    # not arrive during it.
    return sum(b for _, b in written[1:]) / span_days, span_days


_samples = []                   # [{"t", "free", "total", "archives"}, ...]
_samples_lock = threading.Lock()
_history_error = None           # why the history is not being kept, if it is not


def load_samples():
    """Read the sample file back, skipping anything that does not parse.

    A line can be torn - the process can be killed mid-write - and one bad line
    must not cost the other two thousand.
    """
    global _history_error
    rows = []
    try:
        with SPACE_FILE.open() as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if (isinstance(row, dict)
                        and isinstance(row.get("t"), (int, float))
                        and isinstance(row.get("free"), (int, float))):
                    rows.append(row)
    except FileNotFoundError:
        return []
    except OSError as exc:
        _history_error = f"cannot read {SPACE_FILE}: {exc}"
        return []
    rows.sort(key=lambda r: r["t"])
    return rows


def take_sample(now=None):
    """Record one observation of free space. Returns it, or None."""
    global _history_error
    now = now or time.time()
    disk = disk_usage()
    if disk is None:
        return None
    projects, _ = discover_projects()
    row = {"t": int(now), "free": disk["free"], "total": disk["total"],
           "archives": sum(b for _, b in archive_history(projects))}

    with _samples_lock:
        # A restart loop must not become a hundred samples an hour: a cluster
        # of them inside one minute would weight the whole fit towards that
        # minute.
        if _samples and now - _samples[-1]["t"] < SAMPLE_SECONDS / 2:
            return None
        _samples.append(row)
        cutoff = now - HISTORY_DAYS * 86400
        _samples[:] = [r for r in _samples if r["t"] >= cutoff]
        rows = list(_samples)

    # Rewritten whole rather than appended to, so the file always matches what
    # is in memory - including after a failed write, which otherwise leaves a
    # gap in the middle and no way to notice it later.
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = SPACE_FILE.with_suffix(".tmp")
        with tmp.open("w") as fh:
            for r in rows:
                fh.write(json.dumps(r, separators=(",", ":")) + "\n")
        os.replace(tmp, SPACE_FILE)
        _history_error = None
    except OSError as exc:
        # Worth saying out loud on the page: without this file the forecast
        # never gets past its ceiling. Samples still accumulate in memory, so a
        # console left running does learn the trend - it just forgets it on
        # restart.
        _history_error = f"cannot write {SPACE_FILE}: {exc}"
    return row


def sampler():
    """Sample free space forever, on its own clock.

    Not on the back of a request: the history has to be there for whoever opens
    the console after three quiet weeks, not only for the weeks somebody was
    watching it.
    """
    while True:
        try:
            take_sample()
        except Exception:           # a sampler must never take the server down
            pass
        time.sleep(SAMPLE_SECONDS)


def least_squares(points):
    """Slope in y per second, and R², over (t, y) pairs."""
    n = len(points)
    if n < 2:
        return None, None
    mean_t = sum(t for t, _ in points) / n
    mean_y = sum(y for _, y in points) / n
    var_t = sum((t - mean_t) ** 2 for t, _ in points)
    if var_t == 0:
        return None, None
    slope = sum((t - mean_t) * (y - mean_y) for t, y in points) / var_t
    var_y = sum((y - mean_y) ** 2 for _, y in points)
    return slope, (slope ** 2 * var_t / var_y) if var_y > 0 else 1.0


def cycle_average(samples, cycle_days, now):
    """Reduce the samples to one point per whole retention cycle, newest first.

    Averaging a whole cycle removes the sawtooth exactly, whatever phase the
    history happens to start in - which no line fitted to the raw samples can
    do, and no amount of extra history fixes. Only whole cycles are used; a
    part-cycle at the far end is dropped rather than allowed to tilt the line
    by however much of a prune it happens to contain.
    """
    points, end = [], now
    span = cycle_days * 86400
    while samples and end - span >= samples[0]["t"]:
        rows = [r for r in samples if end - span <= r["t"] < end]
        if not rows:
            break               # a gap wider than a cycle; nothing to average
        points.append((end - span / 2, sum(r["free"] for r in rows) / len(rows)))
        end -= span
    return points


def set_runway(trend, free, now):
    """Turn a consumption rate into a verdict and, where there is one, a date."""
    per_day = trend["bytes_per_day"]
    if not per_day or per_day <= 0:
        trend["verdict"] = "freeing" if (per_day or 0) < 0 else "steady"
        return
    days = free / per_day
    if days > FOREVER_DAYS:
        trend["verdict"] = "steady"
        return
    trend.update(verdict="filling", days_left=days,
                 full_at=iso(now + days * 86400))


def space_trend(projects):
    """What free space is doing, and when it runs out if it keeps doing it."""
    disk = disk_usage()
    if disk is None:
        return None

    now = time.time()
    with _samples_lock:
        samples = list(_samples)
    history_days = ((samples[-1]["t"] - samples[0]["t"]) / 86400
                    if len(samples) > 1 else 0.0)

    written = archive_history(projects)
    rate, arch_span = arrival_rate(written)
    # The span the retained archives cover is the prune cycle, measured rather
    # than configured: the console cannot read KEEP_DAYS, because that lives in
    # a file holding the project's database password. Capped so that a host
    # which has never pruned - where the span is just "time since install" -
    # cannot push the confident answer past the history that is kept.
    cycle = min(arch_span, HISTORY_DAYS / 2) if arch_span else None

    trend = {
        "basis": "unknown",         # observed | provisional | ceiling | unknown
        "verdict": "unknown",       # filling | steady | freeing | unknown
        "bytes_per_day": None,      # positive: free space is being consumed
        "days_left": None,
        "full_at": None,
        "span_days": 0.0,           # days of evidence behind this estimate
        "cycles": 0,                # whole prune cycles averaged, if any
        "cycle_days": cycle,
        "fit": None,
        "samples": len(samples),
        "history_days": history_days,
        "history_needed": FORECAST_MIN_DAYS,
        "history_error": _history_error,
    }

    # Best: two or more whole prune cycles, averaged, then fitted. The sawtooth
    # is gone and what is left is the drift that actually matters.
    if cycle and history_days >= 2 * cycle:
        points = cycle_average(samples, cycle, now)
        if len(points) >= 2:
            slope, fit = least_squares(points)
            if slope is not None:
                trend.update(basis="observed", cycles=len(points), fit=fit,
                             span_days=len(points) * cycle,
                             bytes_per_day=-slope * 86400)
                set_runway(trend, disk["free"], now)
                return dict(disk, trend=trend)

    # Less than that: fit the raw samples. Honest about what it is - on a host
    # that prunes, this can read the falling edge of one cycle as a trend, so
    # it is labelled provisional and the page says what it is still waiting for.
    window = [r for r in samples if r["t"] >= now - FORECAST_DAYS * 86400]
    span = (window[-1]["t"] - window[0]["t"]) / 86400 if len(window) > 1 else 0.0
    if span >= FORECAST_MIN_DAYS and len(window) >= 4:
        slope, fit = least_squares([(r["t"], r["free"]) for r in window])
        if slope is not None:
            trend.update(basis="observed" if not cycle else "provisional",
                         span_days=span, fit=fit, bytes_per_day=-slope * 86400)
            if cycle:
                trend["history_needed"] = 2 * cycle
            set_runway(trend, disk["free"], now)
            return dict(disk, trend=trend)

    # Nothing observed yet. The archives still support one bound: what free
    # space would do if nothing were ever pruned. A ceiling, said as one.
    if rate:
        trend.update(basis="ceiling", span_days=arch_span, bytes_per_day=rate)
        set_runway(trend, disk["free"], now)
    return dict(disk, trend=trend)


# ── Status ─────────────────────────────────────────────────────────────────

# Worst-first, so one project's failure is never hidden behind another's calm.
HEALTH_SEVERITY = {"ok": 0, "running": 1, "never": 2, "stale": 3,
                   "failed": 4, "unreadable": 5}


def project_status(project):
    listing = list_archives(project)
    archives = listing.get("archives", [])
    service = service_state(project)
    timer = timer_state(project)

    newest = archives[0] if archives else None
    newest_epoch = stamp_to_epoch(newest["stamp"]) if newest else None
    age_h = (time.time() - newest_epoch) / 3600 if newest_epoch else None

    # Health comes from the archives first and systemd second. An archive
    # exists only because a run passed every one of its own checks and renamed
    # the file into place - the strongest evidence available, and unlike a
    # unit's recorded state it survives a reboot.
    if listing.get("error"):
        # Not the same thing as "no archives yet", and it must not look like
        # it: a permissions mistake would otherwise show a calm, empty panel
        # for a project whose backups are either fine or gone.
        health, reason = "unreadable", f"cannot read {DATA_DIR / project}: {listing['error']}"
    elif service.get("running") or listing.get("partials"):
        health, reason = "running", "a backup is running now"
    elif not archives:
        health, reason = "never", "no archives yet"
    elif age_h is not None and age_h > STALE_HOURS:
        health, reason = "stale", f"newest archive is {age_h:.0f}h old"
    elif service.get("available") and service.get("result") not in (None, "success"):
        health, reason = "failed", f"last run since boot ended with result '{service['result']}'"
    else:
        health, reason = "ok", f"newest archive is {age_h:.0f}h old"

    # Encryption is a property of the next run, not of the archives already
    # written, so it is reported next to them rather than folded into health.
    # A project that was switched on last week has plaintext archives on disk
    # and nothing wrong with it.
    encryption = project_encryption(project)
    encryption["archives_encrypted"] = sum(1 for a in archives if a.get("encrypted"))
    encryption["archives_plain"] = len(archives) - encryption["archives_encrypted"]

    return {
        "name": project,
        "health": health,
        "health_reason": reason,
        "service": service,
        "timer": timer,
        "partials": listing.get("partials", []),
        "error": listing.get("error"),
        "encryption": encryption,
        "archives": {
            "count": len(archives),
            "total_bytes": sum(a["bytes"] for a in archives),
            "newest": newest,
            "oldest": archives[-1] if archives else None,
        },
    }


def status():
    projects, scan_error = discover_projects()
    entries = [project_status(p) for p in projects]

    if scan_error:
        overall, reason = "unreadable", f"cannot read {DATA_DIR}: {scan_error}"
    elif not entries:
        overall, reason = "never", "no projects configured on this host"
    else:
        worst = max(entries, key=lambda e: HEALTH_SEVERITY.get(e["health"], 0))
        overall = worst["health"]
        reason = (worst["health_reason"] if len(entries) == 1
                  else f"{worst['name']}: {worst['health_reason']}")

    return {
        "host": os.uname().nodename if hasattr(os, "uname") else "",
        "data_dir": str(DATA_DIR),
        "now": iso(time.time()),
        "health": overall,
        "health_reason": reason,
        "stale_hours": STALE_HOURS,
        "disk": space_trend(projects),
        "error": scan_error,
        "projects": entries,
        "totals": {
            "projects": len(entries),
            "archives": sum(e["archives"]["count"] for e in entries),
            "bytes": sum(e["archives"]["total_bytes"] for e in entries),
        },
        "capabilities": {
            "run": ALLOW_RUN,
            "download": ALLOW_DOWNLOAD,
            "unit_prefix": UNIT_PREFIX,
        },
        # Filled in by the handler: whether this connection may register a
        # project or ask for a restore depends on how it reached us.
    }


def start_run(project):
    if service_state(project).get("running"):
        return 409, {"error": "a backup is already running for this project"}
    unit = unit_for(project, "service")
    argv = shlex.split(RUN_COMMAND.replace("{unit}", unit))
    out = run_cmd(argv, timeout=30)
    if out is None:
        return 500, {"error": f"could not run {argv[0]}"}
    if out.returncode != 0:
        # Nearly always the polkit rule or the sudoers line: surface what the
        # command actually said rather than a generic failure.
        detail = (out.stderr or out.stdout).strip() or f"exit {out.returncode}"
        return 500, {"error": f"could not start {unit}: {detail}"}
    return 202, {"started": True, "unit": unit}


# ── Registering a project ──────────────────────────────────────────────────

# supabase-backup-setup.sh's own rule. A name the tool would refuse to create
# is not one to create behind its back, so registration is held to it exactly -
# unlike PROJECT_RE, which only has to be able to *display* what is on disk.
NEW_PROJECT_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
REQUEST_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def validate_registration(body):
    """Check a registration request before it is written to the spool.

    The root side validates everything again - it has to, since it must not
    trust a file written by a network-facing process - but rejecting the
    obvious here gives the operator an answer immediately instead of after a
    round trip through systemd.
    """
    if not isinstance(body, dict):
        return None, "expected a JSON object"

    project = (body.get("project") or "").strip()
    if not NEW_PROJECT_RE.match(project):
        return None, "project name: lowercase letters, digits, - and _ only, starting with a letter or digit"

    database_url = (body.get("database_url") or "").strip()
    if not database_url.startswith(("postgresql://", "postgres://")):
        return None, "DATABASE_URL must be a postgresql:// URI"
    if ":5432/" not in database_url:
        return None, ("DATABASE_URL must use port 5432 (session pooler). Transaction mode "
                      "on 6543 does not hold a session across statements and pg_dump fails partway.")

    supabase_url = (body.get("supabase_url") or "").strip().rstrip("/")
    if not re.fullmatch(r"https://[a-z0-9-]+\.supabase\.(co|com)", supabase_url):
        return None, "project URL must look like https://<ref>.supabase.co"

    service_key = (body.get("service_key") or "").strip()
    if len(service_key) < 20:
        return None, "service key looks too short"

    # Both credentials must name the same project. A mismatched pair is exactly
    # how a backup ends up dumping one project's Postgres while walking
    # another's storage - an archive that looks healthy and is half wrong.
    db_ref = re.sub(r".*://(?:postgres\.)?([a-z0-9]+)[.:/].*", r"\1", database_url)
    url_ref = re.sub(r"https://([a-z0-9-]+)\..*", r"\1", supabase_url)
    if db_ref != url_ref:
        return None, f"credentials disagree: the database URI names '{db_ref}' but the project URL names '{url_ref}'"

    try:
        keep_days = int(body.get("keep_days", 30))
    except (TypeError, ValueError):
        return None, "keep_days must be a number"
    if not 0 <= keep_days <= 3650:
        return None, "keep_days must be between 0 and 3650"

    return {
        "project": project,
        "database_url": database_url,
        "supabase_url": supabase_url,
        "service_key": service_key,
        "keep_days": keep_days,
        "run_now": bool(body.get("run_now", True)),
    }, None


def submit_registration(request):
    known, _ = discover_projects()
    if request["project"] in known:
        return 409, {"error": f"a project named '{request['project']}' already exists on this host"}

    request_id = secrets.token_hex(16)
    request["id"] = request_id
    request["requested_at"] = iso(time.time())
    path = REGISTER_DIR / f"{request_id}.json"
    try:
        REGISTER_DIR.mkdir(parents=True, exist_ok=True)
        # 0600 before a byte of it exists: this file holds a service key until
        # the root side shreds it, and it must never be briefly world-readable.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(request, fh)
    except OSError as exc:
        return 500, {"error": f"could not write the request: {exc}. Is the spool directory present?"}
    return 202, {"id": request_id, "project": request["project"], "state": "pending"}


def spool_result(request_id, pending_dir):
    """What the privileged helper made of a request, or that it has not yet.

    Both spools answer the same way: a result file if the helper has written
    one, 'pending' while the request is still sitting there, and 'unknown' for
    an id with neither - a request that was applied before this console
    started, or one that never existed.

    A fourth answer, 'stalled', is for a request nothing has picked up. Every
    helper answers its request even when it fails, so a file still sitting in
    the spool minutes later does not mean the work is slow - it means nothing
    is reading the spool at all, and the page would otherwise say "applying"
    for ever. The .path unit not being enabled is the way that happens.
    """
    if not REQUEST_ID_RE.match(request_id or ""):
        return 404, {"error": "no such request"}
    result = RESULT_DIR / f"{request_id}.json"
    try:
        return 200, json.loads(result.read_text())
    except FileNotFoundError:
        request = pending_dir / f"{request_id}.json"
        try:
            waiting = time.time() - request.stat().st_mtime
        except OSError:
            return 200, {"id": request_id, "state": "unknown"}
        if waiting > STALL_SECONDS:
            unit = SPOOL_UNITS.get(pending_dir.name, "the helper")
            return 200, {"id": request_id, "state": "stalled", "waiting_s": int(waiting),
                         "error": f"nothing has picked this up in {int(waiting)}s. The "
                                  f"privileged helper is not reading the spool - check "
                                  f"`systemctl status {unit}.path` on the host, and "
                                  f"`journalctl -u {unit}` for why it stopped."}
        return 200, {"id": request_id, "state": "pending", "waiting_s": int(waiting)}
    except (OSError, ValueError) as exc:
        return 500, {"error": f"could not read the result: {exc}"}


# ── Changing what a project encrypts to ────────────────────────────────────

MAX_RECIPIENTS = 32


def validate_encryption(project, body):
    """Check a recipients change before it is written to the spool.

    The root side validates all of this again - it must, since the file came
    from a network-facing process - but a bad key rejected here is rejected
    while the person who pasted it is still looking at it.

    An empty list is not an omission. It is how encryption is turned off, and
    it is treated as a deliberate instruction rather than an error.
    """
    if not isinstance(body, dict):
        return None, "expected a JSON object"
    recipients = body.get("recipients")
    if not isinstance(recipients, list):
        return None, "recipients must be a list; an empty one turns encryption off"
    if len(recipients) > MAX_RECIPIENTS:
        return None, f"at most {MAX_RECIPIENTS} recipients, not {len(recipients)}"

    cleaned = []
    for item in recipients:
        if not isinstance(item, str):
            return None, "every recipient must be a string"
        value = item.strip()
        if not value:
            continue
        if not (AGE_RECIPIENT_RE.match(value) or SSH_RECIPIENT_RE.match(value)):
            return None, (f"not an age recipient or an SSH public key: {value[:48]!r}. "
                          "An age recipient is the 'age1...' line age-keygen prints as the "
                          "public key; an SSH one is a whole line from a .pub file.")
        if value not in cleaned:          # duplicates are harmless, and noise
            cleaned.append(value)
    return {"project": project, "recipients": cleaned}, None


def validate_credentials(project, body):
    """Check a credential rotation before it is written to the spool.

    Every field is optional and at least one is required: a rotation is usually
    one credential, and making someone re-type the two that did not change is
    how a rotation becomes a typo. The helper fills the rest in from the file
    this process cannot read.
    """
    if not isinstance(body, dict):
        return None, "expected a JSON object"

    request = {"kind": "credentials", "project": project}

    database_url = (body.get("database_url") or "").strip()
    if database_url:
        if not database_url.startswith(("postgresql://", "postgres://")):
            return None, "the session pooler URI must be a postgresql:// URI"
        if ":5432/" not in database_url:
            return None, ("the URI must use port 5432 (session pooler). Transaction mode on "
                          "6543 does not hold a session across statements, so pg_dump fails "
                          "partway through and the backup that proves it is the nightly one.")
        request["database_url"] = database_url

    supabase_url = (body.get("supabase_url") or "").strip().rstrip("/")
    if supabase_url:
        if not re.fullmatch(r"https://[a-z0-9-]+\.supabase\.(co|com)", supabase_url):
            return None, "the project URL must look like https://<ref>.supabase.co"
        request["supabase_url"] = supabase_url

    service_key = (body.get("service_key") or "").strip()
    if service_key:
        if len(service_key) < 20:
            return None, "that service key looks too short"
        request["service_key"] = service_key

    if len(request) == 2:                       # kind and project only
        return None, "nothing to rotate — give at least one new credential"

    # Both halves have to agree, and only both halves can be checked here. When
    # one of them is staying as it is, the helper is the only side that can
    # compare them, because it is the only side that can read the other.
    if "database_url" in request and "supabase_url" in request:
        db_ref = re.sub(r".*://(?:postgres\.)?([a-z0-9]+)[.:/].*", r"\1", database_url)
        url_ref = re.sub(r"https://([a-z0-9-]+)\..*", r"\1", supabase_url)
        if db_ref != url_ref:
            return None, (f"credentials disagree: the URI names '{db_ref}' but the project "
                          f"URL names '{url_ref}'")
    return request, None


def submit_credentials(request):
    known, _ = discover_projects()
    if request["project"] not in known:
        return 404, {"error": "no such project"}

    request_id = secrets.token_hex(16)
    request["id"] = request_id
    request["requested_at"] = iso(time.time())
    path = CREDENTIALS_DIR / f"{request_id}.json"
    try:
        CREDENTIALS_DIR.mkdir(parents=True, exist_ok=True)
        # 0600 before a byte of it exists: it holds a database password and a
        # service key until the helper shreds it.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(request, fh)
    except OSError as exc:
        return 500, {"error": f"could not write the request: {exc}. Is the spool directory present?"}
    return 202, {"id": request_id, "project": request["project"], "state": "pending"}


def credentials_helper():
    """Whether anything on this host is listening for credential rotations."""
    watch = systemctl_show(f"{UNIT_PREFIX}-credentials.path", ["LoadState", "ActiveState"])
    return {
        "installed": bool(watch) and watch.get("LoadState") == "loaded",
        "watching": bool(watch) and watch.get("ActiveState") == "active",
        "unit": f"{UNIT_PREFIX}-credentials.path",
    }


def encryption_helper():
    """Whether anything on this host is listening for encryption requests.

    Installed but not enabled is a real state, and from the browser it looks
    exactly like a request that is taking a while - the console writes the
    request either way, and it simply sits there. The difference is only
    visible from here, so it has to be reported from here.
    """
    unit = f"{UNIT_PREFIX}-keys.service"
    watch = f"{UNIT_PREFIX}-keys.path"
    props = systemctl_show(unit, ["LoadState"])
    path = systemctl_show(watch, ["LoadState", "ActiveState"])
    return {
        "installed": bool(props) and props.get("LoadState") == "loaded",
        "watching": bool(path) and path.get("ActiveState") == "active",
        "unit": watch,
    }


def submit_encryption(request):
    known, _ = discover_projects()
    if request["project"] not in known:
        return 404, {"error": "no such project"}

    request_id = secrets.token_hex(16)
    request["id"] = request_id
    request["requested_at"] = iso(time.time())
    path = ENCRYPTION_DIR / f"{request_id}.json"
    try:
        ENCRYPTION_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(request, fh)
    except OSError as exc:
        return 500, {"error": f"could not write the request: {exc}. Is the spool directory present?"}
    return 202, {"id": request_id, "project": request["project"],
                 "recipients": len(request["recipients"]), "state": "pending"}


# ── Restoring an archive ───────────────────────────────────────────────────

# Same shape as registration, for the same reason: the console has no privilege
# and holds no credentials, so it asks. `restore --drain`, root, triggered by a
# .path unit, does the work - the identical script an operator runs by hand,
# taking the same steps in the same order and re-deriving every guard from what
# only root can read.
#
# The prompts are what made those guards guards. They are not dropped here,
# they are moved: the request must name the archive, spell out the target ref,
# and carry a separate yes for each question `restore` would have stopped on.
# The root side refuses a request that gets any of them wrong, and this side
# refuses the ones it can see are wrong without waiting for a round trip.

RESTORE_UNIT = f"{UNIT_PREFIX}-restore.service"


def validate_restore(project, archive, body):
    if not isinstance(body, dict):
        return None, "expected a JSON object"

    # An encrypted archive needs an identity, and it has to arrive here: there
    # is none on the host, which is the point of encrypting to a recipient. It
    # is checked for shape only. Whether it is the *right* key is not knowable
    # here and is not worth guessing at - age will say, in seconds.
    identity = (body.get("identity") or "").strip()
    if archive.endswith(".age"):
        if not identity:
            return None, (f"{archive} is encrypted, so restoring it needs the age identity. "
                          "Nothing on this host holds one - that is what makes the archive "
                          "worth encrypting - so it has to come from you, now.")
        if not (identity.startswith("AGE-SECRET-KEY-")
                or "BEGIN OPENSSH PRIVATE KEY" in identity
                or "BEGIN RSA PRIVATE KEY" in identity):
            return None, ("that does not look like a private key. An age identity is the "
                          "'AGE-SECRET-KEY-...' line age-keygen prints; an SSH one is the whole "
                          "file including its BEGIN and END lines. A public key will not open "
                          "anything.")
    elif identity:
        # Refused rather than ignored. Sending a private key to a host that has
        # no use for it is worth stopping, not quietly tolerating.
        return None, f"{archive} is not encrypted, so it needs no identity. None was sent on."

    database_url = (body.get("database_url") or "").strip()
    if not database_url.startswith(("postgresql://", "postgres://")):
        return None, "the target's session pooler URI must be a postgresql:// URI"
    if ":5432/" not in database_url:
        return None, ("the target URI must use port 5432 (session pooler). Transaction "
                      "mode on 6543 does not hold a session across statements, so a "
                      "restore through it stops partway and leaves the target half "
                      "written - the one outcome worth ruling out in advance.")

    supabase_url = (body.get("supabase_url") or "").strip().rstrip("/")
    if not re.fullmatch(r"https://[a-z0-9-]+\.supabase\.(co|com)", supabase_url):
        return None, "the target project URL must look like https://<ref>.supabase.co"

    service_key = (body.get("service_key") or "").strip()
    if len(service_key) < 20:
        return None, "the target's service key looks too short"

    # A mismatched pair writes one project's database while uploading another's
    # files. Checked here and again by the helper.
    db_ref = re.sub(r".*://(?:postgres\.)?([a-z0-9]+)[.:/].*", r"\1", database_url)
    url_ref = re.sub(r"https://([a-z0-9-]+)\..*", r"\1", supabase_url)
    if db_ref != url_ref:
        return None, f"credentials disagree: the database URI names '{db_ref}' but the project URL names '{url_ref}'"

    # Typed, not clicked - the same thing `restore` asks for at its last
    # prompt. Nothing except knowing which project is about to be written to
    # satisfies it.
    if (body.get("confirm_ref") or "").strip() != db_ref:
        return None, f"type the target project ref ('{db_ref}') to confirm"

    return {
        "kind": "restore",
        "project": project,
        "archive": archive,
        "database_url": database_url,
        "supabase_url": supabase_url,
        "service_key": service_key,
        # Empty for a plaintext archive, so the spool file for one carries no
        # key at all rather than an empty field someone has to reason about.
        "identity": identity,
        "confirm_ref": db_ref,
        "dry_run": bool(body.get("dry_run", True)),
        # Each of these is a prompt `restore` would have stopped on. Absent
        # means no, so a request that simply omits them cannot bulldoze past a
        # question it never saw.
        "allow_nonempty": bool(body.get("allow_nonempty", False)),
        "continue_on_catalog_errors": bool(body.get("continue_on_catalog_errors", False)),
    }, None


def restore_activity():
    """Whether a restore is running, and what came of the last one.

    Also what a reloaded page reattaches to: the console keeps nothing between
    requests, so the spool is the only record that something is in flight.
    """
    pending = []
    try:
        pending = sorted(p.stem for p in RESTORE_DIR.iterdir()
                         if REQUEST_ID_RE.match(p.stem))
    except OSError:
        pass

    latest = None
    try:
        results = sorted(RESULT_DIR.glob("*.json"),
                         key=lambda p: p.stat().st_mtime, reverse=True)[:20]
    except OSError:
        results = []
    for path in results:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if data.get("kind") == "restore":
            latest = {key: data.get(key) for key in
                      ("id", "state", "project", "archive", "target_ref", "dry_run",
                       "error", "started_at", "finished_at")}
            break

    props = systemctl_show(RESTORE_UNIT, ["LoadState", "ActiveState"])
    unit_active = bool(props) and props.get("ActiveState") in ("activating", "active")
    # The .path unit is what turns a request into a restore. Installed but not
    # enabled is a real state - the setup script offers it - and it looks
    # exactly like a request that is taking a long time to start unless the
    # console can say which one it is.
    watch = systemctl_show(f"{UNIT_PREFIX}-restore.path", ["LoadState", "ActiveState"])
    # A result still saying "running" with nothing running is a helper that was
    # killed - the one thing the result file can never say for itself. Say it
    # here rather than leaving a spinner going forever.
    if latest and latest.get("state") == "running" and not unit_active and not pending:
        latest["stalled"] = True
    return {
        "running": bool(pending) or unit_active,
        "pending": pending,
        "latest": latest,
        "helper_installed": bool(props) and props.get("LoadState") == "loaded",
        "helper_watching": bool(watch) and watch.get("ActiveState") == "active",
        "unit": RESTORE_UNIT,
    }


def submit_restore(request):
    # One at a time, whatever the helper's own queueing would do. Two restores
    # into the same target at once is not something to find out about later.
    if restore_activity()["running"]:
        return 409, {"error": "a restore is already running on this host"}

    request_id = secrets.token_hex(16)
    request["id"] = request_id
    request["requested_at"] = iso(time.time())
    path = RESTORE_DIR / f"{request_id}.json"
    try:
        RESTORE_DIR.mkdir(parents=True, exist_ok=True)
        # 0600 before it exists: this holds the target's database password and
        # its service key until the helper shreds it.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(request, fh)
    except OSError as exc:
        return 500, {"error": f"could not write the request: {exc}. Is the spool directory present?"}
    return 202, {"id": request_id, "project": request["project"],
                 "archive": request["archive"], "state": "pending"}


# ── The console's own settings ─────────────────────────────────────────────

# What the settings page may change, and what it may not. Not here:
#
#   WEB_ALLOW_ANONYMOUS  a switch that turns authentication off has no business
#                        being reachable through the thing it authenticates
#   WEB_TRUSTED_PROXIES  it decides whose word to take for who a client is
#   DATA_DIR, UNIT_PREFIX, WEB_RUN_COMMAND, WEB_SPOOL_DIR
#                        the shape of the installation, not a preference
#
# Those stay in web.env, changed on the host by someone who is already root.

USERNAME_RE = re.compile(r"^[A-Za-z0-9._@-]{1,64}$")
# Long enough to be worth the 600k PBKDF2 iterations behind it. The console is
# one HTTP request away from every archive's manifest and, if downloads are on,
# from every auth password hash the project ever stored.
MIN_PASSWORD = 12


def current_settings():
    """What the running process is actually using, not what a file says.

    web.env is readable here, but the environment is what took effect: if the
    two disagree - an edit made without a restart, an Environment= line in a
    drop-in - the page must show what the console is doing.
    """
    return {
        "username": WEB_USER,
        "bind": BIND,
        "stale_hours": STALE_HOURS,
        "allow_run": ALLOW_RUN,
        "allow_download": ALLOW_DOWNLOAD,
        "allow_register": ALLOW_REGISTER,
        "allow_settings": ALLOW_SETTINGS,
        "allow_upgrade": ALLOW_UPGRADE,
        "anonymous": ALLOW_ANON,
        "password_set": bool(PASSWORD_HASH),
        "min_password": MIN_PASSWORD,
        "config_path": WEB_ENV_PATH,
        "unit": WEB_UNIT,
        # Without the spool there is no helper to apply anything, and a form
        # that cannot work should say so instead of failing on submit.
        "helper_installed": SETTINGS_DIR.is_dir(),
    }


def valid_bind(value):
    """host:port, with a host this process could plausibly bind to.

    Getting this wrong takes the console off the network, so it is checked
    here - but the helper also puts the old file back if the console does not
    come up, because a listen address can be well formed and still not exist
    on this host.
    """
    host, separator, port = value.rpartition(":")
    if not separator:
        return "listen address must be host:port"
    try:
        number = int(port)
    except ValueError:
        return f"'{port}' is not a port number"
    if not 1 <= number <= 65535:
        return "port must be between 1 and 65535"
    bare = host.strip("[]")
    if bare in ("", "localhost"):
        return None
    try:
        ipaddress.ip_address(bare)
    except ValueError:
        return (f"'{bare}' is not an IP address. Use 127.0.0.1 to serve only a tunnel or "
                "a proxy on this host, or 0.0.0.0 to serve the network.")
    return None


def validate_settings(body):
    """Check a settings change, and hash the new password if there is one.

    The helper validates all of this again - it must, the request comes from a
    process exposed to the network - but an answer here is immediate, and the
    hashing has to happen here: it is what keeps the plaintext out of the
    spool file, out of the journal and out of root's argv.
    """
    if not isinstance(body, dict):
        return None, "expected a JSON object"

    # Basic auth already got this far. That is not the same as someone being
    # here: a browser resends a saved password for as long as it is open, so
    # without this an unattended tab is a password change waiting to happen.
    if PASSWORD_HASH and not check_password(body.get("current_password") or "", PASSWORD_HASH):
        return None, "the current password does not match"

    username = (body.get("username") or "").strip() or WEB_USER
    if not USERNAME_RE.match(username):
        return None, "username: letters, digits, and . _ - @ only"

    password = body.get("new_password") or ""
    if password:
        if len(password) < MIN_PASSWORD:
            return None, f"the new password must be at least {MIN_PASSWORD} characters"
        if password != (body.get("confirm_password") or ""):
            return None, "the two new passwords do not match"

    bind = (body.get("bind") or "").strip() or BIND
    problem = valid_bind(bind)
    if problem:
        return None, problem

    try:
        stale_hours = float(body.get("stale_hours", STALE_HOURS))
    except (TypeError, ValueError):
        return None, "stale hours must be a number"
    if not 1 <= stale_hours <= 8760:
        return None, "stale hours must be between 1 hour and a year"

    request = {
        "kind": "settings",
        "username": username,
        "bind": bind,
        # Canonical text, not a float: 26 has to arrive as "26" so the helper
        # can tell it from the "26" already in the file and report no change.
        "stale_hours": f"{round(stale_hours, 2):g}",
        # Absent means "leave it as it is", not "turn it off": a request that
        # omits a switch must never be read as a request to change it.
        "allow_run": bool(body.get("allow_run", ALLOW_RUN)),
        "allow_download": bool(body.get("allow_download", ALLOW_DOWNLOAD)),
        "allow_register": bool(body.get("allow_register", ALLOW_REGISTER)),
        "allow_settings": bool(body.get("allow_settings", ALLOW_SETTINGS)),
        "allow_upgrade": bool(body.get("allow_upgrade", ALLOW_UPGRADE)),
    }
    if password:
        request["password_hash"] = hash_password(password)
    return request, None


def submit_settings(request):
    request_id = secrets.token_hex(16)
    request["id"] = request_id
    request["requested_at"] = iso(time.time())
    path = SETTINGS_DIR / f"{request_id}.json"
    try:
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        # 0600 like the others. There is no secret in this one - the password
        # left as a PBKDF2 digest - but a request that can rewrite the
        # console's configuration is not something to leave world-readable.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(request, fh)
    except OSError as exc:
        return 500, {"error": f"could not write the request: {exc}. Is the spool directory "
                              "present? Re-run supabase-backup-web-setup.sh."}
    return 202, {"id": request_id, "state": "pending",
                 "password_changed": "password_hash" in request}


# ── Version, and upgrading ─────────────────────────────────────────────────

# Two halves, and they are not the same kind of thing. Asking what version is
# running and what version is published needs no privilege: it reads a file
# under /opt and makes an HTTPS request. Installing it does, and goes through
# the spool - the console never writes to /opt, and could not if it tried.
#
# Both halves are `upgrade`. Reimplementing the comparison here would give the
# host two answers to "is this up to date", and the day they disagreed would be
# the day someone needed the right one.

UPGRADE_CHECK_TIMEOUT = float(env("WEB_UPGRADE_CHECK_TIMEOUT", "45"))


def upgrade_check(refresh=False):
    """`upgrade --check --json`, or why it could not be run.

    Its own cache is what keeps this from hitting GitHub on every visit to the
    settings panel; refresh=True is a person asking again on purpose.
    """
    if not UPGRADE_SCRIPT.exists():
        return {"error": f"{UPGRADE_SCRIPT} is not installed, so this console cannot tell "
                         "what version it is running. Re-run supabase-backup-web-setup.sh "
                         "on the host."}
    args = [str(UPGRADE_SCRIPT), "--check", "--json"]
    if refresh:
        args.append("--refresh")
    # A named environment rather than this process's own. web.env is loaded
    # into it - the password digest included - and there is no reason for any
    # of that to be in the environment of something that opens a socket to
    # GitHub. It needs a PATH and somewhere it may write its cache.
    env_vars = {
        "PATH": os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        "UPGRADE_CACHE": str(UPGRADE_CACHE),
    }
    try:
        out = subprocess.run(args, capture_output=True, text=True,
                             timeout=UPGRADE_CHECK_TIMEOUT, env=env_vars)
    except subprocess.TimeoutExpired:
        return {"error": "the version check timed out. Can this host reach GitHub?"}
    except (OSError, subprocess.SubprocessError) as exc:
        return {"error": f"could not run {UPGRADE_SCRIPT}: {exc}"}
    if out.returncode != 0:
        detail = (out.stderr or out.stdout).strip() or f"exit {out.returncode}"
        return {"error": f"the version check failed: {detail}"}
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"error": "the version check did not return JSON"}


def changelog():
    """The installed CHANGELOG.md, or nothing.

    Read per request rather than cached: an upgrade replaces it underneath this
    process, and a version history showing the previous release's notes would
    be worse than showing none.
    """
    try:
        if CHANGELOG_FILE.stat().st_size > CHANGELOG_MAX:
            return ""
        return CHANGELOG_FILE.read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        return ""


def upgrade_activity():
    """Whether an upgrade is in flight, and what came of the last one.

    The same shape as restore_activity, and for the same reason: the console
    keeps nothing between requests, so a reloaded page can only reattach to
    what is in the spool.
    """
    pending = []
    try:
        pending = sorted(p.stem for p in UPGRADE_DIR.iterdir()
                         if REQUEST_ID_RE.match(p.stem))
    except OSError:
        pass

    latest = None
    try:
        results = sorted(RESULT_DIR.glob("*.json"),
                         key=lambda p: p.stat().st_mtime, reverse=True)[:20]
    except OSError:
        results = []
    for path in results:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if data.get("kind") == "upgrade":
            latest = {key: data.get(key) for key in
                      ("id", "state", "error", "steps", "finished_at")}
            break

    props = systemctl_show(UPGRADE_UNIT, ["LoadState", "ActiveState"])
    unit_active = bool(props) and props.get("ActiveState") in ("activating", "active")
    watch = systemctl_show(f"{UNIT_PREFIX}-upgrade.path", ["LoadState", "ActiveState"])
    # The twice-daily check. Installed but not running is a real state - and
    # the difference between "nothing to report" and "nobody has looked".
    timer = systemctl_show(f"{UNIT_PREFIX}-upgrade-scheduled.timer",
                           ["LoadState", "ActiveState", "NextElapseUSecRealtime"])
    return {
        "running": bool(pending) or unit_active,
        "pending": pending,
        "latest": latest,
        # Installed but not watching is a real state and looks exactly like a
        # request taking a long time to start, unless the console says which.
        "helper_installed": bool(props) and props.get("LoadState") == "loaded",
        "helper_watching": bool(watch) and watch.get("ActiveState") == "active",
        "timer_installed": bool(timer) and timer.get("LoadState") == "loaded",
        "timer_active": bool(timer) and timer.get("ActiveState") == "active",
        "timer_next": iso(parse_systemd_time(timer.get("NextElapseUSecRealtime"))) if timer else None,
        "unit": UPGRADE_UNIT,
    }


def submit_upgrade(action, auto=None):
    """Leave an upgrade request. Two verbs, both closed sets.

    "apply" names no version, no URL and no file list - every one of those is
    fixed in the helper script, so the worst a rewritten request can ask for is
    the upgrade someone was already asking for. "auto" carries one of exactly
    two words. Checking is in neither: it needs no privilege, so this process
    does that itself.
    """
    if action not in ("apply", "auto"):
        return 400, {"error": "unknown action"}
    if auto not in (None, "patch", "minor", "off"):
        return 400, {"error": "the automatic setting is 'off', 'patch' or 'minor'"}
    if action == "auto" and auto is None:
        return 400, {"error": "no automatic setting given"}
    if upgrade_activity()["running"]:
        return 409, {"error": "an upgrade is already running on this host"}

    request_id = secrets.token_hex(16)
    request = {"kind": "upgrade", "action": action, "id": request_id,
               "requested_at": iso(time.time())}
    if action == "auto":
        request["auto"] = auto
    path = UPGRADE_DIR / f"{request_id}.json"
    try:
        UPGRADE_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(request, fh)
    except OSError as exc:
        return 500, {"error": f"could not write the request: {exc}. Is the spool directory "
                              "present? Re-run supabase-backup-web-setup.sh."}
    return 202, {"id": request_id, "action": action, "state": "pending"}


# ── HTTP ───────────────────────────────────────────────────────────────────

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "supabase-backup-web"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    # Whether this request's body has been taken off the socket. HTTP/1.1 means
    # the connection is reused, and a response sent without reading the body
    # leaves those bytes to be parsed as the *next* request - see drain_body,
    # which is what stops that from happening.
    body_read = False
    # How much of an unread body is worth reading just to throw away. Past this
    # the connection is closed instead: the point is to keep it usable, and
    # reading a megabyte to do that is no longer keeping anything.
    DRAIN_MAX = 1 << 20
    # A body that was promised and is not arriving must not hold a thread for
    # as long as the client feels like. Applied only around the drain, never to
    # a response: send_archive streams gigabytes to whoever asked for them.
    DRAIN_TIMEOUT = 5

    def client_label(self):
        """Who to name in the log.

        With a reverse proxy in front, every line otherwise reads as the proxy
        and the actual client is invisible. X-Forwarded-For is only believed
        from an address in WEB_TRUSTED_PROXIES - anyone else can put whatever
        they like in that header - and the forwarded scheme is shown alongside,
        which is what decides whether registration is offered.
        """
        client = self.client_address[0]
        if client not in TRUSTED_PROXIES:
            return client
        proto = (self.headers.get("X-Forwarded-Proto") or "?").lower()
        forwarded = (self.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
        # Keep it to something that cannot smuggle newlines into the journal.
        if not re.fullmatch(r"[0-9a-fA-F.:]{1,45}", forwarded or ""):
            forwarded = ""
        return f"{forwarded or '?'} via {client}/{proto}"

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.client_label(), fmt % args))
        sys.stdout.flush()

    def send_bytes(self, code, body, content_type, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # Decided before the response in the one case that can know it - a body
        # too large to read - so that client is told rather than finding out.
        if self.close_connection:
            self.send_header("Connection", "close")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, code, payload):
        body = json.dumps(payload, indent=1).encode()
        self.send_bytes(code, body, "application/json", {"Cache-Control": "no-store"})

    def read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None, "bad Content-Length"
        if length <= 0:
            return None, "empty request body"
        if length > MAX_BODY:
            # Not read, and not worth draining either. Say so in the response
            # rather than closing the connection out from under the client.
            self.close_connection = True
            return None, "request body too large"
        try:
            raw = self.rfile.read(length)
        except OSError:
            self.close_connection = True
            return None, "could not read the request body"
        # Before the parse, not after: a body that arrived and would not parse
        # is still a body that is off the socket.
        self.body_read = True
        try:
            return json.loads(raw.decode("utf-8")), None
        except (ValueError, UnicodeDecodeError):
            return None, "body is not valid JSON"

    def drain_body(self):
        """Take an unread request body off the socket, or stop reusing it.

        Every path that answers without reading the body ends up here: a 401
        before anything is dispatched, a 403 from one of the channel checks, a
        body over MAX_BODY, a 404 on a POST. On HTTP/1.1 the connection is
        reused, so bytes left behind are what the next request gets parsed
        from - the client's *following* request fails at the transport level
        ("NetworkError when attempting to fetch resource" in a browser), which
        is both baffling to whoever sees it and invisible here: this log
        records the 403 that caused it and nothing else.
        """
        if self.body_read or self.close_connection:
            return
        # Chunked has no Content-Length to say where the body ends, and
        # BaseHTTPRequestHandler does not decode it. Nowhere to skip to.
        if self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            return
        if length <= 0:
            return                                  # no body to begin with
        if length > self.DRAIN_MAX:
            self.close_connection = True
            return
        previous = self.connection.gettimeout()
        try:
            self.connection.settimeout(self.DRAIN_TIMEOUT)
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:                       # client stopped early
                    self.close_connection = True
                    return
                remaining -= len(chunk)
            self.body_read = True
        except OSError:                             # timeout included
            self.close_connection = True
        finally:
            try:
                self.connection.settimeout(previous)
            except OSError:
                pass

    def credential_channel(self, what):
        """Whether THIS connection may carry a project's credentials.

        A service key is the most powerful credential in the system - it
        bypasses RLS on the whole project - so it is not allowed to cross the
        network in the clear, whatever the console password does. Loopback
        covers both supported paths: a TLS proxy on this host forwarding to
        127.0.0.1, and an SSH tunnel. A proxy elsewhere has to be named in
        WEB_TRUSTED_PROXIES and say it terminated TLS.
        """
        client = self.client_address[0]
        if client in LOOPBACK:
            return True, None
        if client in TRUSTED_PROXIES and \
                self.headers.get("X-Forwarded-Proto", "").lower() == "https":
            return True, None
        return False, (
            f"{what} is refused over a plain-HTTP connection from the network. "
            "Reach the console through the TLS proxy on this host, or over an SSH tunnel "
            "(ssh -N -L 8787:127.0.0.1:8787 <host>), and try again from there.")

    def may_register(self):
        if not ALLOW_REGISTER:
            return False, "registration is disabled (WEB_ALLOW_REGISTER=0)"
        return self.credential_channel(
            "Registering a project sends a service key, which bypasses RLS on the whole "
            "project, so it")

    def may_restore(self):
        """Whether THIS connection may ask for a restore.

        Two separate refusals, and they mean different things. Off by
        configuration is the host saying restores are not done from here at
        all. The channel check is the same one registration makes: a restore
        request carries the target's database password and service key.
        """
        if not ALLOW_RESTORE:
            return False, ("restoring from the console is disabled (WEB_ALLOW_RESTORE=0). "
                           "Run restore on the host, or turn it on in web.env and restart "
                           "the console.")
        return self.credential_channel(
            "A restore sends the target project's database password and its service key, "
            "so it")

    def may_rotate(self):
        """Whether THIS connection may carry a project's new credentials.

        The same rule as registration, for the same reason: what travels here
        is a database password and a service key that bypasses RLS on the whole
        project. That they are replacing an old pair rather than creating a new
        one changes nothing about what a listener would get.
        """
        if not ALLOW_CREDENTIALS:
            return False, ("rotating credentials from the console is disabled "
                           "(WEB_ALLOW_CREDENTIALS=0). Edit the project's .conf on the host.")
        if not CREDENTIALS_DIR.is_dir():
            return False, (f"the rotation helper is not installed: {CREDENTIALS_DIR} does not "
                           "exist, so a rotation would sit in the spool unread. Re-run "
                           "supabase-backup-web-setup.sh on the host.")
        return self.credential_channel(
            "Rotating a credential sends a database password and a service key, so it")

    def may_encrypt(self):
        """Whether THIS connection may change what a project encrypts to.

        No secret travels here - an age recipient is a public key, and the
        identity is the half this design keeps somewhere else entirely. The
        rule is the same anyway, for a different reason: this decides who can
        read every archive written from now on, and a request that crosses the
        network in the clear is one that can be rewritten on the way. A
        substituted recipient would not look like an attack. It would look like
        working encryption.
        """
        if not ALLOW_ENCRYPTION:
            return False, ("changing encryption from the console is disabled "
                           "(WEB_ALLOW_ENCRYPTION=0). Edit the recipients file on the host.")
        if not ENCRYPTION_DIR.is_dir():
            return False, (f"the encryption helper is not installed: {ENCRYPTION_DIR} does "
                           "not exist, so nothing would apply the change. Re-run "
                           "supabase-backup-web-setup.sh on the host.")
        return self.credential_channel(
            "Choosing who can read every future archive over a connection anyone can "
            "rewrite is not choosing, so it")

    def may_configure(self):
        """Whether THIS connection may change the console's settings.

        The same channel rule as registration, for a plainer reason: a password
        changed over a connection that shows it to the network has not been
        changed. Everything else on the page rides along with it rather than
        being sorted into secret and not-secret - "turn downloads on" is not a
        secret, but it is exactly what a listener would want to send.
        """
        if not ALLOW_SETTINGS:
            return False, ("changing settings from the console is disabled "
                           "(WEB_ALLOW_SETTINGS=0). Edit web.env on the host.")
        if not SETTINGS_DIR.is_dir():
            return False, (f"the settings helper is not installed: {SETTINGS_DIR} does not "
                           "exist, so there is nothing to apply a change. Re-run "
                           "supabase-backup-web-setup.sh on the host.")
        return self.credential_channel(
            "Changing the console password puts it on the wire, so it")

    def may_upgrade(self):
        """Whether THIS connection may ask the host to install new code.

        No secret travels in an upgrade request - it names a verb and nothing
        else, and the helper takes its URLs from its own source. The channel
        rule is here for what the request causes rather than what it carries:
        root downloads and installs, and "someone on the network can make that
        happen whenever they like" is not a smaller thing than a password
        because the request itself was boring.
        """
        if not ALLOW_UPGRADE:
            return False, ("upgrading from the console is disabled (WEB_ALLOW_UPGRADE=0). "
                           "Run supabase-backup-upgrade on the host.")
        if not UPGRADE_DIR.is_dir():
            return False, (f"the upgrade helper is not installed: {UPGRADE_DIR} does not "
                           "exist, so nothing would act on the request. Re-run "
                           "supabase-backup-web-setup.sh on the host.")
        return self.credential_channel(
            "Asking the host to download and install new code over a connection anyone "
            "can rewrite is not asking, so it")

    def authorised(self):
        if ALLOW_ANON:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                raw = base64.b64decode(header[6:]).decode("utf-8")
            except (ValueError, UnicodeDecodeError):
                raw = ""
            user, _, password = raw.partition(":")
            # Compare both, always, so a wrong username and a wrong password
            # take the same time and neither can be probed for separately.
            user_ok = hmac.compare_digest(user, WEB_USER)
            pass_ok = check_password(password, PASSWORD_HASH)
            if user_ok and pass_ok:
                return True
        self.send_bytes(
            401, b'{"error":"authentication required"}\n', "application/json",
            {"WWW-Authenticate": 'Basic realm="Supabase backup", charset="UTF-8"',
             "Cache-Control": "no-store"})
        return False

    def do_GET(self):
        self.route("GET")

    def do_HEAD(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        self.body_read = False
        try:
            if not self.authorised():
                return
            split = urllib.parse.urlsplit(self.path)
            try:
                self.dispatch(method, split.path, urllib.parse.parse_qs(split.query))
            except BrokenPipeError:
                pass
            except Exception as exc:                   # never leak a traceback
                self.log_message("unhandled error on %s %s: %r", method, self.path, exc)
                self.send_json(500, {"error": "internal error"})
        finally:
            # After the response, not before: by here every path has had its
            # chance to read the body, and what is left is what nobody wanted.
            try:
                self.drain_body()
            except Exception:                          # never fail a served request
                self.close_connection = True

    def dispatch(self, method, path, query):
        if method == "GET":
            if path == "/":
                return self.serve_static("index.html")
            if path.startswith("/static/"):
                return self.serve_static(path[len("/static/"):])
            if path == "/favicon.ico":
                # Browsers ask for this whatever <link rel="icon"> says, and an
                # unanswered request is a 404 in the log on every page load.
                return self.serve_static("favicon.svg")
            if path == "/api/status":
                payload = status()
                allowed, why = self.may_register()
                payload["capabilities"]["register"] = allowed
                payload["capabilities"]["register_blocked_because"] = why
                # Both depend on the connection, so neither can be decided in
                # status() - only here, where the client is known.
                allowed, why = self.may_restore()
                payload["capabilities"]["restore"] = allowed
                payload["capabilities"]["restore_blocked_because"] = why
                allowed, why = self.may_encrypt()
                payload["capabilities"]["encryption"] = allowed
                payload["capabilities"]["encryption_blocked_because"] = why
                payload["restore"] = restore_activity() if ALLOW_RESTORE else None
                # Only worth the two systemctl calls when the panel that uses
                # it is being offered at all.
                payload["encryption_helper"] = encryption_helper() if ALLOW_ENCRYPTION else None
                allowed, why = self.may_rotate()
                payload["capabilities"]["credentials"] = allowed
                payload["capabilities"]["credentials_blocked_because"] = why
                payload["credentials_helper"] = credentials_helper() if ALLOW_CREDENTIALS else None
                return self.send_json(200, payload)
            match = re.fullmatch(r"/api/projects/([^/]+)/archives", path)
            if match:
                return self.project_endpoint("archives", match.group(1), None)
            match = re.fullmatch(r"/api/projects/([^/]+)/runs", path)
            if match:
                try:
                    limit = max(1, min(50, int(query.get("limit", ["10"])[0])))
                except ValueError:
                    limit = 10
                return self.project_endpoint("runs", match.group(1), None, limit)
            match = re.fullmatch(r"/api/projects/([^/]+)/archives/([^/]+)/(manifest|download)", path)
            if match:
                return self.project_endpoint(match.group(3), match.group(1), match.group(2))
            if path == "/api/settings":
                # Readable on any connection - it is how the page explains why
                # it is read-only - but it names no secret: a username, an
                # address, some switches, and whether a password is set.
                allowed, why = self.may_configure()
                return self.send_json(200, {"settings": current_settings(),
                                            "editable": allowed,
                                            "blocked_because": why})
            if path == "/api/upgrade":
                # Readable on any connection, like /api/settings: what version
                # this host runs is exactly what you need before going to it.
                allowed, why = self.may_upgrade()
                refresh = query.get("refresh", ["0"])[0] in ("1", "true", "yes")
                return self.send_json(200, {"check": upgrade_check(refresh),
                                            "activity": upgrade_activity(),
                                            "changelog": changelog(),
                                            "allowed": allowed,
                                            "blocked_because": why})
            match = re.fullmatch(r"/api/upgrade/([^/]+)", path)
            if match:
                code, payload = spool_result(match.group(1), UPGRADE_DIR)
                return self.send_json(code, payload)
            match = re.fullmatch(r"/api/settings/([^/]+)", path)
            if match:
                code, payload = spool_result(match.group(1), SETTINGS_DIR)
                return self.send_json(code, payload)
            match = re.fullmatch(r"/api/register/([^/]+)", path)
            if match:
                code, payload = spool_result(match.group(1), REGISTER_DIR)
                return self.send_json(code, payload)
            match = re.fullmatch(r"/api/encryption/([^/]+)", path)
            if match:
                code, payload = spool_result(match.group(1), ENCRYPTION_DIR)
                return self.send_json(code, payload)
            match = re.fullmatch(r"/api/credentials/([^/]+)", path)
            if match:
                code, payload = spool_result(match.group(1), CREDENTIALS_DIR)
                return self.send_json(code, payload)
            match = re.fullmatch(r"/api/restore/([^/]+)", path)
            if match:
                # Readable whether or not restores are still allowed: turning
                # the switch off must not hide the record of one that ran.
                code, payload = spool_result(match.group(1), RESTORE_DIR)
                return self.send_json(code, payload)
        elif method == "POST":
            match = re.fullmatch(r"/api/projects/([^/]+)/run", path)
            if match:
                if not ALLOW_RUN:
                    return self.send_json(403, {"error": "starting runs is disabled (WEB_ALLOW_RUN=0)"})
                return self.project_endpoint("run", match.group(1), None)
            match = re.fullmatch(r"/api/projects/([^/]+)/credentials", path)
            if match:
                allowed, why = self.may_rotate()
                if not allowed:
                    return self.send_json(403, {"error": why})
                body, error = self.read_json_body()
                if error:
                    return self.send_json(400, {"error": error})
                return self.project_endpoint("credentials", match.group(1), None, body=body)
            match = re.fullmatch(r"/api/projects/([^/]+)/encryption", path)
            if match:
                allowed, why = self.may_encrypt()
                if not allowed:
                    return self.send_json(403, {"error": why})
                body, error = self.read_json_body()
                if error:
                    return self.send_json(400, {"error": error})
                return self.project_endpoint("encryption", match.group(1), None, body=body)
            match = re.fullmatch(r"/api/projects/([^/]+)/archives/([^/]+)/verify", path)
            if match:
                return self.project_endpoint("verify", match.group(1), match.group(2))
            match = re.fullmatch(r"/api/projects/([^/]+)/archives/([^/]+)/restore", path)
            if match:
                allowed, why = self.may_restore()
                if not allowed:
                    return self.send_json(403, {"error": why})
                body, error = self.read_json_body()
                if error:
                    return self.send_json(400, {"error": error})
                return self.project_endpoint("restore", match.group(1), match.group(2),
                                             body=body)
            if path == "/api/settings":
                allowed, why = self.may_configure()
                if not allowed:
                    return self.send_json(403, {"error": why})
                body, error = self.read_json_body()
                if error:
                    return self.send_json(400, {"error": error})
                request, error = validate_settings(body)
                if error:
                    return self.send_json(400, {"error": error})
                code, payload = submit_settings(request)
                return self.send_json(code, payload)
            if path == "/api/upgrade":
                allowed, why = self.may_upgrade()
                if not allowed:
                    return self.send_json(403, {"error": why})
                body, error = self.read_json_body()
                if error:
                    return self.send_json(400, {"error": error})
                body = body or {}
                code, payload = submit_upgrade(body.get("action", "apply"),
                                               body.get("auto"))
                return self.send_json(code, payload)
            if path == "/api/register":
                allowed, why = self.may_register()
                if not allowed:
                    return self.send_json(403, {"error": why})
                body, error = self.read_json_body()
                if error:
                    return self.send_json(400, {"error": error})
                request, error = validate_registration(body)
                if error:
                    return self.send_json(400, {"error": error})
                code, payload = submit_registration(request)
                return self.send_json(code, payload)
        self.send_json(404, {"error": "not found"})

    def project_endpoint(self, action, project, name, limit=10, body=None):
        project = urllib.parse.unquote(project)
        if not PROJECT_RE.match(project):
            return self.send_json(404, {"error": "no such project"})
        known, _ = discover_projects()
        if project not in known:
            return self.send_json(404, {"error": "no such project"})

        if action == "archives":
            return self.send_json(200, list_archives(project))
        if action == "runs":
            return self.send_json(200, journal_runs(project, limit))
        if action == "run":
            code, payload = start_run(project)
            return self.send_json(code, payload)
        if action == "credentials":
            request, error = validate_credentials(project, body)
            if error:
                return self.send_json(400, {"error": error})
            code, payload = submit_credentials(request)
            return self.send_json(code, payload)
        if action == "encryption":
            request, error = validate_encryption(project, body)
            if error:
                return self.send_json(400, {"error": error})
            code, payload = submit_encryption(request)
            return self.send_json(code, payload)

        path = archive_path(project, urllib.parse.unquote(name or ""))
        if path is None:
            return self.send_json(404, {"error": "no such archive"})
        if action == "manifest":
            return self.send_json(200, {"name": path.name, "manifest": read_manifest(path)})
        if action == "verify":
            started = time.time()
            result = verify_archive(path)
            result["name"] = path.name
            result["took_s"] = round(time.time() - started, 1)
            return self.send_json(200, result)
        if action == "restore":
            # path.name, not the name off the wire: what goes in the request is
            # a filename this process has already resolved to a real archive.
            request, error = validate_restore(project, path.name, body)
            if error:
                return self.send_json(400, {"error": error})
            code, payload = submit_restore(request)
            return self.send_json(code, payload)
        if action == "download":
            if not ALLOW_DOWNLOAD:
                return self.send_json(403, {
                    "error": "downloads are disabled (WEB_ALLOW_DOWNLOAD=0). An archive "
                             "contains auth password hashes and every storage object."})
            return self.send_archive(path)
        return self.send_json(404, {"error": "not found"})

    def send_archive(self, path):
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(path.stat().st_size))
        self.send_header("Content-Disposition", f'attachment; filename="{path.name}"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as fh:
            shutil.copyfileobj(fh, self.wfile, 1 << 20)

    def serve_static(self, name):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name.startswith("."):
            return self.send_json(404, {"error": "not found"})
        path = STATIC_DIR / name
        if not path.is_file():
            return self.send_json(404, {"error": "not found"})
        self.send_bytes(200, path.read_bytes(),
                        CONTENT_TYPES.get(path.suffix, "application/octet-stream"),
                        {"Cache-Control": "no-cache"})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        # A browser that navigates away mid-request resets the connection.
        # Routine - and socketserver's default is a full traceback per
        # occurrence, which would bury the errors that matter in a journal this
        # service exists to make readable.
        if isinstance(exc, (ConnectionResetError, BrokenPipeError,
                            ConnectionAbortedError, TimeoutError)):
            return
        super().handle_error(request, client_address)


# ── Entry point ────────────────────────────────────────────────────────────

def make_hash():
    import getpass
    first = getpass.getpass("Password: ")
    if not first:
        sys.exit("empty password")
    if first != getpass.getpass("Again:    "):
        sys.exit("passwords do not match")
    print("\nAdd this to /etc/supabase-backup-web/web.env:\n")
    print(f"WEB_PASSWORD_HASH={hash_password(first)}")


def main():
    if "--hash" in sys.argv:
        return make_hash()
    if "--help" in sys.argv or "-h" in sys.argv:
        return print(__doc__.strip())

    if not ALLOW_ANON and not PASSWORD_HASH:
        sys.exit(
            "refusing to start without authentication.\n"
            "An archive holds auth password hashes and every storage object, so this\n"
            "console is not something to leave open. Either set WEB_PASSWORD_HASH\n"
            "(run `server.py --hash`), or set WEB_ALLOW_ANONYMOUS=1 to say plainly\n"
            "that you meant to.")
    # A hash that is set at all has to be well formed, whether or not auth is
    # on right now - a malformed one left in place is a lockout waiting for
    # whoever turns WEB_ALLOW_ANONYMOUS back off.
    if PASSWORD_HASH and not re.fullmatch(
            r"pbkdf2_sha256\$\d+\$[0-9a-f]+\$[0-9a-f]+", PASSWORD_HASH):
        sys.exit("WEB_PASSWORD_HASH is not a pbkdf2_sha256 hash - run `server.py --hash`")

    host, _, port = BIND.rpartition(":")
    host = host.strip("[]") or "127.0.0.1"
    try:
        port = int(port)
    except ValueError:
        sys.exit(f"WEB_BIND is not host:port: {BIND!r}")

    if not DATA_DIR.is_dir():
        print(f"warning: {DATA_DIR} does not exist or is not readable", file=sys.stderr)

    # Load what earlier runs saw, then take one straight away: a console that
    # has just restarted should not leave a hole at the point it restarted.
    _samples.extend(load_samples())
    take_sample()
    threading.Thread(target=sampler, daemon=True, name="space-sampler").start()

    httpd = Server((host, port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    projects, _ = discover_projects()
    print(f"supabase-backup-web on http://{host}:{port}  data={DATA_DIR}  "
          f"projects={','.join(projects) or 'none'}  "
          f"auth={'off' if ALLOW_ANON else 'basic'}  run={'on' if ALLOW_RUN else 'off'}  "
          f"download={'on' if ALLOW_DOWNLOAD else 'off'}  "
          f"restore={'on' if ALLOW_RESTORE else 'off'}  "
          f"space={len(_samples)} sample(s)", flush=True)
    if ALLOW_RESTORE:
        # Worth a line of its own in the journal. Everything else this console
        # does is reversible; a restore writes into somebody's live project.
        print("restore requests are enabled - they are applied by "
              f"{RESTORE_UNIT} as root, from {RESTORE_DIR}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
