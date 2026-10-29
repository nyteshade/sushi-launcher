import Foundation

/// Owns one `sushi serve` child process: launches it with the arguments the
/// flag registry builds, streams stdout/stderr into a ring buffer, decides
/// when the server is actually ready (banner match raced against an HTTP
/// probe of /v1/models), and stops it politely (SIGTERM, then SIGKILL).
@MainActor
final class ServerController: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let date: Date
        let stream: LogStream
        let text: String
        let level: LogLevel

        /// Badge shown in the console, Copy and Save: level-based, because
        /// sushi logs everything to stderr — the pipe says nothing useful.
        var label: String { stream == .system ? "APP" : level.badge }
    }

    enum Status: Equatable {
        case stopped
        case starting
        case running(Date)
        case exited(Int32)
        case failed(String)

        var label: String {
            switch self {
            case .stopped:        return "Stopped"
            case .starting:       return "Starting…"
            case .running:        return "Serving"
            case .exited(let c):  return c == 0 ? "Exited" : "Exited (\(c))"
            case .failed:         return "Launch failed"
            }
        }
    }

    @Published var status: Status = .stopped
    @Published private(set) var lines: [Line] = []
    private(set) var pid: Int32 = 0
    let maxLines = 20_000

    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private let pending = PendingLines()
    private var drainTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var nextLineID = 0
    private var lastLaunch: (config: LaunchConfig, settings: AppSettings)?
    private var runningArgs: [String] = []

    var isStarting: Bool { if case .starting = status { return true }; return false }
    var isRunning: Bool { if case .running = status { return true }; return false }
    var isBusy: Bool { isStarting || isRunning }

    var runningCommandLinePreview: String {
        runningArgs.isEmpty ? "" : "sushi " + runningArgs.joined(separator: " ")
    }

    // MARK: - Start / stop

    func start(config: LaunchConfig, settings: AppSettings) {
        guard !isBusy else { return }
        guard let binary = SushiBinary.resolve(customPath: settings.sushiPathOverride) else {
            status = .failed("sushi not found")
            addLine(.system, "Could not find the sushi binary. Set its path in Settings (⌘,), or install with: brew install beamivalice/tap/sushi")
            return
        }
        var args = config.arguments()
        if settings.autoParentPid, !config.isSet("parent-pid") {
            // sushi's own watchdog: it SIGTERMs itself if this app dies.
            args += ["--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        }
        lastLaunch = (config, settings)
        runningArgs = args
        lines.removeAll()
        nextLineID = 0

        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.environment = SushiEnvironment.build()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let buffer = pending
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { buffer.append(.stdout, s) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { buffer.append(.stderr, s) }
        }

        addLine(.system, "Launching: \(binary.path) \(args.joined(separator: " "))")
        do {
            try p.run()
        } catch {
            status = .failed(error.localizedDescription)
            addLine(.system, "Launch failed: \(error.localizedDescription)")
            return
        }
        process = p
        outPipe = out
        errPipe = err
        pid = p.processIdentifier
        status = .starting
        startDraining()
        startReadinessProbe(host: config.hostText, port: config.portInt)
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        addLine(.system, "Stopping server (SIGTERM)…")
        p.terminate()
        Task { [weak p] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    func restart() {
        guard let last = lastLaunch else { return }
        stop()
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(8)
            while self.process != nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.start(config: last.config, settings: last.settings)
        }
    }

    func clearLog() {
        lines.removeAll()
        nextLineID = 0
    }

    // MARK: - Drain loop (UI updates batch ~5×/s)

    private func startDraining() {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard let self, !Task.isCancelled else { return }
                self.drainOnce()
            }
        }
    }

    private func drainOnce() {
        let batch = pending.drain()
        if !batch.isEmpty {
            for entry in batch { addLine(entry.stream, entry.text) }
            detectMarkers(batch.map { $0.text })
        }
        if let p = process, !p.isRunning {
            let code = p.terminationStatus
            for entry in pending.drainTrailing() { addLine(entry.stream, entry.text) }
            addLine(.system, code == 0 ? "Server exited cleanly." : "Server exited with status \(code).")
            teardown()
            status = .exited(code)
        }
    }

    private func detectMarkers(_ texts: [String]) {
        for text in texts {
            let lower = text.lowercased()
            if lower.contains("server: http") || lower.contains("listening") || lower.contains("serving at") {
                markReady(detail: text.trimmed)
                if !isStarting { return }
            }
            if lower.contains("already in use") || lower.contains("address in use") {
                addLine(.system, "The port is busy — another sushi may already be running. Stop it, or change the port in Quick settings.")
            }
        }
    }

    private func markReady(detail: String) {
        guard case .starting = status else { return }
        status = .running(Date())
        probeTask?.cancel()
        addLine(.system, "Server is ready — \(detail)")
    }

    // MARK: - Readiness probe (banner match races an HTTP poll of /v1/models)

    private func startReadinessProbe(host: String, port: Int) {
        probeTask?.cancel()
        let displayHost = (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
        guard let url = URL(string: "http://\(displayHost):\(port)/v1/models") else { return }
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isStarting else { return }
                if await Self.probe(url) {
                    self.markReady(detail: url.absoluteString)
                    return
                }
            }
        }
    }

    private static func probe(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (200..<500).contains(code)
    }

    private func teardown() {
        drainTask?.cancel(); drainTask = nil
        probeTask?.cancel(); probeTask = nil
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outPipe = nil
        errPipe = nil
        pid = 0
    }

    // MARK: - Buffer

    private func addLine(_ stream: LogStream, _ text: String) {
        let level = detectLogLevel(stream: stream, text: text)
        lines.append(Line(id: nextLineID, date: Date(), stream: stream, text: text, level: level))
        nextLineID += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
