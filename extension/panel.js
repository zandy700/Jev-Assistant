// Renders chrome.storage.session "view". Page-derived text only ever goes in via textContent.
const brain = await fetch("brain.json").then((r) => r.json());
const $ = (id) => document.getElementById(id);
const label = (group, key) => brain.labels?.[group]?.[key] ?? key;
const el = (tag, text, cls) => {
  const e = document.createElement(tag);
  if (text != null) e.textContent = text;
  if (cls) e.className = cls;
  return e;
};
const note = (t) => { $("note").textContent = t; };

// Settings that live in the panel: key, relationship, auto-analyze.
async function loadSettings() {
  const s = await chrome.storage.local.get(["judgeKey", "relationship", "auto"]);
  const key = s.judgeKey ?? "";
  $("keycard").hidden = Boolean(key);
  $("keymask").textContent = key ? "••••" + key.slice(-4) : "Not set";
  $("relationship").value = s.relationship ?? "";
  $("relationship").placeholder = "A classmate I'm trying to ask out";
  $("auto").checked = s.auto ?? true;
  return key;
}

$("keycard").addEventListener("submit", async (e) => {
  e.preventDefault();
  const key = $("key").value.trim();
  if (!key) { $("key").focus(); return; }
  await chrome.storage.local.set({ judgeKey: key });
  $("key").value = "";
  await loadSettings();
  const { snap } = await chrome.storage.session.get("snap");
  if (snap) chrome.runtime.sendMessage({ type: "analyzeNow" });
});
$("changekey").onclick = async () => {
  await chrome.storage.local.remove("judgeKey");
  await loadSettings();
  $("key").focus();
};

let relTimer = 0;
$("relationship").addEventListener("input", () => {
  clearTimeout(relTimer);
  $("relsaved").textContent = "";
  relTimer = setTimeout(async () => {
    await chrome.storage.local.set({ relationship: $("relationship").value.trim() });
    $("relsaved").textContent = "Saved";
    const { view } = await chrome.storage.session.get("view");
    if (view?.replies) $("analyze").textContent = "Analyze again with this";
  }, 500);
});

$("auto").onchange = () => chrome.storage.local.set({ auto: $("auto").checked });
$("gear").onclick = () => {
  const open = $("drawer").hidden;
  $("drawer").hidden = !open;
  $("gear").setAttribute("aria-expanded", String(open));
};
$("advanced").onclick = (e) => { e.preventDefault(); chrome.runtime.openOptionsPage(); };

function riskColor(score) {
  if (score >= 6) return "var(--coral)";
  if (score >= 3) return "var(--amber)";
  return "var(--mint)";
}

function threadCard(messages) {
  const card = el("div", null, "card");
  const thread = el("div", null, "thread");
  for (const m of messages.slice(-6)) thread.append(el("div", m.text, "bubble " + (m.side === "me" ? "me" : "other")));
  const legend = el("div", null, "legend");
  legend.append(el("span", "Them"), el("span", "You"));
  card.append(el("span", "What Jev read", "label"), thread, legend);
  return card;
}

function readCard(s) {
  const card = el("div", null, "card");
  const top = el("div", null, "top");
  top.append(el("span", "Their mood", "label"));
  if (s.risk != null) {
    const r = el("span", `Risk ${Math.round(s.risk)} / 9`, "risk");
    r.style.color = riskColor(s.risk);
    top.append(r);
  }
  card.append(top);
  const moods = s.moods?.length ? s.moods : (s.mood ? [{ key: s.mood, pct: s.moodPct }] : []);
  for (const m of moods) {
    const row = el("div", null, "mood");
    const bar = el("div", null, "bar");
    const fill = el("i");
    fill.style.width = `${m.pct ?? 0}%`;
    bar.append(fill);
    row.append(el("span", label("mood", m.key)), bar, el("span", m.pct == null ? "" : `${m.pct}%`, "pct"));
    card.append(row);
  }
  if (s.intent) card.append(el("div", `They want: ${label("intent", s.intent)}`, "intent"));
  const chips = el("div", null, "chips");
  if (s.needs && s.needs !== "nothing") chips.append(el("span", `Needs ${label("needs", s.needs)}`, "chip"));
  if (s.bestAction) chips.append(el("span", `Best move: ${label("action", s.bestAction)}`, "chip"));
  if (s.specificsOk != null) chips.append(el("span", s.specificsOk >= 0.5 ? "OK to get specific" : "Hold off on specifics", "chip"));
  if (s.tensionResolved >= 0.7) chips.append(el("span", "Tension resolved", "chip"));
  if (chips.childElementCount) card.append(chips);
  return card;
}

function replyCard(r, i) {
  const card = el("div", null, "reply" + (i === 0 ? " best" : ""));
  card.append(el("span", i === 0 ? `Best pick · ${Math.round(r.prob * 100)}%` : `${Math.round(r.prob * 100)}%`, "rank"));
  card.append(el("p", r.text));
  const row = el("div", null, "row");
  const fill = el("button", "Fill", "btn go");
  fill.type = "button";
  fill.onclick = () => fillReply(r.text);
  const copy = el("button", "Copy", "btn quiet");
  copy.type = "button";
  copy.onclick = () => navigator.clipboard.writeText(r.text).then(() => {
    copy.textContent = "Copied";
    setTimeout(() => { copy.textContent = "Copy"; }, 1500);
  });
  row.append(fill, copy);
  card.append(row);
  return card;
}

function statusCard(text, cls = "") {
  const card = el("div", null, "card");
  card.append(el("div", text, "status " + cls));
  return card;
}

async function render(view) {
  const { snap } = await chrome.storage.session.get("snap");
  const title = view?.title ?? snap?.title;
  $("title").replaceChildren();
  if (title) { $("title").append("Reading "); $("title").append(el("b", title)); }
  else $("title").textContent = snap ? "Chat open" : "No chat open";
  $("analyze").textContent = "Analyze this chat";
  $("analyze").disabled = false;

  const body = $("body");
  if (!view && !snap) {
    const empty = el("div", null, "card empty");
    empty.append(el("strong", "Open a chat"), el("div", "Instagram, WhatsApp Web, Snapchat Web, or Google Messages. Jev reads it here.", "status"));
    body.replaceChildren(empty);
    return;
  }
  const out = el("div", null, "reveal");
  if (snap?.messages?.length) out.append(threadCard(snap.messages));
  if (view?.error) {
    out.append(statusCard(view.error, "err"));
  } else if (view?.status) {
    const busy = view.status.startsWith("Analyzing");
    out.append(statusCard(busy ? "Reading the mood and writing replies" : view.status, busy ? "busy" : ""));
    if (busy) $("analyze").disabled = true;
  } else if (view?.summary) {
    out.append(readCard(view.summary));
    (view.replies ?? []).forEach((r, i) => out.append(replyCard(r, i)));
    $("analyze").textContent = "Analyze again";
  }
  body.replaceChildren(out);
}

async function fillReply(text) {
  const { snap } = await chrome.storage.session.get("snap");
  let ok = false;
  try { ok = (await chrome.tabs.sendMessage(snap.tabId, { type: "fill", text }))?.ok; } catch { ok = false; }
  if (ok) return note("Filled in. Check it, then send it yourself.");
  await navigator.clipboard.writeText(text);
  note("Copied. Click the message box and paste.");
}

$("analyze").onclick = async () => {
  const { snap } = await chrome.storage.session.get("snap");
  if (!snap) return note("Open a chat on Instagram, WhatsApp Web, Snapchat Web, or Google Messages first.");
  note("");
  chrome.runtime.sendMessage({ type: "analyzeNow" });
};
chrome.storage.session.onChanged.addListener(async (c) => {
  if (c.view || c.snap) render((await chrome.storage.session.get("view")).view);
});
chrome.storage.local.onChanged.addListener((c) => { if (c.judgeKey) loadSettings(); });

await loadSettings();
render((await chrome.storage.session.get("view")).view);
