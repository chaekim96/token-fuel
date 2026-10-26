// TokenFuel — a live context-window fuel gauge for Claude Code and Codex.
// Reads the exact token counts each tool writes to its local session logs; never estimates.
import AppKit

// MARK: - Constants

let home = NSHomeDirectory()
let claudeProjects = "\(home)/.claude/projects"
let codexSessions = "\(home)/.codex/sessions"
let activeWindow: TimeInterval = 2 * 60 * 60 // sessions touched in the last 2 hours count as active
let tailBytes = 2 * 1024 * 1024               // how much of each log to read
let historyTurns = 12
let burnWindow = 5
let spark = Array("▁▂▃▄▅▆▇█")
let launchAgentPath = "\(home)/Library/LaunchAgents/local.token-fuel.plist"

// MARK: - Model

struct Turn { var burn: Int; var refuel: Bool }

struct Gauge {
    var path: String
    var source: String   // "Claude Code", "Codex", …
    var title: String
    var used: Int
    var window: Int
    var turns: [Turn]    // oldest → newest; the last one may still be in progress
    var modified: Date

    var left: Int { max(0, window - used) }
    var pct: Int { window > 0 ? Int((Double(left) / Double(window) * 100).rounded()) : 0 }
    var family: String { source.hasPrefix("Codex") ? "codex" : "claude" }
}

enum Event { case prompt, usage(Int), compact(Int?) }

// Replays a session's events into turns. A turn runs from one user prompt to the next;
// its burn is how much the context grew during it.
func buildTurns(_ events: [Event], window: Int) -> (used: Int, turns: [Turn]) {
    struct Open { var start: Int?; var end: Int?; var refuel = false }
    let threshold = max(10_000, window / 20)
    var last: Int?
    var cur: Open?
    var turns: [Turn] = []
    func close(_ o: Open) -> Turn {
        o.refuel ? Turn(burn: 0, refuel: true) : Turn(burn: max(0, (o.end ?? 0) - (o.start ?? o.end ?? 0)), refuel: false)
    }
    for e in events {
        switch e {
        case .prompt:
            if let c = cur { turns.append(close(c)) }
            cur = Open(start: last, end: last)
        case .usage(let u):
            if let l = last, u < l - threshold { cur?.refuel = true } // big drop: compaction or clear
            last = u
            if cur != nil {
                if cur!.start == nil { cur!.start = u }
                cur!.end = u
            }
        case .compact(let post):
            cur?.refuel = true
            if let p = post { last = p }
        }
    }
    if let c = cur { turns.append(close(c)) }
    return (last ?? 0, Array(turns.suffix(historyTurns)))
}

// MARK: - Log reading

func readTail(_ path: String, _ bytes: Int) -> [Substring] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? fh.seek(toOffset: start)
    guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) else { return [] }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    if start > 0, !lines.isEmpty { lines.removeFirst() } // first line is cut off
    return lines
}

func readFirstLine(_ path: String, limit: Int = 4 * 1024 * 1024) -> [String: Any]? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    var buf = Data()
    while buf.count < limit, let chunk = try? fh.read(upToCount: 64 * 1024), !chunk.isEmpty {
        if let nl = chunk.firstIndex(of: 0x0A) { buf.append(chunk[chunk.startIndex..<nl]); break }
        buf.append(chunk)
    }
    return (try? JSONSerialization.jsonObject(with: buf)) as? [String: Any]
}

func json(_ line: Substring) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

// MARK: - Claude Code
// ~/.claude/projects/<project>/<session>.jsonl — used by both the CLI and the desktop Code tab.

var claudeTitles: [String: String] = [:]
var claudeTailBytes: [String: Int] = [:] // how far back each session needs reading to reach its last prompt

func claudeTitle(_ path: String, tail: [Substring]) -> String {
    func scan<S: Sequence>(_ lines: S) -> String? where S.Element == Substring {
        var t: String?
        for l in lines where l.contains("\"custom-title\"") || l.contains("\"agent-name\"") {
            if let o = json(l) { t = (o["customTitle"] as? String) ?? (o["agentName"] as? String) ?? t }
        }
        return t
    }
    if let t = scan(tail) { claudeTitles[path] = t; return t }
    if claudeTitles[path] == nil, let all = try? String(contentsOfFile: path, encoding: .utf8) {
        claudeTitles[path] = scan(all.split(separator: "\n")) ?? ""
    }
    if let t = claudeTitles[path], !t.isEmpty { return t }
    // Fall back to the project folder, e.g. "-Users-chaekim-Desktop" → "Desktop".
    let dir = (path as NSString).deletingLastPathComponent
    return (dir as NSString).lastPathComponent.split(separator: "-").last.map(String.init) ?? "Session"
}

func isRealPrompt(_ o: [String: Any]) -> Bool {
    if (o["isMeta"] as? Bool) == true || (o["isCompactSummary"] as? Bool) == true { return false }
    let content = (o["message"] as? [String: Any])?["content"]
    var text: String?
    if let s = content as? String { text = s }
    else if let a = content as? [[String: Any]], let first = a.first, first["type"] as? String == "text" { text = first["text"] as? String }
    guard let t = text else { return false } // tool results aren't prompts
    let trimmed = t.drop(while: { $0.isWhitespace })
    return !(trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command-"))
}

func parseClaude(_ path: String, modified: Date) -> Gauge? {
    // Long tool-heavy turns can push the last prompt far back; read further until one shows up.
    var bytes = claudeTailBytes[path] ?? tailBytes
    var lines = readTail(path, bytes)
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    while bytes < fileSize, bytes < 64 * 1024 * 1024,
          !lines.contains(where: { $0.contains("\"type\":\"user\"") && !$0.contains("\"tool_use_id\"") && json($0).map(isRealPrompt) == true }) {
        bytes *= 4
        lines = readTail(path, bytes)
    }
    claudeTailBytes[path] = bytes
    var events: [Event] = []
    var model = ""
    var entry = ""
    var maxUsed = 0
    for line in lines {
        let isAssistant = line.contains("\"type\":\"assistant\"")
        let isUser = line.contains("\"type\":\"user\"")
        let isCompact = line.contains("\"compact_boundary\"")
        guard isAssistant || isUser || isCompact, let o = json(line) else { continue }
        if (o["isSidechain"] as? Bool) == true { continue }
        switch o["type"] as? String {
        case "assistant":
            guard let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                  let m = msg["model"] as? String, m != "<synthetic>" else { continue }
            let used = int(u["input_tokens"]) + int(u["cache_creation_input_tokens"]) + int(u["cache_read_input_tokens"])
            model = m
            maxUsed = max(maxUsed, used)
            if let e = o["entrypoint"] as? String { entry = e }
            events.append(.usage(used))
        case "user":
            if isRealPrompt(o) { events.append(.prompt) }
        case "system":
            if o["subtype"] as? String == "compact_boundary" {
                events.append(.compact((o["compactMetadata"] as? [String: Any]).map { int($0["postTokens"]) }))
            }
        default: break
        }
    }
    guard !model.isEmpty else { return nil }
    // Opus 5 models run with a 1M window here; anything that has gone past 200k must have one too.
    let window = (model.contains("opus-5") || model.contains("[1m]") || maxUsed > 200_000) ? 1_000_000 : 200_000
    let (used, turns) = buildTurns(events, window: window)
    let source = entry == "claude-desktop" ? "Claude Code · desktop" : "Claude Code"
    return Gauge(path: path, source: source, title: claudeTitle(path, tail: lines), used: used, window: window, turns: turns, modified: modified)
}

// MARK: - Codex
// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — used by both the Codex CLI and the Codex app.

struct CodexMeta { var title: String; var source: String; var isUserThread: Bool }
var codexMeta: [String: CodexMeta] = [:]

func parseCodex(_ path: String, modified: Date) -> Gauge? {
    if codexMeta[path] == nil {
        let p = (readFirstLine(path)?["payload"] as? [String: Any]) ?? [:]
        let cwd = (p["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Session"
        let threadSource = p["thread_source"] as? String
        let originator = p["originator"] as? String ?? ""
        codexMeta[path] = CodexMeta(title: cwd, source: originator.contains("desktop") ? "Codex · app" : "Codex",
                                    isUserThread: threadSource == nil || threadSource == "user")
    }
    guard let meta = codexMeta[path], meta.isUserThread else { return nil } // skip sub-agent threads
    var events: [Event] = []
    var window = 0
    for line in readTail(path, tailBytes) {
        let tc = line.contains("\"token_count\""), ts = line.contains("\"task_started\""), cp = line.contains("\"type\":\"compacted\"")
        guard tc || ts || cp, let o = json(line) else { continue }
        let type = o["type"] as? String
        let payload = o["payload"] as? [String: Any] ?? [:]
        if type == "compacted" { events.append(.compact(nil)); continue }
        guard type == "event_msg" else { continue }
        switch payload["type"] as? String {
        case "task_started":
            events.append(.prompt)
        case "token_count":
            guard let info = payload["info"] as? [String: Any], let lastUse = info["last_token_usage"] as? [String: Any] else { continue }
            if int(info["model_context_window"]) > 0 { window = int(info["model_context_window"]) }
            events.append(.usage(int(lastUse["total_tokens"])))
        default: break
        }
    }
    guard window > 0 else { return nil }
    let (used, turns) = buildTurns(events, window: window)
    return Gauge(path: path, source: meta.source, title: meta.title, used: used, window: window, turns: turns, modified: modified)
}

// MARK: - Scanning

struct CacheEntry { var mtime: Date; var size: Int; var gauge: Gauge? }
var cache: [String: CacheEntry] = [:]

func listJSONL(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.map { "\(dir)/\($0)" }
}

func scanAll() -> [Gauge] {
    let fm = FileManager.default
    let now = Date()
    var files: [(String, Bool)] = [] // (path, isCodex)
    for d in (try? fm.contentsOfDirectory(atPath: claudeProjects)) ?? [] {
        files += listJSONL("\(claudeProjects)/\(d)").map { ($0, false) }
    }
    // Codex keeps appending to a resumed chat's original YYYY/MM/DD file, so look in every
    // day folder; the modified-time check below keeps only the active ones.
    for y in (try? fm.contentsOfDirectory(atPath: codexSessions)) ?? [] {
        for m in (try? fm.contentsOfDirectory(atPath: "\(codexSessions)/\(y)")) ?? [] {
            for d in (try? fm.contentsOfDirectory(atPath: "\(codexSessions)/\(y)/\(m)")) ?? [] {
                files += listJSONL("\(codexSessions)/\(y)/\(m)/\(d)").map { ($0, true) }
            }
        }
    }
    var out: [Gauge] = []
    for (path, isCodex) in files {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              now.timeIntervalSince(mtime) < activeWindow else { continue }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if let c = cache[path], c.mtime == mtime, c.size == size {
            if let g = c.gauge { out.append(g) }
            continue
        }
        let g = isCodex ? parseCodex(path, modified: mtime) : parseClaude(path, modified: mtime)
        cache[path] = CacheEntry(mtime: mtime, size: size, gauge: g)
        if let g = g { out.append(g) }
    }
    return out.sorted { $0.modified > $1.modified }
}

// MARK: - Rendering

func fmt(_ n: Int) -> String {
    let n = max(0, n)
    func trim(_ v: Double) -> String { let s = String(format: "%.1f", v); return s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
    if n >= 1_000_000 { return trim(Double(n) / 1_000_000) + "M" }
    if n >= 1_000 { return trim(Double(n) / 1_000) + "k" }
    return "\(n)"
}

let magenta = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ? NSColor(srgbRed: 0.93, green: 0.40, blue: 0.86, alpha: 1) : NSColor(srgbRed: 0.75, green: 0.15, blue: 0.65, alpha: 1) }
let yellow = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ? NSColor.systemYellow : NSColor(srgbRed: 0.78, green: 0.55, blue: 0.0, alpha: 1) }

func level(_ pct: Int) -> (String, NSColor) {
    switch pct {
    case 75...: return ("Full", .systemGreen)
    case 50..<75: return ("Good", .systemCyan)
    case 25..<50: return ("Low", yellow)
    case 10..<25: return ("Reserve", magenta)
    default: return ("Refuel soon", .systemRed)
    }
}

let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

func seg(_ s: String, _ color: NSColor = .labelColor, bold: Bool = false, font: NSFont? = nil) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font ?? (bold ? monoBold : mono), .foregroundColor: color])
}

/// ▕███░░░░░░░▏ Low · 33% · 65.6k of 200k left · ~3 turns left · ▂▁▃▂▅ · ▼ 21.4k last turn
func gaugeLine(_ g: Gauge) -> NSAttributedString {
    let (label, color) = level(g.pct)
    let dim = NSColor.tertiaryLabelColor
    let cells = min(10, max(0, Int((Double(g.pct) / 10).rounded())))
    let s = NSMutableAttributedString()
    let sep = seg(" · ", dim)
    s.append(seg("▕")); s.append(seg(String(repeating: "█", count: cells), color))
    s.append(seg(String(repeating: "░", count: 10 - cells), dim)); s.append(seg("▏ "))
    s.append(seg(label, color, bold: true)); s.append(sep)
    s.append(seg("\(g.pct)% · \(fmt(g.left)) of \(fmt(g.window)) left"))
    if g.turns.count >= 2 {
        let burns = g.turns.filter { !$0.refuel && $0.burn > 0 }.suffix(burnWindow).map(\.burn)
        if !burns.isEmpty {
            let avg = Double(burns.reduce(0, +)) / Double(burns.count)
            let n = Int(Double(g.left) / avg)
            s.append(sep); s.append(seg("~\(n) turn\(n == 1 ? "" : "s") left"))
        }
    }
    if !g.turns.isEmpty {
        let mx = max(1, g.turns.map(\.burn).max() ?? 1)
        let chart = String(g.turns.map { $0.burn <= 0 ? spark[0] : spark[min(7, Int((Double($0.burn) / Double(mx) * 8).rounded(.up)) - 1)] })
        s.append(sep); s.append(seg(chart, .secondaryLabelColor))
    }
    if let last = g.turns.last {
        // Right as a new prompt lands, the turn in progress is still 0 — show the one before.
        let shown = (!last.refuel && last.burn == 0 && g.turns.count > 1) ? g.turns[g.turns.count - 2] : last
        s.append(sep)
        s.append(shown.refuel ? seg("⛽ Refueled", .systemGreen, bold: true) : seg("▼ \(fmt(shown.burn)) last turn"))
    }
    return s
}

func headerLine(_ g: Gauge, size: CGFloat = 11) -> NSAttributedString {
    let s = NSMutableAttributedString(string: g.source, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
    s.append(NSAttributedString(string: "  \(g.title)", attributes: [
        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]))
    return s
}

func label(_ text: NSAttributedString) -> NSTextField {
    let l = NSTextField(labelWithAttributedString: text)
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    return l
}

// MARK: - Launch at login (LaunchAgent)

func launchAtLoginEnabled() -> Bool { FileManager.default.fileExists(atPath: launchAgentPath) }

func setLaunchAtLogin(_ on: Bool) {
    if on {
        let exe = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": "local.token-fuel",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], // restart after a crash, not after Quit
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: launchAgentPath, atomically: true)
    } else {
        try? FileManager.default.removeItem(atPath: launchAgentPath)
    }
}

// MARK: - App

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var status: NSStatusItem!
    let menu = NSMenu()
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let stack = NSStackView()
    let scanQueue = DispatchQueue(label: "token-fuel.scan")
    var gauges: [Gauge] = []
    var scanning = false
    var placing = false
    let defaults = UserDefaults.standard

    var showFloating: Bool {
        get { defaults.object(forKey: "showFloating") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFloating") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // One copy at a time.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me }) { NSApp.terminate(nil); return }

        if !defaults.bool(forKey: "didSetup") { // first run: always on
            setLaunchAtLogin(true)
            defaults.set(true, forKey: "didSetup")
        }

        // New menu bar icons go to the far left of the others, which on a notched MacBook is
        // usually behind the notch, where macOS hides them. Start near the right edge instead
        // (distance from the screen's right edge, in points); a ⌘-drag later overrides this.
        let positionKey = "NSStatusItem Preferred Position TokenFuel"
        if defaults.object(forKey: positionKey) == nil { defaults.set(260, forKey: positionKey) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = "TokenFuel"
        status.behavior = []
        status.button?.attributedTitle = seg("⛽ —", font: .menuBarFont(ofSize: 0))
        menu.delegate = self
        status.menu = menu

        setUpPanel()
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common) // keep ticking while the menu is open
    }

    // MARK: data

    func refresh() {
        guard !scanning else { return }
        scanning = true
        scanQueue.async {
            let result = scanAll()
            DispatchQueue.main.async {
                self.scanning = false
                self.gauges = result
                self.render()
            }
        }
    }

    func render() {
        // Menu bar: the most recently active session.
        if let g = gauges.first {
            let (_, color) = level(g.pct)
            let cells = min(5, max(0, Int((Double(g.pct) / 20).rounded())))
            let f = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let small = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let s = NSMutableAttributedString(attributedString: seg("⛽ ", font: f))
            s.append(seg(String(repeating: "█", count: cells), color, font: small))
            s.append(seg(String(repeating: "░", count: 5 - cells), .tertiaryLabelColor, font: small))
            s.append(seg(" \(g.pct)%", font: f))
            status.button?.attributedTitle = s
            status.button?.toolTip = "\(g.source) · \(g.title)"
        } else {
            status.button?.attributedTitle = seg("⛽ —", font: .menuBarFont(ofSize: 0))
            status.button?.toolTip = "No active Claude Code or Codex sessions"
        }
        buildMenu()
        renderPanel()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu() }

    func viewItem(_ text: NSAttributedString, top: CGFloat, bottom: CGFloat) -> NSMenuItem {
        let l = label(text)
        let size = l.fittingSize
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 32, height: size.height + top + bottom))
        l.frame = NSRect(x: 16, y: bottom, width: size.width + 4, height: size.height)
        v.addSubview(l)
        let item = NSMenuItem()
        item.view = v
        return item
    }

    func buildMenu() {
        menu.removeAllItems()
        if gauges.isEmpty {
            menu.addItem(viewItem(NSAttributedString(string: "No active sessions in the last 2 hours", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]), top: 4, bottom: 4))
        }
        for (i, g) in gauges.prefix(6).enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(viewItem(headerLine(g), top: 4, bottom: 1))
            menu.addItem(viewItem(gaugeLine(g), top: 1, bottom: 4))
        }
        menu.addItem(.separator())
        let float = NSMenuItem(title: "Show Floating Window", action: #selector(toggleFloating), keyEquivalent: "")
        float.state = showFloating ? .on : .off
        float.target = self
        menu.addItem(float)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = launchAtLoginEnabled() ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TokenFuel", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleFloating() { showFloating.toggle(); renderPanel() }
    @objc func toggleLogin() { setLaunchAtLogin(!launchAtLoginEnabled()) }

    // MARK: floating window

    func setUpPanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.maskImage = NSImage(size: NSSize(width: 25, height: 25), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill(); return true
        }
        blur.maskImage?.capInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        blur.maskImage?.resizingMode = .stretch
        panel.contentView = blur

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        let m = NSMenu()
        let hide = NSMenuItem(title: "Hide Floating Window", action: #selector(toggleFloating), keyEquivalent: "")
        hide.target = self
        m.addItem(hide)
        m.addItem(NSMenuItem(title: "Quit TokenFuel", action: #selector(NSApp.terminate(_:)), keyEquivalent: ""))
        blur.menu = m
    }

    func renderPanel() {
        // Newest session from each tool (one Claude Code row, one Codex row).
        var seen = Set<String>()
        let rows = gauges.filter { seen.insert($0.family).inserted }
        guard showFloating, !rows.isEmpty else { panel.orderOut(nil); return }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, g) in rows.enumerated() {
            if i > 0, let prev = stack.arrangedSubviews.last { stack.setCustomSpacing(8, after: prev) }
            stack.addArrangedSubview(label(headerLine(g, size: 10)))
            stack.addArrangedSubview(label(gaugeLine(g)))
        }
        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        // fittingSize can come up short for mixed-font text, which clipped the line end; measure the text itself.
        let textWidth = stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.attributedStringValue.size().width }.max() ?? 0
        size.width = max(size.width, ceil(textWidth) + 4 + stack.edgeInsets.left + stack.edgeInsets.right)

        // Keep the top-right corner where the user left it.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var topRight = NSPoint(x: screen.maxX - 16, y: screen.maxY - 16)
        if let s = defaults.string(forKey: "panelTopRight") { topRight = NSPointFromString(s) }
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(topRight) }) {
            topRight = NSPoint(x: screen.maxX - 16, y: screen.maxY - 16)
        }
        placing = true
        panel.setFrame(NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
        placing = false
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func windowDidMove(_ note: Notification) {
        guard !placing else { return }
        let f = panel.frame
        defaults.set(NSStringFromPoint(NSPoint(x: f.maxX, y: f.maxY)), forKey: "panelTopRight")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
