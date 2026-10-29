import Foundation

/// Which stream a log line came from.
enum LogStream {
    case stdout
    case stderr
    case system   // the launcher's own narration

    var tag: String {
        switch self {
        case .stdout: return "OUT"
        case .stderr: return "ERR"
        case .system: return "APP"
        }
    }
}

/// Severity of a log line, derived from its CONTENT rather than its pipe:
/// sushi (Zig std.log style) writes nearly all diagnostics — routine,
/// warning and fatal alike — to stderr, so the stream alone is a poor signal.
enum LogLevel {
    case info, warning, error, debug
}

func detectLogLevel(stream: LogStream, text: String) -> LogLevel {
    let lower = text.lowercased()
    let head = lower.trimmingCharacters(in: .whitespaces)

    // Leading level prefixes: "err: …", "warn: …", etc.
    if head.hasPrefix("err:") || head.hasPrefix("error:")
        || head.hasPrefix("fatal:") || head.hasPrefix("panic:") { return .error }
    if head.hasPrefix("warn:") || head.hasPrefix("warning:") { return .warning }
    if head.hasPrefix("debug:") || head.hasPrefix("trace:") { return .debug }

    // The launcher's own narration.
    if stream == .system {
        let bad = ["failed", "exited with status", "could not", "not found"]
        return bad.contains(where: head.contains) ? .error : .info
    }

    // Periodic engine chatter → debug (dimmed, filtered out of the way).
    // [tag] prefixes are sushi subsystems, not severities.
    if head.hasPrefix("[spec-stats]") { return .debug }
    if head.contains("rss:") && head.contains("cpu:") && head.contains("gpu:") { return .debug }

    // Classic failure phrases, kept tight to avoid false alarms
    // ("Loading model-00039.safetensors…" must land on .info).
    let errorPhrases = ["error", "failed", "panic", "fatal", "abort", "denied",
                        "already in use", "not found", "unsupported", "refus",
                        "out of memory", "cannot run"]
    if errorPhrases.contains(where: head.contains) { return .error }
    let warnPhrases = ["warn", "deprecat", "retry", "may stream", "kernel-panic"]
    if warnPhrases.contains(where: head.contains) { return .warning }

    return .info
}

/// Thread-safe incremental line buffer: pipes hand us arbitrary UTF-8
/// chunks; we reassemble complete newline-terminated lines and hold them
/// until the UI drains them.
final class PendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var complete: [(stream: LogStream, text: String)] = []
    private var partial: [LogStream: String] = [:]

    func append(_ stream: LogStream, _ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        var text = (partial[stream] ?? "") + chunk
        var lines = text.components(separatedBy: "\n")
        text = lines.removeLast()          // trailing fragment, keep buffering
        partial[stream] = text
        for var line in lines {
            if line.hasSuffix("\r") { line.removeLast() }
            complete.append((stream, line))
        }
    }

    func drain() -> [(stream: LogStream, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        let result = complete
        complete.removeAll(keepingCapacity: true)
        return result
    }

    /// Drain everything, flushing any unterminated tail (call on exit).
    func drainTrailing() -> [(stream: LogStream, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        var result = complete
        complete.removeAll(keepingCapacity: true)
        for (stream, text) in partial where !text.isEmpty {
            result.append((stream, text))
        }
        partial.removeAll()
        return result
    }
}
