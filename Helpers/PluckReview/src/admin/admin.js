// The host's admin page. Plain JS, no framework; every piece of text goes in with textContent.
"use strict";
const $ = (id) => document.getElementById(id);
let csrf = null, setup = false, here = "", picked = new Set(), state = null;

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text != null) e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}
function button(text, onclick) { const b = el("button", text); b.addEventListener("click", onclick); return b; }

async function post(path, body) {
  const headers = { "Content-Type": "application/json" };
  if (csrf) headers["X-CSRF"] = csrf;
  const r = await fetch(path, { method: "POST", headers, body: JSON.stringify(body || {}), credentials: "same-origin" });
  if (r.status === 403 && path === "/api/op") { csrf = null; show(false); throw new Error("Sign in again."); }
  return r.json();
}
const op = (o) => post("/api/op", o);

function show(app) {
  $("app").classList.toggle("hidden", !app);
  $("login").classList.toggle("hidden", app);
  $("login-title").textContent = setup ? "Set a password" : "Sign in";
  $("key-row").classList.toggle("hidden", !setup);
}

async function start() {
  const s = await post("/api/session");
  setup = s.setup; csrf = s.csrf;
  $("fp").textContent = "Certificate " + (s.fingerprint || "").slice(0, 23) + "…";
  show(s.loggedIn);
  if (s.loggedIn) { browse(""); refresh(); }
}

$("login-go").addEventListener("click", async () => {
  const body = { password: $("password").value };
  if (setup) body.hostKey = $("host-key").value.trim();
  const r = await post(setup ? "/api/setup" : "/api/login", body);
  $("login-msg").textContent = r.error || "";
  if (r.ok) { csrf = r.csrf; setup = false; $("password").value = ""; show(true); browse(""); refresh(); }
});
$("logout").addEventListener("click", async () => { await post("/api/logout"); csrf = null; show(false); });

function size(n) {
  if (n == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0;
  while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
  return n.toFixed(i ? 1 : 0) + " " + u[i];
}

async function browse(path) {
  const r = await op({ op: "browse", path });
  if (r.error) { $("files").replaceChildren(el("div", r.error, "bad")); return; }
  here = path;
  const crumbs = [el("span", "Roots", "crumb")];
  crumbs[0].addEventListener("click", () => browse(""));
  let acc = "";
  for (const part of path ? path.split("/") : []) {
    acc = acc ? acc + "/" + part : part;
    const at = acc, c = el("span", part, "crumb");
    c.addEventListener("click", () => browse(at));
    crumbs.push(el("span", "›", "faint"), c);
  }
  $("crumbs").replaceChildren(...crumbs);
  $("files").replaceChildren(...r.entries.map((e) => {
    const row = el("div", null, "item" + (e.dir ? " dir" : ""));
    if (e.dir) {
      const n = el("span", "▸ " + e.name, "name");
      n.addEventListener("click", () => browse(e.path));
      row.append(n);
    } else {
      const box = el("input"); box.type = "checkbox"; box.checked = picked.has(e.path);
      box.addEventListener("change", () => { box.checked ? picked.add(e.path) : picked.delete(e.path); count(); });
      row.append(box, el("span", e.name, "name"), el("span", e.kind, "faint"), el("span", size(e.size), "quiet"));
    }
    return row;
  }));
}

function count() { $("count").textContent = picked.size; }
$("make-link").addEventListener("change", () => $("link-opts").classList.toggle("hidden", !$("make-link").checked));

$("publish").addEventListener("click", async () => {
  const body = { op: "admin-publish", files: [...picked] };
  const name = $("new-project").value.trim();
  if (name) body.newProject = name; else body.project = $("project").value;
  if ($("make-link").checked) body.link = { title: $("link-title").value, password: $("link-password").value,
    expiresDays: Number($("link-expires").value), mode: $("link-mode").value, allowDownload: $("link-download").checked,
    allowProxy: $("link-proxy").checked, requireName: $("link-name").checked, watermark: $("link-watermark").value };
  const r = await op(body);
  if (r.error) { $("publish-msg").textContent = r.error; return; }
  $("publish-msg").textContent = r.added + " added" + (r.skipped.length ? ", " + r.skipped.length + " skipped" : "") + ". Making review copies…";
  picked.clear(); count(); $("new-project").value = ""; $("link-password").value = ""; $("link-watermark").value = "";
  if (r.url) newLink(r.link, r.url);
  browse(here); refresh();
});

// §13.24: a new link is shown only once one of the owner's servers holds its room, so nobody who got the address
// early can register it first. Until then it stays in this page's memory (the host keeps no copy of it).
let pending = null, pendingTimer = 0;
function newLink(id, url) {
  pending = { id, url };
  $("url").value = ""; $("url-row").classList.add("hidden");
  $("url-note").replaceChildren(el("span", "Getting the link ready…"));
  clearInterval(pendingTimer);
  pendingTimer = setInterval(checkPending, 2000);
}
function checkPending() {
  const l = pending && (state?.links || []).find((x) => x.id === pending.id);
  if (!l) return void refresh();
  if (l.taken) { clearInterval(pendingTimer); $("url-note").replaceChildren(takenProblem(l)); pending = null; return; }
  if (!l.ready) return void refresh();
  clearInterval(pendingTimer);
  $("url").value = pending.url; $("url-row").classList.remove("hidden");
  $("url-note").textContent = "Copy the link now: this host keeps no copy of it.";
  pending = null;
}
function takenProblem(l) {
  const box = el("span", "Someone else is holding this link's room. Make a new link. ", "problem");
  box.append(button("Make a New Link", async () => {
    const r = await op({ op: "admin-renew", link: l.id });
    if (r.error) { box.textContent = r.error; return; }
    newLink(r.link, r.url); refresh();
  }));
  return box;
}
$("copy").addEventListener("click", () => navigator.clipboard.writeText($("url").value));
$("comments-close").addEventListener("click", () => $("comments-box").classList.add("hidden"));
$("activity-close").addEventListener("click", () => $("activity-box").classList.add("hidden"));

const DID = { opened: "opened the link", viewed: "looked at", played: "watched", commented: "commented on",
  downloaded: "downloaded", uploaded: "uploaded", approved: "set the status of" };
function assetName(id) {
  for (const p of (state && state.projects) || []) for (const a of p.assets || []) if (a.id === id) return a.name;
  return "";
}
async function showActivity(l) {
  const r = await op({ op: "admin-activity", link: l.id });
  $("activity-title").textContent = "Activity · " + l.title;
  const rows = (r.activity || []).map((a) => {
    const who = (a.name || "Guest") + (a.email ? " <" + a.email + ">" : "");
    let what = DID[a.kind] || a.kind;
    if (a.asset) what += " " + assetName(a.asset);
    if (a.kind === "played" && a.detail) what += " (frames " + a.detail.from + "–" + a.detail.to + ")";
    if (a.kind === "downloaded" && a.detail) what += " (" + a.detail.what + ")";
    if (a.kind === "uploaded" && a.detail) what += " " + a.detail.name;
    const row = el("div", null, "item");
    row.append(el("span", (a.at || "").replace("T", " ").slice(0, 16), "faint"), el("span", who + " " + what, "name"));
    return row;
  });
  $("activity").replaceChildren(...(rows.length ? rows : [el("div", "Nothing yet.", "quiet")]));
  $("activity-box").classList.remove("hidden");
}

function copyState(v) {
  const c = v.copy || {};
  if (c.state === "ready") return el("span", "Ready", "good");
  if (c.state === "failed") return el("span", "Failed: " + (c.error || ""), "bad");
  if (c.state === "making") return el("span", "Making review copy " + Math.round((c.progress || 0) * 100) + "%", "warn");
  return el("span", "Waiting", "quiet");
}

async function showComments(a) {
  const r = await op({ op: "admin-comments", asset: a.id });
  $("comments-title").textContent = "Comments · " + a.name;
  $("comments").replaceChildren(...(r.comments || []).map((c) => {
    const box = el("div", null, "item"); box.style.display = "block";
    box.append(el("div", c.author + " · " + (c.frame == null ? (c.page ? "page " + c.page : "general") : "frame " + c.frame) + (c.internal ? " · internal" : "") + (c.completed ? " · done" : ""), "quiet"), el("div", c.text));
    for (const rep of c.replies || []) box.append(el("div", "↳ " + rep.author + ": " + rep.text, "quiet"));
    return box;
  }));
  if (!(r.comments || []).length) $("comments").replaceChildren(el("div", "No comments yet.", "quiet"));
  $("comments-box").classList.remove("hidden");
}

async function refresh() {
  if (!csrf) return;
  try { state = await op({ op: "admin-state" }); } catch { return; }
  const sel = $("project"), keep = sel.value;
  sel.replaceChildren(...(state.projects || []).map((p) => { const o = el("option", p.name); o.value = p.id; return o; }));
  if (keep) sel.value = keep;
  $("projects").replaceChildren(...(state.projects || []).map((p) => {
    const box = el("div"); box.append(el("h2", p.name));
    for (const a of p.assets || []) {
      const v = (a.versions || []).at(-1) || {};
      const row = el("div", null, "item");
      row.append(el("span", a.name, "name"), copyState(v), el("span", a.status, "quiet"), el("span", a.comments + " comments", "quiet"),
        button("Comments", () => showComments(a)),
        button("Remove", async () => { if (confirm("Remove " + a.name + " from the project? The original stays.")) { await op({ op: "admin-unpublish", asset: a.id }); refresh(); } }));
      box.append(row);
    }
    for (const l of (state.links || []).filter((l) => l.project === p.id)) {
      const row = el("div", null, "item");
      const off = l.revoked != null;
      row.append(el("span", "Link · " + l.title, "name"), el("span", off ? "Turned off" : (l.expires ? "Until " + l.expires.slice(0, 10) : "No expiry"), off ? "faint" : "quiet"),
        el("span", l.viewers + " watching", "quiet"), button("Activity (" + l.activity + ")", () => showActivity(l)));
      if (!off && l.taken) row.append(takenProblem(l));
      if (!off) row.append(button("Turn off", async () => { await op({ op: "admin-unpublish", link: l.id }); refresh(); }));
      box.append(row);
    }
    return box;
  }));
}

// Pairing (§13.2): the invitation link is shown once, with its 15-minute countdown.
let pairTimer = null;
async function pair(role) {
  const r = await op({ op: "invite", role });
  if (r.error) { $("pair-note").textContent = r.error === "limit" ? "Pairing locked for 15 min" : r.error; return; }
  $("pair-link").value = r.link;
  $("pair-row").classList.remove("hidden");
  $("pair-note").textContent = "Anyone with this link in the next 15 minutes can browse your NAS media. Code " + r.code;
  const until = Date.parse(r.expires);
  clearInterval(pairTimer);
  pairTimer = setInterval(() => {
    const s = Math.max(0, Math.round((until - Date.now()) / 1000));
    $("pair-left").textContent = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    if (s === 0) { clearInterval(pairTimer); $("pair-row").classList.add("hidden"); $("pair-link").value = ""; $("pair-note").textContent = ""; }
  }, 1000);
}
$("pair-mac").addEventListener("click", () => pair("mac"));
$("pair-backup").addEventListener("click", () => pair("backup"));
$("pair-copy").addEventListener("click", () => navigator.clipboard.writeText($("pair-link").value));
async function devices() {
  if (!csrf) return;
  const r = await op({ op: "devices" }).catch(() => null);
  if (!r || !r.devices) return;
  if (r.pairingLocked) $("pair-note").textContent = "Pairing locked for 15 min";
  $("devices").replaceChildren(...r.devices.map((d) => {
    const row = el("div", null, "item");
    row.append(el("span", d.name, "name"), el("span", d.role === "backup" ? "Backup host" : "Mac", "quiet"),
      el("span", "Last seen " + (d.lastSeen || "").slice(0, 16).replace("T", " "), "faint"));
    return row;
  }));
}

setInterval(refresh, 3000);
setInterval(devices, 10000);
start();
