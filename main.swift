import AppKit
import Foundation

// MARK: - Model

struct Part: Codable {
    var name: String
    var minutes: Double
    /// Short label for the menu bar (falls back to `name`).
    var short: String? = nil
    /// Per-part warning override in minutes (falls back to `Config.warnMinutes`).
    var warnMinutes: Double? = nil
    /// Optional checklist hint shown at part start and in the menu.
    var hint: String? = nil
}

struct Config: Codable {
    // Global fallback warning, used when a part has no warnMinutes of its own.
    var warnMinutes: Double = 2
    var autoAdvance: Bool = true
    var compact: Bool = false

    // How the interview is split: Read + N work parts + Review.
    var problemParts: Int = 4
    var readMinutes: Double = 3
    var workMinutes: Double = 52
    var reviewMinutes: Double = 5
    var readWarnMinutes: Double = 1
    var partWarnMinutes: Double = 3
    var reviewWarnMinutes: Double = 1

    /// Explicit part list. Empty means "generate from the fields above".
    var parts: [Part] = []
    /// True when `parts` came from the config file instead of being generated.
    var partsExplicit: Bool = false

    static let readHint = "Skim both problems, set up 2-3 test cases"
    static let partHint = "Tests first, then logic, then verify"
    static let reviewHint = "Run tests, tidy naming, state complexity"

    enum CodingKeys: String, CodingKey {
        case warnMinutes, autoAdvance, compact
        case problemParts, readMinutes, workMinutes, reviewMinutes
        case readWarnMinutes, partWarnMinutes, reviewWarnMinutes
        case parts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warnMinutes = try c.decodeIfPresent(Double.self, forKey: .warnMinutes) ?? 2
        autoAdvance = try c.decodeIfPresent(Bool.self, forKey: .autoAdvance) ?? true
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? false
        problemParts = try c.decodeIfPresent(Int.self, forKey: .problemParts) ?? 4
        readMinutes = try c.decodeIfPresent(Double.self, forKey: .readMinutes) ?? 3
        workMinutes = try c.decodeIfPresent(Double.self, forKey: .workMinutes) ?? 52
        reviewMinutes = try c.decodeIfPresent(Double.self, forKey: .reviewMinutes) ?? 5
        readWarnMinutes = try c.decodeIfPresent(Double.self, forKey: .readWarnMinutes) ?? 1
        partWarnMinutes = try c.decodeIfPresent(Double.self, forKey: .partWarnMinutes) ?? 3
        reviewWarnMinutes = try c.decodeIfPresent(Double.self, forKey: .reviewWarnMinutes) ?? 1
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        partsExplicit = !parts.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(warnMinutes, forKey: .warnMinutes)
        try c.encode(autoAdvance, forKey: .autoAdvance)
        try c.encode(compact, forKey: .compact)
        try c.encode(problemParts, forKey: .problemParts)
        try c.encode(readMinutes, forKey: .readMinutes)
        try c.encode(workMinutes, forKey: .workMinutes)
        try c.encode(reviewMinutes, forKey: .reviewMinutes)
        try c.encode(readWarnMinutes, forKey: .readWarnMinutes)
        try c.encode(partWarnMinutes, forKey: .partWarnMinutes)
        try c.encode(reviewWarnMinutes, forKey: .reviewWarnMinutes)
        // Only persist `parts` when the user supplied them by hand, so the
        // 3/4-part switch stays a single knob in the config file.
        if partsExplicit { try c.encode(parts, forKey: .parts) }
    }

    /// Read + N evenly-split work parts + Review.
    static func generate(from c: Config) -> [Part] {
        let n = max(1, min(8, c.problemParts))
        let perPart = max(0.1, c.workMinutes) / Double(n)
        var out: [Part] = [
            Part(name: "Read + setup", minutes: max(0.1, c.readMinutes), short: "Read",
                 warnMinutes: c.readWarnMinutes, hint: readHint),
        ]
        for i in 1...n {
            out.append(Part(name: "Part \(i)", minutes: perPart, short: "Part \(i)",
                            warnMinutes: c.partWarnMinutes, hint: partHint))
        }
        out.append(Part(name: "Review + cleanup", minutes: max(0.1, c.reviewMinutes), short: "Review",
                        warnMinutes: c.reviewWarnMinutes, hint: reviewHint))
        return out
    }
}

struct SavedState: Codable {
    var remaining: [Double]
    var current: Int
    var savedAt: Date
}

// MARK: - Paths

enum Paths {
    static let dir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/timerbar", isDirectory: true)
    static var config: URL { dir.appendingPathComponent("config.json") }
    static var state: URL { dir.appendingPathComponent("state.json") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var config = Config()
    private var remaining: [TimeInterval] = []
    private var current = 0
    private var running = false
    private var lastTick = Date()
    private var warned: [Bool] = []

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var partItems: [NSMenuItem] = []
    private var isMenuOpen = false
    private var highlighted = false
    private var ticker: Timer?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Paths.ensureDir()
        loadConfig(writeDefaultIfMissing: true)
        restoreState()
        setupStatusItem()
        startTicker()
        if CommandLine.arguments.contains("--autostart") {
            running = true
            lastTick = Date()
        }
        updateTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startTicker() {
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common keeps the timer alive while the menu is open.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: Config

    private func loadConfig(writeDefaultIfMissing: Bool) {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else {
            config = Config()
            if writeDefaultIfMissing { writeConfig() }
            sanitizeConfig()
            materializeParts()
            return
        }
        do {
            let data = try Data(contentsOf: Paths.config)
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("TimerBar: could not read config (\(error)). Using defaults.")
            config = Config()
        }
        sanitizeConfig()
        materializeParts()
    }

    /// Turn the Read/work/review knobs into an actual part list.
    private func materializeParts() {
        if config.parts.isEmpty {
            config.parts = Config.generate(from: config)
            config.partsExplicit = false
        }
    }

    private func sanitizeConfig() {
        config.warnMinutes = max(0, config.warnMinutes)
        config.problemParts = max(1, min(8, config.problemParts))
        config.readMinutes = max(0.1, config.readMinutes)
        config.workMinutes = max(0.1, config.workMinutes)
        config.reviewMinutes = max(0.1, config.reviewMinutes)
        config.readWarnMinutes = max(0, config.readWarnMinutes)
        config.partWarnMinutes = max(0, config.partWarnMinutes)
        config.reviewWarnMinutes = max(0, config.reviewWarnMinutes)

        config.parts = config.parts.map { raw in
            var p = raw
            p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.name.isEmpty { p.name = "Part" }
            p.minutes = max(0.1, p.minutes)

            let short = p.short?.trimmingCharacters(in: .whitespacesAndNewlines)
            p.short = (short?.isEmpty ?? true) ? nil : short

            if let w = p.warnMinutes { p.warnMinutes = max(0, w) }

            let hint = p.hint?.trimmingCharacters(in: .whitespacesAndNewlines)
            p.hint = (hint?.isEmpty ?? true) ? nil : hint
            return p
        }
        // An empty `parts` array is intentional: it means "generate them".
    }

    /// Warning threshold for a part: its own `warnMinutes` if set, else the global one.
    /// A warning longer than the part itself would fire on the first tick, so fall back
    /// to halfway through the part.
    private func warnThreshold(_ i: Int) -> TimeInterval {
        guard i >= 0, i < config.parts.count else { return 0 }
        let part = config.parts[i]
        let configured = part.warnMinutes ?? config.warnMinutes
        let effective = configured >= part.minutes ? part.minutes / 2 : configured
        return max(0, effective * 60)
    }

    private func hint(for i: Int) -> String? {
        guard i >= 0, i < config.parts.count else { return nil }
        return config.parts[i].hint
    }

    private func menuBarLabel(_ i: Int) -> String {
        let raw = (config.parts[i].short ?? config.parts[i].name)
            .trimmingCharacters(in: .whitespaces)
        return raw.count <= 10 ? raw : String(raw.prefix(9)) + "\u{2026}"
    }

    private func minutesLabel(_ seconds: TimeInterval) -> String {
        let m = seconds / 60
        return m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m)
    }

    private func writeConfig() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: Paths.config)
        }
    }

    // MARK: State

    private func restoreState() {
        remaining = config.parts.map { max(0, $0.minutes * 60) }
        warned = Array(repeating: false, count: config.parts.count)
        current = 0

        guard let data = try? Data(contentsOf: Paths.state),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data),
              saved.remaining.count == config.parts.count,
              Date().timeIntervalSince(saved.savedAt) < 12 * 3600 else { return }

        remaining = zip(saved.remaining, config.parts).map { min(max(0, $0), $1.minutes * 60) }
        current = min(max(0, saved.current), config.parts.count - 1)
        running = false
        warned = remaining.indices.map { remaining[$0] <= warnThreshold($0) }
    }

    private func saveState() {
        let state = SavedState(remaining: remaining, current: current, savedAt: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(state) {
            try? data.write(to: Paths.state)
        }
    }

    // MARK: Tick

    private func tick() {
        let now = Date()
        if running {
            // Cap the delta so a stall/sleep can't wipe out a whole part.
            let dt = min(60, max(0, now.timeIntervalSince(lastTick)))
            lastTick = now
            if dt > 0 {
                remaining[current] = max(0, remaining[current] - dt)
                maybeWarn()
                if remaining[current] <= 0 { expireCurrent() }
            }
        } else {
            lastTick = now
        }
        updateTitle()
        if isMenuOpen { refreshPartItems() }
    }

    private func maybeWarn() {
        let threshold = warnThreshold(current)
        guard threshold > 0,
              remaining[current] > 0,
              remaining[current] <= threshold,
              !warned[current] else { return }
        warned[current] = true
        notify(title: "\(config.parts[current].name): \(minutesLabel(threshold)) left",
               body: "\(formatted(remaining[current])) remaining")
    }

    /// Show a part's checklist hint as a quiet notification (no beep).
    private func announceHintIfNeeded() {
        guard let h = hint(for: current) else { return }
        notify(title: config.parts[current].name, body: h, beep: false)
    }

    private func expireCurrent() {
        remaining[current] = 0
        running = false
        notify(title: "Time's up: \(config.parts[current].name)",
               body: "Move on to the next part.")

        if config.autoAdvance, current + 1 < config.parts.count {
            current += 1
            lastTick = Date()
            running = true
            let h = hint(for: current).map { " \($0)" } ?? ""
            notify(title: "Started \(config.parts[current].name)",
                   body: "\(formatted(remaining[current])) on the clock.\(h)",
                   beep: false)
        }
        saveState()
    }

    // MARK: Display

    private func updateTitle() {
        let r = max(0, remaining[current])
        let text = config.compact ? formatted(r) : "\(menuBarLabel(current)) \(formatted(r))"

        let color: NSColor
        if r <= 0 {
            color = .systemRed
        } else if r <= warnThreshold(current) {
            color = .systemOrange
        } else {
            color = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ]

        let title = NSMutableAttributedString()
        if running {
            // Live indicator: a green dot only while the clock is actually counting.
            title.append(NSAttributedString(string: "\u{25CF} ", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.systemGreen,
                .baselineOffset: 1.5,
            ]))
        }
        title.append(NSAttributedString(string: text, attributes: attrs))
        statusItem.button?.attributedTitle = title
        applyRunningHighlight()
    }

    /// Give the menu bar item the same "selected" pill look it gets when clicked,
    /// for as long as the timer is running.
    private func applyRunningHighlight() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        layer.cornerRadius = max(4, button.bounds.height / 2)
        guard running != highlighted else { return }
        highlighted = running
        layer.backgroundColor = running
            ? NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(max(0, seconds)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func partTitle(_ i: Int) -> String {
        "\(config.parts[i].name) — \(formatted(remaining[i])) left"
    }

    private func refreshPartItems() {
        for (i, item) in partItems.enumerated() {
            guard i < config.parts.count else { break }
            let color: NSColor
            if remaining[i] <= 0 {
                color = .systemRed
            } else if i == current {
                color = .labelColor
            } else {
                color = .secondaryLabelColor
            }
            item.attributedTitle = NSAttributedString(string: partTitle(i), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: i == current ? .semibold : .regular),
                .foregroundColor: color,
            ])
            item.state = (i == current) ? .on : .off
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func buildMenu() {
        menu.removeAllItems()
        partItems = []

        for i in config.parts.indices {
            let item = NSMenuItem(title: partTitle(i), action: #selector(selectPart(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = i
            item.state = (i == current) ? .on : .off
            menu.addItem(item)
            partItems.append(item)

            // Checklist hint for the active part, shown as a grey sub-line.
            if i == current, let h = hint(for: i) {
                let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                hintItem.isEnabled = false
                hintItem.attributedTitle = NSAttributedString(string: "   \(h)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                menu.addItem(hintItem)
            }
        }
        refreshPartItems()

        menu.addItem(.separator())
        add(running ? "Pause" : "Start \(config.parts[current].name)", #selector(toggleRun), "p")
        add("Skip to next part", #selector(nextPart), "n", enabled: current + 1 < config.parts.count)
        add("+1 min to current", #selector(extend(_:)), "", 1.0)
        add("+5 min to current", #selector(extend(_:)), "", 5.0)

        menu.addItem(.separator())
        addInfo("Total left: \(formatted(remaining.reduce(0, +)))")
        addInfo("Work: \(formatted(config.workMinutes * 60)) across \(config.problemParts) parts")
        for n in [3, 4] {
            add("\(n)-part problem (\(formatted(config.workMinutes / Double(n) * 60)) each)",
                #selector(setPartCount(_:)), "", n,
                state: config.problemParts == n ? .on : .off)
        }
        add("Auto-advance at 0:00", #selector(toggleAutoAdvance), "", state: config.autoAdvance ? .on : .off)
        add("Compact menu bar (time only)", #selector(toggleCompact), "", state: config.compact ? .on : .off)

        menu.addItem(.separator())
        add("Edit parts…", #selector(editConfig), "e")
        add("Reload parts (resets timers)", #selector(reloadParts), "r")
        add("Reset all timers", #selector(resetAll), "", enabled: true)

        menu.addItem(.separator())
        add("Quit TimerBar", #selector(quit), "q")
    }

    @discardableResult
    private func add(_ title: String,
                     _ action: Selector?,
                     _ key: String = "",
                     _ obj: Any? = nil,
                     enabled: Bool = true,
                     state: NSControl.StateValue = .off) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil { item.target = self }
        item.representedObject = obj
        item.isEnabled = (action != nil) && enabled
        item.state = state
        menu.addItem(item)
        return item
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func selectPart(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int,
              i >= 0, i < config.parts.count else { return }
        current = i
        lastTick = Date()
        if remaining[current] <= 0 { running = false }
        warned[current] = remaining[current] <= warnThreshold(current)
        saveState()
        updateTitle()
    }

    @objc private func toggleRun() {
        if running {
            running = false
        } else {
            let fresh = abs(remaining[current] - config.parts[current].minutes * 60) < 0.5
            if remaining[current] <= 0 {
                if current + 1 < config.parts.count {
                    current += 1
                } else {
                    remaining[current] = config.parts[current].minutes * 60
                    warned[current] = false
                }
            }
            running = true
            lastTick = Date()
            // Only surface the checklist when a part is being started from the top.
            if fresh { announceHintIfNeeded() }
        }
        lastTick = Date()
        saveState()
        updateTitle()
    }

    @objc private func nextPart() {
        guard current + 1 < config.parts.count else { return }
        current += 1
        lastTick = Date()
        if remaining[current] <= 0 { running = false }
        announceHintIfNeeded()
        saveState()
        updateTitle()
    }

    @objc private func extend(_ sender: NSMenuItem) {
        let mins = (sender.representedObject as? Double) ?? 5
        remaining[current] += mins * 60
        warned[current] = false
        saveState()
        updateTitle()
    }

    @objc private func toggleAutoAdvance() {
        config.autoAdvance.toggle()
        writeConfig()
    }

    /// Switch between a 3-part and 4-part problem without losing time already spent.
    @objc private func setPartCount(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int,
              n != config.problemParts else { return }

        let total = config.parts.reduce(0) { $0 + $1.minutes * 60 }
        let elapsed = max(0, total - remaining.reduce(0, +))

        config.problemParts = max(1, min(8, n))
        config.partsExplicit = false
        config.parts = Config.generate(from: config)
        applyPartsKeepingElapsed(elapsed)
        writeConfig()
        saveState()
        updateTitle()

        notify(title: "Split: \(config.problemParts) parts",
               body: "\(formatted(config.workMinutes / Double(config.problemParts) * 60)) each, \(formatted(remaining.reduce(0, +))) left overall.",
               beep: false)
    }

    /// Rebuild `remaining` for a new part list, consuming the time already spent
    /// from the front so the clock doesn't jump backwards.
    private func applyPartsKeepingElapsed(_ elapsed: TimeInterval) {
        let durations = config.parts.map { max(0, $0.minutes * 60) }
        remaining = durations
        warned = Array(repeating: false, count: config.parts.count)

        var left = elapsed
        var idx = 0
        for i in durations.indices {
            if left >= durations[i] {
                left -= durations[i]
                remaining[i] = 0
                idx = i
            } else {
                remaining[i] = durations[i] - left
                left = 0
                idx = i
                break
            }
        }

        // Land on the part that's actually in play.
        if remaining[idx] <= 0, idx + 1 < config.parts.count { idx += 1 }
        current = idx
        warned = remaining.indices.map { remaining[$0] <= warnThreshold($0) }
        lastTick = Date()
        if remaining[current] <= 0 { running = false }
    }

    @objc private func toggleCompact() {
        config.compact.toggle()
        writeConfig()
        updateTitle()
    }

    @objc private func editConfig() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) { writeConfig() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-e", Paths.config.path]
        try? p.run()
    }

    @objc private func reloadParts() {
        loadConfig(writeDefaultIfMissing: true)
        remaining = config.parts.map { max(0, $0.minutes * 60) }
        warned = Array(repeating: false, count: config.parts.count)
        current = 0
        running = false
        lastTick = Date()
        saveState()
        updateTitle()
    }

    @objc private func resetAll() {
        remaining = config.parts.map { max(0, $0.minutes * 60) }
        warned = Array(repeating: false, count: config.parts.count)
        current = 0
        running = false
        lastTick = Date()
        saveState()
        updateTitle()
    }

    @objc private func quit() {
        saveState()
        NSApp.terminate(nil)
    }

    // MARK: Notifications

    private func notify(title: String, body: String, beep: Bool = true) {
        if beep { NSSound.beep() }
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")
        let safeBody = body.replacingOccurrences(of: "\"", with: "'")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(safeBody)\" with title \"\(safeTitle)\""]
        try? p.run()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
