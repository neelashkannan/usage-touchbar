import AppKit
import Foundation
import Security

/// A structured, real-data snapshot of a provider's usage.
///
/// `dailyPercent` / `weeklyPercent` are the share of the rolling primary
/// (5-hour) and secondary (weekly) limit windows that have been consumed.
struct UsageSnapshot: Sendable {
    let provider: Provider
    let isConnected: Bool
    let dailyPercent: Double?
    let weeklyPercent: Double?
    let dailyResetAt: Date?
    let weeklyResetAt: Date?
    let totalTokens: Int?
    let planLabel: String?
    let updatedAt: Date
    let error: String?

    static func disconnected(_ provider: Provider) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            isConnected: false,
            dailyPercent: nil,
            weeklyPercent: nil,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            totalTokens: nil,
            planLabel: nil,
            updatedAt: Date(),
            error: "Login required"
        )
    }

    static func failure(_ provider: Provider, message: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            isConnected: true,
            dailyPercent: nil,
            weeklyPercent: nil,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            totalTokens: nil,
            planLabel: nil,
            updatedAt: Date(),
            error: message
        )
    }
}

enum Provider: String, CaseIterable, Sendable {
    case claude = "Claude"
    case codex = "Codex"

    var symbol: String { rawValue }

    var loginURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/login")!
        case .codex: URL(string: "https://chatgpt.com/codex")!
        }
    }

    var accentColor: NSColor {
        switch self {
        case .claude: NSColor(calibratedRed: 0.85, green: 0.49, blue: 0.30, alpha: 1)
        case .codex: NSColor(calibratedWhite: 0.92, alpha: 1)
        }
    }
}

enum UsageFormat {
    /// Color graded by how much of a limit is consumed.
    static func color(forPercent percent: Double) -> NSColor {
        switch percent {
        case ..<60: NSColor.systemGreen
        case ..<85: NSColor.systemOrange
        default: NSColor.systemRed
        }
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func tokenText(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct AuthState {
    let connectedProviders: Set<Provider>

    var requiresLogin: Bool {
        !Provider.allCases.allSatisfy { connectedProviders.contains($0) }
    }

    func isConnected(_ provider: Provider) -> Bool {
        connectedProviders.contains(provider)
    }
}

enum AuthDetector {
    static func current() -> AuthState {
        AuthState(connectedProviders: Set(Provider.allCases.filter { provider in
            authPaths(for: provider).contains { FileManager.default.fileExists(atPath: expand($0)) }
        }))
    }

    static func authPaths(for provider: Provider) -> [String] {
        switch provider {
        case .codex:
            [
                "~/.codex/auth.json",
                "~/.codex/config.toml"
            ]
        case .claude:
            [
                "~/.claude.json",
                "~/.claude/.credentials.json",
                "~/.claude/config.json",
                "~/.config/claude/credentials.json"
            ]
        }
    }

    private static func expand(_ path: String) -> String {
        path.replacingOccurrences(
            of: "~",
            with: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

protocol UsageCollecting: Sendable {
    var provider: Provider { get }
    func collect() async -> UsageSnapshot
}

final class UsageStore: @unchecked Sendable {
    private let collectors: [UsageCollecting]
    private let queue = DispatchQueue(label: "UsageTouchBar.UsageStore")
    private var snapshots: [Provider: UsageSnapshot] = [:]

    init(collectors: [UsageCollecting]) {
        self.collectors = collectors
    }

    func currentSnapshots() -> [UsageSnapshot] {
        queue.sync {
            Provider.allCases.compactMap { snapshots[$0] }
        }
    }

    func refresh() async -> [UsageSnapshot] {
        let collected = await withTaskGroup(of: UsageSnapshot.self) { group in
            for collector in collectors {
                group.addTask { await collector.collect() }
            }

            var results: [UsageSnapshot] = []
            for await snapshot in group {
                results.append(snapshot)
            }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }

        queue.sync {
            for snapshot in collected {
                snapshots[snapshot.provider] = snapshot
            }
        }

        return currentSnapshots()
    }
}

/// Shared helpers for locating and reading provider data files.
enum DataFiles {
    static func home() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func expand(_ path: String) -> String {
        path.replacingOccurrences(of: "~", with: home())
    }

    /// Returns regular files under `directory` (recursively) sorted newest first.
    static func recentFiles(
        in directory: String,
        extensions: Set<String>,
        modifiedAfter: Date? = nil,
        maxInspected: Int = 5_000
    ) -> [URL] {
        let root = URL(fileURLWithPath: directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [(URL, Date)] = []
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > maxInspected { break }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if let cutoff = modifiedAfter, modified < cutoff { continue }
            matches.append((url, modified))
        }

        return matches.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Streams a file line by line without loading the whole file into memory.
    static func forEachLine(in url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = UInt8(ascii: "\n")
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { return false }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    body(line)
                }
            }
            return true
        }) {}

        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            body(line)
        }
    }
}

/// Reads Codex's real rate-limit + token telemetry from its session rollout files.
///
/// Codex writes `token_count` events into `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl`.
/// Each event carries `rate_limits.primary` (5-hour window) and `rate_limits.secondary`
/// (weekly window) with `used_percent` + `resets_at`, plus cumulative token totals.
struct CodexUsageCollector: UsageCollecting {
    let provider: Provider = .codex

    private struct Window: Decodable {
        let used_percent: Double
        let resets_at: Double?
    }
    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }
    private struct TokenUsage: Decodable {
        let total_tokens: Int?
    }
    private struct Info: Decodable {
        let total_token_usage: TokenUsage?
    }
    private struct TokenCountPayload: Decodable {
        let type: String
        let info: Info?
        let rate_limits: RateLimits?
    }
    private struct Event: Decodable {
        let timestamp: String?
        let payload: TokenCountPayload?
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.codex) else {
            return .disconnected(.codex)
        }

        let sessionsDir = DataFiles.expand("~/.codex/sessions")
        let files = DataFiles.recentFiles(in: sessionsDir, extensions: ["jsonl"]).prefix(12)
        guard !files.isEmpty else {
            return .failure(.codex, message: "No Codex sessions found")
        }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var best: (date: Date, event: TokenCountPayload)?

        // The most recently modified rollout holds the freshest account-wide
        // rate limits; scan a few in case the newest has no token_count yet.
        for file in files {
            DataFiles.forEachLine(in: file) { line in
                guard line.contains("\"token_count\"") else { return }
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(Event.self, from: data),
                      let payload = event.payload, payload.type == "token_count",
                      payload.rate_limits != nil else { return }
                let date = event.timestamp.flatMap { isoFormatter.date(from: $0) } ?? Date.distantPast
                if best == nil || date > best!.date {
                    best = (date, payload)
                }
            }
            if best != nil { break }
        }

        guard let result = best, let limits = result.event.rate_limits else {
            return .failure(.codex, message: "No usage telemetry yet")
        }

        return UsageSnapshot(
            provider: .codex,
            isConnected: true,
            dailyPercent: limits.primary?.used_percent,
            weeklyPercent: limits.secondary?.used_percent,
            dailyResetAt: limits.primary?.resets_at.map { Date(timeIntervalSince1970: $0) },
            weeklyResetAt: limits.secondary?.resets_at.map { Date(timeIntervalSince1970: $0) },
            totalTokens: result.event.info?.total_token_usage?.total_tokens,
            planLabel: limits.plan_type.map { $0.capitalized },
            updatedAt: result.date == .distantPast ? Date() : result.date,
            error: nil
        )
    }
}

/// Optional user configuration for the Claude token-budget estimate.
///
/// Anthropic does not publish exact token limits for Claude Code (they are
/// session/weekly based and shared with the web app), so the percentage shown
/// for Claude is an estimate against these budgets. Override them by creating
/// `~/.config/usage-touchbar/config.json`:
///
///     { "claudeFiveHourTokenBudget": 90000000, "claudeWeeklyTokenBudget": 440000000, "claudePlanLabel": "Max 20x" }
struct AppConfig: Decodable {
    var claudeFiveHourTokenBudget: Int?
    var claudeWeeklyTokenBudget: Int?
    var claudePlanLabel: String?

    static let shared = load()

    private static func load() -> AppConfig {
        let path = DataFiles.expand("~/.config/usage-touchbar/config.json")
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }
}

/// Reads Claude's OAuth credentials from the macOS Keychain, where Claude Code
/// stores them under the generic-password service `Claude Code-credentials`.
enum ClaudeCredentials {
    struct OAuth: Decodable {
        let accessToken: String
        let subscriptionType: String?
    }

    static func current() -> OAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        struct Wrapper: Decodable { let claudeAiOauth: OAuth }
        return try? JSONDecoder().decode(Wrapper.self, from: data).claudeAiOauth
    }
}

/// Reads Claude Code's **live** usage limits from the same endpoint the CLI's
/// `/usage` command uses: `GET https://api.anthropic.com/api/oauth/usage`.
///
/// This returns the real `five_hour` and `seven_day` utilization percentages and
/// reset times for the signed-in plan. If the API is unreachable (offline, token
/// expired), it falls back to a local token-throughput estimate parsed from
/// `~/.claude/projects/**/*.jsonl`.
struct ClaudeUsageCollector: UsageCollecting {
    let provider: Provider = .claude

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private struct Window: Decodable {
        let utilization: Double
        let resets_at: String?
    }
    private struct LiveUsage: Decodable {
        let five_hour: Window?
        let seven_day: Window?
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.claude) else {
            return .disconnected(.claude)
        }

        if let live = await liveSnapshot() {
            return live
        }
        return estimatedSnapshot()
    }

    // MARK: - Live API

    private func liveSnapshot() async -> UsageSnapshot? {
        guard let credentials = ClaudeCredentials.current() else { return nil }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 8
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let usage = try? JSONDecoder().decode(LiveUsage.self, from: data) else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parseDate: (String?) -> Date? = { stamp in
            guard let stamp else { return nil }
            return isoFormatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }

        let plan = credentials.subscriptionType
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }

        return UsageSnapshot(
            provider: .claude,
            isConnected: true,
            dailyPercent: usage.five_hour?.utilization,
            weeklyPercent: usage.seven_day?.utilization,
            dailyResetAt: parseDate(usage.five_hour?.resets_at),
            weeklyResetAt: parseDate(usage.seven_day?.resets_at),
            totalTokens: nil,
            planLabel: plan,
            updatedAt: Date(),
            error: nil
        )
    }

    // MARK: - Local fallback estimate

    /// Estimated total-token budgets for the rolling windows. Defaults are tuned
    /// for a heavy Max plan; override via `~/.config/usage-touchbar/config.json`.
    private var fiveHourTokenBudget: Int { AppConfig.shared.claudeFiveHourTokenBudget ?? 90_000_000 }
    private var weeklyTokenBudget: Int { AppConfig.shared.claudeWeeklyTokenBudget ?? 440_000_000 }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
    private struct Message: Decodable {
        let usage: Usage?
    }
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private func estimatedSnapshot() -> UsageSnapshot {
        let projectsDir = DataFiles.expand("~/.claude/projects")
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)

        let files = DataFiles.recentFiles(in: projectsDir, extensions: ["jsonl"], modifiedAfter: weekAgo)
        guard !files.isEmpty else {
            return .failure(.claude, message: "Offline — no cached usage")
        }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var fiveHourTokens = 0
        var weeklyTokens = 0
        var oldestFiveHour: Date?
        var oldestWeekly: Date?
        var latest = Date.distantPast

        for file in files {
            DataFiles.forEachLine(in: file) { line in
                guard line.contains("\"usage\"") else { return }
                guard let data = line.data(using: .utf8),
                      let parsed = try? decoder.decode(Line.self, from: data),
                      parsed.type == "assistant",
                      let usage = parsed.message?.usage,
                      let stamp = parsed.timestamp,
                      let date = isoFormatter.date(from: stamp) else { return }

                // Total throughput, including cache reads — this is the figure
                // users recognize from Claude's `/usage`.
                let tokens = (usage.input_tokens ?? 0)
                    + (usage.output_tokens ?? 0)
                    + (usage.cache_creation_input_tokens ?? 0)
                    + (usage.cache_read_input_tokens ?? 0)
                guard tokens > 0 else { return }

                if date >= weekAgo {
                    weeklyTokens += tokens
                    latest = max(latest, date)
                    if oldestWeekly == nil || date < oldestWeekly! { oldestWeekly = date }
                }
                if date >= fiveHoursAgo {
                    fiveHourTokens += tokens
                    if oldestFiveHour == nil || date < oldestFiveHour! { oldestFiveHour = date }
                }
            }
        }

        guard weeklyTokens > 0 else {
            return .failure(.claude, message: "No usage in the last 7 days")
        }

        let dailyPercent = min(100, Double(fiveHourTokens) / Double(fiveHourTokenBudget) * 100)
        let weeklyPercent = min(100, Double(weeklyTokens) / Double(weeklyTokenBudget) * 100)

        return UsageSnapshot(
            provider: .claude,
            isConnected: true,
            dailyPercent: dailyPercent,
            weeklyPercent: weeklyPercent,
            dailyResetAt: oldestFiveHour?.addingTimeInterval(5 * 3600),
            weeklyResetAt: oldestWeekly?.addingTimeInterval(7 * 24 * 3600),
            totalTokens: weeklyTokens,
            planLabel: AppConfig.shared.claudePlanLabel ?? "est.",
            updatedAt: latest == .distantPast ? now : latest,
            error: nil
        )
    }
}

@MainActor
final class TouchBarHostPanel: NSPanel {
    weak var touchBarController: TouchBarController?

    init(touchBarController: TouchBarController) {
        self.touchBarController = touchBarController

        let rect = NSRect(x: 0, y: 0, width: 320, height: 84)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        title = "Usage Touch Bar"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentViewController = TouchBarHostViewController()
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func makeTouchBar() -> NSTouchBar? {
        touchBarController?.makeTouchBar()
    }
}

@MainActor
final class TouchBarHostViewController: NSViewController {
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))

        let label = NSTextField(wrappingLabelWithString: "Keep this small window focused to show Usage Touch Bar controls.")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        self.view = view
    }
}

@MainActor
final class LoginViewController: NSViewController {
    private let onRefresh: () -> Void
    private let stack = NSStackView()

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    func reload() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: "Connect Accounts")
        title.font = .boldSystemFont(ofSize: 17)
        stack.addArrangedSubview(title)

        let note = NSTextField(wrappingLabelWithString: "Usage Touch Bar needs local Codex and Claude Code login state before it shows provider usage.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let auth = AuthDetector.current()
        for provider in Provider.allCases {
            stack.addArrangedSubview(row(provider: provider, connected: auth.isConnected(provider)))
        }

        let refresh = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        stack.addArrangedSubview(refresh)
    }

    private func row(provider: Provider, connected: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let icon = ProviderLogoView(provider: provider, selected: connected)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        row.addArrangedSubview(icon)

        let label = NSTextField(labelWithString: "\(provider.rawValue): \(connected ? "connected" : "login required")")
        label.font = .systemFont(ofSize: 13)
        label.textColor = connected ? .labelColor : .systemOrange
        row.addArrangedSubview(label)

        let spacer = NSView()
        row.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: connected ? "Open" : "Login", target: self, action: #selector(openLogin(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
        row.addArrangedSubview(button)

        return row
    }

    @objc private func checkAgain() {
        onRefresh()
        reload()
    }

    @objc private func openLogin(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let provider = Provider(rawValue: raw) else {
            return
        }
        NSWorkspace.shared.open(provider.loginURL)
    }
}

final class ProviderLogoView: NSView {
    private let provider: Provider
    private let selected: Bool

    init(provider: Provider, selected: Bool) {
        self.provider = provider
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 32, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        let fill: NSColor
        let stroke: NSColor
        switch provider {
        case .codex:
            fill = selected ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.28, alpha: 1)
            stroke = NSColor(calibratedWhite: 0.78, alpha: 1)
        case .claude:
            fill = selected ? NSColor(calibratedRed: 0.63, green: 0.35, blue: 0.20, alpha: 1) : NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.25, alpha: 1)
            stroke = NSColor(calibratedRed: 0.86, green: 0.73, blue: 0.58, alpha: 1)
        }

        fill.setFill()
        stroke.setStroke()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        path.lineWidth = selected ? 2 : 1
        path.fill()
        path.stroke()

        let text = provider == .codex ? "CX" : "CL"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 10),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

/// A compact inline gauge sized to fit the ~30pt Touch Bar strip:
/// `5h ▓▓▓░ 19%` on a single vertically-centered line.
final class UsageBarView: NSView {
    private let caption: String
    private let percent: Double?
    private let trailing: String

    init(caption: String, percent: Double?, trailing: String) {
        self.caption = caption
        self.percent = percent
        self.trailing = trailing
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 108, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]

        let midY = bounds.height / 2
        let captionSize = caption.size(withAttributes: captionAttrs)
        caption.draw(at: NSPoint(x: 0, y: midY - captionSize.height / 2), withAttributes: captionAttrs)

        let valueSize = trailing.size(withAttributes: valueAttrs)
        trailing.draw(
            at: NSPoint(x: bounds.maxX - valueSize.width, y: midY - valueSize.height / 2),
            withAttributes: valueAttrs
        )

        let barX = captionSize.width + 6
        let barWidth = bounds.maxX - valueSize.width - 6 - barX
        guard barWidth > 6 else { return }

        let barHeight: CGFloat = 6
        let barRect = NSRect(x: barX, y: midY - barHeight / 2, width: barWidth, height: barHeight)
        let track = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor(white: 0.34, alpha: 1).setFill()
        track.fill()

        guard let percent else { return }
        let clamped = max(0, min(100, percent))
        let fillWidth = max(barHeight, barWidth * CGFloat(clamped / 100))
        let fillRect = NSRect(x: barX, y: barRect.minY, width: fillWidth, height: barHeight)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        UsageFormat.color(forPercent: clamped).setFill()
        fill.fill()
    }
}


/// Pins a Touch Bar item to the always-visible **Control Strip** region so usage
/// is shown by default, regardless of which app is frontmost.
///
/// macOS exposes no public API for persistent Control Strip items, so this wraps
/// the private `DFRFoundation` functions and the private `NSTouchBarItem`
/// system-tray selectors that ship in every modern macOS. All calls are guarded
/// with `responds(to:)`/`dlsym` so an OS that drops these stays crash-free.
@MainActor
enum ControlStrip {
    private typealias PresenceFn = @convention(c) (NSString, Bool) -> Void
    private typealias CloseBoxFn = @convention(c) (Bool) -> Void

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation",
        RTLD_NOW
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Whether the running OS still exposes the Control Strip private API.
    static var isSupported: Bool {
        (NSTouchBarItem.self as AnyObject).responds(to: NSSelectorFromString("addSystemTrayItem:"))
    }

    /// Adds an item to the persistent Control Strip and marks it present.
    static func add(_ item: NSTouchBarItem) {
        let sel = NSSelectorFromString("addSystemTrayItem:")
        guard (NSTouchBarItem.self as AnyObject).responds(to: sel) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(sel, with: item)
        setPresent(item.identifier, true)
    }

    /// Removes a previously added Control Strip item.
    static func remove(_ item: NSTouchBarItem) {
        setPresent(item.identifier, false)
        let sel = NSSelectorFromString("removeSystemTrayItem:")
        guard (NSTouchBarItem.self as AnyObject).responds(to: sel) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(sel, with: item)
    }

    private static func setPresent(_ identifier: NSTouchBarItem.Identifier, _ present: Bool) {
        symbol("DFRElementSetControlStripPresenceForIdentifier", as: PresenceFn.self)?(
            identifier.rawValue as NSString, present
        )
    }

    /// Expands the given Touch Bar over the whole strip (system modal), anchored
    /// to the Control Strip item the user tapped.
    static func presentModal(_ touchBar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) {
        symbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: CloseBoxFn.self)?(true)
        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
        ]
        for name in selectors {
            let sel = NSSelectorFromString(name)
            if (NSTouchBar.self as AnyObject).responds(to: sel) {
                _ = (NSTouchBar.self as AnyObject).perform(sel, with: touchBar, with: trayIdentifier.rawValue)
                return
            }
        }
    }

    /// Dismisses a previously presented system-modal Touch Bar.
    static func dismissModal(_ touchBar: NSTouchBar) {
        for name in ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
            let sel = NSSelectorFromString(name)
            if (NSTouchBar.self as AnyObject).responds(to: sel) {
                _ = (NSTouchBar.self as AnyObject).perform(sel, with: touchBar)
                return
            }
        }
    }
}

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let codexIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.codex")
    static let claudeIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.claude")
    static let detailIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.detail")
    static let refreshIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.refresh")
    static let controlStripIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.controlStrip")

    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let touchBar = NSTouchBar()
    private let popover = NSPopover()
    private let loginWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private lazy var hostPanel = TouchBarHostPanel(touchBarController: self)
    private weak var detailItem: NSCustomTouchBarItem?
    private weak var codexButton: NSButton?
    private weak var claudeButton: NSButton?
    private var controlStripItem: NSCustomTouchBarItem?
    private weak var controlStripButton: NSButton?
    private var selectedProvider: Provider = .codex
    private var authState = AuthDetector.current()
    private var timer: Timer?

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configureTouchBar()
        configurePopover()
        configureLoginWindow()
    }

    func start() {
        NSApp.touchBar = touchBar
        installControlStripItem()
        showLoginIfNeeded()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func makeTouchBar() -> NSTouchBar {
        touchBar
    }

    /// Removes the persistent Control Strip item before the app exits.
    func stop() {
        timer?.invalidate()
        timer = nil
        teardownControlStripItem()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.codexIdentifier:
            return providerButtonItem(identifier: identifier, provider: .codex)
        case Self.claudeIdentifier:
            return providerButtonItem(identifier: identifier, provider: .claude)
        case Self.detailIdentifier:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = makeDetailView()
            detailItem = item
            return item
        case Self.refreshIdentifier:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "Refresh", target: self, action: #selector(refreshButtonPressed))
            button.bezelColor = .controlAccentColor
            item.view = button
            return item
        default:
            return nil
        }
    }

    private func configureStatusItem() {
        statusItem.button?.title = "Usage"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshButtonPressed), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let showItem = NSMenuItem(title: "Show Usage", action: #selector(togglePopover), keyEquivalent: "u")
        showItem.target = self
        menu.addItem(showItem)

        let loginItem = NSMenuItem(title: "Connect Accounts", action: #selector(showLoginWindow), keyEquivalent: "l")
        loginItem.target = self
        menu.addItem(loginItem)

        let focusItem = NSMenuItem(title: "Focus Touch Bar", action: #selector(focusTouchBarHost), keyEquivalent: "t")
        focusItem.target = self
        menu.addItem(focusItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Usage Touch Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func configureTouchBar() {
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.codexIdentifier, Self.claudeIdentifier, Self.detailIdentifier, Self.refreshIdentifier]
        touchBar.customizationAllowedItemIdentifiers = [Self.codexIdentifier, Self.claudeIdentifier, Self.detailIdentifier, Self.refreshIdentifier]
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("UsageTouchBar.default")
        touchBar.principalItemIdentifier = Self.detailIdentifier
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 240)
        popover.contentViewController = UsageViewController(store: store)
    }

    private func configureLoginWindow() {
        loginWindow.title = "Usage Touch Bar"
        loginWindow.isReleasedWhenClosed = false
        loginWindow.center()
        loginWindow.contentViewController = LoginViewController { [weak self] in
            self?.refreshAuthState()
        }
    }

    private func providerButtonItem(identifier: NSTouchBarItem.Identifier, provider: Provider) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(title: "", target: self, action: #selector(providerButtonPressed(_:)))
        button.image = makeLogoImage(provider: provider, selected: provider == selectedProvider)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.toolTip = provider.rawValue
        button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
        item.view = button
        if provider == .codex {
            codexButton = button
        } else {
            claudeButton = button
        }
        return item
    }

    private func makeLogoImage(provider: Provider, selected: Bool) -> NSImage {
        let view = ProviderLogoView(provider: provider, selected: selected)
        view.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func makeDetailView() -> NSView {
        let snapshots = Dictionary(uniqueKeysWithValues: store.currentSnapshots().map { ($0.provider, $0) })
        let snapshot = snapshots[selectedProvider]

        // A single horizontal row sized to the Touch Bar strip height (~30pt).
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        // Provider name (+ plan) at the left.
        let title = NSStackView()
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 0
        title.addArrangedSubview(label(selectedProvider.symbol, color: selectedProvider.accentColor, bold: true, size: 13))
        if let plan = snapshot?.planLabel {
            title.addArrangedSubview(label(plan.uppercased(), color: .tertiaryLabelColor, bold: false, size: 8))
        }
        row.addArrangedSubview(title)

        if let snapshot, snapshot.error == nil {
            row.addArrangedSubview(bar(
                caption: "5h",
                percent: snapshot.dailyPercent,
                trailing: UsageFormat.percentText(snapshot.dailyPercent)
            ))
            row.addArrangedSubview(bar(
                caption: "Wk",
                percent: snapshot.weeklyPercent,
                trailing: UsageFormat.percentText(snapshot.weeklyPercent)
            ))

            let reset = UsageFormat.resetText(snapshot.dailyResetAt ?? snapshot.weeklyResetAt)
            if reset != "—" {
                row.addArrangedSubview(label("↻ \(reset)", color: .secondaryLabelColor, bold: false, size: 10))
            }
        } else {
            let message = snapshot?.error ?? "Loading…"
            row.addArrangedSubview(label(message, color: .systemOrange, bold: false, size: 11))
        }

        // Wrap in a rounded card that fills the strip height.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        container.layer?.cornerRadius = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func bar(caption: String, percent: Double?, trailing: String) -> UsageBarView {
        let view = UsageBarView(caption: caption, percent: percent, trailing: trailing)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 108).isActive = true
        view.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return view
    }

    private func label(_ text: String, color: NSColor, bold: Bool, size: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = color
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    private func refreshTouchBar() {
        refreshAuthState()
        detailItem?.view = makeDetailView()
        controlStripButton?.attributedTitle = controlStripTitle()
        touchBar.defaultItemIdentifiers = [Self.codexIdentifier, Self.claudeIdentifier, Self.detailIdentifier, Self.refreshIdentifier]
        statusItem.button?.title = statusTitle()
        (popover.contentViewController as? UsageViewController)?.reload()
    }

    private func statusTitle() -> String {
        let snapshots = store.currentSnapshots()
        guard !snapshots.isEmpty else { return "Usage" }
        let parts = snapshots.map { snapshot -> String in
            if snapshot.error != nil { return "\(snapshot.provider.symbol) –" }
            return "\(snapshot.provider.symbol) \(UsageFormat.percentText(snapshot.dailyPercent))"
        }
        return parts.joined(separator: "  ")
    }

    @objc private func refreshButtonPressed() {
        refresh()
    }

    @objc private func providerButtonPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let provider = Provider(rawValue: raw) else {
            return
        }

        selectedProvider = provider
        codexButton?.image = makeLogoImage(provider: .codex, selected: selectedProvider == .codex)
        claudeButton?.image = makeLogoImage(provider: .claude, selected: selectedProvider == .claude)
        detailItem?.view = makeDetailView()
        touchBar.defaultItemIdentifiers = [Self.codexIdentifier, Self.claudeIdentifier, Self.detailIdentifier, Self.refreshIdentifier]
        showLoginIfNeeded()
    }

    private func installControlStripItem() {
        guard ControlStrip.isSupported else {
            // macOS without the private Control Strip API: fall back to the
            // focusable host panel so the bar is still reachable.
            focusTouchBarHost()
            return
        }

        let item = NSCustomTouchBarItem(identifier: Self.controlStripIdentifier)
        let button = NSButton(title: "", target: self, action: #selector(controlStripTapped))
        button.isBordered = false
        button.imagePosition = .noImage
        button.attributedTitle = controlStripTitle()
        item.view = button

        controlStripItem = item
        controlStripButton = button
        ControlStrip.add(item)
    }

    /// Compact, always-visible summary shown directly in the Control Strip, e.g.
    /// `CX 19%  CL 35%`, with each provider tinted by its accent and usage color.
    private func controlStripTitle() -> NSAttributedString {
        let snapshots = store.currentSnapshots()
        let result = NSMutableAttributedString()
        guard !snapshots.isEmpty else {
            return NSAttributedString(
                string: "Usage",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium)
                ]
            )
        }

        for (index, snapshot) in snapshots.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  "))
            }
            result.append(NSAttributedString(
                string: snapshot.provider.symbol + " ",
                attributes: [
                    .foregroundColor: snapshot.provider.accentColor,
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
                ]
            ))
            let text = snapshot.error == nil ? UsageFormat.percentText(snapshot.dailyPercent) : "–"
            let color = snapshot.error == nil
                ? UsageFormat.color(forPercent: snapshot.dailyPercent ?? 0)
                : NSColor.systemGray
            result.append(NSAttributedString(
                string: text,
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium)
                ]
            ))
        }
        return result
    }

    @objc private func controlStripTapped() {
        // Tap the always-on summary to expand the full usage bar over the strip.
        ControlStrip.presentModal(touchBar, trayIdentifier: Self.controlStripIdentifier)
    }

    private func teardownControlStripItem() {
        guard let item = controlStripItem else { return }
        ControlStrip.remove(item)
        controlStripItem = nil
        controlStripButton = nil
    }

    @objc private func focusTouchBarHost() {
        if let screen = NSScreen.main {
            let frame = hostPanel.frame
            let visible = screen.visibleFrame
            hostPanel.setFrameOrigin(NSPoint(
                x: visible.maxX - frame.width - 24,
                y: visible.maxY - frame.height - 24
            ))
        }

        hostPanel.makeKeyAndOrderFront(nil)
        hostPanel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showLoginWindow() {
        (loginWindow.contentViewController as? LoginViewController)?.reload()
        loginWindow.center()
        loginWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showLoginIfNeeded() {
        refreshAuthState()
        if authState.requiresLogin {
            showLoginWindow()
        }
    }

    private func refreshAuthState() {
        authState = AuthDetector.current()
    }

    private func refresh() {
        Task {
            _ = await store.refresh()
            await MainActor.run {
                self.refreshTouchBar()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            (popover.contentViewController as? UsageViewController)?.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

@MainActor
final class UsageViewController: NSViewController {
    private let store: UsageStore
    private let stack = NSStackView()
    private let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(store: UsageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 190))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    func reload() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: "Usage Touch Bar")
        title.font = .boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(title)

        let snapshots = store.currentSnapshots()
        if snapshots.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "Loading provider usage..."))
            return
        }

        for snapshot in snapshots {
            stack.addArrangedSubview(row(for: snapshot))
        }
    }

    private func row(for snapshot: UsageSnapshot) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6

        let headline = NSTextField(labelWithString: snapshot.provider.rawValue)
        headline.font = .boldSystemFont(ofSize: 14)
        headline.textColor = snapshot.error == nil ? .labelColor : .systemOrange
        titleRow.addArrangedSubview(headline)

        if let plan = snapshot.planLabel {
            let planLabel = NSTextField(labelWithString: plan)
            planLabel.font = .systemFont(ofSize: 11)
            planLabel.textColor = .tertiaryLabelColor
            titleRow.addArrangedSubview(planLabel)
        }
        container.addArrangedSubview(titleRow)

        if let error = snapshot.error {
            let errorLabel = NSTextField(wrappingLabelWithString: error)
            errorLabel.font = .systemFont(ofSize: 12)
            errorLabel.textColor = .systemOrange
            container.addArrangedSubview(errorLabel)
        } else {
            let reset = UsageFormat.resetText(snapshot.dailyResetAt ?? snapshot.weeklyResetAt)
            let daily = NSTextField(labelWithString:
                "5-hour window: \(UsageFormat.percentText(snapshot.dailyPercent))  ·  resets in \(reset)")
            daily.font = .systemFont(ofSize: 12)
            daily.textColor = .labelColor
            container.addArrangedSubview(daily)

            let weekly = NSTextField(labelWithString:
                "Weekly: \(UsageFormat.percentText(snapshot.weeklyPercent))  ·  \(UsageFormat.tokenText(snapshot.totalTokens)) tokens")
            weekly.font = .systemFont(ofSize: 12)
            weekly.textColor = .secondaryLabelColor
            container.addArrangedSubview(weekly)

            let updated = formatter.localizedString(for: snapshot.updatedAt, relativeTo: Date())
            let updatedLabel = NSTextField(labelWithString: "updated \(updated)")
            updatedLabel.font = .systemFont(ofSize: 10)
            updatedLabel.textColor = .tertiaryLabelColor
            container.addArrangedSubview(updatedLabel)
        }

        return container
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TouchBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let collectors: [UsageCollecting] = [
            ClaudeUsageCollector(),
            CodexUsageCollector()
        ]

        let controller = TouchBarController(store: UsageStore(collectors: collectors))
        self.controller = controller
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
