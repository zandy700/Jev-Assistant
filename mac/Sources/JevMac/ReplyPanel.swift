import AppKit
import JevCore

/// Floating, non-activating panel: Jev's read of the chat and 3 ranked replies with Fill / Copy.
/// Same dusk palette and hierarchy as the Chrome extension's side panel.
@MainActor
final class ReplyPanel {
    var onFill: ((String) -> Void)?
    private static let width: CGFloat = 360
    private let panel: NSPanel
    private let column = Backdrop()
    private let header = Header()
    private let noteLabel = text("", JevFont.body(12), Palette.muted)
    private var body: [NSView] = []
    private var note: String?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: true)
        panel.title = "Jev"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = Palette.dusk
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = column
        column.wantsLayer = true
        column.addSubview(header)
        noteLabel.alignment = .center
    }

    func show(title: String?) {
        let t = title ?? "Messages"
        panel.title = "Jev · \(t)"
        header.chat = t
        bringUp()
    }

    func status(_ s: String) {
        set([Card([(StatusRow(s, busy: s.hasSuffix("…")), 0)])])
    }

    func error(_ s: String) {
        set([Card([(text("Something went wrong", JevFont.body(14, .semibold), Palette.coral), 0),
                   (text(s, JevFont.body(13), Palette.muted), 4)])])
    }

    /// A line under the current cards. Keeps the replies on screen, unlike `status`.
    func note(_ s: String) {
        note = s
        layoutAll()
    }

    func show(summary s: Summary, replies: [RankedReply]) {
        set([readCard(s)] + replies.enumerated().map { replyCard($1, best: $0 == 0) }, reveal: true)
    }

    private func readCard(_ s: Summary) -> Card {
        var rows: [(NSView, CGFloat)] = []
        let risk = s.risk.map { r -> NSTextField in
            let n = Int(r.rounded())
            return text("Risk \(n) / 9", JevFont.display(15), Palette.risk(n), lines: 1)
        }
        rows.append((SplitRow(caption("Their mood"), risk), 0))
        let moods = s.moods.isEmpty ? (s.mood.map { [MoodGuess($0, s.moodPct)] } ?? []) : s.moods
        for (i, m) in moods.enumerated() {
            rows.append((MoodBar(brainLabel("mood", m.key), pct: m.pct, lead: i == 0), i == 0 ? 10 : 6))
        }
        if let i = s.intent {
            let line = NSMutableAttributedString(string: "They want  ",
                attributes: [.font: JevFont.body(13), .foregroundColor: Palette.muted])
            line.append(NSAttributedString(string: brainLabel("intent", i),
                attributes: [.font: JevFont.body(14, .semibold), .foregroundColor: Palette.ink]))
            let l = text("", JevFont.body(14), Palette.ink)
            l.attributedStringValue = line
            rows.append((l, 12))
        }
        var chips: [Chip] = []
        if let n = s.needs, n != "nothing" { chips.append(Chip("Needs \(brainLabel("needs", n))")) }
        if let a = s.bestAction { chips.append(Chip("Best move: \(brainLabel("action", a))")) }
        if let ok = s.specificsOk { chips.append(Chip(ok >= 0.5 ? "OK to get specific" : "Hold off on specifics")) }
        if let t = s.tensionResolved, t >= 0.7 { chips.append(Chip("Tension resolved", tint: Palette.mint, symbol: "checkmark")) }
        if !chips.isEmpty { rows.append((ChipFlow(chips), 10)) }
        return Card(rows)
    }

    private func replyCard(_ r: RankedReply, best: Bool) -> Card {
        let pct = "\(Int((r.prob * 100).rounded()))%"
        let rank = text(best ? "Best pick · \(pct)" : pct, JevFont.mono(11), best ? Palette.mint : Palette.muted, lines: 1)
        let fill = PillButton("Fill", style: .primary) { [weak self] in self?.onFill?(r.text) }
        var copy: PillButton!
        copy = PillButton("Copy", style: .quiet) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(r.text, forType: .string)
            copy.flash("Copied")
        }
        return Card([(rank, 0), (text(r.text, JevFont.body(14), Palette.ink), 5), (ButtonRow(fill, copy), 12)],
                    border: best ? Palette.mint.withAlphaComponent(0.7) : nil)
    }

    private func caption(_ s: String) -> NSTextField {
        let l = text("", JevFont.body(11, .semibold), Palette.muted, lines: 1)
        l.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: JevFont.body(11, .semibold), .foregroundColor: Palette.muted, .kern: 0.8])
        return l
    }

    private func set(_ views: [NSView], reveal: Bool = false) {
        body.forEach { $0.removeFromSuperview() }
        body = views
        note = nil
        layoutAll()
        guard reveal, Self.animates else { return }
        for (i, v) in views.enumerated() {
            v.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    v.animator().alphaValue = 1
                }
            }
        }
    }

    private static var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !CommandLine.arguments.contains("--preview")
    }

    private func layoutAll() {
        let width = Self.width
        let pad: CGFloat = 14
        let gap: CGFloat = 10
        let innerW = width - pad * 2
        noteLabel.removeFromSuperview()
        var views = body
        if let n = note {
            noteLabel.stringValue = n
            views.append(noteLabel)
        }
        let heights = views.map { height(of: $0, width: innerW) }
        let (mid, left) = titlebarAnchor()
        let top = mid * 2 + 8
        let total = top + heights.reduce(0, +) + gap * CGFloat(max(views.count - 1, 0)) + pad
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 48
        panel.setContentSize(NSSize(width: width, height: min(total, maxH)))
        let h = panel.contentView?.bounds.height ?? total
        column.frame = NSRect(x: 0, y: 0, width: width, height: h)
        header.leftInset = left
        header.frame = NSRect(x: 0, y: h - mid * 2, width: width, height: mid * 2)
        // AppKit's origin is the bottom. Place the first card under the header.
        var y = h - top
        for (v, vh) in zip(views, heights) {
            y -= vh
            v.frame = NSRect(x: pad, y: y, width: innerW, height: vh)
            column.addSubview(v)
            y -= gap
        }
        column.needsDisplay = true
        column.layoutSubtreeIfNeeded()
        bringUp()
    }

    /// Vertical center of the close button (from the top) and where the header may start after it.
    private func titlebarAnchor() -> (CGFloat, CGFloat) {
        guard let b = panel.standardWindowButton(.closeButton), b.superview != nil else { return (15, 34) }
        let r = b.convert(b.bounds, to: nil)
        let fromTop = panel.frame.height - r.midY
        return (fromTop > 6 && fromTop < 30 ? fromTop : 15, max(r.maxX + 12, 34))
    }

    /// Writes the panel contents to a PNG (used by `--preview` for docs screenshots).
    func writePNG(to path: String) -> Bool {
        column.layoutSubtreeIfNeeded()
        let bounds = column.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = column.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        column.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    private func bringUp() {
        guard !panel.isVisible else { return }
        if let f = NSScreen.main?.visibleFrame { panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 380, y: f.maxY - 20)) }
        panel.orderFront(nil)
    }
}

// MARK: - Tokens

@MainActor
enum Palette {
    static let dusk = hex(0x17152A)
    static let panel = hex(0x221F3B)
    static let line = hex(0x35315A)
    static let them = hex(0x34304F)
    static let glow = hex(0x2C2758)
    static let mint = hex(0x3EE0D2)
    static let coral = hex(0xFF8A7A)
    static let amber = hex(0xF5C26B)
    static let ink = hex(0xF1EEFC)
    static let muted = hex(0xA39FC2)

    static func risk(_ n: Int) -> NSColor { n >= 6 ? coral : n >= 3 ? amber : mint }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum JevFont {
    static func display(_ size: CGFloat, _ weight: NSFont.Weight = .heavy) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
    static func body(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .medium) }
}

/// Single-line labels clip: AppKit's tail truncation adds "…" even at exactly the intrinsic width.
@MainActor
private func text(_ s: String, _ font: NSFont, _ color: NSColor, lines: Int = 0) -> NSTextField {
    let l = lines == 1 ? NSTextField(labelWithString: s) : NSTextField(wrappingLabelWithString: s)
    l.font = font
    l.textColor = color
    l.isSelectable = false
    return l
}

// MARK: - Frame-based views

/// A view that reports its height for a given width. Layout is frame-based so PNG capture matches the screen.
@MainActor
protocol Measured: NSView {
    func measure(width: CGFloat) -> CGFloat
}

@MainActor
private func height(of v: NSView, width: CGFloat) -> CGFloat {
    if let m = v as? Measured { return m.measure(width: width) }
    if let l = v as? NSTextField {
        l.preferredMaxLayoutWidth = width
        return max(ceil(l.intrinsicContentSize.height), 16)
    }
    return ceil(v.fittingSize.height)
}

class Box: NSView {
    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        needsLayout = true
    }
}

/// Dusk ground with the same soft top-right glow as the extension.
final class Backdrop: Box {
    override func draw(_ dirtyRect: NSRect) {
        Palette.dusk.setFill()
        bounds.fill()
        let c = NSPoint(x: bounds.maxX, y: bounds.maxY + 30)
        NSGradient(colors: [Palette.glow, Palette.glow.withAlphaComponent(0)])?
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: 280, options: [])
    }
}

/// "Jev." wordmark beside the close button, and the chat name in a pill on the right.
final class Header: Box {
    var leftInset: CGFloat = 34 { didSet { needsLayout = true } }
    var chat = "" {
        didSet {
            pill.stringValue = chat
            pill.toolTip = chat
            needsLayout = true
            needsDisplay = true
        }
    }
    private let brand = text("", JevFont.display(19), Palette.ink, lines: 1)
    private let pill = text("", JevFont.body(12, .semibold), Palette.ink, lines: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let mark = NSMutableAttributedString(string: "Jev", attributes: [.font: JevFont.display(19), .foregroundColor: Palette.ink])
        mark.append(NSAttributedString(string: ".", attributes: [.font: JevFont.display(19), .foregroundColor: Palette.mint]))
        brand.attributedStringValue = mark
        pill.lineBreakMode = .byTruncatingTail
        addSubview(brand)
        addSubview(pill)
    }

    required init?(coder: NSCoder) { nil }

    private var pillRect: NSRect {
        guard !chat.isEmpty else { return .zero }
        let b = brand.intrinsicContentSize
        let room = bounds.width - 14 - (leftInset + ceil(b.width) + 12)
        let w = min(ceil(pill.intrinsicContentSize.width) + 28, max(room, 60))
        return NSRect(x: bounds.width - 14 - w, y: bounds.midY - 11, width: w, height: 22)
    }

    override func layout() {
        super.layout()
        let b = brand.intrinsicContentSize
        brand.frame = NSRect(x: leftInset, y: floor(bounds.midY - b.height / 2), width: ceil(b.width) + 6, height: ceil(b.height))
        let r = pillRect
        let ph = ceil(pill.intrinsicContentSize.height)
        pill.frame = NSRect(x: r.minX + 10, y: floor(r.midY - ph / 2), width: max(r.width - 20, 0), height: ph)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = pillRect
        guard r.width > 0 else { return }
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        Palette.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Rounded panel card that stacks rows top-down; each row carries the gap above it.
final class Card: Box, Measured {
    private let rows: [(NSView, CGFloat)]
    private let border: NSColor?
    private let padX: CGFloat = 14
    private let padTop: CGFloat = 12
    private let padBottom: CGFloat = 14

    init(_ rows: [(NSView, CGFloat)], border: NSColor? = nil) {
        self.rows = rows
        self.border = border
        super.init(frame: .zero)
        rows.forEach { addSubview($0.0) }
    }

    required init?(coder: NSCoder) { nil }

    func measure(width: CGFloat) -> CGFloat {
        let w = width - padX * 2
        return rows.enumerated().reduce(padTop + padBottom) { h, e in
            h + height(of: e.element.0, width: w) + (e.offset > 0 ? e.element.1 : 0)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width - padX * 2
        var y = bounds.height - padTop
        for (i, (v, gap)) in rows.enumerated() {
            if i > 0 { y -= gap }
            let h = height(of: v, width: w)
            y -= h
            v.frame = NSRect(x: padX, y: y, width: w, height: h)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        Palette.panel.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Left label and optional right label on one line.
final class SplitRow: Box, Measured {
    private let left: NSTextField
    private let right: NSTextField?

    init(_ left: NSTextField, _ right: NSTextField?) {
        self.left = left
        self.right = right
        super.init(frame: .zero)
        addSubview(left)
        if let right { addSubview(right) }
    }

    required init?(coder: NSCoder) { nil }

    func measure(width: CGFloat) -> CGFloat {
        ceil(max(left.intrinsicContentSize.height, right?.intrinsicContentSize.height ?? 0))
    }

    override func layout() {
        super.layout()
        let rw = ceil(right?.intrinsicContentSize.width ?? 0)
        for (l, x, w) in [(left, 0, bounds.width - rw - 8), (right, bounds.width - rw, rw)] as [(NSTextField?, CGFloat, CGFloat)] {
            guard let l else { continue }
            let h = ceil(l.intrinsicContentSize.height)
            l.frame = NSRect(x: x, y: floor((bounds.height - h) / 2), width: w, height: h)
        }
    }
}

/// Mood name, a probability bar, and the percent.
final class MoodBar: Box, Measured {
    private let name: NSTextField
    private let value: NSTextField
    private let pct: Int?
    private let lead: Bool
    private let nameW: CGFloat = 84
    private let pctW: CGFloat = 38

    init(_ name: String, pct: Int?, lead: Bool) {
        self.name = text(name, JevFont.body(13, lead ? .semibold : .regular), lead ? Palette.ink : Palette.muted, lines: 1)
        self.value = text(pct.map { "\($0)%" } ?? "", JevFont.mono(11), lead ? Palette.ink : Palette.muted, lines: 1)
        self.pct = pct
        self.lead = lead
        super.init(frame: .zero)
        value.alignment = .right
        addSubview(self.name)
        addSubview(value)
    }

    required init?(coder: NSCoder) { nil }

    func measure(width: CGFloat) -> CGFloat { 18 }

    override func layout() {
        super.layout()
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: 0, y: floor((bounds.height - nh) / 2), width: nameW, height: nh)
        let vh = ceil(value.intrinsicContentSize.height)
        value.frame = NSRect(x: bounds.width - pctW, y: floor((bounds.height - vh) / 2), width: pctW, height: vh)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: nameW + 6, y: bounds.midY - 3.5, width: bounds.width - nameW - pctW - 16, height: 7)
        Palette.dusk.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
        guard let pct, pct > 0 else { return }
        var bar = track
        bar.size.width = max(track.width * CGFloat(min(pct, 100)) / 100, 7)
        (lead ? Palette.mint : Palette.mint.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).fill()
    }
}

/// Small pill of advice, optionally with an SF Symbol.
final class Chip: Box {
    private let label: NSTextField
    private let icon: NSImageView?

    init(_ s: String, tint: NSColor? = nil, symbol: String? = nil) {
        let tint = tint ?? Palette.muted
        label = text(s, JevFont.body(11.5, .medium), tint, lines: 1)
        icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.map {
            let v = NSImageView(image: $0)
            v.symbolConfiguration = .init(pointSize: 9, weight: .bold)
            v.contentTintColor = tint
            return v
        }
        super.init(frame: .zero)
        addSubview(label)
        if let icon { addSubview(icon) }
    }

    required init?(coder: NSCoder) { nil }

    var size: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 24 + (icon == nil ? 0 : 14), height: 22)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 10
        if let icon {
            icon.frame = NSRect(x: x, y: bounds.midY - 5, width: 10, height: 10)
            x += 14
        }
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: floor((bounds.height - h) / 2), width: bounds.width - x - 8, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.dusk.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Chips that wrap onto new rows.
final class ChipFlow: Box, Measured {
    private let chips: [Chip]
    private let gap: CGFloat = 6

    init(_ chips: [Chip]) {
        self.chips = chips
        super.init(frame: .zero)
        chips.forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    private func place(width: CGFloat) -> [NSRect] {
        var rects: [NSRect] = []
        var x: CGFloat = 0
        var row: CGFloat = 0
        for c in chips {
            let s = c.size
            let w = min(s.width, width)
            if x > 0, x + w > width {
                x = 0
                row += 1
            }
            rects.append(NSRect(x: x, y: row * (s.height + gap), width: w, height: s.height))
            x += w + gap
        }
        return rects
    }

    func measure(width: CGFloat) -> CGFloat { place(width: width).map(\.maxY).max() ?? 0 }

    override func layout() {
        super.layout()
        // Rects are measured top-down; flip them into AppKit's bottom-up space.
        for (c, r) in zip(chips, place(width: bounds.width)) {
            c.frame = NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        }
    }
}

/// Fill and Copy, sharing the card width.
final class ButtonRow: Box, Measured {
    private let buttons: [PillButton]

    init(_ buttons: PillButton...) {
        self.buttons = buttons
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    func measure(width: CGFloat) -> CGFloat { 30 }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let w = (bounds.width - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
        }
    }
}

/// Rounded button drawn in the palette, with hover and pressed states. Works on first click in the non-activating panel.
final class PillButton: Box {
    enum Style { case primary, quiet }
    private let title: String
    private let style: Style
    private let action: () -> Void
    private let label: NSTextField
    private var hover = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var restore: DispatchWorkItem?

    init(_ title: String, style: Style, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
        label = text(title, JevFont.body(13, .semibold), style == .primary ? Palette.dusk : Palette.ink, lines: 1)
        label.alignment = .center
        super.init(frame: .zero)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    /// Swap the title briefly, e.g. "Copied".
    func flash(_ s: String) {
        restore?.cancel()
        label.stringValue = s
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            label.stringValue = title
        }
        restore = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    override func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 4, y: floor((bounds.height - h) / 2), width: bounds.width - 8, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        var fill = style == .primary ? Palette.mint : Palette.them
        if pressed { fill = fill.blended(withFraction: 0.18, of: .black) ?? fill }
        else if hover { fill = fill.blended(withFraction: 0.12, of: .white) ?? fill }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// Status line, with a spinner while Jev is working.
final class StatusRow: Box, Measured {
    private let label: NSTextField
    private let spinner: NSProgressIndicator?

    init(_ s: String, busy: Bool) {
        label = text(s, JevFont.body(13), busy ? Palette.ink : Palette.muted)
        spinner = busy ? NSProgressIndicator() : nil
        super.init(frame: .zero)
        addSubview(label)
        if let spinner {
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            addSubview(spinner)
        }
    }

    required init?(coder: NSCoder) { nil }

    private var textX: CGFloat { spinner == nil ? 0 : 24 }

    func measure(width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width - textX
        return max(ceil(label.intrinsicContentSize.height), 16)
    }

    override func layout() {
        super.layout()
        label.preferredMaxLayoutWidth = bounds.width - textX
        label.frame = NSRect(x: textX, y: 0, width: bounds.width - textX, height: bounds.height)
        spinner?.frame = NSRect(x: 0, y: bounds.height - 16, width: 16, height: 16)
    }
}
