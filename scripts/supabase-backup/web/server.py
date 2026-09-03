#!/usr/bin/env python3
"""
supabase-backup-web - a web console for a supabase-backup host.

It answers the question a timer cannot: did last night's backup work, and is
what it wrote any good? For every project on the host it shows the archives
with their manifests, the run history, when the next run is due, and it can
verify an archive against its own checksums and its own inventory.

It deliberately does NOT restore. `restore` is interactive, destructive, needs
the target project's credentials, and carries guards - refuses production,
refuses credentials naming two different projects - that hold because a person
is reading them while answering prompts. A web button would keep the code and
lose the setting.

Python standard library only, matching backup.sh's posture: no pip, no
virtualenv, no container, nothing that needs keeping up to date.

  server.py            serve; configuration comes from the environment
  server.py --hash     print a WEB_PASSWORD_HASH line and exit

Configuration lives in /etc/supabase-backup-web/web.env. That is a different file
from the per-project .conf files on purpose: this process never needs a
database password or a service key, so it must not be able to read one.
"""

import base64
import hashlib
import hmac
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
# A proxy terminating TLS on another host, trusted to speak for the client.
TRUSTED_PROXIES = {h.strip() for h in env("WEB_TRUSTED_PROXIES", "").split(",") if h.strip()}
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


def list_archives(project):
    directory = project_dir(project)
    if directory is None:
        return {"error": "invalid project name", "archives": [], "partials": []}
    archive_re = re.compile(rf"^{re.escape(project)}-({STAMP_RE})\.tar\.gz$")
    partial_re = re.compile(rf"^{re.escape(project)}-({STAMP_RE})\.tar\.gz\.partial$")
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
            archives.append({
                "name": entry.name,
                "stamp": match.group(1),
                "captured_at": iso(stamp_to_epoch(match.group(1))),
                "written_at": iso(st.st_mtime),
                "bytes": st.st_size,
            })
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
    if not re.fullmatch(rf"{re.escape(project)}-{STAMP_RE}\.tar\.gz", name):
        return None
    path = directory / name
    return path if path.is_file() else None


def tar_name(name):
    """`tar -czf ... -C "$WORK" .` stores members as './manifest.json'."""
    return name[2:] if name.startswith("./") else name


_manifest_cache = {}

def read_manifest(path):
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

    return {
        "name": project,
        "health": health,
        "health_reason": reason,
        "service": service,
        "timer": timer,
        "partials": listing.get("partials", []),
        "error": listing.get("error"),
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

    try:
        usage = shutil.disk_usage(DATA_DIR)
        disk = {"total": usage.total, "used": usage.used, "free": usage.free}
    except OSError:
        disk = None

    return {
        "host": os.uname().nodename if hasattr(os, "uname") else "",
        "data_dir": str(DATA_DIR),
        "now": iso(time.time()),
        "health": overall,
        "health_reason": reason,
        "stale_hours": STALE_HOURS,
        "disk": disk,
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


def registration_result(request_id):
    if not REQUEST_ID_RE.match(request_id or ""):
        return 404, {"error": "no such request"}
    result = RESULT_DIR / f"{request_id}.json"
    try:
        return 200, json.loads(result.read_text())
    except FileNotFoundError:
        pending = (REGISTER_DIR / f"{request_id}.json").exists()
        return 200, {"id": request_id, "state": "pending" if pending else "unknown"}
    except (OSError, ValueError) as exc:
        return 500, {"error": f"could not read the result: {exc}"}


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

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    def send_bytes(self, code, body, content_type, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
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
            return None, "request body too large"
        try:
            return json.loads(self.rfile.read(length).decode("utf-8")), None
        except (OSError, ValueError, UnicodeDecodeError):
            return None, "body is not valid JSON"

    def may_register(self):
        """Whether THIS connection may hand over a service key.

        The key is the most powerful credential in the system - it bypasses RLS
        on the whole project - so it is not allowed to cross the network in the
        clear, whatever the console password does. Loopback covers both
        supported paths: a TLS proxy on this host forwarding to 127.0.0.1, and
        an SSH tunnel. A proxy elsewhere has to be named in WEB_TRUSTED_PROXIES
        and say it terminated TLS.
        """
        if not ALLOW_REGISTER:
            return False, "registration is disabled (WEB_ALLOW_REGISTER=0)"
        client = self.client_address[0]
        if client in LOOPBACK:
            return True, None
        if client in TRUSTED_PROXIES and \
                self.headers.get("X-Forwarded-Proto", "").lower() == "https":
            return True, None
        return False, (
            "registering a project sends a service key, which bypasses RLS on the whole "
            "project, so it is refused over a plain-HTTP connection from the network. "
            "Reach the console through the TLS proxy on this host, or over an SSH tunnel "
            "(ssh -N -L 8787:127.0.0.1:8787 <host>), and try again from there.")

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
        if not self.authorised():
            return
        split = urllib.parse.urlsplit(self.path)
        try:
            self.dispatch(method, split.path, urllib.parse.parse_qs(split.query))
        except BrokenPipeError:
            pass
        except Exception as exc:                       # never leak a traceback
            self.log_message("unhandled error on %s %s: %r", method, self.path, exc)
            self.send_json(500, {"error": "internal error"})

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
            match = re.fullmatch(r"/api/register/([^/]+)", path)
            if match:
                code, payload = registration_result(match.group(1))
                return self.send_json(code, payload)
        elif method == "POST":
            match = re.fullmatch(r"/api/projects/([^/]+)/run", path)
            if match:
                if not ALLOW_RUN:
                    return self.send_json(403, {"error": "starting runs is disabled (WEB_ALLOW_RUN=0)"})
                return self.project_endpoint("run", match.group(1), None)
            match = re.fullmatch(r"/api/projects/([^/]+)/archives/([^/]+)/verify", path)
            if match:
                return self.project_endpoint("verify", match.group(1), match.group(2))
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

    def project_endpoint(self, action, project, name, limit=10):
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

    httpd = Server((host, port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    projects, _ = discover_projects()
    print(f"supabase-backup-web on http://{host}:{port}  data={DATA_DIR}  "
          f"projects={','.join(projects) or 'none'}  "
          f"auth={'off' if ALLOW_ANON else 'basic'}  run={'on' if ALLOW_RUN else 'off'}  "
          f"download={'on' if ALLOW_DOWNLOAD else 'off'}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
