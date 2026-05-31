import AppKit
import Foundation
import Security

/// A structured, reale-data snapshot of a provider's usage.
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
///
/// The Keychain read is **cached in memory** and only repeated once the cached
/// token is close to expiry. Without this, every 60-second usage refresh would
/// hit the Keychain and — on an unsigned/dev binary whose ACL entry isn't
/// trusted — trigger a fresh "allow access" password prompt each time.
enum ClaudeCredentials {
    struct OAuth: Decodable {
        let accessToken: String
        let subscriptionType: String?
        /// Unix epoch in milliseconds when the access token expires.
        let expiresAt: Double?

        var expiryDate: Date? {
            expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: OAuth?

    static func current() -> OAuth? {
        lock.lock()
        defer { lock.unlock() }

        // Reuse the cached token until it is within 2 minutes of expiry.
        if let cached, let expiry = cached.expiryDate, expiry.timeIntervalSinceNow > 120 {
            return cached
        }

        guard let fresh = read() else {
            // Keychain unavailable this time (e.g. user clicked Deny): keep using
            // the last good token if we still have one rather than failing hard.
            return cached
        }
        cached = fresh
        return fresh
    }

    private static func read() -> OAuth? {
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

    /// In-memory cache of the last successful **live** `/usage` response.
    ///
    /// The endpoint is aggressively rate-limited (HTTP 429), so refreshing it on
    /// every 20-second tick keeps it permanently throttled — which is why usage
    /// silently degraded to the rough local estimate. We therefore only hit the
    /// network at most once per `liveMinInterval`, serve the cached live snapshot
    /// in between, and on failure keep showing the last good live data instead of
    /// dropping to the estimate.
    private static let liveCacheLock = NSLock()
    private nonisolated(unsafe) static var liveCache: UsageSnapshot?
    private nonisolated(unsafe) static var liveCacheAt: Date?
    private static let liveMinInterval: TimeInterval = 5 * 60

    private static func freshLiveSnapshot() -> UsageSnapshot? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        guard let snapshot = liveCache, let at = liveCacheAt,
              Date().timeIntervalSince(at) < liveMinInterval else { return nil }
        return snapshot
    }

    private static func lastLiveSnapshot() -> UsageSnapshot? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        return liveCache
    }

    private static func storeLiveSnapshot(_ snapshot: UsageSnapshot) {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveCache = snapshot
        liveCacheAt = Date()
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.claude) else {
            return .disconnected(.claude)
        }

        // Serve a recent live snapshot without touching the network.
        if let cached = Self.freshLiveSnapshot() {
            return cached
        }

        // Time to refresh: fetch the real numbers from the live endpoint.
        if let live = await liveSnapshot() {
            Self.storeLiveSnapshot(live)
            return live
        }

        // Live fetch failed (offline / rate-limited): prefer the last good live
        // data over a coarse local estimate so the numbers stay accurate.
        if let stale = Self.lastLiveSnapshot() {
            return stale
        }
        return estimatedSnapshot()
    }

    // MARK: - Live API

    private func liveSnapshot() async -> UsageSnapshot? {
        guard let credentials = ClaudeCredentials.current() else { return nil }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 8
        // Always hit the network — a cached GET response would freeze the usage
        // numbers and make refreshes look like they do nothing.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
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
        title.font = .systemFont(ofSize: 18, weight: .bold)
        stack.addArrangedSubview(title)

        let note = NSTextField(wrappingLabelWithString: "Usage Touch Bar reads local Codex and Claude Code login state before it shows provider usage. Sign in to each provider below.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 384
        stack.addArrangedSubview(note)

        stack.setCustomSpacing(16, after: note)

        let auth = AuthDetector.current()
        var lastRow: NSView?
        for provider in Provider.allCases {
            let providerRow = row(provider: provider, connected: auth.isConnected(provider))
            stack.addArrangedSubview(providerRow)
            lastRow = providerRow
        }

        let refresh = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        refresh.bezelStyle = .rounded
        refresh.keyEquivalent = "\r"
        if let lastRow { stack.setCustomSpacing(16, after: lastRow) }
        stack.addArrangedSubview(refresh)
    }

    private func row(provider: Provider, connected: Bool) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .clear
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 384).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(row)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                row.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
                row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10)
            ])
        }

        let icon = NSImageView(image: ProviderBranding.icon(for: provider, size: 28))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.addArrangedSubview(icon)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let name = NSTextField(labelWithString: provider.rawValue)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        labels.addArrangedSubview(name)

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 5

        let dot = StatusDotView(color: connected ? .systemGreen : .systemOrange)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        statusRow.addArrangedSubview(dot)

        let status = NSTextField(labelWithString: connected ? "Connected" : "Login required")
        status.font = .systemFont(ofSize: 11)
        status.textColor = connected ? .secondaryLabelColor : .systemOrange
        statusRow.addArrangedSubview(status)
        labels.addArrangedSubview(statusRow)

        row.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: connected ? "Open" : "Login", target: self, action: #selector(openLogin(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
        row.addArrangedSubview(button)

        return box
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

/// Shared source for each provider's brand icon, used by the popover and the
/// Connect Accounts window so both surfaces show the real desktop-app glyph
/// (falling back to the `CL`/`CX` badge when the app isn't installed).
enum ProviderBranding {
    static func appIcon(for provider: Provider) -> NSImage? {
        let bundleID: String
        let fallbackPath: String
        switch provider {
        case .claude:
            bundleID = "com.anthropic.claudefordesktop"
            fallbackPath = "/Applications/Claude.app"
        case .codex:
            bundleID = "com.openai.codex"
            fallbackPath = "/Applications/Codex.app"
        }
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: bundleID)
            ?? (FileManager.default.fileExists(atPath: fallbackPath) ? URL(fileURLWithPath: fallbackPath) : nil)
        guard let url else { return nil }
        return workspace.icon(forFile: url.path)
    }

    @MainActor
    static func icon(for provider: Provider, size: CGFloat) -> NSImage {
        if let appIcon = appIcon(for: provider) {
            let copy = appIcon.copy() as! NSImage
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        let view = ProviderLogoView(provider: provider, selected: true)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A full-width labeled limit gauge for the menu-bar popover:
/// `5-hour  ▓▓▓░░░░░  19%` with the fill color-graded by consumption.
final class PopoverLimitBar: NSView {
    private let caption: String
    private let percent: Double?

    init(caption: String, percent: Double?) {
        self.caption = caption
        self.percent = percent
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        let midY = bounds.midY

        let captionSize = caption.size(withAttributes: captionAttrs)
        caption.draw(at: NSPoint(x: 0, y: midY - captionSize.height / 2), withAttributes: captionAttrs)

        let valueText = UsageFormat.percentText(percent)
        let valueSize = valueText.size(withAttributes: valueAttrs)
        valueText.draw(
            at: NSPoint(x: bounds.maxX - valueSize.width, y: midY - valueSize.height / 2),
            withAttributes: valueAttrs
        )

        let barX: CGFloat = 62
        let barMaxX = bounds.maxX - valueSize.width - 12
        let barWidth = barMaxX - barX
        guard barWidth > 4 else { return }

        let barHeight: CGFloat = 6
        let trackRect = NSRect(x: barX, y: midY - barHeight / 2, width: barWidth, height: barHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        guard let percent else { return }
        let clamped = max(0, min(100, percent))
        let fillWidth = max(barHeight, barWidth * CGFloat(clamped / 100))
        let fillRect = NSRect(x: barX, y: trackRect.minY, width: fillWidth, height: barHeight)
        UsageFormat.color(forPercent: clamped).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
}

/// A small status dot used in the popover to signal a provider's headline health.
final class StatusDotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// A compact two-line gauge sized to fit the ~30pt Touch Bar strip:
/// top line is `5h ▓▓▓░ 19%`, the line beneath it is the reset countdown
/// `↻ 2h 14m` so each window shows exactly when it refills.
final class UsageBarView: NSView {
    private let caption: String
    private let percent: Double?
    private let trailing: String
    private let reset: String?

    init(caption: String, percent: Double?, trailing: String, reset: String? = nil) {
        self.caption = caption
        self.percent = percent
        self.trailing = trailing
        self.reset = reset
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 82, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        let resetAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.7)
        ]

        let hasReset = (reset != nil)
        let topLineY: CGFloat = hasReset ? 18 : (bounds.height - 9) / 2
        let topMidY = topLineY + 4.5

        let captionSize = caption.size(withAttributes: captionAttrs)
        caption.draw(at: NSPoint(x: 0, y: topMidY - captionSize.height / 2), withAttributes: captionAttrs)

        let valueSize = trailing.size(withAttributes: valueAttrs)
        trailing.draw(
            at: NSPoint(x: bounds.maxX - valueSize.width, y: topMidY - valueSize.height / 2),
            withAttributes: valueAttrs
        )

        let barX = captionSize.width + 5
        let barWidth = bounds.maxX - valueSize.width - 5 - barX
        if barWidth > 6 {
            let barHeight: CGFloat = 3
            if let percent {
                let clamped = max(0, min(100, percent))
                let fillWidth = max(barHeight, barWidth * CGFloat(clamped / 100))
                let fillRect = NSRect(x: barX, y: topMidY - barHeight / 2, width: fillWidth, height: barHeight)
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
                UsageFormat.color(forPercent: clamped).setFill()
                fillPath.fill()
            }
        }

        // Second line: reset countdown sits quietly below the caption.
        if let reset {
            let resetText = "↻ \(reset)" as NSString
            resetText.draw(at: NSPoint(x: 0, y: 1), withAttributes: resetAttrs)
        }
    }
}

final class VerticalSeparatorView: NSView {
    private let color: NSColor

    init(color: NSColor = .separatorColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        let rect = NSRect(x: 0, y: 3, width: 1, height: bounds.height - 6)
        NSBezierPath(rect: rect).fill()
    }
}

@MainActor
final class ControlStripSummaryButton: NSButton {
    var providers: [Provider] = []
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
    static let summaryIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.summary")
    static let codexIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.codex")
    static let claudeIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.claude")
    static let detailIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.detail")
    static let refreshIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.refresh")

    static let controlStripIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.controlStrip")

    /// Per-provider Control Strip identifier retained for agent fallback builds.
    static func controlStripIdentifier(for provider: Provider) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("UsageTouchBar.controlStrip.\(provider.rawValue)")
    }

    /// Running mode: the launcher (menu bar + combined Control Strip item) or a
    /// single-provider agent fallback.
    enum Mode: Equatable {
        case launcher
        case agent(Provider)
    }

    private let mode: Mode
    /// The provider this process's Control Strip slot represents (nil for launcher).
    private var ownedProvider: Provider? {
        if case .agent(let provider) = mode { return provider }
        return nil
    }

    private let store: UsageStore
    private let statusItem: NSStatusItem?
    private let touchBar = NSTouchBar()
    private let popover = NSPopover()
    private let loginWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private lazy var hostPanel = TouchBarHostPanel(touchBarController: self)
    private weak var summaryItem: NSCustomTouchBarItem?
    private weak var detailItem: NSCustomTouchBarItem?
    private weak var codexButton: NSButton?
    private weak var claudeButton: NSButton?
    private var controlStripItem: NSCustomTouchBarItem?
    private weak var controlStripButton: ControlStripSummaryButton?
    private var selectedProvider: Provider = .codex
    private var authState = AuthDetector.current()
    private var timer: Timer?

    init(store: UsageStore, mode: Mode) {
        self.store = store
        self.mode = mode
        if case .agent(let provider) = mode { self.selectedProvider = provider }
        // Only the launcher shows a menu-bar item.
        self.statusItem = mode == .launcher
            ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            : nil
        super.init()
        if mode == .launcher { configureStatusItem() }
        configureTouchBar()
        configurePopover()
        configureLoginWindow()
    }

    func start() {
        NSApp.touchBar = touchBar
        if mode == .launcher {
            showLoginIfNeeded()
            installControlStripItem()
        } else {
            installControlStripItem()
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
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
        case Self.summaryIdentifier:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = makeSummaryView()
            summaryItem = item
            return item
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
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
                target: self,
                action: #selector(refreshButtonPressed)
            )
            button.isBordered = false
            button.bezelStyle = .texturedRounded
            button.toolTip = "Refresh"
            item.view = button
            return item
        default:
            return nil
        }
    }

    private func configureStatusItem() {
        guard let statusItem else { return }
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
        touchBar.defaultItemIdentifiers = [Self.detailIdentifier, Self.refreshIdentifier]
        touchBar.customizationAllowedItemIdentifiers = [Self.summaryIdentifier, Self.codexIdentifier, Self.claudeIdentifier, Self.detailIdentifier, Self.refreshIdentifier]
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("UsageTouchBar.default")
        touchBar.principalItemIdentifier = Self.detailIdentifier
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: UsageViewController.popoverWidth, height: 240)
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

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false

        for provider in [Provider.codex, Provider.claude] {
            let snapshot = snapshots[provider]

            // Brand icon.
            let icon = NSImageView(image: ProviderBranding.icon(for: provider, size: 18))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            row.addArrangedSubview(icon)

            // Name + plan stacked.
            let title = NSStackView()
            title.orientation = .vertical
            title.alignment = .leading
            title.spacing = 0
            title.addArrangedSubview(label(provider.symbol, color: .labelColor, bold: true, size: 11))
            if let plan = snapshot?.planLabel {
                title.addArrangedSubview(label(plan.uppercased(), color: .tertiaryLabelColor, bold: false, size: 7))
            }
            row.addArrangedSubview(title)

            if let snapshot, snapshot.error == nil {
                let dailyReset = UsageFormat.resetText(snapshot.dailyResetAt)
                row.addArrangedSubview(bar(
                    caption: "5h",
                    percent: snapshot.dailyPercent,
                    trailing: UsageFormat.percentText(snapshot.dailyPercent),
                    reset: dailyReset == "—" ? nil : dailyReset
                ))
                let weeklyReset = UsageFormat.resetText(snapshot.weeklyResetAt)
                row.addArrangedSubview(bar(
                    caption: "Wk",
                    percent: snapshot.weeklyPercent,
                    trailing: UsageFormat.percentText(snapshot.weeklyPercent),
                    reset: weeklyReset == "—" ? nil : weeklyReset
                ))
            } else {
                row.addArrangedSubview(label(snapshot?.error ?? "—", color: .systemOrange, bold: false, size: 10))
            }

            // Accent-tinted vertical hairline between Codex and Claude.
            if provider == .codex {
                row.addArrangedSubview(VerticalSeparatorView(color: provider.accentColor.withAlphaComponent(0.35)))
            }
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.borderWidth = 0
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

    private func makeSummaryView() -> NSView {
        let snapshots = Dictionary(uniqueKeysWithValues: store.currentSnapshots().map { ($0.provider, $0) })

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false

        let codexButton = summaryButton(provider: Provider.codex, snapshot: snapshots[Provider.codex])
        row.addArrangedSubview(codexButton)

        let claudeButton = summaryButton(provider: Provider.claude, snapshot: snapshots[Provider.claude])
        row.addArrangedSubview(claudeButton)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            container.widthAnchor.constraint(equalToConstant: 322),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func summaryButton(provider: Provider, snapshot: UsageSnapshot?) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(providerButtonPressed(_:)))
        button.image = makeExpandedProviderImage(provider: provider, snapshot: snapshot)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.toolTip = provider.rawValue
        button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 153).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func bar(caption: String, percent: Double?, trailing: String, reset: String? = nil) -> UsageBarView {
        let view = UsageBarView(caption: caption, percent: percent, trailing: trailing, reset: reset)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 82).isActive = true
        view.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
        summaryItem?.view = makeSummaryView()
        detailItem?.view = makeDetailView()
        if let controlStripButton {
            controlStripButton.image = makeControlStripTriggerImage()
            controlStripButton.needsDisplay = true
        }
        touchBar.defaultItemIdentifiers = [Self.detailIdentifier, Self.refreshIdentifier]
        statusItem?.button?.title = statusTitle()
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
        selectProvider(provider)
        showLoginIfNeeded()
    }

    /// Switches the expanded detail tile to `provider` and re-renders the
    /// provider logo buttons so the selection is reflected in both places.
    private func selectProvider(_ provider: Provider) {
        selectedProvider = provider
        codexButton?.image = makeLogoImage(provider: .codex, selected: selectedProvider == .codex)
        claudeButton?.image = makeLogoImage(provider: .claude, selected: selectedProvider == .claude)
        summaryItem?.view = makeSummaryView()
        detailItem?.view = makeDetailView()
        touchBar.defaultItemIdentifiers = [Self.detailIdentifier, Self.refreshIdentifier]
    }

    private func installControlStripItem() {
        guard ControlStrip.isSupported else {
            // macOS without the private Control Strip API: fall back to the
            // focusable host panel so the bar is still reachable.
            focusTouchBarHost()
            return
        }

        let providers: [Provider]
        let itemIdentifier: NSTouchBarItem.Identifier
        if let ownedProvider {
            providers = [ownedProvider]
            itemIdentifier = Self.controlStripIdentifier(for: ownedProvider)
        } else {
            removeLegacyControlStripItems()
            providers = [.codex, .claude]
            itemIdentifier = Self.controlStripIdentifier
        }

        let item = NSCustomTouchBarItem(identifier: itemIdentifier)
        let button = makeControlStripButton(for: providers)
        item.view = button

        controlStripItem = item
        controlStripButton = button
        ControlStrip.add(item)
        if ownedProvider == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                ControlStrip.presentModal(self.touchBar, trayIdentifier: Self.controlStripIdentifier)
            }
        }
    }

    private func removeLegacyControlStripItems() {
        for provider in Provider.allCases {
            let legacyItem = NSCustomTouchBarItem(identifier: Self.controlStripIdentifier(for: provider))
            ControlStrip.remove(legacyItem)
        }
    }

    private func makeControlStripButton(for providers: [Provider]) -> ControlStripSummaryButton {
        let button = ControlStripSummaryButton(title: "", target: self, action: #selector(controlStripTriggerPressed(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = providers.count > 1 ? makeControlStripTriggerImage() : makeControlStripImage(for: providers)
        button.toolTip = providers.map(\.rawValue).joined(separator: " / ")
        button.providers = providers
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: providers.count > 1 ? 32 : 59).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    /// Bundle identifiers / fallback app paths for the providers' desktop apps,
    /// used to source their real brand icons.
    private func appIcon(for provider: Provider) -> NSImage? {
        ProviderBranding.appIcon(for: provider)
    }

    /// Compact usage number tinted green/orange/red by how full the limit is.
    private func controlStripNumber(for provider: Provider) -> NSAttributedString {
        let snapshot = store.currentSnapshots().first { $0.provider == provider }
        let text: String
        let color: NSColor
        if let snapshot, snapshot.error == nil, let percent = snapshot.dailyPercent {
            text = "\(min(99, Int(percent.rounded())))"
            color = UsageFormat.color(forPercent: percent)
        } else {
            text = "–"
            color = .systemGray
        }
        return NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 17, weight: .bold)
            ]
        )
    }

    private func makeControlStripTriggerImage() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let iconRect = NSRect(x: 1, y: 1, width: 22, height: 22)
        NSColor(white: 0.14, alpha: 1).setFill()
        let background = NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6)
        background.fill()

        // Two mini vertical gauges — one per provider — that fill from the
        // bottom by real 5-hour usage and take on the usage color, so the
        // always-visible Control Strip glyph reflects live state at a glance.
        let snapshots = Dictionary(uniqueKeysWithValues: store.currentSnapshots().map { ($0.provider, $0) })
        let slots: [(provider: Provider, x: CGFloat)] = [(.codex, 5), (.claude, 13)]
        let trackY: CGFloat = 5
        let trackHeight: CGFloat = 14
        let barWidth: CGFloat = 6
        for slot in slots {
            let track = NSBezierPath(
                roundedRect: NSRect(x: slot.x, y: trackY, width: barWidth, height: trackHeight),
                xRadius: 2, yRadius: 2
            )
            NSColor(white: 0.32, alpha: 1).setFill()
            track.fill()

            let snapshot = snapshots[slot.provider]
            guard let snapshot, snapshot.error == nil, let percent = snapshot.dailyPercent else { continue }
            let clamped = max(0, min(100, percent))
            let fillHeight = max(2, trackHeight * CGFloat(clamped / 100))
            let fill = NSBezierPath(
                roundedRect: NSRect(x: slot.x, y: trackY, width: barWidth, height: fillHeight),
                xRadius: 2, yRadius: 2
            )
            UsageFormat.color(forPercent: clamped).setFill()
            fill.fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    private func makeExpandedProviderImage(provider: Provider, snapshot: UsageSnapshot?) -> NSImage {
        let width: CGFloat = 153
        let height: CGFloat = 24
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let iconSide: CGFloat = 22
        let icon = appIcon(for: provider) ?? makeLogoImage(provider: provider, selected: provider == selectedProvider)
        icon.draw(
            in: NSRect(x: 1, y: (height - iconSide) / 2, width: iconSide, height: iconSide),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        // Name in labelColor with a small accent underline for provider identity.
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        let hasUsage = snapshot != nil && snapshot?.error == nil
        let dailyPercent = hasUsage ? snapshot?.dailyPercent : nil
        let usageColor: NSColor = hasUsage
            ? UsageFormat.color(forPercent: dailyPercent ?? 0)
            : .systemGray
        let usageText = hasUsage ? UsageFormat.percentText(dailyPercent) : "–"

        let usageAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: usageColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        ]
        let weekAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        ]

        let textX: CGFloat = 27

        // Top line: provider name (left) + large 5-hour percentage (right).
        let name = provider.rawValue as NSString
        let nameSize = name.size(withAttributes: nameAttrs)
        name.draw(at: NSPoint(x: textX, y: 14), withAttributes: nameAttrs)

        // Accent dot aligned with the name's baseline.
        let dotSize: CGFloat = 5
        let dot = NSBezierPath(roundedRect: NSRect(x: textX + nameSize.width + 5, y: 14 + (nameSize.height - dotSize) / 2, width: dotSize, height: dotSize), xRadius: dotSize / 2, yRadius: dotSize / 2)
        provider.accentColor.setFill()
        dot.fill()

        let usage = usageText as NSString
        let usageSize = usage.size(withAttributes: usageAttrs)
        usage.draw(at: NSPoint(x: width - usageSize.width - 2, y: 10), withAttributes: usageAttrs)

        // Bottom line: a visible 5-hour usage bar + weekly percentage on the right.
        let weeklyText = "W \(UsageFormat.percentText(hasUsage ? snapshot?.weeklyPercent : nil))" as NSString
        let weeklySize = weeklyText.size(withAttributes: weekAttrs)
        weeklyText.draw(at: NSPoint(x: width - weeklySize.width - 2, y: 1.5), withAttributes: weekAttrs)

        let barX = textX
        let barMaxX = width - weeklySize.width - 8
        let barWidth = barMaxX - barX
        if barWidth > 6 {
            let barHeight: CGFloat = 3
            let barY: CGFloat = 4
            if let dailyPercent {
                let clamped = max(0, min(100, dailyPercent))
                let fillWidth = max(barHeight, barWidth * CGFloat(clamped / 100))
                let fillRect = NSRect(x: barX, y: barY, width: fillWidth, height: barHeight)
                usageColor.setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    /// Draws a provider as `[app icon] 13%` into a crisp 2× bitmap.
    /// Uses the real Anthropic / OpenAI app icon, falling back to the `CL`/`CX`
    /// badge if the desktop app isn't installed.
    private func makeControlStripImage(for providers: [Provider]) -> NSImage {
        let iconSize: CGFloat = 24
        let iconGap: CGFloat = 2
        let providerGap: CGFloat = 5

        let segments = providers.map { provider in
            let number = controlStripNumber(for: provider)
            let icon = appIcon(for: provider) ?? makeLogoImage(provider: provider, selected: true)
            return (icon: icon, number: number, textSize: number.size())
        }

        let contentWidth = segments.enumerated().reduce(CGFloat(0)) { total, pair in
            let separator = pair.offset == 0 ? CGFloat(0) : providerGap
            return total + separator + iconSize + iconGap + ceil(pair.element.textSize.width)
        }
        let maxTextHeight = segments.map { ceil($0.textSize.height) }.max() ?? 1
        let width = max(1, contentWidth)
        let height = max(1, max(iconSize, maxTextHeight))

        // Render into a 2× bitmap so the Touch Bar (a Retina surface) shows it
        // sharp rather than upscaling a 1× image into a fuzzy, smaller-looking blob.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { x += providerGap }
            segment.icon.draw(
                in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            x += iconSize + iconGap
            segment.number.draw(at: NSPoint(x: x, y: (height - segment.textSize.height) / 2))
            x += ceil(segment.textSize.width)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    @objc private func controlStripTriggerPressed(_ sender: ControlStripSummaryButton) {
        controlStripTapped()
    }

    private func controlStripTapped() {
        if let ownedProvider {
            selectProvider(ownedProvider)
        }
        let trayIdentifier = ownedProvider.map { Self.controlStripIdentifier(for: $0) } ?? Self.controlStripIdentifier
        ControlStrip.presentModal(touchBar, trayIdentifier: trayIdentifier)
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
        guard let button = statusItem?.button else { return }
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
    static let popoverWidth: CGFloat = 380
    static let cardWidth: CGFloat = popoverWidth - 32

    private let store: UsageStore
    private let stack = NSStackView()
    private let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 200))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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

        stack.addArrangedSubview(header())

        let snapshots = store.currentSnapshots()
        if snapshots.isEmpty {
            let loading = NSTextField(labelWithString: "Loading provider usage…")
            loading.font = .systemFont(ofSize: 12)
            loading.textColor = .secondaryLabelColor
            stack.addArrangedSubview(loading)
        } else {
            for snapshot in snapshots {
                stack.addArrangedSubview(card(for: snapshot))
            }
        }

        // Size the popover to fit its content.
        view.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 32
        preferredContentSize = NSSize(width: Self.popoverWidth, height: height)
    }

    private func header() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2

        let title = NSTextField(labelWithString: "Usage")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        container.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Claude Code & Codex limits")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        container.addArrangedSubview(subtitle)

        return container
    }

    private func card(for snapshot: UsageSnapshot) -> NSView {
        let innerWidth = Self.cardWidth - 24

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .clear
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
                content.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10)
            ])
        }

        content.addArrangedSubview(headerRow(for: snapshot, width: innerWidth))

        if let error = snapshot.error {
            let errorLabel = NSTextField(wrappingLabelWithString: error)
            errorLabel.font = .systemFont(ofSize: 12)
            errorLabel.textColor = .systemOrange
            errorLabel.preferredMaxLayoutWidth = innerWidth
            content.addArrangedSubview(errorLabel)
        } else {
            content.addArrangedSubview(limitBar(caption: "5-hour", percent: snapshot.dailyPercent, width: innerWidth))
            content.addArrangedSubview(resetRow(label: "5h resets", date: snapshot.dailyResetAt, width: innerWidth))
            content.setCustomSpacing(10, after: content.arrangedSubviews.last!)
            content.addArrangedSubview(limitBar(caption: "Weekly", percent: snapshot.weeklyPercent, width: innerWidth))
            content.addArrangedSubview(resetRow(label: "Week resets", date: snapshot.weeklyResetAt, width: innerWidth))

            let meta = NSTextField(labelWithString: metaText(for: snapshot))
            meta.font = .systemFont(ofSize: 10)
            meta.textColor = .tertiaryLabelColor
            meta.lineBreakMode = .byTruncatingTail
            content.addArrangedSubview(meta)
            content.setCustomSpacing(10, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        }

        return box
    }

    /// A small right-aligned reset caption shown beneath a window's usage bar,
    /// e.g. `5h resets in 2h 14m  ·  9:00 PM`.
    private func resetRow(label: String, date: Date?, width: CGFloat) -> NSView {
        let text: String
        if let date {
            let relative = UsageFormat.resetText(date)
            let clock = Self.clockFormatter.string(from: date)
            text = relative == "now" ? "\(label) now" : "\(label) in \(relative)  ·  \(clock)"
        } else {
            text = "\(label) —"
        }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.alignment = .right
        return field
    }

    private func headerRow(for snapshot: UsageSnapshot, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true

        let icon = NSImageView(image: ProviderBranding.icon(for: snapshot.provider, size: 20))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        row.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: snapshot.provider.rawValue)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = snapshot.error == nil ? .labelColor : .systemOrange
        row.addArrangedSubview(name)

        if let plan = snapshot.planLabel {
            let planLabel = NSTextField(labelWithString: plan.uppercased())
            planLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            planLabel.textColor = .tertiaryLabelColor
            row.addArrangedSubview(planLabel)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let dotColor: NSColor
        if snapshot.error != nil {
            dotColor = .systemGray
        } else {
            dotColor = UsageFormat.color(forPercent: snapshot.dailyPercent ?? snapshot.weeklyPercent ?? 0)
        }
        let dot = StatusDotView(color: dotColor)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        row.addArrangedSubview(dot)

        return row
    }

    private func limitBar(caption: String, percent: Double?, width: CGFloat) -> NSView {
        let bar = PopoverLimitBar(caption: caption, percent: percent)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: width).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return bar
    }

    private func metaText(for snapshot: UsageSnapshot) -> String {
        var parts: [String] = []
        if let tokens = snapshot.totalTokens, tokens > 0 {
            parts.append("\(UsageFormat.tokenText(tokens)) tokens")
        }
        parts.append("updated \(formatter.localizedString(for: snapshot.updatedAt, relativeTo: Date()))")
        return parts.joined(separator: "  ·  ")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TouchBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--agent <provider>` runs a single-provider agent that owns one Control
        // Strip slot. With no flag we are the launcher: menu bar + one combined
        // Control Strip item containing Codex and Claude buttons side by side.
        let args = CommandLine.arguments
        let agentProvider = args.firstIndex(of: "--agent")
            .flatMap { args.indices.contains($0 + 1) ? Provider(rawValue: args[$0 + 1]) : nil }

        let mode: TouchBarController.Mode = agentProvider.map { .agent($0) } ?? .launcher

        // An agent only needs its own provider's collector (keeps it light and
        // avoids touching the other provider's credentials).
        let collectors: [UsageCollecting]
        switch mode {
        case .agent(.claude): collectors = [ClaudeUsageCollector()]
        case .agent(.codex): collectors = [CodexUsageCollector()]
        case .launcher: collectors = [ClaudeUsageCollector(), CodexUsageCollector()]
        }

        // An agent reparented to launchd (ppid == 1) means the launcher died —
        // quit so the slot doesn't linger.
        if mode != .launcher {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                if getppid() == 1 { Task { @MainActor in NSApp.terminate(nil) } }
            }
        }

        let controller = TouchBarController(store: UsageStore(collectors: collectors), mode: mode)
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
