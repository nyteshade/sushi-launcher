import Foundation

// MARK: - Config derivation
//
// A launch configuration is DERIVED from three things a person can actually
// answer:
//
//   • the pack they want to run
//   • how much context they want
//   • how much of their Mac they are willing to give it
//
// Everything else — KV quantisation, GDN state width, prefill chunk, cache
// budgets, the GPU limit — follows from those by arithmetic. This replaces
// the old hand-transcribed presets, which were snapshots of one Mac's
// recipe: the 2.75bpw pack's only recipe was the 64 GB one, so a 128 GB Mac
// was offered 250k context and no way to see it had 4x the headroom.
//
// The derivation is the deliverable. A new pack needs a PackProfile, not a
// new preset per Mac size.

// MARK: - Intent

/// How much of the machine to spend. This is the "variance" a person picks.
enum MemoryPosture: String, CaseIterable, Identifiable, Codable {
    /// Leave room for other apps; the safe default.
    case balanced
    /// Give the model as much as it can use.
    case maximum
    /// Coexist with heavy other work (Xcode, Docker, a browser fleet).
    case conservative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced:     return "Balanced"
        case .maximum:      return "Maximum"
        case .conservative: return "Conservative"
        }
    }

    var note: String {
        switch self {
        case .balanced:
            return "Most of the GPU limit, leaving a working margin for other apps."
        case .maximum:
            return "The whole wired limit. Fastest, but other apps will feel it."
        case .conservative:
            return "A smaller share, so Xcode and a browser fleet stay comfortable."
        }
    }

    /// Fraction of the usable budget this posture will spend.
    var budgetFraction: Double {
        switch self {
        case .balanced:     return 0.90
        case .maximum:      return 1.00
        case .conservative: return 0.70
        }
    }
}

/// What the KV cache is stored at. Presented as a quality/context tradeoff,
/// not as a number.
enum KVQuality: String, CaseIterable, Identifiable, Codable {
    case quality
    case balanced
    case longContext

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quality:     return "Best quality"
        case .balanced:    return "Balanced"
        case .longContext: return "Longest context"
        }
    }

    var note: String {
        switch self {
        case .quality:     return "8-bit KV. The default; no measurable quality loss."
        case .balanced:    return "6-bit KV. Slightly smaller cache, still lossless in practice."
        case .longContext: return "4-bit KV. About 1.8x the context for the same memory."
        }
    }

    /// The `--kv-quant` value.
    var kvQuant: Int {
        switch self {
        case .quality:     return 8
        case .balanced:    return 6
        case .longContext: return 4
        }
    }

    /// Families that refuse this value, so the chooser can disable it.
    func isAvailable(for family: ModelFamily) -> Bool {
        switch self {
        case .quality:     return family != .deepseek
        case .balanced:    return family != .deepseek
        case .longContext: return family != .deepseek && family != .glm
        }
    }
}

// MARK: - Pack profile

/// What the deriver needs to know about a pack. Anchors come from the docs'
/// memory matrix; everything else is arithmetic on them.
struct PackProfile {
    var family: ModelFamily
    /// Resident weights in GiB, by bpw. Interpolated between anchors.
    var weightsAnchors: [(bpw: Double, gib: Double)]
    /// The smallest Mac the pack is documented for.
    var minMacGB: Int
    /// Whether the pack streams routed experts from SSD (DeepSeek, Hy4).
    var streamsExperts: Bool = false
    /// Whether the pack ships an n-gram table that MTP drafts against.
    var hasNgramTable: Bool = true

    func weightsGiB(atBPW bpw: Double) -> Double? {
        guard !weightsAnchors.isEmpty else { return nil }
        let a = weightsAnchors.sorted { $0.bpw < $1.bpw }
        if a.count == 1 { return a[0].gib * bpw / a[0].bpw }
        if bpw <= a[0].bpw { return a[0].gib * bpw / a[0].bpw }
        if bpw >= a[a.count - 1].bpw {
            let last = a[a.count - 1]
            return last.gib * bpw / last.bpw
        }
        for i in 1..<a.count where bpw <= a[i].bpw {
            let (x0, y0) = (a[i - 1].bpw, a[i - 1].gib)
            let (x1, y1) = (a[i].bpw, a[i].gib)
            guard x1 > x0 else { continue }
            return y0 + (y1 - y0) * (bpw - x0) / (x1 - x0)
        }
        return a[a.count - 1].gib
    }
}

// MARK: - Deriver

enum ConfigDeriver {

    /// A derived configuration plus the reasoning behind it, so the UI can
    /// show WHY rather than just what.
    struct Derived {
        var config: LaunchConfig
        var budget: MemoryModel.Budget
        var contextTokens: Int
        var kvQuant: Int
        var gpuLimitMB: Int
        /// Plain-language lines explaining each non-obvious choice.
        var rationale: [String]
        /// Things the person should know but that do not block.
        var warnings: [String]

        var fits: Bool { budget.fits }
    }

    /// Derive a configuration from intent.
    ///
    /// - Parameters:
    ///   - packName: the pack's folder or short name (family is detected).
    ///   - contextTokens: the window the person asked for.
    ///   - ramGB: this Mac's unified memory.
    ///   - posture: how much of it to spend.
    ///   - kv: the quality/context tradeoff.
    ///   - profile: the pack's memory anchors.
    static func derive(packName: String,
                       contextTokens: Int,
                       ramGB: Int,
                       posture: MemoryPosture,
                       kv: KVQuality,
                       profile: PackProfile) -> Derived {
        let family = profile.family
        let bpw = PackKnowledge.bpw(from: packName) ?? 4.0
        let weights = profile.weightsGiB(atBPW: bpw) ?? 0

        // The GPU limit is the posture's share of the standard limit, rounded
        // to the nearest 1000 MB because that is the granularity sysctl and
        // the docs' own recipes use.
        let standard = MemoryModel.standardLimitMB(forRAMGB: ramGB)
        let limitMB = Int((Double(standard) * posture.budgetFraction / 1000).rounded()) * 1000

        // KV quantisation: the person's choice, unless the family refuses it,
        // in which case fall back to the best it accepts.
        var kvQuant = kv.kvQuant
        var warnings: [String] = []
        if !kv.isAvailable(for: family) {
            if family == .deepseek {
                // No KV cache at all, so there is nothing to fall back to and
                // nothing to warn about — the flag is simply not passed.
                kvQuant = 0
            } else {
                let fallback = KVQuality.allCases.first { $0.isAvailable(for: family) } ?? .quality
                warnings.append("\(family.label) refuses \(kvQuant)-bit KV; using \(fallback.kvQuant)-bit instead.")
                kvQuant = fallback.kvQuant
            }
        }

        // A streamed pack's anchor describes what stays resident when the
        // whole expert set fits. On a smaller Mac it streams instead, so the
        // resident figure is whatever remains after the KV cache and warmup —
        // which is why a streamed pack always fits and the budget only
        // decides how much of it stays in memory.
        let usable = MemoryModel.usableGiB(ramGB: ramGB, limitMB: limitMB)
        let kvForContext = MemoryModel.kvGiB(contextTokens: contextTokens,
                                             kvQuant: kvQuant, family: family)
        let residentWeights = profile.streamsExperts
            ? max(8, usable - kvForContext - MemoryModel.warmupGiB)
            : weights

        let budget = MemoryModel.budget(weightsGiB: residentWeights,
                                        contextTokens: contextTokens,
                                        kvQuant: kvQuant,
                                        family: family,
                                        ramGB: ramGB,
                                        limitMB: limitMB)

        // ── Flags ──────────────────────────────────────────────────────
        var assignments: [String: OptionAssignment] = [:]
        func set(_ id: String, _ value: FlagValue) {
            assignments[id] = OptionAssignment(included: true, value: value)
        }

        set("model", .string(ModelPath.resolve(repo: (packName as NSString).lastPathComponent)))
        set("ctx-size", .int(contextTokens))
        set("max-tokens", .int(maxTokens(forContext: contextTokens)))
        set("temp", .double(1))
        set("prefix-cache-disk", .string("20GB"))
        set("max-concurrent", .int(1))

        var rationale: [String] = []

        // KV quantisation, where the family has a KV cache at all.
        if family != .deepseek {
            set("kv-quant", .string(String(kvQuant)))
            rationale.append("KV cache at \(kvQuant)-bit: \(fmt(budget.kvGiB)) GiB for \(ContextChoice.label(forTokens: contextTokens)).")
        } else {
            rationale.append("No KV cache to size: DeepSeek-V4.1 keeps none, so context costs no cache memory.")
        }

        // MTP: on by default for Qwen/MiMo/DeepSeek, off for GLM. Only assert
        // it where the default is not already what we want.
        if family == .qwen || family == .mimo {
            set("mtp", .bool(true))
            if family == .qwen {
                set("mtp-head-kv-quant", .bool(true))
                rationale.append("MTP on, with its head KV quantised to match — the head is a second cache and leaving it dense costs memory for no quality gain.")
            } else {
                rationale.append("MTP on (the default for this family).")
            }
        }

        // GDN state width: bf16 halves every cache checkpoint. Worth it when
        // memory is tight; on a large Mac the f32 default is free quality.
        if family == .qwen {
            let tight = budget.utilisation > 0.85
            set("qwen-gdn", .string(tight ? "16" : "32"))
            if tight {
                rationale.append("GatedDeltaNet state at bf16 (--qwen-gdn 16): this configuration uses \(pct(budget.utilisation)) of the budget, so halving each cache checkpoint buys real headroom.")
            } else {
                rationale.append("GatedDeltaNet state at f32 (the default): there is room, so no reason to halve it.")
            }
        }

        // Prefill chunk: the model's own start width unless memory is tight.
        if budget.utilisation > 0.85 {
            set("prefill-chunk-max", .string("2048"))
            rationale.append("Prefill capped at 2048 rows to keep the prefill arena small.")
        } else {
            set("prefill-chunk-max", .string("4096"))
            rationale.append("Prefill at 4096 rows (Qwen's own start width) — a wider chunk means fewer passes over the prompt.")
        }

        // Streamed packs need an explicit budget, and it is NOT the whole
        // ceiling: `--ssd-budget-gb` is the WEIGHTS budget (trunk, MTP head,
        // routed experts and their stream buffers), with the KV cache and the
        // prefill arena beside it. So it is what remains after those.
        if profile.streamsExperts {
            let budgetGB = Int(residentWeights.rounded())
            set("ssd-budget-gb", .int(budgetGB))
            rationale.append("Experts stream from SSD within a \(budgetGB) GiB weights budget, with the KV cache and prefill arena beside it.")
        }

        // ── Fit ────────────────────────────────────────────────────────
        // A streamed pack's weights anchor already describes what stays
        // resident, so the budget above is the honest comparison. A resident
        // pack's anchor is the whole weight set.
        if !budget.fits {
            warnings.append(
                "This does not fit: \(fmt(budget.totalGiB)) GiB needed, \(fmt(budget.usableGiB)) GiB available at a \(limitMB) MB limit. "
                + "Lower the context, pick a smaller KV cache, or choose a larger posture.")
        }
        if ramGB < profile.minMacGB {
            warnings.append("This pack is documented for a \(profile.minMacGB) GB Mac or larger; this Mac has \(ramGB) GB.")
        }
        if !profile.hasNgramTable {
            warnings.append("This pack has no n-gram table, so MTP's prompt-lookup drafts have nothing to match against.")
        }

        rationale.insert("Weights \(fmt(residentWeights)) GiB + KV \(fmt(budget.kvGiB)) GiB + \(fmt(budget.overheadGiB)) GiB warmup = \(fmt(budget.totalGiB)) GiB of \(fmt(budget.usableGiB)) GiB usable at a \(limitMB) MB wired limit.", at: 0)

        return Derived(config: LaunchConfig(assignments: assignments),
                       budget: budget,
                       contextTokens: contextTokens,
                       kvQuant: kvQuant,
                       gpuLimitMB: limitMB,
                       rationale: rationale,
                       warnings: warnings)
    }

    /// Output-token cap, scaled to the window: a request should be able to
    /// use a meaningful fraction of the context it was given, but the cap
    /// also reserves memory per request, so it is not simply the context.
    static func maxTokens(forContext tokens: Int) -> Int {
        switch tokens {
        case ..<65_536:    return 16_000
        case ..<262_144:   return 32_000
        case ..<1_048_576: return 64_000
        default:           return 128_000
        }
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
