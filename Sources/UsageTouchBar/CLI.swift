import AppKit
import Foundation

/// Terminal-only entry points for `usage-touchbar`.
///
/// The default invocation (no subcommand) still launches the Touch Bar
/// accessory so existing users see no change. Subcommands print the same
/// provider data the Touch Bar would show, without booting AppKit or a
/// `NSApplication` run loop:
///
/// * `usage-touchbar start`      — forks the Touch Bar + silent live loop
///                                 into the background. Terminal returns
///                                 immediately; Touch Bar stays alive until
///                                 `usage-touchbar stop` is run.
/// * `usage-touchbar stop`       — gracefully stops the background daemon
///                                 and removes the PID file.
/// * `usage-touchbar status`     — one-shot, ANSI-colored table, exits.
/// * `usage-touchbar watch`      — foreground silent live loop; exits on ^C.
/// * `usage-touchbar refresh`    — same as `status` but always re-fetches
///                                 network providers (bypasses the 5-minute
///                                 live-API cache).
/// * `usage-touchbar providers`  — list the configured providers and their
///                                 auth state, useful for shell scripts.
/// * `usage-touchbar help`       — usage text.
enum CLI {
    /// Parsed command-line invocation.
    ///
    /// `.help` is overloaded: it's returned both for the bare invocation
    /// (no args) and for the explicit `help` / `-h` / `--help` form. The
    /// `wasExplicit` flag distinguishes the two so the entry-point can
    /// decide whether to print CLI help or launch the Touch Bar app.
    ///
    /// `withTouchBar` (parsed from `--touchbar` / `-t`) is honored by every
    /// command that produces a live snapshot (`status`, `watch`, `refresh`).
    /// When set, the entry point also starts the Touch Bar controller and
    /// runs the AppKit run loop alongside the CLI work.
    enum Command {
        case help(wasExplicit: Bool)
        case status(interval: Int, json: Bool, once: Bool, withTouchBar: Bool)
        case providers(json: Bool)
        case refresh(json: Bool, withTouchBar: Bool)
        case watch(interval: Int, json: Bool, withTouchBar: Bool)
        case start(interval: Int)
        case stop
    }

    static func parse(_ arguments: [String]) -> Command {
        var args = arguments
        // Drop argv[0] (executable path).
        if !args.isEmpty { args.removeFirst() }

        let sub = args.first?.lowercased() ?? ""
        let rest = Array(args.dropFirst())
        let touchBar = hasFlag(rest, "--touchbar") || hasFlag(rest, "-t")

        // `usage-touchbar --touchbar` / `-t` (no subcommand, just a flag)
        // is the lite-mode shortcut. The main entry point promotes it to
        // a `watch --touchbar` with a 5s default interval, but parsing
        // it here lets us recognize it as a valid invocation that does
        // not print "Unknown command: --touchbar".
        if sub.isEmpty || sub.hasPrefix("-") {
            return .help(wasExplicit: false)
        }

        switch sub {
        case "touchbar", "gui", "app":
            // Explicit "launch the Touch Bar app" — same as no subcommand.
            return .help(wasExplicit: false)
        case "status":
            return .status(
                interval: flagInt(rest, "--interval", "-i") ?? 0,
                json: hasFlag(rest, "--json"),
                once: hasFlag(rest, "--once") || (flagInt(rest, "--interval", "-i") == nil),
                withTouchBar: touchBar
            )
        case "watch":
            return .watch(
                interval: flagInt(rest, "--interval", "-i") ?? 5,
                json: hasFlag(rest, "--json"),
                withTouchBar: touchBar
            )
        case "start":
            return .start(interval: flagInt(rest, "--interval", "-i") ?? 5)
        case "stop":
            return .stop
        case "providers":
            return .providers(json: hasFlag(rest, "--json"))
        case "refresh":
            return .refresh(json: hasFlag(rest, "--json"), withTouchBar: touchBar)
        case "help", "-h", "--help":
            return .help(wasExplicit: true)
        default:
            FileHandle.standardError.write(Data("Unknown command: \(sub)\n".utf8))
            return .help(wasExplicit: true)
        }
    }

    private static func hasFlag(_ args: [String], _ flag: String) -> Bool {
        args.contains(flag)
    }

    private static func flagInt(_ args: [String], _ long: String, _ short: String) -> Int? {
        for (index, arg) in args.enumerated() {
            if arg == long || arg == short, index + 1 < args.count, let value = Int(args[index + 1]) {
                return value
            }
            if arg.hasPrefix(long + "="), let value = Int(String(arg.dropFirst(long.count + 1))) {
                return value
            }
        }
        return nil
    }

    static func printHelp() {
        let text = """
        usage-touchbar — Claude, Codex & OpenCode usage limits

        USAGE
          usage-touchbar                       Launch the Touch Bar accessory (default)
          usage-touchbar start                 Start daemon in background; close terminal
          usage-touchbar --touchbar            Same as `start` (friendly shortcut)
          usage-touchbar stop                  Gracefully stop the background daemon
          usage-touchbar status                One-shot, ANSI-colored provider usage
          usage-touchbar watch                 Silent foreground live loop; ^C to exit
          usage-touchbar refresh               One-shot, bypasses the live-API cache
          usage-touchbar providers             List providers + login state
          usage-touchbar help                  This message

        OPTIONS
          --interval <seconds>, -i             Refresh period for `watch`/`start` (default 5)
                                               For `status`, defaults to one-shot.
          --json                               Emit machine-readable JSON
          --once                               Same as default for `status`; explicit
          --touchbar, -t                       Also start the Touch Bar accessory (implied
                                               by `start`; optional for `status`/`refresh`)

        EXAMPLES
          usage-touchbar --touchbar            # Start daemon, close terminal
          usage-touchbar stop                  # Stop the daemon
          usage-touchbar start --interval 10   # Start with 10s refresh interval
          usage-touchbar status
          usage-touchbar status --json | jq '.[] | select(.provider == "OpenCode")'
        """
        print(text)
    }

    // MARK: - Top-level dispatch

    /// Runs the parsed CLI command. The async signature lets the entry
    /// point `await` the whole rendering pipeline (refresh → paint) without
    /// spawning a Task, so a one-shot `status` actually waits for the first
    /// network call before the process exits.
    ///
    /// When the command requests `--touchbar`, the entry point has already
    /// started the Touch Bar controller and is running the AppKit run loop
    /// in parallel; this function focuses on the CLI work and returns when
    /// it's done. The entry point observes the return value of the Task and
    /// terminates `NSApp` accordingly.
    @MainActor
    static func run(_ command: Command) async {
        switch command {
        case .help(let wasExplicit):
            if wasExplicit {
                printHelp()
            }
            // No-arg invocation falls through to AppKit; the entry point
            // handles that case directly without calling us.
        case .status(let interval, let json, let once, _):
            await statusLoop(interval: interval, json: json, once: once || interval == 0)
        case .watch(let interval, let json, _):
            // Silent foreground live loop; user presses ^C to exit.
            await watchLoopSilent(interval: interval, json: json)
        case .start(let interval):
            startDaemon(interval: interval)
        case .stop:
            stopDaemon()
        case .refresh(let json, _):
            UsageStore.flushLiveCaches()
            await statusLoop(interval: 0, json: json, once: true)
        case .providers(let json):
            listProviders(json: json)
        }
    }

    // MARK: - One-shot / live loop

    /// Runs the `status` / `watch` rendering loop. For one-shot invocations
    /// (`once == true`) this awaits the first fresh paint and returns; for
    /// `watch` it paints on a `Task.sleep` ticker until the SIGINT handler
    /// calls `requestStop()`, which sets `stopRequested` and the loop exits
    /// at the top of the next iteration.
    @MainActor
    private static func statusLoop(interval: Int, json: Bool, once: Bool) async {
        if once {
            await runOneShot(json: json)
            return
        }

        stopRequested = false
        installSignalHandler()

        let store = UsageStore(collectors: defaultCollectors())

        let render: () -> Void = {
            let snapshots = store.currentSnapshots()
            if json {
                emitJSON(snapshots: snapshots)
            } else {
                emitHumanReadable(snapshots: snapshots, clearScreen: true, singleFrame: false)
            }
            fflush(stdout)
        }

        render()
        _ = await store.refresh()
        render()

        // Live loop: use a Task.sleep-based ticker so the process can
        // still react to SIGINT cleanly. The store is concurrency-safe.
        let period = max(1, interval)
        while !stopRequested && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(period) * 1_000_000_000)
            if stopRequested { break }
            _ = await store.refresh()
            render()
        }
    }

    /// One-shot render for `status` / `refresh`. Awaits the first refresh
    /// directly (the `await` releases the main actor, so the underlying
    /// `URLSession` work runs without deadlocking) and then paints the
    /// freshest data.
    @MainActor
    private static func runOneShot(json: Bool) async {
        let store = UsageStore(collectors: defaultCollectors())

        let render: () -> Void = {
            let snapshots = store.currentSnapshots()
            if json {
                emitJSON(snapshots: snapshots)
            } else {
                emitHumanReadable(snapshots: snapshots, clearScreen: false, singleFrame: true)
            }
            fflush(stdout)
        }

        _ = await store.refresh()
        render()
    }

    /// Silent live loop for `watch`. Refreshes a local store on every tick
    /// (so a second consumer — e.g. the Touch Bar, if `--touchbar` is set —
    /// sees fresh data through its own collector) and exits on SIGINT.
    /// Without a Touch Bar, this command is effectively a no-op that holds
    /// the process open until the user interrupts.
    @MainActor
    private static func watchLoopSilent(interval: Int, json: Bool) async {
        stopRequested = false
        installSignalHandler()

        let store = UsageStore(collectors: defaultCollectors())

        // First refresh so the Touch Bar / any other consumer sees data
        // immediately on startup, not after the first `interval` seconds.
        _ = await store.refresh()

        let period = max(1, interval)
        while !stopRequested && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(period) * 1_000_000_000)
            if stopRequested { break }
            _ = await store.refresh()
            // `json` is accepted for API symmetry but we deliberately don't
            // print on every tick — the user asked for silent watch.
            _ = json
        }
    }

    /// `true` when a SIGINT has been received and the live `watch` loop
    /// should exit at the top of its next iteration. Written from the
    /// signal handler and read from the main actor — the `.main` dispatch
    /// queue serializes those accesses, and we use `nonisolated(unsafe)` so
    /// the `static var` satisfies the concurrency checker.
    nonisolated(unsafe) private static var stopRequested = false

    // MARK: - Daemon (start / stop)

    /// Path to the PID file that tracks the background daemon.
    /// `~/.config/usage-touchbar/daemon.pid`.
    static var daemonPIDPath: String {
        DataFiles.expand("~/.config/usage-touchbar/daemon.pid")
    }

    /// Reads the daemon PID file and returns `(pid, nil)` if a process with
    /// that PID is alive and is a `usage-touchbar` binary. Returns `(0,
    /// errorMessage)` if the PID file is absent, the process is dead, or
    /// the PID didn't belong to `usage-touchbar`.
    static func daemonPID() -> (pid: pid_t, message: String?) {
        let path = daemonPIDPath
        guard FileManager.default.fileExists(atPath: path) else {
            // Normal first-launch case — no PID file yet, nothing to warn about.
            return (0, nil)
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            // Stale / corrupted PID file — clean it up.
            try? FileManager.default.removeItem(atPath: path)
            return (0, "Stale PID file removed — daemon was not running")
        }
        // /proc is Linux-only; on macOS we use `kill -0` to check liveness
        // and then `proc_pidpath` or a simpler `pgrep -P` style check.
        // `kill(pid, 0)` returns 0 if the process is alive (no signal sent).
        if kill(pid, 0) != 0 {
            try? FileManager.default.removeItem(atPath: path)
            return (0, "Stale PID file removed — daemon was not running")
        }
        return (pid, nil)
    }

    /// Writes `pid` to the daemon PID file, creating the parent directory
    /// if needed. Returns `true` on success.
    @discardableResult
    static func writeDaemonPID(_ pid: pid_t) -> Bool {
        let path = daemonPIDPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        do {
            try "\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            FileHandle.standardError.write(
                Data("Failed to write PID file at \(path): \(error)\n".utf8)
            )
            return false
        }
    }

    /// Removes the daemon PID file. Safe to call even when the file doesn't
    /// exist.
    static func removeDaemonPID() {
        try? FileManager.default.removeItem(atPath: daemonPIDPath)
    }

    /// Spawns a **daemonized** child process that survives terminal closure.
    /// Uses `posix_spawn` with `POSIX_SPAWN_SETSID` so the child gets its own
    /// session and process group — closing the terminal won't kill it.
    ///
    /// The child inherits the window-server connection from the parent, so
    /// AppKit works, but we redirect stdin/stdout/stderr to /dev/null so the
    /// parent can exit immediately.
    static func startDaemon(interval: Int) {
        let (existingPID, msg) = daemonPID()
        if existingPID > 0 {
            print("usage-touchbar daemon is already running (PID \(existingPID)).")
            print("Stop it with: usage-touchbar stop")
            return
        }
        if let msg {
            print("warning: \(msg) — starting fresh daemon.")
        }

        // Resolve the binary we are currently running as.
        var pathBuffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        _ = pathBuffer.withUnsafeMutableBufferPointer { buf in
            proc_pidpath(getpid(), buf.baseAddress, UInt32(buf.count))
        }
        let binaryPath = String(cString: pathBuffer)

        // Build a C-style argv: [binaryPath, "watch", "--touchbar", "--interval", "N", nil]
        let cArgs: [String] = [
            binaryPath,
            "watch", "--touchbar",
            "--interval", "\(interval)"
        ]

        var pid: pid_t = 0
        let ret: Int32 = cArgs.withUnsafeBufferPointer { argsBuf -> Int32 in
            // Convert String args to C strings
            let cStrings: [UnsafeMutablePointer<CChar>] = argsBuf.map { strdup($0) }
            defer { cStrings.forEach { free($0) } }

            // Build the argv array with a nil terminator
            var argv = cStrings.map(UnsafeMutablePointer<CChar>?.init)
            argv.append(nil)

            var attrs: posix_spawnattr_t?
            posix_spawnattr_init(&attrs)
            // SETSID: child gets its own session — survives terminal closure.
            // CLOEXEC_DEFAULT: all file descriptors except stdin/out/err are
            // closed on exec.
            posix_spawnattr_setflags(&attrs, Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
            ))

            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            // Redirect stdin to /dev/null and stdout/stderr to a log file so
            // the parent can exit but we can still diagnose the detached
            // daemon if AppKit / the Touch Bar fails to come up.
            let logPath = DataFiles.expand("~/.config/usage-touchbar/daemon.log")
            let logDir = (logPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO,  "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)

            let r = posix_spawn(&pid, binaryPath, &fileActions, &attrs, argv, nil)
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attrs)
            return r
        }

        if ret != 0 {
            print("Failed to start daemon: \(String(cString: strerror(ret)))")
            return
        }

        writeDaemonPID(pid)
        print("✅ Touch Bar is now live and showing usage (PID \(pid)).")
        print("   This terminal is free — keep using it for other commands.")
        print("   The Touch Bar stays live until you run: usage-touchbar stop")
    }

    /// Sends SIGTERM to the daemon (if running) and removes the PID file.
    /// SIGTERM is used instead of SIGINT because the AppKit-based daemon
    /// runs inside `NSApplication.run()` which does not reliably process
    /// SIGINT via dispatch sources; SIGTERM delivers a clean process
    /// termination that AppKit handles via its `applicationWillTerminate`
    /// delegate callback.
    static func stopDaemon() {
        let (pid, msg) = daemonPID()
        guard pid > 0 else {
            print(msg ?? "No daemon is running.")
            return
        }
        print("Stopping daemon (PID \(pid))…")
        if kill(pid, SIGTERM) != 0 {
            let err = String(cString: strerror(errno))
            print("warning: could not signal daemon: \(err)")
        }
        removeDaemonPID()
        // Give the daemon a moment to uninstall the Control Strip item
        // and clean up its watchers before we exit.
        Thread.sleep(forTimeInterval: 0.5)
        print("Daemon stopped.")
    }

    /// Flips `stopRequested` so the live loop exits on its next tick.
    /// Safe to call from a signal handler because the underlying storage is
    /// a single `Bool` and the only writer is the signal handler.
    static func requestStop() {
        stopRequested = true
        // Restore cursor so a SIGINT mid-partial-line leaves the terminal
        // in a sane state. We never hide it, but it's a polite cleanup.
        if isatty(STDOUT_FILENO) != 0 {
            print("\u{1B}[?25h")
        }
    }

    @MainActor
    private static func listProviders(json: Bool) {
        let auth = AuthDetector.current()
        if json {
            let payload: [String: Any] = [
                "providers": Provider.allCases.map { provider in
                    [
                        "id": provider.rawValue.lowercased(),
                        "name": provider.rawValue,
                        "connected": auth.isConnected(provider)
                    ]
                }
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }
        print("Providers")
        print(String(repeating: "─", count: 40))
        for provider in Provider.allCases {
            let mark = auth.isConnected(provider) ? "✓" : "·"
            print("  \(mark)  \(provider.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))")
        }
    }

    // MARK: - Output rendering

    @MainActor
    private static func emitJSON(snapshots: [UsageSnapshot]) {
        // `[Any]` payload for ordered, predictable keys.
        let payload: [Any] = snapshots.map { snapshot in
            var dict: [String: Any] = [
                "provider": snapshot.provider.rawValue,
                "isConnected": snapshot.isConnected,
                "updatedAt": ISO8601DateFormatter().string(from: snapshot.updatedAt),
                "error": snapshot.error as Any,
                "planLabel": snapshot.planLabel as Any
            ]
            dict["dailyPercent"] = snapshot.dailyPercent.map { Int($0.rounded()) } as Any
            dict["weeklyPercent"] = snapshot.weeklyPercent.map { Int($0.rounded()) } as Any
            if let date = snapshot.dailyResetAt {
                dict["dailyResetsAt"] = ISO8601DateFormatter().string(from: date)
                dict["dailyResetsIn"] = UsageFormat.resetText(date)
            } else {
                dict["dailyResetsAt"] = NSNull()
                dict["dailyResetsIn"] = NSNull()
            }
            if let date = snapshot.weeklyResetAt {
                dict["weeklyResetsAt"] = ISO8601DateFormatter().string(from: date)
                dict["weeklyResetsIn"] = UsageFormat.resetText(date)
            } else {
                dict["weeklyResetsAt"] = NSNull()
                dict["weeklyResetsIn"] = NSNull()
            }
            dict["totalTokens"] = snapshot.totalTokens as Any
            return dict
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    @MainActor
    private static func emitHumanReadable(
        snapshots: [UsageSnapshot],
        clearScreen: Bool,
        singleFrame: Bool
    ) {
        if clearScreen && isatty(STDOUT_FILENO) != 0 {
            // Move cursor home + clear below; cheap and works in every TUI.
            print("\u{1B}[H\u{1B}[2J", terminator: "")
        }

        let now = Date()
        let clockFormatter = DateFormatter()
        clockFormatter.dateFormat = "HH:mm:ss"

        print("Usage Touch Bar  ·  \(clockFormatter.string(from: now))")
        print(String(repeating: "─", count: 56))

        if snapshots.isEmpty {
            print("  Loading…")
        }

        for snapshot in snapshots {
            renderSnapshot(snapshot, singleFrame: singleFrame)
        }
    }

    @MainActor
    private static func renderSnapshot(_ snapshot: UsageSnapshot, singleFrame: Bool) {
        if let error = snapshot.error {
            let name = snapshot.provider.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let line = "  " + name + "  " + color(.dim) + error + color(.reset)
            print(line)
            return
        }

        let name = snapshot.provider.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)

        let dailyText = UsageFormat.percentText(snapshot.dailyPercent)
        let weeklyText = UsageFormat.percentText(snapshot.weeklyPercent)
        let dailyColor = snapshot.dailyPercent.map(UsageFormat.color(forPercent:)) ?? NSColor.secondaryLabelColor
        let weeklyColor = snapshot.weeklyPercent.map(UsageFormat.color(forPercent:)) ?? NSColor.secondaryLabelColor

        let dailyReset = formatReset(snapshot.dailyResetAt)
        let weeklyReset = formatReset(snapshot.weeklyResetAt)

        let planTag: String
        if let plan = snapshot.planLabel {
            planTag = "  \(color(.dim))[\(plan.uppercased())]\(color(.reset))"
        } else {
            planTag = ""
        }

        // 5h line
        let dailyBar = bar(snapshot.dailyPercent, width: 24)
        let dailyLine = "  " + color(.bold) + name + color(.reset)
            + color(.dim) + "5h" + color(.reset) + " "
            + dailyBar + " "
            + colorize(dailyText, dailyColor)
            + "  " + color(.dim) + "↻ " + dailyReset + color(.reset)
            + planTag
        print(dailyLine)

        // Wk line — always rendered (this is the "weekly refresh" the user
        // explicitly asked for).
        let weeklyBar = bar(snapshot.weeklyPercent, width: 24)
        let weeklyHint = isOpenCodeHeuristic(snapshot)
            ? "  " + color(.dim) + "(rolling window est.)" + color(.reset)
            : ""
        let weeklyLine = "           " + color(.dim) + "Wk" + color(.reset) + " "
            + weeklyBar + " "
            + colorize(weeklyText, weeklyColor)
            + "  " + color(.dim) + "↻ " + weeklyReset + color(.reset)
            + weeklyHint
        print(weeklyLine)

        if !singleFrame, let tokens = snapshot.totalTokens, tokens > 0 {
            let refreshed = relativeRefreshed(snapshot.updatedAt)
            let footer = "           " + color(.dim)
                + UsageFormat.tokenText(tokens) + " tokens · updated " + refreshed
                + color(.reset)
            print(footer)
        }
    }

    @MainActor
    private static func isOpenCodeHeuristic(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.provider == .opencode && snapshot.planLabel == "est."
    }

    // MARK: - ANSI helpers

    private enum AnsiColor {
        case red, green, orange, dim, bold, reset, secondary
    }

    private static func color(_ which: AnsiColor) -> String {
        guard isatty(STDOUT_FILENO) != 0 else { return "" }
        switch which {
        case .red:       return "\u{1B}[31m"
        case .green:     return "\u{1B}[32m"
        case .orange:    return "\u{1B}[33m"
        case .dim:       return "\u{1B}[2m"
        case .bold:      return "\u{1B}[1m"
        case .secondary: return "\u{1B}[90m"
        case .reset:     return "\u{1B}[0m"
        }
    }

    private static func colorize(_ text: String, _ nscolor: NSColor) -> String {
        // Map AppKit NSColor → ANSI escape. Keeps the color logic in one place
        // (UsageFormat.color) so the Touch Bar and CLI agree on what "warn"
        // and "alert" look like.
        let mapped: AnsiColor
        switch nscolor {
        case NSColor.systemGreen:  mapped = .green
        case NSColor.systemOrange: mapped = .orange
        case NSColor.systemRed:    mapped = .red
        default:                   mapped = .secondary
        }
        return "\(color(mapped))\(text)\(color(.reset))"
    }

    /// Mini ASCII bar so the CLI doesn't need a TUI library. `width` is the
    /// total bar width in characters (including brackets).
    private static func bar(_ percent: Double?, width: Int) -> String {
        let inner = max(0, width - 2)
        let fillCount: Int
        if let percent {
            let clamped = max(0, min(100, percent))
            fillCount = Int((Double(inner) * clamped / 100).rounded())
        } else {
            fillCount = 0
        }
        let emptyCount = inner - fillCount
        let fill = String(repeating: "█", count: fillCount)
        let empty = String(repeating: "░", count: emptyCount)
        return "[\(fill)\(empty)]"
    }

    private static func formatReset(_ date: Date?) -> String {
        guard let date else { return "—" }
        return UsageFormat.resetText(date)
    }

    private static func relativeRefreshed(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Signal handling

    private static let signalSource = DispatchSource.makeSignalSource(
        signal: SIGINT, queue: .main
    )
    nonisolated(unsafe) private static var signalInstalled = false

    private static func installSignalHandler() {
        guard !signalInstalled else { return }
        signalInstalled = true
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            // The handler runs on `.main`, so it's effectively on the
            // main actor — fine for the (currently empty) cleanup we need
            // to do. The live loop checks `stopRequested` at the top of
            // each tick and exits before the next render.
            CLI.requestStop()
        }
        signalSource.resume()
    }

    // MARK: - Default collector set

    /// Same providers as the Touch Bar app, in the same order, so a user who
    /// arranges providers in the GUI sees the identical set in the CLI.
    static func defaultCollectors() -> [UsageCollecting] {
        [
            ClaudeUsageCollector(),
            CodexUsageCollector(),
            OpenCodeUsageCollector()
        ]
    }
}

// MARK: - Live-cache bypass hook (used by `refresh`)

extension UsageStore {
    /// Clears the in-memory caches used by every collector so the next
    /// `refresh()` is forced to re-read its source of truth — the network for
    /// Claude/Codex, the local SQLite DB for OpenCode. Mirrors the "Always
    /// refresh" affordance the Touch Bar's manual refresh button provides.
    @MainActor
    static func flushLiveCaches() {
        ClaudeUsageCollector.flushLiveCache()
        CodexUsageCollector.flushLiveCache()
        OpenCodeUsageCollector.flushLiveCache()
    }
}
