import { judgeBody, rankBody, draftBody, parseThree, rankReplies, summarize } from "./lib/core.js";
import { postJson } from "./lib/api.js";

const brainP = fetch(chrome.runtime.getURL("brain.json")).then((r) => r.json());
try { chrome.sidePanel?.setPanelBehavior({ openPanelOnActionClick: true }); } catch { /* Firefox */ }
if (chrome.sidebarAction && chrome.action?.onClicked) {
  chrome.action.onClicked.addListener(() => { chrome.sidebarAction.open().catch(() => {}); });
}

async function settings() {
  const brain = await brainP;
  const s = await chrome.storage.local.get(
    ["judgeKey", "replyKey", "relationship", "judgeUrl", "judgeModel", "replyUrl", "replyModel", "auto"]);
  return {
    brain,
    judgeKey: s.judgeKey ?? "",
    replyKey: s.replyKey || s.judgeKey || "",
    relationship: s.relationship || brain.default_relationship,
    judgeUrl: s.judgeUrl || brain.judge_url_default,
    judgeModel: s.judgeModel || brain.judge_model_default,
    replyUrl: s.replyUrl || brain.reply_url_default,
    replyModel: s.replyModel || brain.reply_model_default,
    auto: s.auto ?? true,
  };
}

const show = (view) => chrome.storage.session.set({ view });

const UNREADABLE = "Jev can't read the messages on this page. Open one conversation (not the inbox), scroll it a little, then click Analyze.";

async function analyze(snap) {
  if (!snap.messages?.length) return show({ title: snap.title, error: UNREADABLE });
  const cfg = await settings();
  if (!cfg.judgeKey) return show({ title: snap.title, error: "Paste your OpenRouter key above, then analyze." });
  await show({ title: snap.title, status: "Analyzing…" });
  const { brain, relationship: rel } = cfg;
  try {
    const [judged, candidates] = await Promise.all([
      postJson(cfg.judgeUrl, cfg.judgeKey, judgeBody(brain, cfg.judgeModel, snap.messages, rel)),
      postJson(cfg.replyUrl, cfg.replyKey, draftBody(brain, cfg.replyModel, snap.messages, rel))
        .then((r) => parseThree(r.choices?.[0]?.message?.content ?? "", brain.fallback_reply)),
    ]);
    const ranked = await postJson(cfg.judgeUrl, cfg.judgeKey,
      rankBody(brain, cfg.judgeModel, snap.messages, rel, candidates));
    await show({
      title: snap.title,
      summary: summarize(judged.answers ?? {}),
      replies: rankReplies(ranked.answers?.best_reply, candidates),
    });
  } catch (e) {
    await show({ title: snap.title, error: String(e?.message ?? e) });
  }
}

async function onSnapshot(snapshot, tabId) {
  const { sig } = await chrome.storage.session.get("sig");
  if (snapshot.sig === sig) return;
  const snap = { ...snapshot, tabId };
  await chrome.storage.session.set({ sig: snapshot.sig, snap });
  if (snap.messages.length === 0) return show({ title: snap.title, error: UNREADABLE });
  const { auto } = await settings();
  if (snap.latestFrom === "other" && auto) return analyze(snap);
  return show({ title: snap.title, status: "Press Analyze when you want suggestions." });
}

/** Re-read the chat tab right before analyzing, so a stale or empty snapshot is never sent. */
async function analyzeNow() {
  const { snap } = await chrome.storage.session.get("snap");
  if (!snap) return;
  let fresh = null;
  try {
    fresh = (await chrome.tabs.sendMessage(snap.tabId, { type: "capture" }))?.snapshot ?? null;
  } catch {
    return show({ title: snap.title, error: "Reload the chat tab so Jev can read it, then click Analyze." });
  }
  if (!fresh) return show({ title: snap.title, error: UNREADABLE });
  const next = { ...fresh, tabId: snap.tabId };
  await chrome.storage.session.set({ sig: fresh.sig, snap: next });
  return analyze(next);
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg.type === "snapshot" && sender.tab) onSnapshot(msg.snapshot, sender.tab.id);
  if (msg.type === "analyzeNow") analyzeNow();
});
