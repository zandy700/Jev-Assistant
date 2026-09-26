import Foundation

/// One OCR text box. Coordinates: origin top-left, y grows down (same as AX).
public struct ScreenTextBox: Equatable {
    public let text: String
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public init(text: String, x: Double, y: Double, w: Double, h: Double) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
    }
    public var left: Double { x }
    public var right: Double { x + w }
    public var midY: Double { y + h / 2 }
}

/// Pure grouping: OCR boxes → Snapshot. No capture / Vision — safe for JevChecks.
/// `width` is the captured window width; the chat column runs to its right edge.
public func snapshotFromScreenText(_ boxes: [ScreenTextBox], title: String? = nil, width: Double? = nil) -> Snapshot {
    let trimmed = boxes.compactMap { b -> ScreenTextBox? in
        let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return ScreenTextBox(text: t, x: b.x, y: b.y, w: b.w, h: b.h)
    }
    let (thread, composerX) = focusOpenThread(trimmed)
    let kept = dropReplyQuotes(thread.filter { !looksLikeScreenChrome($0.text) })
    guard !kept.isEmpty else { return Snapshot(title: title, messages: []) }
    let lines = clusterScreenLines(kept)
    let bubbles = clusterScreenBubbles(lines)
    let colLeft = composerX.map { min($0 - 16, bubbles.map(\.left).min()!) } ?? bubbles.map(\.left).min()!
    let colRight = max(width ?? 0, bubbles.map(\.right).max()!)
    return Snapshot(title: title, messages: msgsFromScreenBubbles(bubbles, colLeft: colLeft, colRight: colRight))
}

/// "Alex replied to you" / "You replied to Sam" and the quoted bubble under it are not new messages.
func dropReplyQuotes(_ boxes: [ScreenTextBox]) -> [ScreenTextBox] {
    let sorted = boxes.sorted { $0.y < $1.y }
    var out: [ScreenTextBox] = []
    var skipQuoteBelow: ScreenTextBox?
    for b in sorted {
        let s = b.text.lowercased()
        if s.contains("replied to ") || s.hasPrefix("replying to ") || s == "original message:" {
            skipQuoteBelow = b
            continue
        }
        if let label = skipQuoteBelow {
            skipQuoteBelow = nil
            if b.y - (label.y + label.h) <= max(label.h, b.h) * 2.5 { continue }
        }
        out.append(b)
    }
    return out
}

/// Clocks, receipts, URL bars — same spirit as MessagesApp chrome filtering.
public func looksLikeScreenChrome(_ t: String) -> Bool {
    let s = t.lowercased()
    if s == "search" || s == "today" || s == "yesterday" { return true }
    if s == "messages" || s == "requests" || s == "your note" { return true }
    if s.hasPrefix("delivered") || s.hasPrefix("read") || s.hasPrefix("edited") || s.hasPrefix("seen") {
        return true
    }
    if s.hasPrefix("you sent") || s.hasPrefix("you:") || s.hasPrefix("active ") { return true }
    if s.hasPrefix("monday") || s.hasPrefix("tuesday") || s.hasPrefix("wednesday")
        || s.hasPrefix("thursday") || s.hasPrefix("friday") || s.hasPrefix("saturday")
        || s.hasPrefix("sunday") { return true }
    if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("www.") { return true }
    if !t.contains(" ") && (t.contains("/") || s.contains(".com")) { return true }
    if ["type a message", "message…", "message...", "send a message", "write a message"].contains(s) {
        return true
    }
    return t.range(of: #"^\d{1,2}:\d{2}\s*(am|pm)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

/// The open chat is the column that contains the message box. Inbox rows sit to its left.
/// Also returns the message box's left edge, which is the chat column's left edge.
func focusOpenThread(_ boxes: [ScreenTextBox]) -> ([ScreenTextBox], Double?) {
    if let composer = boxes.filter({ isComposerLabel($0.text) }).max(by: { $0.y < $1.y }) {
        let kept = boxes.filter { b in
            b.y + b.h < composer.y - 4 && (b.x + b.w / 2) >= composer.x - 16
        }
        return (kept, composer.x)
    }
    // No message box read: drop only a column that looks like an inbox, never the other person's bubbles.
    let rows = boxes.filter { looksLikeInboxRow($0.text) }
    guard rows.count >= 2, let rowLeft = rows.map(\.left).min() else { return (boxes, nil) }
    let inbox = boxes.filter { abs($0.left - rowLeft) <= 24 || looksLikeInboxRow($0.text) }
    guard let inboxRight = inbox.map(\.right).max() else { return (boxes, nil) }
    return (boxes.filter { $0.left > inboxRight }, nil)
}

private func looksLikeInboxRow(_ t: String) -> Bool {
    let s = t.lowercased()
    if s.hasPrefix("you:") || s.hasPrefix("you sent") || s.hasPrefix("active now") { return true }
    if s.range(of: #"^(active|sent|seen) \d+\s*[smhdw]\w* ago$"#, options: .regularExpression) != nil { return true }
    return s.range(of: #"·\s*\d+\s*[smhdw]\b"#, options: .regularExpression) != nil
}

private func isComposerLabel(_ t: String) -> Bool {
    let s = t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if s == "message" || s == "message…" || s == "message..." { return true }
    if s.hasPrefix("message") && s.count <= 16 { return true }
    return ["type a message", "send a message", "write a message", "imessage"].contains(s)
}

// MARK: - clustering

private struct ScreenLine {
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var left: Double { x }
    var right: Double { x + w }
}

private func clusterScreenLines(_ boxes: [ScreenTextBox]) -> [ScreenLine] {
    let sorted = boxes.sorted {
        $0.midY < $1.midY - 0.5 || (abs($0.midY - $1.midY) <= 0.5 && $0.x < $1.x)
    }
    var groups: [[ScreenTextBox]] = []
    for b in sorted {
        if var last = groups.last, let ref = last.first {
            let thresh = max(max(ref.h, b.h) * 0.65, 8)
            if abs(b.midY - last.map(\.midY).reduce(0, +) / Double(last.count)) <= thresh {
                last.append(b)
                groups[groups.count - 1] = last
                continue
            }
        }
        groups.append([b])
    }
    return groups.map { group in
        let ordered = group.sorted { $0.x < $1.x }
        let left = ordered.map(\.left).min()!
        let right = ordered.map(\.right).max()!
        let top = ordered.map(\.y).min()!
        let bottom = ordered.map { $0.y + $0.h }.max()!
        return ScreenLine(
            text: ordered.map(\.text).joined(separator: " "),
            x: left, y: top, w: right - left, h: max(bottom - top, 1)
        )
    }
}

/// Consecutive lines with a shared left edge become one multi-line bubble.
private func clusterScreenBubbles(_ lines: [ScreenLine]) -> [ScreenLine] {
    var bubbles: [ScreenLine] = []
    for line in lines {
        if let last = bubbles.last {
            let tol = max(24.0, max(last.w, line.w) * 0.12)
            let leftClose = abs(line.left - last.left) <= tol
            let gap = line.y - (last.y + last.h)
            let closeVert = gap <= max(line.h, last.h) * 1.35
            if leftClose && closeVert {
                let left = min(last.left, line.left)
                let right = max(last.right, line.right)
                let top = last.y
                let bottom = line.y + line.h
                bubbles[bubbles.count - 1] = ScreenLine(
                    text: last.text + " " + line.text,
                    x: left, y: top, w: right - left, h: max(bottom - top, 1)
                )
                continue
            }
        }
        bubbles.append(line)
    }
    return bubbles
}

/// Your bubbles hug the right edge of the chat column; theirs hug the left.
func screenSide(left: Double, right: Double, colLeft: Double, colRight: Double) -> String {
    let gapLeft = left - colLeft
    let gapRight = colRight - right
    if gapRight <= (colRight - colLeft) * 0.06 { return "me" }
    return gapRight < gapLeft ? "me" : "other"
}

private func msgsFromScreenBubbles(_ bubbles: [ScreenLine], colLeft: Double, colRight: Double) -> [Msg] {
    let edgeIdx = bubbles.indices.filter { !isDecorativeScreenText(bubbles[$0].text) }
    let edgeBalls = edgeIdx.isEmpty ? bubbles : edgeIdx.map { bubbles[$0] }
    let edgeSides = edgeBalls.map { screenSide(left: $0.left, right: $0.right, colLeft: colLeft, colRight: colRight) }
    var sideByEdgeIndex: [Int: String] = [:]
    for (i, side) in zip(edgeIdx.isEmpty ? Array(bubbles.indices) : edgeIdx, edgeSides) {
        sideByEdgeIndex[i] = side
    }
    return bubbles.enumerated().map { i, b in
        if let side = sideByEdgeIndex[i] { return Msg(side, b.text) }
        let inherited = bubbles.indices
            .filter { sideByEdgeIndex[$0] != nil }
            .min(by: { abs($0 - i) < abs($1 - i) })
            .flatMap { sideByEdgeIndex[$0] } ?? "other"
        return Msg(inherited, b.text)
    }
}

private func isDecorativeScreenText(_ raw: String) -> Bool {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return true }
    if t.count > 8 { return false }
    return t.unicodeScalars.allSatisfy { s in
        s.properties.isEmoji || s.properties.isEmojiPresentation || s == "\u{FE0F}" || s == "\u{200D}"
    }
}
