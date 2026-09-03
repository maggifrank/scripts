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
  if (!response.ok) throw new Error((payload && payload.error) || `HTTP ${response.status}`);
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

  cards.append(status.disk
    ? card("Free space", bytes(status.disk.free), `of ${bytes(status.disk.total)}`)
    : card("Free space", "unknown", status.data_dir, true));
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

  const actions = el("div", "body-actions");
  const verify = el("button", "btn-ghost", "Verify checksums");
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
      verify.textContent = "Verify checksums";
    }
  });
  actions.append(verify);

  if (capabilities.download) {
    const download = el("a", "btn-ghost", "Download");
    download.href = `/api/projects/${enc(project)}/archives/${enc(archive.name)}/download`;
    actions.append(download);
  }
  body.append(actions, output);
}

function renderVerify(container, result) {
  if (result.fatal) {
    container.replaceChildren(el("div", "result bad", result.fatal));
    return;
  }
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

function field(label, name, hint, type = "text", placeholder = "") {
  const wrap = el("div", "field");
  const id = `reg-${name}`;
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

// ── Polling ────────────────────────────────────────────────────────────────

async function refresh() {
  try {
    const status = await api("/api/status");
    capabilities = status.capabilities;
    anyRunning = status.projects.some((p) => p.health === "running");
    renderSummary(status);
    renderProjects(status);
    renderRegister(status);
    // Only open panels cost requests; a host with many projects stays quiet
    // until someone actually looks at one.
    for (const project of status.projects) {
      if (!openProjects.has(project.name)) continue;
      const body = document.querySelector(`.project[data-name="${CSS.escape(project.name)}"] .project-body`);
      if (body) await loadProject(project.name, body, project);
    }
  } catch (error) {
    $("health").textContent = "unreachable";
    $("health").className = "pill pill-unknown";
    $("reason").textContent = error.message;
  } finally {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(refresh, anyRunning ? POLL_BUSY : POLL_IDLE);
  }
}

document.addEventListener("visibilitychange", () => {
  clearTimeout(pollTimer);
  if (!document.hidden) refresh();
});

refresh();
