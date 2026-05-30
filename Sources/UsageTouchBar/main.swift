import AppKit
import Foundation

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

struct LocalLogCollector: UsageCollecting {
    let provider: Provider
    let candidatePaths: [String]
    let keywords: [String]
    private let maxBytesPerFile = 512 * 1024

    func collect() async -> UsageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expandedPaths = candidatePaths.map { $0.replacingOccurrences(of: "~", with: home) }
        let files = expandedPaths.flatMap { path in
            recentFiles(at: path, limit: 80)
        }

        guard !files.isEmpty else {
            return UsageSnapshot(
                provider: provider,
                primaryText: "No data",
                detailText: "No local usage files found",
                warningText: nil,
                updatedAt: Date(),
                source: expandedPaths.joined(separator: ", "),
                error: "Configure the usage data path once the provider source is confirmed."
            )
        }

        var requestCount = 0
        var tokenCount = 0
        var latestDate = Date.distantPast

        for file in files {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modified = attributes[.modificationDate] as? Date {
                latestDate = max(latestDate, modified)
            }

            guard let text = readPrefix(from: file) else {
                continue
            }

            requestCount += countUsageHints(in: text)
            tokenCount += extractTokenHints(from: text)
        }

        let primary: String
        let detail: String
        if tokenCount > 0 {
            primary = Self.format(tokenCount) + " tokens"
            detail = "\(requestCount) events"
        } else if requestCount > 0 {
            primary = "\(requestCount) events"
            detail = "Token totals unavailable"
        } else {
            primary = "Files found"
            detail = "No usage counters detected"
        }

        return UsageSnapshot(
            provider: provider,
            primaryText: primary,
            detailText: detail,
            warningText: nil,
            updatedAt: latestDate == Date.distantPast ? Date() : latestDate,
            source: files.first?.deletingLastPathComponent().path ?? expandedPaths.joined(separator: ", "),
            error: nil
        )
    }

    private func recentFiles(at path: String, limit: Int) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            return [URL(fileURLWithPath: path)]
        }

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var inspected = 0
        var files: [URL] = []

        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 1_000 || files.count >= limit * 2 {
                break
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent.lowercased()
                if ["cache", "caches", "node_modules", "tmp", "temp"].contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let allowed = ["json", "jsonl", "log", "txt"].contains(url.pathExtension.lowercased())
            if allowed && values?.isRegularFile == true {
                files.append(url)
            }
        }

        return files
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .map { $0 }
    }

    private func readPrefix(from file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: maxBytesPerFile)
        return String(data: data, encoding: .utf8)
    }

    private func countUsageHints(in text: String) -> Int {
        let lowercased = text.lowercased()
        let explicitHits = keywords.reduce(0) { count, keyword in
            count + lowercased.components(separatedBy: keyword.lowercased()).count - 1
        }

        if explicitHits > 0 {
            return explicitHits
        }

        return text.split(separator: "\n").filter { line in
            let lower = line.lowercased()
            return lower.contains("model") || lower.contains("tokens") || lower.contains("completion")
        }.count
    }

    private func extractTokenHints(from text: String) -> Int {
        let patterns = [
            #""(?:total_tokens|tokens|input_tokens|output_tokens)"\s*:\s*(\d+)"#,
            #"(?i)(?:total tokens|tokens|input tokens|output tokens)[^0-9]{0,24}(\d+)"#
        ]

        return patterns.reduce(0) { total, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return total }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return total + regex.matches(in: text, range: range).reduce(0) { subtotal, match in
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let value = Int(text[valueRange]) else {
                    return subtotal
                }
                return subtotal + value
            }
        }
    }

    private static func format(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
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

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let codexIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.codex")
    static let claudeIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.claude")
    static let detailIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.detail")
    static let refreshIdentifier = NSTouchBarItem.Identifier("UsageTouchBar.refresh")

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
        focusTouchBarHost()
        showLoginIfNeeded()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func makeTouchBar() -> NSTouchBar {
        touchBar
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
        popover.contentSize = NSSize(width: 360, height: 190)
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
        let usage = UsagePresenter.usage(
            for: selectedProvider,
            snapshot: snapshots[selectedProvider],
            authState: authState
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 64))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.84, alpha: 1).cgColor
        container.layer?.cornerRadius = 4

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .gravityAreas
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("\(usage.provider.symbol) : \(usage.usageLine)", color: .secondaryLabelColor, bold: false, size: 11))
        stack.addArrangedSubview(label(usage.resetLine, color: .secondaryLabelColor, bold: false, size: 11))
        stack.addArrangedSubview(label(usage.weeklyLine, color: .secondaryLabelColor, bold: false, size: 11))

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 230),
            container.heightAnchor.constraint(equalToConstant: 64),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5)
        ])

        return container
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
        touchBar.defaultItemIdentifiers = [Self.codexIdentifier, Self.claudeIdentifier, Self.detailIdentifier, Self.refreshIdentifier]
        statusItem.button?.title = statusTitle()
        (popover.contentViewController as? UsageViewController)?.reload()
    }

    private func statusTitle() -> String {
        let snapshots = store.currentSnapshots()
        guard !snapshots.isEmpty else { return "Usage" }
        return snapshots.map { "\($0.provider.symbol): \($0.primaryText)" }.joined(separator: "  ")
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
        container.spacing = 2

        let headline = NSTextField(labelWithString: "\(snapshot.provider.rawValue): \(snapshot.primaryText)")
        headline.font = .boldSystemFont(ofSize: 13)
        headline.textColor = snapshot.error == nil ? .labelColor : .systemOrange
        container.addArrangedSubview(headline)

        let updated = formatter.localizedString(for: snapshot.updatedAt, relativeTo: Date())
        let detail = NSTextField(labelWithString: "\(snapshot.detailText) · updated \(updated)")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        container.addArrangedSubview(detail)

        if let error = snapshot.error {
            let errorLabel = NSTextField(wrappingLabelWithString: error)
            errorLabel.font = .systemFont(ofSize: 11)
            errorLabel.textColor = .tertiaryLabelColor
            container.addArrangedSubview(errorLabel)
        }

        return container
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TouchBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let collectors: [UsageCollecting] = [
            LocalLogCollector(
                provider: .claude,
                candidatePaths: [
                    "~/.claude",
                    "~/Library/Application Support/Claude",
                    "~/Library/Logs/Claude"
                ],
                keywords: ["claude", "total_tokens", "input_tokens", "output_tokens"]
            ),
            LocalLogCollector(
                provider: .codex,
                candidatePaths: [
                    "~/.codex",
                    "~/Library/Application Support/Codex",
                    "~/Library/Logs/Codex"
                ],
                keywords: ["codex", "total_tokens", "input_tokens", "output_tokens"]
            )
        ]

        let controller = TouchBarController(store: UsageStore(collectors: collectors))
        self.controller = controller
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
