import Foundation
import AppKit

// MARK: - String conveniences

extension String {
    /// NSString tilde expansion for paths typed by the user.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension FileManager {
    func ensureDirectory(_ url: URL) {
        try? createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Subprocess helpers (call off the main thread)

enum Shell {
    /// Run a program and capture stdout/stderr. BLOCKS.
    @discardableResult
    static func runCapture(_ path: String, _ arguments: [String],
                           timeout: TimeInterval = 60) -> (status: Int32, stdout: String, stderr: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.environment = SushiEnvironment.build()
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate() }
        group.wait()
        return (task.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    /// Run a shell command with administrator privileges via the macOS
    /// authorization panel (password / Touch ID). BLOCKS.
    @discardableResult
    static func runPrivileged(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return runCapture("/usr/bin/osascript", ["-e", script], timeout: 300)?.status == 0
    }
}

// MARK: - GPU wired limit
//
// sushi's docs are explicit that the GPU limit is only half the setting:
//
//   "Every GPU limit below is set together with the two user-wire limits,
//    always, at the same value in bytes (N MB becomes N × 1,048,576 bytes);
//    otherwise macOS keeps capping what sushi may wire at its lower default
//    and prefill slows with no error."
//
// So the unit of work is the TRIPLE, not the GPU key. Setting only
// iogpu.wired_limit_mb — which is what this app used to do — leaves the two
// user-wire limits at whatever they were, and the cap silently wins.

enum GPULimit {
    static let sysctlKey = "iogpu.wired_limit_mb"
    static let userWireKeys = ["vm.global_user_wire_limit", "vm.user_wire_limit"]

    /// Bytes per MB, as the docs define the conversion.
    static let bytesPerMB = 1_048_576

    /// The three keys, in the order the docs' command sets them.
    static var allKeys: [String] { [sysctlKey] + userWireKeys }

    /// The byte value the two user-wire limits must carry for a given MB.
    static func wireBytes(forMB mb: Int) -> Int { mb * bytesPerMB }

    // MARK: Reading

    /// Current GPU limit in MB, or nil when unreadable. BLOCKS.
    static func currentMB() -> Int? {
        guard let r = Shell.runCapture("/usr/sbin/sysctl", ["-n", sysctlKey], timeout: 10),
              r.status == 0 else { return nil }
        return Int(r.stdout.trimmed)
    }

    /// All three limits as they are now. BLOCKS.
    struct State {
        var gpuMB: Int?
        var globalWireBytes: Int?
        var userWireBytes: Int?

        /// True when both user-wire limits carry the GPU limit's byte value.
        /// A false here is the silent-prefill-slowdown condition.
        var isConsistent: Bool {
            guard let gpuMB else { return false }
            let want = GPULimit.wireBytes(forMB: gpuMB)
            return globalWireBytes == want && userWireBytes == want
        }

        /// The user-wire limits expressed in MB, for a readable message.
        var globalWireMB: Int? { globalWireBytes.map { $0 / GPULimit.bytesPerMB } }
        var userWireMB: Int? { userWireBytes.map { $0 / GPULimit.bytesPerMB } }
    }

    static func readState() -> State {
        var state = State()
        state.gpuMB = currentMB()
        if let r = Shell.runCapture("/usr/sbin/sysctl", ["-n"] + userWireKeys, timeout: 10),
           r.status == 0 {
            // `sysctl -n a b` prints one value per line, in argument order.
            let values = r.stdout
                .components(separatedBy: "\n")
                .map { $0.trimmed }
                .filter { !$0.isEmpty }
            if values.count >= 2 {
                state.globalWireBytes = Int(values[0])
                state.userWireBytes = Int(values[1])
            }
        }
        return state
    }

    // MARK: Writing

    /// The command the docs prescribe, as one string.
    static func command(mb: Int) -> String {
        let bytes = wireBytes(forMB: mb)
        return "/usr/sbin/sysctl \(sysctlKey)=\(mb) "
            + userWireKeys.map { "\($0)=\(bytes)" }.joined(separator: " ")
    }

    /// Set all three limits, prompting for authorization once. BLOCKS.
    static func raise(mb: Int) -> Bool {
        Shell.runPrivileged(command(mb: mb))
    }

    /// A one-line description of what is wrong, or nil when consistent.
    static func inconsistencyNote(_ state: State) -> String? {
        guard let gpuMB = state.gpuMB else { return "Could not read \(sysctlKey)." }
        if state.isConsistent { return nil }
        let want = wireBytes(forMB: gpuMB)
        var parts: [String] = []
        if let g = state.globalWireBytes, g != want {
            parts.append("vm.global_user_wire_limit is \(g) bytes (\(g / bytesPerMB) MB)")
        }
        if let u = state.userWireBytes, u != want {
            parts.append("vm.user_wire_limit is \(u) bytes (\(u / bytesPerMB) MB)")
        }
        if parts.isEmpty { return nil }
        return "\(sysctlKey) is \(gpuMB) MB but \(parts.joined(separator: " and ")) — both must be \(want) bytes (\(gpuMB) MB). macOS caps what sushi may wire at the lower value and prefill slows with no error."
    }
}

// MARK: - Small UI conveniences (main thread)

enum UIActions {
    static func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    static func openWeb(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    static func revealPath(_ path: String) {
        let url = URL(fileURLWithPath: path.expandingTilde)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            var parent = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent = parent.deletingLastPathComponent()
            }
            NSWorkspace.shared.open(parent)
        }
    }

    /// Non-blocking save panel; writes `content` if the user confirms.
    static func savePanel(suggestedName: String, content: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.data(using: .utf8)?.write(to: url)
        }
    }
}

// MARK: - JSON persistence (Application Support)

enum Storage {
    static let applicationDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SushiLauncher", isDirectory: true)
        FileManager.default.ensureDirectory(dir)
        return dir
    }()

    private static let configURL = applicationDirectory.appendingPathComponent("launch-config.json")
    private static let settingsURL = applicationDirectory.appendingPathComponent("settings.json")

    static func loadConfig() -> LaunchConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(LaunchConfig.self, from: data)
    }

    static func saveConfig(_ config: LaunchConfig) {
        guard let data = try? makeEncoder().encode(config) else { return }
        try? data.write(to: configURL)
    }

    static func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let data = try? makeEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
