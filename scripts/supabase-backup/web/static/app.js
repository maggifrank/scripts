// supabase-backup console. Vanilla ES modules, no build step - one less thing
// to install on a backup host.

const $ = (id) => document.getElementById(id);

const POLL_IDLE = 10_000;   // nothing is happening; be quiet
const POLL_BUSY = 2_000;    // a run is in flight; follow it

const manifests = new Map();       // "project/archive" -> manifest
const openProjects = new Set();     // panels the reader has expanded
const openArchives = new Set();
const openRuns = new Set();
const archiveKeys = new Map();      // project -> last rendered archive signature
const runKeys = new Map();

let pollTimer = null;
let capabilities = {};
let anyRunning = false;
let stickyMessage = null;           // {project, text} - an error stays put
let projectListKey = "";            // rebuild panels only when the set changes
let restorePoll = null;
let restoreShown = null;            // id of the restore whose log is on screen
let restoreBusy = false;            // one at a time, and the host agrees
let restoreStalled = false;         // running, with nothing running it
let restoreUnwatched = false;       // allowed here, not watched for on the host
let signedOut = false;              // the password changed under this browser

// ── Formatting ─────────────────────────────────────────────────────────────

const RTF = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

function relative(iso) {
  if (!iso) return "—";
  const seconds = (new Date(iso) - Date.now()) / 1000;
  const units = [["year", 31536000], ["month", 2592000], ["day", 86400],
                 ["hour", 3600], ["minute", 60], ["second", 1]];
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size || unit === "second") {
      return RTF.format(Math.round(seconds / size), unit);
    }
  }
}

function bytes(n) {
  if (n === null || n === undefined) return "—";
  const units = ["B", "kB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
}

function duration(seconds) {
  if (seconds === null || seconds === undefined) return "—";
  if (seconds < 60) return `${seconds.toFixed(seconds < 10 ? 1 : 0)}s`;
  const m = Math.floor(seconds / 60);
  return `${m}m ${Math.round(seconds - m * 60)}s`;
}

// How long is left, in the unit that unit is still useful in. Intl's relative
// format turns 41 days into "in 1 month", which is both vaguer and calmer than
// the number it replaced - the wrong trade for the one card that has to alarm.
function runway(days) {
  if (days < 1) return "today";
  if (days < 90) return `${Math.round(days)} days`;
  if (days < 730) return `${Math.round(days / 30.44)} months`;
  return `${(days / 365.25).toFixed(1)} years`;
}

// Month and year. The day is false precision on a forecast this soft, and the
// card has room for about twenty characters.
function shortDate(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "short" });
}

// Archives are named for the UTC instant a run started. Show it in the
// reader's timezone, but keep the stamp visible - it is what you type into
// `restore`.
function localTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const enc = encodeURIComponent;

// ── API ────────────────────────────────────────────────────────────────────

async function api(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", ...options });
  let payload = null;
  try { payload = await response.json(); } catch { /* non-JSON body */ }
  if (!response.ok) {
    const error = new Error((payload && payload.error) || `HTTP ${response.status}`);
    // 401 after a settings save is not a failure - it is the new password
    // taking effect - and only the status can tell the two apart.
    error.status = response.status;
    throw error;
  }
  return payload;
}

// ── Summary ────────────────────────────────────────────────────────────────

function card(label, value, sub, muted) {
  const node = el("div", "card");
  node.append(el("div", "card-label", label));
  node.append(el("div", `card-value${muted ? " muted" : ""}`, value));
  if (sub) node.append(el("div", "card-sub", sub));
  return node;
}

function renderSummary(status) {
  $("host").textContent = status.host || "";
  const pill = $("health");
  pill.textContent = status.health;
  pill.className = `pill pill-${status.health}`;
  $("reason").textContent = status.health_reason || "";

  const cards = $("cards");
  cards.replaceChildren();
  const t = status.totals;
  cards.append(card("Projects", String(t.projects), t.projects ? "" : "none configured", !t.projects));
  cards.append(card("Archives", String(t.archives), bytes(t.bytes)));

  // The soonest scheduled run across every project answers "is anything
  // still on a schedule?" better than any single project's timer.
  const next = status.projects
    .map((p) => p.timer && p.timer.next_run)
    .filter(Boolean)
    .sort()[0];
  cards.append(next
    ? card("Next run", relative(next), localTime(next))
    : card("Next run", "none scheduled", "no active timer", true));

  const space = status.disk
    ? card("Free space", bytes(status.disk.free), `of ${bytes(status.disk.total)}`)
    : card("Free space", "unknown", status.data_dir, true);
  if (status.disk) space.append(...forecast(status.disk.trend));
  cards.append(space);
}

// The forecast, in at most two lines: what happens, then what that rests on.
// The date leads because it is the thing you act on; the rate is underneath so
// you can judge whether to believe the date.
function forecast(trend) {
  if (!trend) return [];
  const note = (text, tone) => el("div", `card-note${tone ? " " + tone : ""}`, text);
  const perDay = `${bytes(Math.abs(trend.bytes_per_day || 0))}/day`;
  const over = trend.span_days >= 1 ? `over ${Math.round(trend.span_days)}d` : "";

  if (trend.history_error) {
    // No history file means the forecast can never get past its ceiling, and
    // that is something to fix on the host rather than something to hide.
    return [note("forecast is not being kept", "warn"),
            note(trend.history_error, "dim")];
  }

  if (trend.verdict === "filling") {
    const days = trend.days_left;
    const tone = days < 14 ? "crit" : days < 60 ? "warn" : null;
    return [note(trend.basis === "ceiling"
                   ? `full in ${runway(days)} at worst`
                   : `full in ${runway(days)}`, tone),
            note(basisLine(trend, perDay, over), "dim")];
  }
  // "not filling" is a real answer, and on a host whose retention is doing its
  // job it is the usual one. Saying it plainly is the point.
  if (trend.verdict === "freeing") {
    return [note("not filling"), note(`freeing ${perDay}`, "dim")];
  }
  if (trend.verdict === "steady") {
    return [note("not filling"), note(basisLine(trend, perDay, over), "dim")];
  }
  return [note("trend: not enough history yet", "dim")];
}

// What the number stands on, in about twenty characters. Only the two weaker
// bases spend their line saying so - a fit over whole prune cycles is what the
// card is meant to show, so it just shows the rate and the date.
function basisLine(trend, perDay, over) {
  if (trend.basis === "ceiling") {
    return `${perDay} arriving · if never pruned`;
  }
  if (trend.basis === "provisional") {
    const need = Math.ceil(trend.history_needed - trend.history_days);
    return `provisional · ${need}d short of 2 cycles`;
  }
  return trend.full_at ? `${perDay} · ${shortDate(trend.full_at)}`
                       : `${perDay} ${over}`.trim();
}

// ── Projects ───────────────────────────────────────────────────────────────

function renderProjects(status) {
  const container = $("projects");
  const projects = status.projects || [];
  if (!projects.length) {
    container.replaceChildren(el("p", "empty", status.error
      ? status.health_reason
      : `No projects found under ${status.data_dir}. Add one with supabase-backup-setup.sh.`));
    return;
  }
  // A lone project is the whole page; open it rather than making the reader
  // click to see anything at all.
  if (projects.length === 1 && !openProjects.size) openProjects.add(projects[0].name);

  const key = projects.map((p) => p.name).join("|");
  if (key !== projectListKey) {
    projectListKey = key;
    container.replaceChildren();
    for (const project of projects) container.append(projectPanel(project));
    return;
  }
  // Same projects as last time: update in place, so an open panel keeps its
  // loaded archives, its scroll position and whatever the reader expanded.
  for (const project of projects) {
    const panel = container.querySelector(`.project[data-name="${CSS.escape(project.name)}"]`);
    if (!panel) continue;
    updateHead(panel, project);
    const body = panel.querySelector(".project-body");
    if (body && !body.hidden) refreshProjectBody(body, project);
  }
}

function updateHead(panel, project) {
  const pill = panel.querySelector(".project-head .pill");
  if (pill) {
    pill.textContent = project.health;
    pill.className = `pill pill-${project.health}`;
  }
  const facts = panel.querySelector(".project-facts");
  if (facts) facts.replaceChildren(...factNodes(project));
}

function factNodes(project) {
  const nodes = [];
  const newest = project.archives.newest;
  nodes.push(el("span", null, newest ? `last ${relative(newest.captured_at)}` : "never run"));
  nodes.push(el("span", null, `${project.archives.count} archive${project.archives.count === 1 ? "" : "s"} · ${bytes(project.archives.total_bytes)}`));
  if (project.timer && project.timer.next_run) {
    nodes.push(el("span", null, `next ${relative(project.timer.next_run)}`));
  }
  return nodes;
}

function projectPanel(project) {
  const panel = el("div", "project");
  panel.dataset.name = project.name;
  const open = openProjects.has(project.name);
  if (open) panel.classList.add("open");

  const head = el("button", "project-head");
  head.append(el("span", "chev", "›"));
  head.append(el("span", "project-name", project.name));
  const pill = el("span", `pill pill-${project.health}`, project.health);
  head.append(pill);

  const facts = el("div", "project-facts");
  facts.append(...factNodes(project));
  head.append(facts);

  const body = el("div", "project-body");
  body.hidden = !open;

  head.addEventListener("click", () => {
    const nowOpen = body.hidden;
    body.hidden = !nowOpen;
    panel.classList.toggle("open", nowOpen);
    if (nowOpen) {
      openProjects.add(project.name);
      buildProjectBody(body, project);
    } else {
      openProjects.delete(project.name);
    }
  });

  panel.append(head, body);
  if (open) buildProjectBody(body, project);
  return panel;
}

function buildProjectBody(body, project) {
  if (body.dataset.built === "1") {
    refreshProjectBody(body, project);
    return;
  }
  body.dataset.built = "1";
  body.replaceChildren();

  body.append(el("p", "reason", project.health_reason));

  const bar = el("div", "bar");
  if (capabilities.run) {
    const button = el("button", "btn",
      project.health === "running" ? "Running…" : "Run backup now");
    button.disabled = project.health === "running";
    button.addEventListener("click", () => startRun(project.name, body, button));
    bar.append(button);
  }
  const message = el("span", "bar-msg");
  message.dataset.role = "msg";
  bar.append(message);
  body.append(bar);

  const encryption = el("div", "encryption");
  encryption.dataset.role = "encryption";
  body.append(encryption);
  renderEncryption(encryption, project);

  body.append(el("h3", null, "Archives"));
  const archives = el("div", "list");
  archives.dataset.role = "archives";
  archives.append(el("p", "empty", "Loading…"));
  body.append(archives);

  body.append(el("h3", null, "Recent runs"));
  const runs = el("div", "list");
  runs.dataset.role = "runs";
  runs.append(el("p", "empty", "Loading…"));
  body.append(runs);

  loadProject(project.name, body, project);
}

function refreshProjectBody(body, project) {
  const reason = body.querySelector(".reason");
  if (reason) reason.textContent = project.health_reason;
  const button = body.querySelector(".btn");
  if (button) {
    const running = project.health === "running";
    button.disabled = running;
    button.textContent = running ? "Running…" : "Run backup now";
  }
  const encryption = body.querySelector('[data-role="encryption"]');
  if (encryption) renderEncryption(encryption, project);
  const message = body.querySelector('[data-role="msg"]');
  if (message && !(stickyMessage && stickyMessage.project === project.name)) {
    const partial = project.partials && project.partials[0];
    message.className = "bar-msg";
    message.textContent = partial
      ? `writing ${partial.name} (${bytes(partial.bytes)} so far)`
      : (project.health === "running" ? "backup in progress" : "");
  }
}

async function loadProject(name, body, project) {
  refreshProjectBody(body, project);
  const archivesNode = body.querySelector('[data-role="archives"]');
  const runsNode = body.querySelector('[data-role="runs"]');
  if (!archivesNode || !runsNode) return;
  try {
    const [archives, runs] = await Promise.all([
      api(`/api/projects/${enc(name)}/archives`),
      api(`/api/projects/${enc(name)}/runs?limit=10`),
    ]);
    renderArchives(name, archivesNode, archives);
    renderRuns(name, runsNode, runs);
  } catch (error) {
    archivesNode.replaceChildren(el("p", "empty", error.message));
  }
}

async function startRun(name, body, button) {
  if (!confirm(`Start a backup of ${name} now?\n\nIt dumps the project's Postgres and walks its storage buckets. Read-only against the project.`)) return;
  const message = body.querySelector('[data-role="msg"]');
  button.disabled = true;
  stickyMessage = null;
  if (message) { message.className = "bar-msg"; message.textContent = "starting…"; }
  try {
    await api(`/api/projects/${enc(name)}/run`, { method: "POST" });
    anyRunning = true;
    if (message) message.textContent = "started";
    runKeys.delete(name);
  } catch (error) {
    stickyMessage = { project: name, text: error.message };
    if (message) { message.className = "bar-msg err"; message.textContent = error.message; }
    button.disabled = false;
  }
  clearTimeout(pollTimer);
  refresh();
}

// ── Encryption ─────────────────────────────────────────────────────────────

let encryptionPoll = null;

function encryptionSignature(project) {
  const e = project.encryption || {};
  return [e.enabled, (e.recipients || []).join(","), e.error,
          e.archives_encrypted, e.archives_plain].join("|");
}

function renderEncryption(container, project) {
  // Never redraw underneath someone who is typing into the form. A poll every
  // ten seconds would otherwise wipe a half-pasted key.
  if (container.dataset.editing === "1") return;
  const signature = encryptionSignature(project);
  if (container.dataset.sig === signature) return;
  container.dataset.sig = signature;

  const e = project.encryption || {};
  container.replaceChildren();

  const head = el("div", "enc-head");
  head.append(el("h3", null, "Encryption"));
  head.append(el("span", `pill pill-${e.error ? "unreadable" : (e.enabled ? "ok" : "never")}`,
    e.error ? "unknown" : (e.enabled ? "on" : "off")));
  container.append(head);

  if (e.error) {
    container.append(el("p", "hint", e.error));
  } else if (e.enabled) {
    const n = e.recipients.length;
    container.append(el("p", "hint",
      `New archives are encrypted to ${n} recipient${n === 1 ? "" : "s"}. `
      + "This host holds no private key for them, so nothing here — including this "
      + "console — can read what it writes. Restoring needs one of these identities."));
    const chips = el("div", "chips");
    for (const r of e.recipients) chips.append(el("span", "chip mono", r));
    container.append(chips);
  } else {
    container.append(el("p", "hint",
      "Archives are written in the clear. Anyone who can read this host, or a copy "
      + "of it, can read every auth password hash and every storage object in them."));
  }

  // A project that was switched on partway through has both kinds on disk, and
  // that is worth stating: the old ones did not become encrypted.
  if (e.archives_encrypted > 0 && e.archives_plain > 0) {
    container.append(el("p", "hint",
      `On disk: ${e.archives_encrypted} encrypted, ${e.archives_plain} in the clear. `
      + "Switching encryption on does not reach back — the older archives stay as they were."));
  }

  const bar = el("div", "bar");
  if (capabilities.encryption) {
    const edit = el("button", "btn-ghost", e.enabled ? "Change recipients" : "Turn on encryption");
    edit.addEventListener("click", () => buildEncryptionForm(container, project));
    bar.append(edit);
    if (e.enabled) {
      const off = el("button", "btn-ghost", "Turn off");
      off.addEventListener("click", () => disableEncryption(container, project));
      bar.append(off);
    }
  }
  const message = el("span", "bar-msg");
  message.dataset.role = "enc-msg";
  bar.append(message);
  container.append(bar);

  if (!capabilities.encryption && capabilities.encryption_blocked_because) {
    container.append(el("div", "notice", capabilities.encryption_blocked_because));
  }
  container.append(el("div", "enc-out"));
}

function buildEncryptionForm(container, project) {
  container.dataset.editing = "1";
  const e = project.encryption || {};
  const form = el("div", "form enc-form");

  const label = el("label", null, "Recipients, one per line");
  const area = document.createElement("textarea");
  area.rows = 4;
  area.spellcheck = false;
  area.autocomplete = "off";
  area.value = (e.recipients || []).join("\n");
  area.placeholder = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p";
  form.append(label, area);

  form.append(el("div", "hint",
    "An age recipient, or a whole line from an SSH .pub file. More than one means "
    + "any of them can restore — which is how you avoid a single lost key costing "
    + "you every backup."));
  form.append(el("div", "hint",
    "Make the key somewhere you keep secrets, not here: age-keygen -o backup.key "
    + "prints a public key to paste in and a private key to store. This console will "
    + "not generate one for you — a key that was ever on the backup host is a key "
    + "that was, for a moment, exactly where it must never be."));

  const bar = el("div", "bar");
  const save = el("button", "btn", "Save recipients");
  const cancel = el("button", "btn-ghost", "Cancel");
  const message = el("span", "bar-msg");
  bar.append(save, cancel, message);
  form.append(bar);
  const output = el("div");
  form.append(output);

  cancel.addEventListener("click", () => {
    container.dataset.editing = "0";
    container.dataset.sig = "";
    renderEncryption(container, project);
  });

  save.addEventListener("click", () => {
    const recipients = area.value.split("\n").map((r) => r.trim()).filter(Boolean);
    if (!recipients.length) {
      message.className = "bar-msg err";
      message.textContent = "no recipients — use Turn off if that is what you meant";
      return;
    }
    if (!confirm(
      `Encrypt future archives of '${project.name}' to ${recipients.length} recipient(s)?\n\n`
      + "Only those keys will open them. If you lose every one of them, the archives "
      + "written from now on cannot be recovered by anyone, including you.")) return;
    submitEncryption(project, recipients, container, save, message, output);
  });

  container.replaceChildren(form);
  area.focus();
}

function disableEncryption(container, project) {
  if (!confirm(
    `Stop encrypting '${project.name}'?\n\n`
    + "Every archive written from now on is readable by anyone who can read this "
    + "host or a copy of it. The archives already written stay encrypted and still "
    + "need their identity.")) return;
  const message = container.querySelector('[data-role="enc-msg"]');
  const output = container.querySelector(".enc-out") || el("div", "enc-out");
  submitEncryption(project, [], container, null, message, output);
}

async function submitEncryption(project, recipients, container, button, message, output) {
  if (button) button.disabled = true;
  if (message) { message.className = "bar-msg"; message.textContent = "submitting…"; }
  if (output) output.replaceChildren();
  let id;
  try {
    ({ id } = await api(`/api/projects/${enc(project.name)}/encryption`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ recipients }),
    }));
  } catch (error) {
    if (message) { message.className = "bar-msg err"; message.textContent = error.message; }
    if (button) button.disabled = false;
    return;
  }
  if (message) message.textContent = "applying…";
  pollEncryption(id, project, container, button, message, output);
}

function pollEncryption(id, project, container, button, message, output) {
  clearTimeout(encryptionPoll);
  const tick = async () => {
    let result;
    try {
      result = await api(`/api/encryption/${encodeURIComponent(id)}`);
    } catch (error) {
      if (message) { message.className = "bar-msg err"; message.textContent = error.message; }
      if (button) button.disabled = false;
      return;
    }
    if (result.state === "pending") {
      encryptionPoll = setTimeout(tick, 1200);
      return;
    }
    if (button) button.disabled = false;
    if (message) message.textContent = "";

    const ok = result.state === "ok";
    const box = el("div", `result ${ok ? "ok" : "bad"}`);
    // "Not applied" would be a guess for a stalled request: nothing read it, so
    // nothing decided anything. Saying it is still sitting there is the fact,
    // and the one that points at the thing to go and fix.
    box.append(el("div", null, ok
      ? "Applied. It takes effect on the next run — archives already on disk are unchanged."
      : result.state === "stalled"
        ? `Still waiting — ${result.error}`
        : `Not applied — ${result.error || "the host reported a failure"}`));
    if (Array.isArray(result.steps) && result.steps.length) {
      const ul = el("ul", "steps");
      for (const step of result.steps) ul.append(el("li", null, step));
      box.append(ul);
    }
    if (result.state === "unknown") {
      box.replaceChildren(el("div", null,
        "No result came back. The privileged helper may not be installed — check "
        + "systemctl status supabase-backup-keys.path on the host."));
    }

    // Back to the read-only view, with the outcome kept under it. The next
    // poll brings the new state from the host rather than this guessing at it.
    container.dataset.editing = "0";
    container.dataset.sig = "";
    renderEncryption(container, project);
    container.append(box);
    clearTimeout(pollTimer);
    refresh();
  };
  encryptionPoll = setTimeout(tick, 800);
}

// ── Archives ───────────────────────────────────────────────────────────────

function renderArchives(project, container, listing) {
  const archives = listing.archives || [];
  const key = archives.map((a) => `${a.name}:${a.bytes}`).join("|");
  if (archiveKeys.get(project) === key) return;   // unchanged; keep the DOM
  archiveKeys.set(project, key);
  for (const cached of [...manifests.keys()]) {   // a finished run changed this
    if (cached.startsWith(project + "/")) manifests.delete(cached);
  }

  container.replaceChildren();
  if (!archives.length) {
    container.append(el("p", "empty", "No archives yet."));
    return;
  }
  for (const archive of archives) container.append(archiveItem(project, archive));
}

function archiveItem(project, archive) {
  const id = `${project}/${archive.name}`;
  const item = el("div", "item");
  const head = el("button", "item-head");
  head.append(el("span", "chev", "›"));
  head.append(el("span", "item-name", archive.name));
  const meta = el("div", "item-meta");
  meta.append(el("span", null, relative(archive.captured_at)));
  meta.append(el("span", "mono", bytes(archive.bytes)));
  if (archive.encrypted) {
    meta.append(el("span", archive.sidecar_error ? "tag tag-warn" : "tag", "encrypted"));
  }
  head.append(meta);

  const body = el("div", "item-body");
  body.hidden = true;
  head.addEventListener("click", () => {
    const open = body.hidden;
    body.hidden = !open;
    item.classList.toggle("open", open);
    if (open) { openArchives.add(id); fillArchive(body, project, archive); }
    else openArchives.delete(id);
  });

  item.append(head, body);
  if (openArchives.has(id)) {
    body.hidden = false;
    item.classList.add("open");
    fillArchive(body, project, archive);
  }
  return item;
}

async function fillArchive(body, project, archive) {
  if (body.dataset.filled === "1") return;
  body.dataset.filled = "1";
  body.replaceChildren(el("p", "empty", "Reading manifest…"));

  const id = `${project}/${archive.name}`;
  let manifest = manifests.get(id);
  if (!manifest) {
    try {
      manifest = (await api(`/api/projects/${enc(project)}/archives/${enc(archive.name)}/manifest`)).manifest;
      manifests.set(id, manifest);
    } catch (error) {
      manifest = { error: error.message };
    }
  }

  body.replaceChildren();
  const list = el("dl", "kv");
  const rows = [
    ["captured", `${archive.captured_at}  (${localTime(archive.captured_at)})`],
    ["written", localTime(archive.written_at)],
    ["size", bytes(archive.bytes)],
  ];
  if (manifest && !manifest.error) {
    rows.push(["storage objects", String(manifest.storage_objects ?? "—")]);
    rows.push(["pg_dump", manifest.pg_dump_version ?? "—"]);
  } else if (manifest) {
    rows.push(["manifest", manifest.error]);
  }
  if (archive.encrypted) {
    const n = (archive.recipients || []).length;
    rows.push(["encryption", n
      ? `age — ${n} recipient${n === 1 ? "" : "s"}`
      : "age — the sidecar does not say to whom"]);
  }
  for (const [key, value] of rows) list.append(el("dt", null, key), el("dd", null, value));
  body.append(list);

  // Schemas, buckets and row counts are lists, not single values - they read
  // far better as chips than crammed into the table above.
  if (manifest && !manifest.error) {
    for (const [label, values] of [["schemas", manifest.schemas], ["buckets", manifest.buckets]]) {
      if (Array.isArray(values) && values.length) {
        body.append(el("h3", null, label));
        const chips = el("div", "chips");
        for (const v of values) chips.append(el("span", "chip", v));
        body.append(chips);
      }
    }
    const rowCounts = manifest.rows && Object.entries(manifest.rows);
    if (rowCounts && rowCounts.length) {
      body.append(el("h3", null, "rows in this archive"));
      const chips = el("div", "chips");
      for (const [table, n] of rowCounts.sort((a, b) => a[0].localeCompare(b[0]))) {
        chips.append(el("span", "chip", `${table} ${n}`));
      }
      body.append(chips);
    }
  }

  if (archive.encrypted && (archive.recipients || []).length) {
    body.append(el("h3", null, "readable by"));
    const chips = el("div", "chips");
    for (const r of archive.recipients) chips.append(el("span", "chip mono", r));
    body.append(chips);
    body.append(el("p", "hint",
      "The matching private key is not on this host, by design. Restoring this "
      + "archive means bringing one of these identities to it."));
  }

  const actions = el("div", "body-actions");
  const verify = el("button", "btn-ghost",
    archive.encrypted ? "Check for damage" : "Verify checksums");
  const output = el("div");
  verify.addEventListener("click", async () => {
    verify.disabled = true;
    verify.textContent = "Verifying…";
    output.replaceChildren();
    try {
      renderVerify(output, await api(
        `/api/projects/${enc(project)}/archives/${enc(archive.name)}/verify`, { method: "POST" }));
    } catch (error) {
      output.replaceChildren(el("div", "result bad", error.message));
    } finally {
      verify.disabled = false;
      verify.textContent = archive.encrypted ? "Check for damage" : "Verify checksums";
    }
  });
  actions.append(verify);

  if (capabilities.download) {
    const download = el("a", "btn-ghost", "Download");
    download.href = `/api/projects/${enc(project)}/archives/${enc(archive.name)}/download`;
    actions.append(download);
  } else if (archive.encrypted) {
    // Downloads are off because an archive holds every auth password hash and
    // every stored object. That reasoning does not survive encryption - what
    // would leave here is ciphertext - and saying nothing leaves someone with
    // a key at a panel offering only "Check for damage", with no hint that
    // taking the archive to the key is how an encrypted one is read at all.
    actions.append(el("span", "bar-msg",
      "Encrypted, so what would leave here is ciphertext — taking it to the machine that "
      + "holds the key is how it gets read. Downloading over HTTP is off "
      + "(WEB_ALLOW_DOWNLOAD, in the gear); scp from the host needs nothing turned on."));
  }

  // The form opens inside the archive it would restore, never beside it: which
  // archive is being written into a live project is not a thing to select from
  // a list a second time and get wrong.
  const restoreHost = el("div");
  if (capabilities.restore && archive.encrypted) {
    // Not a button that fails: the identity that opens this is deliberately
    // not on the host, so there is nothing the console could ask for that
    // would make the restore possible from here.
    actions.append(el("span", "bar-msg",
      "Encrypted — restoring it needs the age identity, which is kept off this host. " +
      "Run supabase-restore at the terminal and supply the key there."));
  } else if (capabilities.restore) {
    const toggle = el("button", "btn-ghost", "Restore this archive…");
    toggle.addEventListener("click", () => {
      const open = !restoreHost.firstChild;
      restoreHost.replaceChildren(...(open ? [buildRestoreForm(project, archive)] : []));
      toggle.textContent = open ? "Cancel" : "Restore this archive…";
    });
    actions.append(toggle);
  }
  body.append(actions, output, restoreHost);
}

const shortHash = (h) => (h ? `${h.slice(0, 12)}…` : "—");

function renderVerifyEncrypted(container, result) {
  const box = el("div", `result ${result.ok ? "ok" : "bad"}`);
  box.append(el("div", null, result.ok
    ? `OK — ${bytes(result.bytes)} of ciphertext, byte for byte what the run wrote (${result.took_s}s)`
    : "FAILED — these are not the bytes the run wrote. Use an older archive."));

  const problems = [];
  if (result.sha256_ok === false) {
    problems.push(`sha256 is ${shortHash(result.actual_sha256)}, the run recorded ${shortHash(result.expected_sha256)}`);
  }
  if (result.size_ok === false) {
    problems.push(`${result.bytes} bytes on disk, the run recorded ${result.expected_bytes}`);
  }
  if (result.header_ok === false) {
    problems.push("this does not start like an age file — it may not be an encrypted archive at all");
  }
  if (problems.length) {
    const ul = el("ul");
    for (const problem of problems) ul.append(el("li", null, problem));
    box.append(ul);
  }

  // Saying what a check covers matters more here than anywhere else on the
  // page, because this one covers less than the name suggests.
  box.append(el("div", "hint",
    "This compares the file against the digest taken when it was written, so it "
    + "catches a disk that rotted, a copy that truncated, a file that changed. It "
    + "cannot look inside: that needs the identity, which this host does not have. "
    + "The contents were checked against storage.objects by the run itself, before "
    + "any of it was encrypted."));
  container.replaceChildren(box);
}

function renderVerify(container, result) {
  if (result.fatal) {
    container.replaceChildren(el("div", "result bad", result.fatal));
    return;
  }
  if (result.encrypted) return renderVerifyEncrypted(container, result);
  const box = el("div", `result ${result.ok ? "ok" : "bad"}`);
  box.append(el("div", null, result.ok
    ? `OK — ${result.checked} file(s) match their checksums, ${result.files_in_archive} storage object(s) present (${result.took_s}s)`
    : "FAILED — this archive does not verify. Use an older one."));

  const problems = [];
  for (const name of result.mismatched) problems.push(`checksum mismatch: ${name}`);
  for (const name of result.missing) problems.push(`listed in SHA256SUMS but absent: ${name}`);
  for (const name of result.unlisted) problems.push(`present but unlisted: ${name}`);
  for (const name of result.filelist_orphans) problems.push(`in filelist.txt but not stored: ${name}`);
  if (result.manifest_error) problems.push(`manifest unreadable: ${result.manifest_error}`);
  if (result.counts_agree === false) {
    problems.push(`manifest says ${result.manifest.storage_objects} object(s), archive holds ${result.files_in_archive}`);
  }
  if (problems.length) {
    const ul = el("ul");
    for (const problem of problems.slice(0, 25)) ul.append(el("li", null, problem));
    box.append(ul);
  }
  container.replaceChildren(box);
}

// ── Runs ───────────────────────────────────────────────────────────────────

function renderRuns(project, container, payload) {
  if (!payload.available) {
    container.replaceChildren(el("p", "empty",
      "No journal here — run history is read from journalctl on the backup host."));
    return;
  }
  const runs = payload.runs || [];
  const key = runs.map((r) => `${r.id}:${r.lines.length}:${r.outcome}`).join("|");
  if (runKeys.get(project) === key) return;
  runKeys.set(project, key);

  container.replaceChildren();
  if (!runs.length) {
    container.append(el("p", "empty",
      "Nothing in the journal. Debian keeps it in memory only unless /var/log/journal exists, so it empties on reboot."));
    return;
  }
  for (const run of runs) container.append(runItem(project, run));
}

function runItem(project, run) {
  const id = `${project}/${run.id}`;
  const item = el("div", "item");
  const head = el("button", "item-head");
  head.append(el("span", "chev", "›"));
  const marks = { success: ["mark-ok", "✓"], failed: ["mark-bad", "✗"], unknown: ["mark-unknown", "·"] };
  const [markClass, glyph] = marks[run.outcome] || marks.unknown;
  head.append(el("span", `mark ${markClass}`, glyph));
  head.append(el("span", null, localTime(run.started_at)));
  const meta = el("div", "item-meta");
  meta.append(el("span", null, relative(run.started_at)));
  meta.append(el("span", "mono", duration(run.duration_s)));
  head.append(meta);

  const body = el("div", "item-body");
  body.hidden = true;
  const log = el("div", "log");
  for (const line of run.lines) {
    const row = el("div", line.err ? "err" : null);
    row.append(el("span", "t", (line.t || "").slice(11, 19) + "  "));
    row.append(document.createTextNode(line.m));
    log.append(row);
  }
  body.append(log);

  head.addEventListener("click", () => {
    const open = body.hidden;
    body.hidden = !open;
    item.classList.toggle("open", open);
    open ? openRuns.add(id) : openRuns.delete(id);
  });
  if (openRuns.has(id)) { body.hidden = false; item.classList.add("open"); }
  item.append(head, body);
  return item;
}

// ── Registering a project ──────────────────────────────────────────────────

let registerBuilt = false;
let registerPoll = null;

function renderRegister(status) {
  const section = $("register-section");
  const host = $("register");
  const caps = status.capabilities || {};
  section.hidden = false;

  // Refused connections get the reason rather than a form that cannot work.
  if (!caps.register) {
    if (host.dataset.mode === "blocked") return;
    host.dataset.mode = "blocked";
    registerBuilt = false;
    host.replaceChildren(el("div", "notice", caps.register_blocked_because ||
      "Registering a project is not available on this connection."));
    return;
  }
  if (registerBuilt && host.dataset.mode === "form") return;
  host.dataset.mode = "form";
  registerBuilt = true;
  buildRegisterForm(host);
}

function field(label, name, hint, type = "text", placeholder = "", prefix = "reg") {
  const wrap = el("div", "field");
  const id = `${prefix}-${name}`;
  const l = el("label", null, label);
  l.htmlFor = id;
  const input = document.createElement("input");
  input.type = type;
  input.id = id;
  input.name = name;
  input.placeholder = placeholder;
  input.autocomplete = "off";
  input.spellcheck = false;
  wrap.append(l, input);
  if (hint) wrap.append(el("div", "hint", hint));
  return wrap;
}

function buildRegisterForm(host) {
  const form = el("div", "form");

  form.append(field("Project name", "project",
    "Lowercase letters, digits, - and _. Becomes the config name, the archive directory and the timer instance.",
    "text", "billing"));

  form.append(field("Session pooler URI", "database_url",
    "Supabase dashboard → Connect → Direct → Session pooler. Port 5432, not 6543: transaction mode does not hold a session across statements and pg_dump fails partway.",
    "password", "postgresql://postgres.<ref>:<password>@…pooler.supabase.com:5432/postgres"));

  form.append(field("Project URL", "supabase_url",
    "Must name the same project as the URI above — a mismatched pair dumps one project's Postgres while walking another's storage.",
    "text", "https://<ref>.supabase.co"));

  form.append(field("Service key", "service_key",
    "Bypasses RLS. It is written to a root-owned 0600 config and the request holding it is shredded straight after.",
    "password", ""));

  const row = el("div", "row");
  row.append(field("Keep days", "keep_days", "Prune archives older than this. 0 disables pruning.", "text", "30"));
  const check = el("label", "check");
  const box = document.createElement("input");
  box.type = "checkbox";
  box.id = "reg-run_now";
  box.checked = true;
  check.append(box, document.createTextNode("Run the first backup now"));
  const checkField = el("div", "field");
  checkField.append(check);
  row.append(checkField);
  form.append(row);

  const bar = el("div", "bar");
  const submit = el("button", "btn", "Register project");
  const message = el("span", "bar-msg");
  bar.append(submit, message);
  form.append(bar);

  const output = el("div");
  form.append(output);

  form.querySelector("#reg-keep_days").value = "30";
  submit.addEventListener("click", () => submitRegistration(form, submit, message, output));
  host.replaceChildren(form);
}

async function submitRegistration(form, submit, message, output) {
  const value = (name) => (form.querySelector(`#reg-${name}`).value || "").trim();
  const body = {
    project: value("project"),
    database_url: value("database_url"),
    supabase_url: value("supabase_url"),
    service_key: value("service_key"),
    keep_days: Number(value("keep_days") || 30),
    run_now: form.querySelector("#reg-run_now").checked,
  };
  if (!confirm(`Register '${body.project}' and start backing it up nightly?`)) return;

  submit.disabled = true;
  message.className = "bar-msg";
  message.textContent = "submitting…";
  output.replaceChildren();
  let id;
  try {
    ({ id } = await api("/api/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }));
  } catch (error) {
    message.className = "bar-msg err";
    message.textContent = error.message;
    submit.disabled = false;
    return;
  }

  // The secrets have left the browser; do not keep them in the DOM either.
  for (const name of ["database_url", "service_key"]) form.querySelector(`#reg-${name}`).value = "";
  message.textContent = "applying…";
  pollRegistration(id, form, submit, message, output);
}

function pollRegistration(id, form, submit, message, output) {
  clearTimeout(registerPoll);
  const tick = async () => {
    let result;
    try {
      result = await api(`/api/register/${encodeURIComponent(id)}`);
    } catch (error) {
      message.className = "bar-msg err";
      message.textContent = error.message;
      submit.disabled = false;
      return;
    }
    if (result.state === "pending") {
      registerPoll = setTimeout(tick, 1500);
      return;
    }
    submit.disabled = false;
    message.textContent = "";
    const ok = result.state === "ok";
    const box = el("div", `result ${ok ? "ok" : "bad"}`);
    box.append(el("div", null, ok
      ? "Registered. It now has a nightly timer, and its panel appears above."
      : `Not registered — ${result.error || "the host reported a failure"}`));
    if (Array.isArray(result.steps) && result.steps.length) {
      const ul = el("ul", "steps");
      for (const step of result.steps) ul.append(el("li", null, step));
      box.append(ul);
    }
    if (result.state === "unknown") {
      box.replaceChildren(el("div", null,
        "No result came back. The privileged helper may not be installed — check " +
        "systemctl status supabase-backup-register.path on the host."));
    }
    output.replaceChildren(box);
    if (ok) {
      form.querySelector("#reg-project").value = "";
      form.querySelector("#reg-supabase_url").value = "";
      projectListKey = "";          // force the project list to rebuild
      clearTimeout(pollTimer);
      refresh();
    }
  };
  registerPoll = setTimeout(tick, 1000);
}

// ── Console settings ───────────────────────────────────────────────────────

// The console cannot write its own configuration, so saving here is the same
// round trip as registering a project: leave a request, a root helper applies
// it and restarts the service, poll for what it made of it. Which is why the
// save is not instant, and why the page has to survive the console going away
// for a second in the middle of it.

let settingsPoll = null;
let settingsBusy = false;           // a save is in flight; do not rebuild under it

function openSettings() {
  const dialog = $("settings-dialog");
  if (!dialog) return;
  dialog.showModal();
  // Reloading under an in-flight save or upgrade would throw away the box
  // reporting it, and the poll writes into nodes this would have replaced.
  if (!settingsBusy && !upgradeBusy) loadSettings();
}

function closeSettings() {
  const dialog = $("settings-dialog");
  if (dialog && dialog.open) dialog.close();
}

async function loadSettings() {
  const host = $("settings");
  if (!host) return;
  host.replaceChildren(el("p", "empty", "Loading…"));

  let payload;
  try {
    payload = await api("/api/settings");
  } catch (error) {
    host.replaceChildren(el("div", "notice", error.message));
    return;
  }
  // Above the form either way, and it loads on its own: what version this host
  // runs is the first thing you look for here, and asking GitHub about it must
  // not hold up a panel you opened to change a password.
  const settings = payload.settings || {};
  if (!payload.editable) {
    // Still worth the panel: what the console is running with is exactly what
    // you need to know before going to the host to change it.
    host.replaceChildren(versionBlock(), el("div", "notice", payload.blocked_because ||
      "Settings cannot be changed from this connection."));
    host.append(settingsSummary(settings));
    return;
  }
  host.replaceChildren(versionBlock(), buildSettingsForm(settings));
}

function settingsSummary(s) {
  const wrap = el("div", "form");
  const list = el("dl", "kv");
  const rows = [
    ["username", s.username],
    ["password", s.password_set ? "set" : (s.anonymous ? "none — authentication is off" : "not set")],
    ["listening on", s.bind],
    ["stale after", `${s.stale_hours}h`],
    ["run button", s.allow_run ? "on" : "off"],
    ["downloads", s.allow_download ? "on" : "off"],
    ["add a project", s.allow_register ? "on" : "off"],
    ["settings here", s.allow_settings ? "on" : "off"],
    ["upgrade here", s.allow_upgrade ? "on" : "off"],
    ["config file", s.config_path],
  ];
  for (const [key, value] of rows) list.append(el("dt", null, key), el("dd", null, String(value)));
  wrap.append(list);
  return wrap;
}

// Named for the panel it belongs to: this file has more than one form now, and
// a second plain `checkbox` further down would quietly win the name.
function settingCheckbox(label, name, checked, hint) {
  const wrap = el("div", "field");
  const check = el("label", "check");
  const box = document.createElement("input");
  box.type = "checkbox";
  box.id = `set-${name}`;
  box.checked = !!checked;
  check.append(box, document.createTextNode(label));
  wrap.append(check);
  if (hint) wrap.append(el("div", "hint", hint));
  return wrap;
}

function buildSettingsForm(s) {
  const form = el("div", "form");
  const set = (label, name, hint, type, placeholder) =>
    field(label, name, hint, type, placeholder, "set");

  form.append(el("h3", null, "Sign in"));
  form.append(set("Username", "username",
    "Changing it signs this browser out — the credentials it has saved stop matching.",
    "text"));
  form.append(set("New password", "new_password",
    `At least ${s.min_password} characters. Leave both boxes empty to keep the one you have.`,
    "password"));
  form.append(set("Repeat new password", "confirm_password", "", "password"));
  form.append(set("Current password", "current_password",
    s.password_set
      ? "Asked for because a browser resends a saved password all day. Typing it here is what says someone is at the keyboard."
      : "No password is set on this console yet, so leave this empty.",
    "password"));

  form.append(el("h3", null, "This console"));
  const row = el("div", "row");
  row.append(set("Listen address", "bind",
    "127.0.0.1:8787 serves only an SSH tunnel or a proxy on this host. 0.0.0.0:8787 serves the network, with Basic auth in the clear on every request.",
    "text"));
  row.append(set("Stale after (hours)", "stale_hours",
    "How old the newest archive may be before a project is called stale. The timer fires nightly, so past ~26h a night was missed.",
    "text"));
  form.append(row);

  form.append(settingCheckbox('Offer "Run backup now"', "allow_run", s.allow_run,
    "Needs the polkit rule the setup script installs."));
  form.append(settingCheckbox("Allow downloading whole archives over HTTP", "allow_download", s.allow_download,
    "An archive holds every auth password hash and every storage object. scp is the better route for a one-off."));
  form.append(settingCheckbox('Offer "Add a project"', "allow_register", s.allow_register,
    "Registering sends a service key, so it is refused over plain HTTP whatever this says."));
  form.append(settingCheckbox("Allow changing settings from here", "allow_settings", s.allow_settings,
    `Turning this off leaves ${s.config_path} on the host as the only way back.`));
  form.append(settingCheckbox('Offer "Upgrade"', "allow_upgrade", s.allow_upgrade,
    "The version panel above keeps saying what is running either way. With this off it " +
    "stops offering to do anything about it, and supabase-backup-upgrade on the host is " +
    "the way."));

  const bar = el("div", "bar");
  const submit = el("button", "btn", "Save settings");
  const message = el("span", "bar-msg");
  bar.append(submit, message);
  form.append(el("div", "hint",
    `Saving restarts ${s.unit}. Everything on the page goes quiet for a second; if the ` +
    "username or password changed, the browser will ask for them again."));
  form.append(bar);

  const output = el("div");
  form.append(output);

  form.querySelector("#set-username").value = s.username || "";
  form.querySelector("#set-bind").value = s.bind || "";
  form.querySelector("#set-stale_hours").value = String(s.stale_hours ?? "");
  if (!s.password_set) form.querySelector("#set-current_password").disabled = true;

  submit.addEventListener("click", () => saveSettings(form, submit, message, output, s));
  return form;
}

async function saveSettings(form, submit, message, output, s) {
  // Not trimmed, unlike everything else here: a password is whatever was
  // typed, spaces included.
  const raw = (name) => form.querySelector(`#set-${name}`).value || "";
  const value = (name) => raw(name).trim();
  const checked = (name) => form.querySelector(`#set-${name}`).checked;

  const password = raw("new_password");
  if (password && password !== raw("confirm_password")) {
    message.className = "bar-msg err";
    message.textContent = "the two new passwords do not match";
    return;
  }
  const body = {
    current_password: raw("current_password"),
    username: value("username"),
    new_password: password,
    confirm_password: raw("confirm_password"),
    bind: value("bind"),
    stale_hours: Number(value("stale_hours")),
    allow_run: checked("allow_run"),
    allow_download: checked("allow_download"),
    allow_register: checked("allow_register"),
    allow_settings: checked("allow_settings"),
    allow_upgrade: checked("allow_upgrade"),
  };

  const warnings = [];
  if (password) warnings.push("The console password changes — this browser will have to sign in again.");
  if (body.bind !== s.bind) warnings.push(`It will listen on ${body.bind} instead of ${s.bind}. If that address cannot reach you, this page stops here.`);
  if (body.allow_download && !s.allow_download) warnings.push("Archives become downloadable over HTTP — auth password hashes included.");
  if (!body.allow_settings) warnings.push(`This panel becomes read-only. Only ${s.config_path} on the host can undo that.`);
  if (!confirm([`Save these settings and restart ${s.unit}?`, ...warnings].join("\n\n"))) return;

  submit.disabled = true;
  message.className = "bar-msg";
  message.textContent = "saving…";
  output.replaceChildren();

  let id;
  try {
    ({ id } = await api("/api/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }));
  } catch (error) {
    message.className = "bar-msg err";
    message.textContent = error.message;
    submit.disabled = false;
    return;
  }

  // Whatever happens next, the passwords have left the browser.
  for (const name of ["new_password", "confirm_password", "current_password"]) {
    form.querySelector(`#set-${name}`).value = "";
  }
  message.textContent = "applying…";
  settingsBusy = true;
  pollSettings(id, submit, message, output, !!password);
}

function pollSettings(id, submit, message, output, passwordChanged) {
  clearTimeout(settingsPoll);
  // The console restarts in the middle of this, so a failed request is the
  // expected case for a few seconds - not an error to report. After a minute
  // and a half it is no longer a restart.
  const deadline = Date.now() + 90_000;

  const tick = async () => {
    let result;
    try {
      result = await api(`/api/settings/${enc(id)}`);
    } catch (error) {
      if (error.status === 401) return signedOutBox(output, message, submit);
      if (Date.now() < deadline) {
        message.textContent = "the console is restarting…";
        settingsPoll = setTimeout(tick, 2000);
        return;
      }
      settingsBusy = false;
      message.className = "bar-msg err";
      message.textContent = "the console has not come back on this address";
      output.replaceChildren(el("div", "result bad",
        "It may be listening somewhere else now, or it may not have started. On the host: " +
        "systemctl status supabase-backup-web, and journalctl -u supabase-backup-reconfigure -n 30 " +
        "for what the helper did — it puts the old settings back if the console will not start."));
      submit.disabled = false;
      return;
    }

    if (result.state === "pending" || result.state === "running") {
      message.textContent = result.state === "running"
        ? "applying…" : "waiting for the helper…";
      settingsPoll = setTimeout(tick, 1500);
      return;
    }
    // The helper takes the request, then works for a few seconds. An id with
    // no result yet is that gap, not a missing helper - which is only what it
    // means if it is still saying so when the time is up.
    if (result.state === "unknown" && Date.now() < deadline) {
      settingsPoll = setTimeout(tick, 1500);
      return;
    }
    settingsBusy = false;
    submit.disabled = false;
    message.textContent = "";
    const ok = result.state === "ok";
    const box = el("div", `result ${ok ? "ok" : "bad"}`);
    box.append(el("div", null, ok
      ? "Saved."
      : `Not saved — ${result.error || "the host reported a failure"}`));
    if (Array.isArray(result.steps) && result.steps.length) {
      const ul = el("ul", "steps");
      for (const step of result.steps) ul.append(el("li", null, step));
      box.append(ul);
    }
    if (result.state === "unknown") {
      box.replaceChildren(el("div", null,
        "No result came back. The settings helper may not be installed — check " +
        "systemctl status supabase-backup-reconfigure.path on the host."));
    }
    output.replaceChildren(box);
    // Deliberately not reloading the panel on success: it would replace the
    // box that just said what changed, and the form already shows what took
    // effect - it is what was typed into it.
    if (ok && passwordChanged) signedOutBox(output, message, submit, true);
  };
  settingsPoll = setTimeout(tick, 1200);
}

function signedOutBox(output, message, submit, saved) {
  settingsBusy = false;
  submit.disabled = false;
  message.className = "bar-msg";
  message.textContent = "";
  const box = el("div", "result ok");
  box.append(el("div", null, saved
    // Appended, not replacing: the box above it lists what actually changed,
    // which is the part worth reading before signing back in.
    ? "The password changed, so this browser is still signed in with the old one."
    : "The password changed — this browser is signed in with the old one."));
  const bar = el("div", "body-actions");
  const reload = el("button", "btn-ghost", "Reload and sign in again");
  reload.addEventListener("click", () => location.reload());
  bar.append(reload);
  box.append(bar);
  output.append(box);
}

// ── Version, and upgrading ─────────────────────────────────────────────────

// What is running here, what GitHub publishes, and a button between the two.
// The console installs nothing: it leaves a request, a root helper downloads
// and installs, and this polls for what it made of it - the same round trip as
// saving settings, and it ends the same way, with the console restarting
// underneath the page that asked.

let upgradePoll = null;
let upgradeBusy = false;            // an upgrade is in flight; do not rebuild

function versionBlock() {
  const wrap = el("div", "form version");
  wrap.append(el("h3", null, "Version"), el("p", "empty", "Checking…"));
  loadVersion(wrap);
  return wrap;
}

async function loadVersion(wrap, refresh) {
  if (refresh) {
    wrap.replaceChildren(el("h3", null, "Version"),
                         el("p", "empty", "Asking GitHub…"));
  }
  let payload;
  try {
    payload = await api(`/api/upgrade${refresh ? "?refresh=1" : ""}`);
  } catch (error) {
    wrap.replaceChildren(el("h3", null, "Version"), el("div", "notice", error.message));
    return;
  }
  paintVersion(wrap, payload);
  // An upgrade already running - started here before a reload, or from
  // another browser. Reattach to it rather than offering to start a second.
  const pending = (payload.activity && payload.activity.pending) || [];
  if (pending.length && !upgradeBusy) {
    const bar = wrap.querySelector(".bar");
    const message = wrap.querySelector(".bar-msg");
    const output = wrap.querySelector(".upgrade-output");
    if (bar && message && output) {
      for (const button of bar.querySelectorAll("button")) button.disabled = true;
      upgradeBusy = true;
      message.textContent = "an upgrade is already running…";
      pollUpgrade(pending[0], wrap, message, output);
    }
  }
}

// One line each, in the order the question is asked: what is here, what is
// there. The commit is shown next to the version because the version is a
// label someone typed and the commit is not.
function versionLine(version, commit, when, whenLabel) {
  const parts = [version || "unknown"];
  if (commit) parts.push(commit.slice(0, 7));
  if (when) parts.push(`${whenLabel} ${localTime(when)}`);
  return parts.join(" · ");
}

function paintVersion(wrap, payload) {
  const check = payload.check || {};
  // A repaint after an action carries a fresh check but no fresh activity -
  // the helper reports what it did, not what systemd's timer is up to. Keep
  // the last real one rather than redrawing as though the timer vanished.
  if (payload.activity && Object.keys(payload.activity).length) {
    wrap._activity = payload.activity;
  }
  if (typeof payload.changelog === "string") wrap._changelog = payload.changelog;
  payload = { ...payload, changelog: payload.changelog ?? wrap._changelog };
  const nodes = [el("h3", null, "Version")];

  if (check.error) {
    nodes.push(el("div", "notice", check.error));
    wrap.replaceChildren(...nodes);
    return;
  }

  const installed = check.installed || {};
  const available = check.available || {};
  const list = el("dl", "kv");
  list.append(el("dt", null, "running"),
              el("dd", null, versionLine(installed.version, installed.commit,
                                         installed.installed_at, "installed")));
  list.append(el("dt", null, "available"),
              el("dd", null, versionLine(available.version, available.commit,
                                         available.committed_at, "committed")));
  if (Array.isArray(installed.components)) {
    list.append(el("dt", null, "installed"), el("dd", null, installed.components.join(", ")));
  }
  if (check.repo) {
    list.append(el("dt", null, "source"), el("dd", null, `${check.repo} · ${check.branch}`));
  }
  nodes.push(list);

  if (check.reason) nodes.push(el("div", "hint", check.reason));

  const bar = el("div", "bar");
  const message = el("span", "bar-msg");
  const output = el("div", "upgrade-output");

  const upgrade = el("button", check.upgrade_available ? "btn" : "btn-ghost",
                     check.upgrade_available ? "Upgrade" : "Reinstall");
  const recheck = el("button", "btn-ghost", "Check again");
  bar.append(upgrade, recheck, message);

  if (!payload.allowed) {
    upgrade.disabled = true;
    nodes.push(bar, el("div", "notice", payload.blocked_because ||
      "Upgrading is not possible from this connection."), output);
    recheck.addEventListener("click", () => loadVersion(wrap, true));
    wrap.replaceChildren(...nodes);
    return;
  }

  // Installed but not watching: the helper would never see the request. It
  // looks exactly like an upgrade that is taking a while, so say which it is
  // before the button is pressed rather than after.
  const activity = wrap._activity || {};
  if (activity.helper_installed && !activity.helper_watching) {
    nodes.push(el("div", "notice",
      `${activity.unit} is installed but supabase-backup-upgrade.path is not watching the ` +
      "spool, so a request would sit there unread. On the host: systemctl enable --now " +
      "supabase-backup-upgrade.path"));
  }

  upgrade.addEventListener("click",
    () => startUpgrade(check, wrap, upgrade, recheck, message, output));
  recheck.addEventListener("click", () => loadVersion(wrap, true));

  // What you would be getting, above the button that gets it. Commit subjects
  // rather than release notes: a patch never writes release notes, and the
  // subject line is what it wrote instead.
  const news = whatsNew(check);
  if (news) nodes.push(news);
  nodes.push(bar, autoBox(check, activity, wrap));
  const history = versionHistory(payload.changelog, wrap);
  if (history) nodes.push(history);
  nodes.push(output);

  const last = activity.latest;
  if (last && last.state && last.state !== "running" && !upgradeBusy) {
    output.append(upgradeResult(last));
  }
  wrap.replaceChildren(...nodes);
}

// The twice-daily timer checks either way; this is only whether it may also
// install. Its own control rather than a line in the settings form below,
// because it is a decision about the host and not about this console - and
// because saving the form would be a strange way to change what happens at
// midnight.
function autoBox(check, activity, wrap) {
  const wrapper = el("div", "field auto");
  const label = el("label", "check");
  const box = document.createElement("input");
  box.type = "checkbox";
  box.id = "set-auto_upgrade";
  box.checked = check.auto === "patch";
  label.append(box, document.createTextNode("Install patches automatically"));
  wrapper.append(label);

  // What a patch is, said where the decision is made. The rule is not obvious
  // and the consequence of misreading it is a host that updates itself when
  // you thought it would ask.
  const when = activity.timer_next
    ? `Next check ${relative(activity.timer_next)}, ${localTime(activity.timer_next)}.`
    : "";
  wrapper.append(el("div", "hint",
    "A patch is a new commit against the version already running. Anything that " +
    "changes the version number is left for you — which is what changing it is for. " +
    when));

  if (activity.timer_installed && !activity.timer_active) {
    wrapper.append(el("div", "notice",
      "supabase-backup-upgrade-scheduled.timer is installed but not running, so nothing " +
      "is checking on a schedule. On the host: systemctl enable --now " +
      "supabase-backup-upgrade-scheduled.timer"));
  } else if (activity.timer_installed === false) {
    wrapper.append(el("div", "notice",
      "The twice-daily timer is not installed on this host. Re-run " +
      "supabase-backup-web-setup.sh, or upgrade once from here."));
  }

  const status = el("span", "bar-msg");
  wrapper.append(status);
  box.addEventListener("change", () => setAuto(box, status, wrap));
  return wrapper;
}

async function setAuto(box, status, wrap) {
  const want = box.checked ? "patch" : "off";
  box.disabled = true;
  status.className = "bar-msg";
  status.textContent = "saving…";
  let id;
  try {
    ({ id } = await api("/api/upgrade", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "auto", auto: want }),
    }));
  } catch (error) {
    box.checked = !box.checked;          // it did not take; do not pretend it did
    box.disabled = false;
    status.className = "bar-msg err";
    status.textContent = error.message;
    return;
  }

  // The helper writes one small file - fast, and no restart - but it is still
  // a round trip through root, so wait for the answer rather than assuming.
  const deadline = Date.now() + 30_000;
  const tick = async () => {
    let result;
    try {
      result = await api(`/api/upgrade/${enc(id)}`);
    } catch (error) {
      box.disabled = false;
      status.className = "bar-msg err";
      status.textContent = error.message;
      return;
    }
    if ((result.state === "pending" || result.state === "running" ||
         result.state === "unknown") && Date.now() < deadline) {
      setTimeout(tick, 700);
      return;
    }
    box.disabled = false;
    if (result.state === "ok") {
      status.className = "bar-msg";
      status.textContent = want === "patch" ? "on" : "off";
      // Repaint so the terminal and the panel agree on what the file says,
      // rather than on what was clicked.
      if (result.check) paintVersion(wrap, { check: result.check, activity: {}, allowed: true });
    } else {
      box.checked = !box.checked;
      status.className = "bar-msg err";
      status.textContent = result.error || "the host would not set it";
    }
  };
  setTimeout(tick, 500);
}

function whatsNew(check) {
  const changes = check.changes || {};
  const commits = changes.commits || [];
  if (!commits.length) return null;

  const box = el("div", "whats-new");
  box.append(el("div", "whats-new-head",
    commits.length === 1 ? "What's new — 1 commit" : `What's new — ${commits.length} commits`));
  const list = el("ul", "commits");
  for (const commit of commits) {
    const item = el("li");
    item.append(el("code", null, (commit.sha || "").slice(0, 7)));
    item.append(document.createTextNode(" " + (commit.subject || "")));
    if (commit.date) item.append(el("span", "commit-when", ` · ${relative(commit.date)}`));
    list.append(item);
  }
  box.append(list);
  if (changes.truncated) {
    box.append(el("div", "hint",
      "…and older. This host's commit is not in the last 30, so this is the recent " +
      "history rather than the whole of what you would be getting."));
  }
  return box;
}

// The releases this host has notes for. What is ahead of it is the commit list
// above instead - CHANGELOG.md arrives with an upgrade, so it can only ever
// describe versions already installed, and saying otherwise would be inventing.
function versionHistory(text, wrap) {
  const releases = parseChangelog(text || "");
  if (!releases.length) return null;

  const details = document.createElement("details");
  details.className = "history";
  if (wrap._historyOpen) details.open = true;
  details.addEventListener("toggle", () => { wrap._historyOpen = details.open; });
  const summary = document.createElement("summary");
  summary.textContent = `Version history (${releases.length})`;
  details.append(summary);

  for (const release of releases) {
    const entry = el("div", "release");
    const head = el("div", "release-head");
    head.append(el("b", null, release.version));
    if (release.date) head.append(el("span", "commit-when", ` · ${release.date}`));
    entry.append(head);
    if (release.lines.length) {
      const list = el("ul", "commits");
      for (const line of release.lines) list.append(inlineCode(el("li"), line));
      entry.append(list);
    }
    details.append(entry);
  }
  return details;
}

// `backticks` are the only markdown worth honouring here - the notes are full
// of unit and file names, and left raw they read as punctuation. Built as text
// nodes and <code>, never innerHTML: this file is written by hand today, but
// it arrives over the network with every upgrade.
function inlineCode(node, text) {
  const parts = String(text).split("`");
  parts.forEach((part, i) => {
    if (!part) return;
    node.append(i % 2 ? el("code", null, part) : document.createTextNode(part));
  });
  return node;
}

// CHANGELOG.md is written by hand and read here, so this stays deliberately
// dull: "## <version> — <date>" starts a release, "- " is a bullet, and prose
// between them is kept as a line of its own. Anything it does not recognise it
// leaves out rather than guessing.
function parseChangelog(text) {
  const releases = [];
  let current = null;
  for (const raw of text.split("\n")) {
    const line = raw.trimEnd();
    const heading = /^##\s+(\S+)(?:\s+[—-]\s+(.+))?$/.exec(line);
    if (heading) {
      current = { version: heading[1], date: (heading[2] || "").trim(), lines: [] };
      releases.push(current);
      continue;
    }
    if (!current || !line.trim()) continue;
    if (line.startsWith("#")) continue;
    current.lines.push(line.replace(/^[-*]\s+/, "").trim());
  }
  // A bullet wrapped across lines arrives as two entries; rejoin anything that
  // is plainly a continuation rather than showing half a sentence per row.
  for (const release of releases) {
    const joined = [];
    for (const line of release.lines) {
      if (joined.length && /^[a-z(]/.test(line)) joined[joined.length - 1] += " " + line;
      else joined.push(line);
    }
    release.lines = joined;
  }
  return releases;
}

function upgradeResult(result) {
  const ok = result.state === "ok";
  const box = el("div", `result ${ok ? "ok" : "bad"}`);
  box.append(el("div", null, ok
    ? "Upgraded."
    // "Not upgraded" would be a guess for a stalled request: nothing read it,
    // so nothing decided anything, and the upgrade may yet happen.
    : result.state === "stalled"
      ? `Still waiting — ${result.error}`
      : `Not upgraded — ${result.error || "the host reported a failure"}`));
  if (Array.isArray(result.steps) && result.steps.length) {
    const ul = el("ul", "steps");
    for (const step of result.steps) ul.append(el("li", null, step));
    box.append(ul);
  }
  return box;
}

async function startUpgrade(check, wrap, upgrade, recheck, message, output) {
  const lines = [
    check.upgrade_available
      ? `Upgrade supabase-backup on this host? ${check.reason}`
      : "Reinstall the version this host is already running?",
    "The host downloads the code from GitHub as root and installs it. Configs, " +
    "credentials and archives are not touched, and neither is whether this host acts " +
    "on a restore request.",
    "The console restarts at the end, so this page goes quiet for a moment. If the new " +
    "console will not start, everything is put back as it was.",
  ];
  if (!confirm(lines.join("\n\n"))) return;

  upgrade.disabled = true;
  recheck.disabled = true;
  message.className = "bar-msg";
  message.textContent = "asking…";
  output.replaceChildren();

  let id;
  try {
    ({ id } = await api("/api/upgrade", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "apply" }),
    }));
  } catch (error) {
    message.className = "bar-msg err";
    message.textContent = error.message;
    upgrade.disabled = false;
    recheck.disabled = false;
    return;
  }
  upgradeBusy = true;
  message.textContent = "downloading and installing…";
  pollUpgrade(id, wrap, message, output);
}

function pollUpgrade(id, wrap, message, output) {
  clearTimeout(upgradePoll);
  // Longer than the settings poll: this downloads a couple of dozen files
  // before it restarts anything, and a slow host on a slow link is not a
  // failure. The console going away in the middle is the expected case.
  const deadline = Date.now() + 300_000;
  const enable = () => {
    upgradeBusy = false;
    const bar = wrap.querySelector(".bar");
    if (bar) for (const button of bar.querySelectorAll("button")) button.disabled = false;
  };

  const tick = async () => {
    let result;
    try {
      result = await api(`/api/upgrade/${enc(id)}`);
    } catch (error) {
      if (Date.now() < deadline) {
        message.textContent = "the console is restarting…";
        upgradePoll = setTimeout(tick, 2500);
        return;
      }
      enable();
      message.className = "bar-msg err";
      message.textContent = "the console has not come back on this address";
      output.replaceChildren(el("div", "result bad",
        "On the host: systemctl status supabase-backup-web, and " +
        "journalctl -u supabase-backup-upgrade -n 50 for what the helper did — it puts " +
        "the previous files back if the console will not start on the new ones."));
      return;
    }

    if (result.state === "pending" || result.state === "running") {
      message.textContent = result.state === "running"
        ? "downloading and installing…" : "waiting for the helper…";
      upgradePoll = setTimeout(tick, 2000);
      return;
    }
    // Nothing has read the request. Not a failure - nothing decided anything -
    // so it keeps polling in case the helper is only just starting, and says
    // what is actually true meanwhile.
    if (result.state === "stalled" && Date.now() < deadline) {
      message.textContent = "nothing has picked this up yet…";
      upgradePoll = setTimeout(tick, 3000);
      return;
    }
    // The gap between the helper taking the request and writing a result. Only
    // a missing helper if it is still saying this when the time is up.
    if (result.state === "unknown" && Date.now() < deadline) {
      upgradePoll = setTimeout(tick, 2000);
      return;
    }
    enable();
    message.textContent = "";
    if (result.state === "unknown") {
      output.replaceChildren(el("div", "result bad",
        "No result came back. The upgrade helper may not be installed — check " +
        "systemctl status supabase-backup-upgrade.path on the host."));
      return;
    }
    const box = upgradeResult(result);
    // Repaint from the result the helper handed back rather than asking again:
    // it checked after installing, and the console it is describing is the one
    // that just came back up.
    if (result.check) {
      paintVersion(wrap, { check: result.check, activity: {}, allowed: true });
      const fresh = wrap.querySelector(".upgrade-output");
      if (fresh) fresh.replaceChildren(box);
    } else {
      output.replaceChildren(box);
    }
    if (result.state === "ok") {
      const reload = el("button", "btn-ghost", "Reload the console");
      reload.addEventListener("click", () => location.reload());
      const actions = el("div", "body-actions");
      actions.append(reload);
      (wrap.querySelector(".upgrade-output") || output).append(
        el("div", "hint",
           "This page is still the old console's HTML and JavaScript. Reload to run what " +
           "was just installed."),
        actions);
    }
  };
  upgradePoll = setTimeout(tick, 1500);
}


// ── Restoring an archive ───────────────────────────────────────────────────

// The console cannot restore, so this asks for one: a form, a request, a poll.
// What comes back is not a summary written for the browser - it is the lines
// `restore` prints on the host, arriving as it prints them, which is the only
// account of a destructive operation worth showing anyone.

function refOf(url) {
  const match = /^https:\/\/([a-z0-9-]+)\./.exec((url || "").trim());
  return match ? match[1] : "";
}

function restoreCheckbox(id, text, checked) {
  const label = el("label", "check");
  const input = document.createElement("input");
  input.type = "checkbox";
  input.id = id;
  input.checked = checked;
  label.append(input, document.createTextNode(text));
  return label;
}

function buildRestoreForm(project, archive) {
  const form = el("div", "form");
  // Unique per archive: two archives can have their forms open at once, and
  // duplicate ids would quietly wire one form's label to the other's input.
  const uid = `res-${project}-${archive.stamp}`;

  form.append(el("div", "notice",
    "Restoring writes this archive into another Supabase project: auth users first, " +
    "then schema and data, then catalog objects, then every storage object. The host " +
    "refuses any project it backs up. Supabase's control plane is not part of it — " +
    "auth providers, email templates, the JWT secret and Vault values stay as they are " +
    "in the target."));

  form.append(field("Target session pooler URI", "database_url",
    "The project being restored INTO. Its dashboard → Connect → Direct → Session pooler. " +
    "Port 5432: transaction mode on 6543 drops the session between statements and stops a restore partway.",
    "password", "postgresql://postgres.<ref>:<password>@…pooler.supabase.com:5432/postgres", uid));

  form.append(field("Target project URL", "supabase_url",
    "Must name the same project as the URI above — a mismatched pair writes one project's database while uploading another's files.",
    "text", "https://<ref>.supabase.co", uid));

  form.append(field("Target service key", "service_key",
    "Uploads the storage objects. The request holding it is shredded as soon as the host has read it.",
    "password", "", uid));

  const confirmField = field("Type the target project ref", "confirm_ref",
    "The last thing restore asks for at a terminal, and the one thing here that cannot be clicked.",
    "text", "", uid);
  form.append(confirmField);

  // The ref is derivable from the URL above, so name it rather than leaving
  // someone to guess what to type. Typing it is still the point.
  const urlInput = form.querySelector(`#${uid}-supabase_url`);
  const hint = confirmField.querySelector(".hint");
  const hintText = hint.textContent;
  urlInput.addEventListener("input", () => {
    const ref = refOf(urlInput.value);
    hint.textContent = ref
      ? `Type ${ref} to say plainly that is the project being written into.`
      : hintText;
  });

  const boxes = el("div", "field");
  // Checked by default, and deliberately: the first click on a form like this
  // should rehearse, not restore.
  boxes.append(restoreCheckbox(`${uid}-dry_run`,
    "Dry run — extract, check and connect, then stop before any writes", true));
  // Each of the other two is a prompt restore would have stopped on. Unticked
  // is the answer it gives when nobody says otherwise.
  boxes.append(restoreCheckbox(`${uid}-allow_nonempty`,
    "Go ahead even if the target already has tables in public", false));
  boxes.append(restoreCheckbox(`${uid}-continue_on_catalog_errors`,
    "Continue if catalog objects (triggers, buckets, jobs) fail to apply", false));
  form.append(boxes);

  const bar = el("div", "bar");
  const submit = el("button", "btn", "Start restore");
  const message = el("span", "bar-msg");
  bar.append(submit, message);
  form.append(bar);

  submit.addEventListener("click", () =>
    submitRestore(project, archive, form, uid, submit, message));
  return form;
}

async function submitRestore(project, archive, form, uid, submit, message) {
  const value = (name) => (form.querySelector(`#${uid}-${name}`).value || "").trim();
  const ticked = (name) => form.querySelector(`#${uid}-${name}`).checked;
  const body = {
    database_url: value("database_url"),
    supabase_url: value("supabase_url"),
    service_key: value("service_key"),
    confirm_ref: value("confirm_ref"),
    dry_run: ticked("dry_run"),
    allow_nonempty: ticked("allow_nonempty"),
    continue_on_catalog_errors: ticked("continue_on_catalog_errors"),
  };

  if (restoreBusy) {
    message.className = "bar-msg err";
    message.textContent = "a restore is already running on this host";
    return;
  }

  const ref = refOf(body.supabase_url) || body.confirm_ref || "that project";
  const question = body.dry_run
    ? `Rehearse restoring ${archive.name} into ${ref}?\n\nEverything except the writes: the archive is extracted and its checksums verified, the target is connected to, and it stops before the first write.`
    : `Restore ${archive.name} into ${ref}?\n\nThis writes the archive's auth users, schema, data and storage objects into that project. It cannot be undone.`;
  if (!confirm(question)) return;

  submit.disabled = true;
  message.className = "bar-msg";
  message.textContent = "submitting…";
  let id;
  try {
    ({ id } = await api(
      `/api/projects/${enc(project)}/archives/${enc(archive.name)}/restore`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }));
  } catch (error) {
    message.className = "bar-msg err";
    message.textContent = error.message;
    submit.disabled = false;
    return;
  }

  // The credentials have left the browser; do not leave them in the DOM.
  for (const name of ["database_url", "service_key"]) {
    form.querySelector(`#${uid}-${name}`).value = "";
  }
  submit.disabled = false;
  message.textContent = "handed to the host — it is running at the top of this page";
  restoreBusy = true;
  restoreShown = null;
  pollRestore(id);
}

// Which restore is on screen is decided here; pollRestore owns what it says.
function renderRestore(status) {
  const section = $("restore-section");
  if (!section) return;
  const activity = status.restore;
  restoreBusy = Boolean(activity && activity.running);
  const latest = activity && activity.latest;
  restoreStalled = Boolean(latest && latest.stalled);

  // Allowed here but nothing watching the spool on the host: a request would
  // sit there unread. Say so before someone fills in a form and waits.
  restoreUnwatched = Boolean(activity && activity.helper_installed && !activity.helper_watching);
  // ...and if one has already run, the log below says it far better than a
  // warning about the future would, so this only takes over an empty panel.
  if (restoreUnwatched && !latest) {
    section.hidden = false;
    $("restore").replaceChildren(el("div", "notice",
      "Restores are enabled here, but the host is not watching for them: " +
      "supabase-backup-restore.path is installed and not enabled. Until it is, a request " +
      "would sit in the spool unread. Enable it with " +
      "systemctl enable --now supabase-backup-restore.path, or re-run " +
      "supabase-backup-web-setup.sh and answer yes to restores."));
    return;
  }
  if (!activity || (!latest && !activity.running)) {
    if (!restorePoll && !restoreShown) section.hidden = true;
    return;
  }
  if (!latest) {
    // Written, not yet picked up. Saying so beats an empty panel while the
    // .path unit wakes the helper.
    section.hidden = false;
    $("restore").replaceChildren(el("div", "notice",
      "A restore request is waiting for the host to pick it up."));
    return;
  }
  if (latest.id !== restoreShown) pollRestore(latest.id);
}

async function pollRestore(id) {
  clearTimeout(restorePoll);
  restorePoll = null;
  restoreShown = id;
  $("restore-section").hidden = false;

  let result;
  try {
    result = await api(`/api/restore/${enc(id)}`);
  } catch (error) {
    $("restore").replaceChildren(el("div", "result bad", error.message));
    return;
  }
  renderRestoreResult($("restore"), result);
  if (result.state === "running" || result.state === "pending") {
    restorePoll = setTimeout(() => pollRestore(id), 2000);
  }
}

const RESTORE_PILL = { ok: "ok", running: "running", pending: "running", failed: "failed" };

function renderRestoreResult(host, result) {
  const wrap = el("div");

  const head = el("div", "restore-head");
  const state = result.state || "unknown";
  head.append(el("span", `pill pill-${RESTORE_PILL[state] || "unknown"}`,
    state === "ok" ? (result.dry_run ? "rehearsed" : "restored") : state));
  head.append(el("span", "restore-what", result.archive
    ? `${result.archive} → ${result.target_ref || "?"}`
    : "waiting to be picked up"));
  if (result.dry_run) head.append(el("span", "chip", "dry run"));
  if (result.started_at) head.append(el("span", "restore-when", localTime(result.started_at)));
  wrap.append(head);

  if (state === "pending" && restoreUnwatched) {
    wrap.append(el("div", "notice",
      "This request is waiting, and nothing on the host is watching for it: " +
      "supabase-backup-restore.path is not enabled. Enable it with " +
      "systemctl enable --now supabase-backup-restore.path and it will be picked up."));
  }
  if (state === "unknown") {
    wrap.append(el("div", "notice",
      "No result came back for that request. The privileged helper may not be installed — " +
      "check systemctl status supabase-backup-restore.path on the host."));
  }
  if (state === "running" && restoreStalled) {
    wrap.append(el("div", "result bad",
      "This says it is running, but nothing is running it. The helper was killed or the " +
      "host rebooted mid-restore — journalctl -u supabase-backup-restore for how far it got. " +
      "The target is in whatever state the log below leaves it."));
  }
  if (result.error) wrap.append(el("div", "result bad", result.error));
  if (state === "ok") {
    wrap.append(el("div", "result ok", result.dry_run
      ? "Dry run complete — the archive verifies and the target is reachable. Nothing was written."
      : `Restored into ${result.target_ref}. Every row count and the storage object count match the archive.`));
  }

  const steps = Array.isArray(result.steps) ? result.steps : [];
  if (steps.length) {
    const log = el("div", "log");
    for (const step of steps) {
      log.append(el("div", `k-${(step && step.k) || "info"}`, (step && step.m) || ""));
    }
    wrap.append(log);
    host.replaceChildren(wrap);
    // Follow a running restore rather than making someone scroll after it.
    if (state === "running" || state === "pending") log.scrollTop = log.scrollHeight;
    return;
  }
  host.replaceChildren(wrap);
}

// The footer says what this console will and will not do about restoring, and
// it changes with the answer - including the reason, when the answer is no.
function renderFooter(status) {
  const footer = $("footer");
  if (!footer) return;
  const caps = status.capabilities || {};
  footer.replaceChildren();
  if (caps.restore) {
    footer.append(document.createTextNode("A restore asked for here is carried out on the host by "));
    footer.append(el("code", null, "restore"));
    footer.append(document.createTextNode(
      ", as root: the same script, the same order, the same guards. It refuses any project " +
      "this host backs up, and nothing is written until the target ref has been typed out in full."));
  } else {
    footer.append(document.createTextNode(caps.restore_blocked_because ||
      "Restoring is not done from here."));
    if (!caps.restore_blocked_because) {
      footer.append(document.createTextNode(" Run "));
      footer.append(el("code", null, "restore"));
      footer.append(document.createTextNode(" on the host."));
    }
  }
}

// ── Polling ────────────────────────────────────────────────────────────────

async function refresh() {
  try {
    const status = await api("/api/status");
    capabilities = status.capabilities;
    // Before anyRunning is worked out: this is what sets restoreBusy, and a
    // restore in flight is exactly when the page should not be polling lazily.
    renderRestore(status);
    anyRunning = status.projects.some((p) => p.health === "running") || restoreBusy;
    renderSummary(status);
    renderProjects(status);
    renderRegister(status);
    renderFooter(status);
    // Only open panels cost requests; a host with many projects stays quiet
    // until someone actually looks at one.
    for (const project of status.projects) {
      if (!openProjects.has(project.name)) continue;
      const body = document.querySelector(`.project[data-name="${CSS.escape(project.name)}"] .project-body`);
      if (body) await loadProject(project.name, body, project);
    }
  } catch (error) {
    // A password change signs this browser out mid-poll. Saying "unreachable"
    // and carrying on retrying would be wrong twice over: the console is fine,
    // and no number of retries with the old password will get anywhere.
    signedOut = error.status === 401;
    $("health").textContent = signedOut ? "signed out" : "unreachable";
    $("health").className = "pill pill-unknown";
    $("reason").textContent = signedOut
      ? "The console no longer accepts the credentials this browser saved — its username or password changed. Reload the page to sign in again."
      : error.message;
  } finally {
    clearTimeout(pollTimer);
    if (!signedOut) pollTimer = setTimeout(refresh, anyRunning ? POLL_BUSY : POLL_IDLE);
  }
}

document.addEventListener("visibilitychange", () => {
  clearTimeout(pollTimer);
  if (!document.hidden && !signedOut) refresh();
});

refresh();

$("gear").addEventListener("click", openSettings);
$("settings-close").addEventListener("click", closeSettings);
// A click that lands on the dialog element itself landed on the backdrop: the
// box has no padding of its own, so everything inside it is a child.
$("settings-dialog").addEventListener("click", (event) => {
  if (event.target === $("settings-dialog")) closeSettings();
});
