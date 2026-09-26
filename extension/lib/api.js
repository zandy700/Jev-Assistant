// POST JSON. Retries 429/529 twice with backoff. Keys are never logged.
export async function postJson(url, key, body) {
  const headers = { Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
  if (url.includes("openrouter.ai")) {
    headers["HTTP-Referer"] = "https://jev-assistant.local";
    headers["X-Title"] = "Jev Assistant";
  }
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url, { method: "POST", headers, body: JSON.stringify(body) });
    if ((res.status === 429 || res.status === 529) && attempt < 2) {
      await new Promise((r) => setTimeout(r, 1000 << attempt));
      continue;
    }
    const text = await res.text();
    if (res.status === 401) throw new Error("OpenRouter rejected this key. Open settings, click Change, and paste a new one.");
    if (res.status === 402) throw new Error("This OpenRouter key needs more credit. Add some at openrouter.ai/settings/credits, then analyze again.");
    if (!res.ok) throw new Error(`OpenRouter returned ${res.status}: ${text.slice(0, 120)}`);
    return JSON.parse(text);
  }
}
