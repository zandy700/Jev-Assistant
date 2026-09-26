// Reads the open thread by position when a site's own markup is not recognized:
// the column that holds the message box, text above that box, right side = me.

const CHROME = [
  /^(seen|seen by .*|delivered|sent|read|edited|typing…|typing\.\.\.|enter)$/i,
  /^active (now|\d+\s*\w+ ago)$/i,
  /^you (sent|unsent|reacted).*$/i,
  /^(today|yesterday)\b.*$/i,
  /^(mon|tue|wed|thu|fri|sat|sun)\w*\b.{0,24}$/i,
  /^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w* \d{1,2}\b.{0,24}$/i,
  /^\d{1,2}:\d{2}\s*(am|pm)?$/i,
  /^message(…|\.\.\.)?$/i,
];
const REPLY_LABEL = /(replied to |replying to |original message)/i;
const HEADER = 80;

/** The first ancestor of the message box tall enough to be the whole chat column. */
export function paneOf(box, rectOf, viewHeight) {
  let el = box;
  while (el.parentElement) {
    el = el.parentElement;
    if (rectOf(el).height >= viewHeight * 0.6) return el;
  }
  return el;
}

/**
 * @param composer the site's message box element
 * @param rectOf   element → box (layout of containers)
 * @param textRect element → box of the text itself (bubbles can sit in wide rows)
 */
export function readByLayout(composer, rectOf, textRect, viewHeight) {
  if (!composer) return null;
  const pane = paneOf(composer, rectOf, viewHeight);
  const p = rectOf(pane);
  const c = rectOf(composer);
  // Every element that holds text directly; nested ones fold into the outermost.
  const holders = new Set();
  for (const el of pane.querySelectorAll("*")) {
    if (el.closest("script, style, svg, button, a[href], h1, h2, h3, h4, h5, h6, [role=\"heading\"], header")) continue;
    if (composer.contains(el)) continue;
    if ([...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) holders.add(el);
  }
  const items = [];
  for (const el of holders) {
    let up = el.parentElement;
    while (up && up !== pane && !holders.has(up)) up = up.parentElement;
    if (up && up !== pane) continue;
    const text = el.textContent.trim();
    const r = textRect(el);
    // The top strip of the column is the chat header (name, @handle, call buttons).
    if (!r.width || !r.height || r.bottom > c.top || r.top < p.top + HEADER) continue;
    items.push({ text, r });
  }
  items.sort((a, b) => a.r.top - b.r.top);

  const messages = [];
  let label = null;
  for (const it of items) {
    if (REPLY_LABEL.test(it.text)) { label = it; continue; }
    if (label) {
      const quote = it.r.top - label.r.bottom < it.r.height * 2.5;
      label = null;
      if (quote) continue;
    }
    if (CHROME.some((re) => re.test(it.text))) continue;
    const gapLeft = it.r.left - p.left;
    const gapRight = p.right - it.r.right;
    if (Math.abs(gapLeft - gapRight) < p.width * 0.08) continue;
    messages.push({ side: gapRight < gapLeft ? "me" : "other", text: it.text });
  }
  return { title: null, messages };
}
