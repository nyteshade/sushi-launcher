import Foundation

// MARK: - Config migration
//
// A persisted launch config outlives the sushi binary that wrote it. When
// sushi removes a flag, the saved config keeps passing it, and the launch
// fails with an error that names a flag the user never typed — they picked
// it from a menu months ago.
//
// This is the data-evolution problem, and the rules that apply are the
// generic ones: the store carries its own version, migration is idempotent,
// and a value the migration cannot know is never fabricated.
//
// Two kinds of change, deliberately separated:
//
//   RENAME — the CLI named a successor and the value carries over. Only
//            these can be derived from the CLI's own error message, and
//            only where the successor means the same thing.
//   DROP   — the flag is gone with no successor. Derived from the
//            conformance report, so a future removal needs no edit here.
//
// A rename is NOT mechanical even when the CLI names a successor:
// `--prefix-cache-entries 1` became `--max-concurrent 1` because the RAM
// prefix cache is now sized by max_concurrent, but `--prefill-chunk 2048`
// became `--prefill-chunk-max 2048` because the flag was split in two. The
// table below records those judgements; the drops do not need one.

enum ConfigMigration {

    struct Outcome {
        var config: LaunchConfig
        var changes: [String] = []
        var warnings: [String] = []
        var didChange: Bool { !changes.isEmpty }
    }

    /// Flags whose successor is a judgement call, not a mechanical rewrite.
    /// Keyed by the removed id; the value is the surviving id.
    static let renames: [String: String] = [
        // "a model's RAM prefix cache keeps as many finished conversations as
        //  its max_concurrent; set max_concurrent (--max-concurrent)"
        "prefix-cache-entries": "max-concurrent",
        // "use --prefill-chunk-max <n> and --prefill-chunk-min <n>"; the
        // single old ceiling maps onto the new maximum.
        "prefill-chunk": "prefill-chunk-max",
    ]

    // MARK: Migrate

    /// Bring `config` up to the current schema, then reconcile it against the
    /// installed CLI. Idempotent: running it twice produces identical state.
    ///
    /// Two passes, deliberately different in kind:
    ///   • the VERSIONED pass (renames, path repair) runs once, gated on the
    ///     stamp, and advances it;
    ///   • the RECONCILE pass (drop flags the CLI rejects) is not versioned —
    ///     it is a statement about the installed binary, so it runs whenever a
    ///     conformance report is available, including on a config already at
    ///     the current version.
    static func migrate(_ config: LaunchConfig,
                        conformance: CLIConformance.Report?) -> Outcome {
        var out = Outcome(config: config)

        // Refuse too-new data cleanly rather than writing over a shape this
        // binary does not understand.
        if config.schemaVersion > LaunchConfig.currentSchemaVersion {
            out.warnings.append(
                "This launch config was written by a newer version of Sushi Launcher "
                + "(schema \(config.schemaVersion); this build understands \(LaunchConfig.currentSchemaVersion)). "
                + "It has been left untouched — update the app rather than editing it by hand.")
            return out
        }

        if out.config.schemaVersion < LaunchConfig.currentSchemaVersion {
            migrateV1toV2(&out)
            out.config.schemaVersion = LaunchConfig.currentSchemaVersion
        }

        reconcile(&out, conformance: conformance)
        return out
    }

    /// v1 → v2: sushi 1.8 removed six flags. Rename the two with successors
    /// and repair a model path that no longer resolves.
    private static func migrateV1toV2(_ out: inout Outcome) {
        // Renames first, so a renamed flag is not also dropped.
        for (old, new) in renames.sorted(by: { $0.key < $1.key }) {
            guard let assignment = out.config.assignments[old] else { continue }
            out.config.assignments.removeValue(forKey: old)
            if out.config.assignments[new] == nil {
                out.config.assignments[new] = assignment
                out.changes.append("--\(old) → --\(new) (sushi renamed it)")
            } else {
                out.changes.append("--\(old) dropped (--\(new) was already set)")
            }
        }

        // Repair a model path that does not exist. Only when the pack can
        // actually be found — a migration never invents a path.
        if let model = out.config.assignments["model"],
           let path = model.value.stringValue {
            let expanded = path.expandingTilde
            if !FileManager.default.fileExists(atPath: expanded),
               let repaired = resolveExistingPack(for: expanded) {
                out.config.assignments["model"] = OptionAssignment(
                    included: model.included, value: .string(repaired))
                out.changes.append("model path → \(repaired) (the saved path did not exist)")
            }
        }
    }

    /// Drop flags the installed CLI rejects. Derived from the conformance
    /// report, so a future removal needs no edit here.
    private static func reconcile(_ out: inout Outcome,
                                  conformance: CLIConformance.Report?) {
        guard let conformance else {
            out.warnings.append(
                "Could not check the installed sushi version, so flags it may have removed were left in place.")
            return
        }
        let deadIDs = Set(conformance.dead.map { $0.id })
        for id in out.config.assignments.keys.sorted() where deadIDs.contains(id) {
            out.config.assignments.removeValue(forKey: id)
            out.changes.append("--\(id) dropped (removed in \(conformance.version))")
        }
    }

    /// Find the pack the saved path meant, under either layout `sushi pull`
    /// uses. Returns nil when nothing matches — the caller then leaves the
    /// path alone and the launch reports it.
    static func resolveExistingPack(for path: String) -> String? {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.sushi/models/\(name)",
            "\(home)/.sushi/models/beamster/\(name)",
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate) {
            return candidate.replacingOccurrences(of: home, with: "~")
        }
        return nil
    }
}
