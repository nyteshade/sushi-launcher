import Foundation

// MARK: - CLI conformance
//
// SushiOptionRegistry is a TRANSCRIPTION of `sushi serve --help`. A
// transcription drifts: sushi 1.8.1 removed six flags the registry still
// offered and added nine it did not know, and nothing noticed until a
// launch failed with exit 1.
//
// This file closes that loop. It reads the INSTALLED binary's own help,
// diffs it against the registry, and classifies the difference:
//
//   dead    — a registry flag the CLI no longer accepts. The CLI's own
//             error message usually names the replacement, so a dead flag
//             is reported WITH its successor rather than as a bare loss.
//   missing — a flag the CLI accepts that the registry cannot express.
//   inert   — a registry flag the CLI accepts and ignores. Worse than dead:
//             it launches, and the setting silently does nothing.
//
// The point is that the next version bump reports itself. Nobody has to
// remember to re-read a help page.

enum CLIConformance {

    // MARK: Report

    struct DeadFlag: Identifiable {
        let id: String              // registry id, e.g. "prefill-chunk"
        let message: String         // what the CLI said
        let replacements: [String]  // flags the CLI named as successors
        var hasReplacement: Bool { !replacements.isEmpty }
    }

    struct Report {
        var version: String = ""
        var dead: [DeadFlag] = []
        var missing: [String] = []
        var inert: [String] = []
        var checkedAt: Date = Date()
        var failure: String? = nil

        var isClean: Bool { dead.isEmpty && missing.isEmpty && inert.isEmpty }
        var issueCount: Int { dead.count + missing.count + inert.count }

        /// One line for a banner.
        var summary: String {
            if let failure { return "Conformance check failed: \(failure)" }
            if isClean { return "Registry matches \(version)." }
            var parts: [String] = []
            if !dead.isEmpty { parts.append("\(dead.count) removed") }
            if !missing.isEmpty { parts.append("\(missing.count) unmodelled") }
            if !inert.isEmpty { parts.append("\(inert.count) inert") }
            return "Registry drifted from \(version): " + parts.joined(separator: ", ") + "."
        }
    }

    // MARK: Non-serve options
    //
    // `sushi serve --help` prints the whole option list, which includes
    // switches that are not serve flags: the mode selector, the one-shot
    // prompt path, and the informational switches that exit before serving.
    // Derived from the help's own "Commands:" section plus the options that
    // terminate the process. Everything else in the Options: block is a
    // serve flag and belongs in the registry.
    static let nonServeOptions: Set<String> = [
        "serve", "prompt", "stream", "version", "help", "guest-manifest",
    ]

    // MARK: Parsing

    /// Extract flag → description from the help's `Options:` block.
    /// A block starts at a line whose first token is `--flag` and runs until
    /// the next such line, so wrapped descriptions stay with their flag.
    static func parseOptions(_ help: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var body: [String] = []
        var inOptions = false

        func flush() {
            if let current { out[current] = body.joined(separator: " ").trimmed }
            current = nil
            body = []
        }

        for rawLine in help.components(separatedBy: "\n") {
            let line = rawLine
            if line.hasPrefix("Options:") { inOptions = true; continue }
            guard inOptions else { continue }

            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }

            // A new option block begins with --flag (possibly "--help, -h").
            if trimmedLine.hasPrefix("--") {
                flush()
                let token = trimmedLine.components(separatedBy: CharacterSet(charactersIn: " ,")).first ?? ""
                current = String(token.dropFirst(2))
                body = [trimmedLine]
            } else if current != nil {
                body.append(trimmedLine)
            }
        }
        flush()
        return out
    }

    /// The serve flags the CLI actually accepts, as bare ids.
    static func serveFlags(from help: String) -> Set<String> {
        Set(parseOptions(help).keys).subtracting(nonServeOptions)
    }

    // MARK: Checking

    /// Run the check against the resolved binary. BLOCKS — call off the main thread.
    static func check(customPath: String?) -> Report {
        var report = Report()
        guard let exe = SushiBinary.resolve(customPath: customPath) else {
            report.failure = "sushi not found"
            return report
        }
        guard let helpResult = Shell.runCapture(exe.path, ["serve", "--help"], timeout: 30),
              !helpResult.stdout.trimmed.isEmpty else {
            report.failure = "could not read `sushi serve --help`"
            return report
        }
        let help = helpResult.stdout
        let descriptions = parseOptions(help)
        let cliFlags = serveFlags(from: help)

        if let v = Shell.runCapture(exe.path, ["--version"], timeout: 15) {
            report.version = v.stdout.components(separatedBy: "\n").first?.trimmed ?? ""
        }

        // Registry flags the CLI does not accept, and flags it accepts but ignores.
        for option in SushiOptionRegistry.all {
            if !cliFlags.contains(option.id) {
                let probe = probeDeadFlag(option, exe: exe)
                // The probe outranks the help parse: a flag the CLI accepts is
                // not dead, even when the help page does not list it.
                if probe.accepted { continue }
                report.dead.append(DeadFlag(id: option.id,
                                            message: probe.message,
                                            replacements: probe.replacements))
            } else if isInert(option, descriptions: descriptions) {
                report.inert.append(option.id)
            }
        }

        // CLI flags the registry cannot express. A `--no-X` is covered when the
        // registry models X as an .onOff (the negation is generated, not stored).
        let modelled = Set(SushiOptionRegistry.all.map { $0.id })
        let negations = Set(SushiOptionRegistry.all.filter {
            if case .onOff = $0.kind { return true }
            return false
        }.map { $0.id })
        report.missing = cliFlags
            .filter { flag in
                if modelled.contains(flag) { return false }
                if flag.hasPrefix("no-"), negations.contains(String(flag.dropFirst(3))) { return false }
                return true
            }
            .sorted()

        return report
    }

    /// A flag is inert when the CLI's own help says it does nothing.
    ///
    /// The scan covers EVERY description, not just the flag's own, because an
    /// inert flag is often not listed as a block at all: `--metrics` has no
    /// entry of its own — it is mentioned only at the end of `--no-metrics`'s
    /// description ("--metrics is accepted and does nothing"). The sentence
    /// must name THIS flag as its subject, so that mention marks `--metrics`
    /// inert without marking the working `--no-metrics` inert too.
    static func isInert(_ option: SushiOption, descriptions: [String: String]) -> Bool {
        let own = option.flagName.lowercased()
        for text in descriptions.values {
            for sentence in text.lowercased().components(separatedBy: ".") {
                guard sentence.contains("does nothing") else { continue }
                if sentence.contains(own) { return true }
            }
        }
        return false
    }

    /// Ask the CLI why it rejects a flag, and pull the successor flags out of
    /// its answer. A value-taking flag is probed with a value so the CLI
    /// reports removal rather than a missing argument.
    private static func probeDeadFlag(_ option: SushiOption,
                                      exe: URL) -> (accepted: Bool, message: String, replacements: [String]) {
        var args: [String] = [option.flagName]
        switch option.kind {
        case .presence, .onOff:
            break
        case .int(let d):    args.append(String(d))
        case .double(let d): args.append(String(d))
        case .text(let d):   args.append(d.isEmpty ? "x" : d)
        case .choice(let c): args.append(c.first ?? "x")
        }
        args.append("--version")

        guard let r = Shell.runCapture(exe.path, args, timeout: 15) else {
            return (false, "could not probe the flag", [])
        }
        let message = ([r.stdout, r.stderr]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: " "))
            .components(separatedBy: "\n")
            .first?.trimmed ?? "rejected"

        // Success means the flag is fine and the diff was a parsing artifact.
        if r.status == 0 { return (true, "accepted (help parse disagreed)", []) }

        return (false, message, replacementFlags(in: message, excluding: option.id))
    }

    /// `--prefill-chunk is removed: use --prefill-chunk-max <n> and
    /// --prefill-chunk-min <n>` → ["prefill-chunk-max", "prefill-chunk-min"]
    ///
    /// `--help` is excluded: an "unrecognized argument" message ends with
    /// "see --help for the flag list", and offering --help as the replacement
    /// for a removed flag is worse than offering nothing.
    static func replacementFlags(in message: String, excluding id: String) -> [String] {
        let pattern = "--[a-z0-9][a-z0-9-]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(message.startIndex..., in: message)
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: message, range: range) {
            guard let r = Range(match.range, in: message) else { continue }
            let flag = String(message[r].dropFirst(2))
            guard flag != id, flag != "help", !seen.contains(flag) else { continue }
            seen.insert(flag)
            out.append(flag)
        }
        return out
    }
}

// MARK: - Launch validation
//
// The single decision point for "may this configuration be launched?".
// Both the Start button and the command preview ask it, so a configuration
// that cannot work is refused in the UI instead of failing 30 seconds into
// a model load.

enum LaunchValidator {
    enum Severity { case blocking, warning }

    struct Issue: Identifiable {
        let id = UUID()
        var severity: Severity
        var flag: String
        var message: String
    }

    /// Everything wrong with `config` given the installed CLI and the model
    /// family it targets. Blocking issues mean sushi will exit non-zero.
    static func issues(config: LaunchConfig,
                       conformance: CLIConformance.Report?) -> [Issue] {
        var out: [Issue] = []
        let family = config.family

        // 1. Flags the installed CLI no longer accepts.
        if let conformance {
            for dead in conformance.dead {
                guard config.isSet(dead.id) else { continue }
                let fix = dead.hasReplacement
                    ? " Use \(dead.replacements.map { "--" + $0 }.joined(separator: " / ")) instead."
                    : ""
                out.append(Issue(severity: .blocking,
                                 flag: "--" + dead.id,
                                 message: "sushi \(conformance.version) no longer accepts --\(dead.id).\(fix)"))
            }
            for inert in conformance.inert where config.isSet(inert) {
                out.append(Issue(severity: .warning,
                                 flag: "--" + inert,
                                 message: "--\(inert) is accepted by sushi and does nothing — the setting will not take effect."))
            }
        }

        // 2. Flags (or values) the model family refuses at load.
        for option in SushiOptionRegistry.all {
            guard config.isSet(option.id) else { continue }
            let value = config.assignment(for: option).value.stringValue
            if let refusal = option.refusal(family: family, value: value) {
                out.append(Issue(severity: .blocking,
                                 flag: option.flagName,
                                 message: "\(family.label) refuses \(option.flagName)\(value.map { " \($0)" } ?? ""): \(refusal.reason)"))
            }
        }

        // 3. Families sushi no longer supports.
        if let note = family.supportNote {
            out.append(Issue(severity: .warning, flag: family.label, message: note))
        }

        // 4. A streamed pack needs a budget; DeepSeek refuses to load without one.
        if family == .deepseek, !config.isSet("ssd-budget-gb") {
            out.append(Issue(severity: .warning,
                             flag: "--ssd-budget-gb",
                             message: "DeepSeek-V4.1 streams its routed experts; sushi picks a budget from this Mac's RAM, but setting it explicitly is what the docs recommend."))
        }

        return out
    }

    static func blocking(_ issues: [Issue]) -> [Issue] {
        issues.filter { $0.severity == .blocking }
    }
}
