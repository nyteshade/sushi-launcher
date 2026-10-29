import Foundation

// MARK: - Finding sushi

enum SushiBinary {
    /// Resolve the sushi executable: explicit override first, then the
    /// usual install locations (Homebrew tap, ~/.local/bin, /usr/local/bin).
    static func resolve(customPath: String?) -> URL? {
        var candidates: [String] = []
        if let custom = customPath?.trimmed.nonEmpty {
            candidates.append(custom)
        }
        candidates += [
            "/opt/homebrew/bin/sushi",
            "/usr/local/bin/sushi",
            NSHomeDirectory() + "/.local/bin/sushi",
            "/usr/bin/sushi",
        ]
        let fm = FileManager.default
        for candidate in candidates {
            let path = candidate.expandingTilde
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

// MARK: - Child environment

enum SushiEnvironment {
    /// When macOS launches a .app from the Dock/Finder the PATH is minimal;
    /// give the child the paths sushi (and its helpers) expect.
    static func build() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let current = (env["PATH"] ?? "")
            .components(separatedBy: ":")
            .filter { !$0.isEmpty }
        var parts = extra.filter { !current.contains($0) }
        parts.append(contentsOf: current)
        env["PATH"] = parts.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["NO_COLOR"] = "1"
        return env
    }
}

// MARK: - Synchronous runner (for short commands: list, --version)

struct SushiRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum SushiRunner {
    /// Run sushi with captured output. BLOCKS — call from a background thread.
    static func run(args: [String], customPath: String?, timeout: TimeInterval = 120) -> SushiRunResult? {
        guard let exe = SushiBinary.resolve(customPath: customPath) else { return nil }
        guard let r = Shell.runCapture(exe.path, args, timeout: timeout) else { return nil }
        return SushiRunResult(status: r.status, stdout: r.stdout, stderr: r.stderr)
    }
}
