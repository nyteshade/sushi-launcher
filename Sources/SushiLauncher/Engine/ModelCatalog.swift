import Foundation

// MARK: - `sushi list` parsing

struct SushiPack: Identifiable, Hashable {
    enum Source: String, Hashable { case catalog, disk }

    let name: String
    var size: String
    var downloaded: Bool
    var status: String          // "fits", "may stream (--ssd-budget-gb)", "(not yet published)", "on disk", …
    var recommended: Bool
    var source: Source

    var id: String { source.rawValue + ":" + name }
    var sizeLabel: String { size.isEmpty ? "—" : size }
}

struct SushiListReport {
    var macTier: String?
    var packs: [SushiPack]
    var raw: String
}

/// Parses the fixed-width `sushi list` table. Rows we cannot make sense of
/// are skipped — the raw output is kept and shown as a fallback.
enum SushiListParser {
    static func parse(_ output: String) -> SushiListReport {
        var tier: String?
        var packs: [SushiPack] = []
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmed
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("this mac:") {
                tier = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmed
                continue
            }
            if isHeader(lower) { continue }
            if let pack = parseRow(line) { packs.append(pack) }
        }
        return SushiListReport(macTier: tier, packs: packs, raw: output)
    }

    private static func isHeader(_ lower: String) -> Bool {
        lower.hasPrefix("pack ") || (lower.contains("downloaded") && lower.contains("size"))
            || lower.hasPrefix("models on disk") || lower.hasPrefix("this mac")
            || lower.hasPrefix("no network") || lower.hasPrefix("hugging face unreachable")
    }

    private static func parseRow(_ line: String) -> SushiPack? {
        let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return nil }
        let name = tokens[0]
        guard !name.hasSuffix(":"), !name.hasPrefix("("), !name.hasPrefix("-") else { return nil }

        var index = 1
        var size = ""
        if tokens.count >= index + 1, isNumberToken(tokens[index]), hasUnitToken(tokens[index + 1]) {
            size = tokens[index] + " " + tokens[index + 1]
            index += 2
        }
        var downloaded = false
        if index < tokens.count, tokens[index] == "yes" || tokens[index] == "no" {
            downloaded = (tokens[index] == "yes")
            index += 1
        }
        var statusTokens = Array(tokens[min(index, tokens.count)...])
        var recommended = false
        if let marker = statusTokens.firstIndex(of: "<-") {
            recommended = true
            statusTokens = Array(statusTokens[0..<marker])
        }
        var status = statusTokens.joined(separator: " ")
        if status.isEmpty, downloaded { status = "on disk" }
        guard !status.isEmpty || downloaded || !size.isEmpty else { return nil }

        return SushiPack(name: name, size: size, downloaded: downloaded,
                         status: status, recommended: recommended, source: .catalog)
    }

    private static func isNumberToken(_ token: String) -> Bool {
        let stripped = token.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
        return !stripped.isEmpty && stripped.allSatisfy { $0.isNumber }
    }

    private static func hasUnitToken(_ token: String) -> Bool {
        ["GB", "MB", "TB", "GiB", "MiB", "TiB"].contains(token)
    }
}

extension SushiPack {
    /// Match the current `--model` value back to a curated pack: either the
    /// short name itself, or the installed folder it points at
    /// (e.g. qwen3.8-flash-next:2bpw ↔ ~/.sushi/models/...-Sushi-2bpw).
    static func match(modelText: String, in packs: [SushiPack]) -> SushiPack? {
        let last = (modelText.trimmed as NSString).lastPathComponent
        let target = normalize(last)
        guard !target.isEmpty else { return nil }
        if let exact = packs.first(where: { normalize($0.name) == target }) { return exact }
        return packs.first {
            let n = normalize($0.name)
            return n.contains(target) || target.contains(n)
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "sushi", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Catalog

/// Runs `sushi list` on demand and streams `sushi pull` in the background.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var report = SushiListReport(macTier: nil, packs: [], raw: "")
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    @Published private(set) var pullingPack: String?
    @Published private(set) var pullLog: [String] = []

    var packs: [SushiPack] { report.packs }
    var macTier: String? { report.macTier }

    private let pullPending = PendingLines()
    private var pullProcess: Process?
    private var pullOutPipe: Pipe?
    private var pullErrPipe: Pipe?
    private var pullDrainTask: Task<Void, Never>?
    private var lastRefresh: Date?
    private var lastCustomPath = ""

    // MARK: list

    func refreshIfNeeded(customPath: String, force: Bool = false) {
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > 300 } ?? true
        if force || stale || packs.isEmpty { refresh(customPath: customPath) }
    }

    func refresh(customPath: String) {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        lastCustomPath = customPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SushiRunner.run(args: ["list"], customPath: customPath, timeout: 120)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.lastRefresh = Date()
                guard let result else {
                    self.lastError = "sushi not found — set its path in Settings (⌘,)."
                    return
                }
                if result.stdout.trimmed.isEmpty {
                    self.lastError = "sushi list failed: "
                        + (result.stderr.trimmed.nonEmpty ?? "exit status \(result.status)")
                    return
                }
                self.report = SushiListParser.parse(result.stdout)
                if self.report.packs.isEmpty {
                    self.lastError = "Could not parse `sushi list` output — showing raw text."
                }
            }
        }
    }

    // MARK: pull

    func pull(_ pack: String, customPath: String) {
        guard pullingPack == nil else { return }
        guard let exe = SushiBinary.resolve(customPath: customPath) else {
            lastError = "sushi not found — set its path in Settings."
            return
        }
        lastCustomPath = customPath
        let p = Process()
        p.executableURL = exe
        p.arguments = ["pull", pack]
        p.environment = SushiEnvironment.build()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let buffer = pullPending
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { buffer.append(.stdout, s) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { buffer.append(.stderr, s) }
        }
        do {
            try p.run()
        } catch {
            lastError = "pull failed: \(error.localizedDescription)"
            return
        }
        pullProcess = p
        pullOutPipe = out
        pullErrPipe = err
        pullingPack = pack
        pullLog = ["$ \(exe.path) pull \(pack)"]
        startPullDrain()
    }

    func cancelPull() { pullProcess?.terminate() }

    func dismissPullLog() {
        guard pullingPack == nil else { return }
        pullLog.removeAll()
    }

    private func startPullDrain() {
        pullDrainTask?.cancel()
        pullDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pullDrainOnce()
            }
        }
    }

    private func pullDrainOnce() {
        for entry in pullPending.drain() where !entry.text.isEmpty {
            pullLog.append(entry.text)
        }
        if pullLog.count > 3000 { pullLog.removeFirst(pullLog.count - 3000) }

        if let p = pullProcess, !p.isRunning {
            for entry in pullPending.drainTrailing() where !entry.text.isEmpty {
                pullLog.append(entry.text)
            }
            pullOutPipe?.fileHandleForReading.readabilityHandler = nil
            pullErrPipe?.fileHandleForReading.readabilityHandler = nil
            let code = p.terminationStatus
            pullLog.append(code == 0 ? "— pull finished" : "— pull exited with status \(code)")
            pullingPack = nil
            pullProcess = nil
            pullOutPipe = nil
            pullErrPipe = nil
            pullDrainTask?.cancel()
            pullDrainTask = nil
            refresh(customPath: lastCustomPath)
        }
    }
}
