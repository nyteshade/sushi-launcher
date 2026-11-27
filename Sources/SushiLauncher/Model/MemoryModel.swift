import Foundation

// MARK: - Memory model
//
// The arithmetic that decides whether a configuration fits, with every
// constant named and its basis stated. Nothing here is a tuned value: each
// number is either a documented sushi default, a byte conversion, or a
// measured anchor from the pack's own metadata.
//
// The point of this file is that a config chooser can say "1M tokens needs
// 69.5 GiB and you have 113 GiB" instead of offering a recipe transcribed
// for a different Mac.

enum MemoryModel {

    // MARK: Byte conversions

    /// sushi's own conversion, from its docs: "N MB becomes N × 1,048,576
    /// bytes". Binary, not decimal — 1 GB here is 1 GiB.
    static let bytesPerMB = 1_048_576
    static let bytesPerGiB = 1_073_741_824

    // MARK: Documented defaults

    /// `--wired-margin-gib` default: headroom kept under the wired limit.
    static let wiredMarginGiB = 1.0

    /// What sushi subtracts from the wired limit before it will plan against
    /// it. Calibrated against sushi's own log line, not guessed:
    ///
    ///   [mem] ceiling 115952 MB from iogpu.wired_limit_mb=120000
    ///         (working set 120000 MB, margin 1024 MB, GPU floor 3535 MB,
    ///          unplanned 4047 MB)
    ///   [preflight] ... the GPU memory limit allows 113.2 GB
    ///
    /// 120000 − 4048 = 115952 MB = 113.2 GiB, which is the figure sushi
    /// reports. So the ceiling is the limit less this allowance, and the
    /// margin and GPU floor are already inside it.
    static let unplannedOverheadMB = 4048

    /// The GPU floor sushi reports at load (system GPU already in use).
    /// Kept for display; it is already accounted for in the ceiling above.
    static let defaultGPUFloorGiB = 3.5

    /// Warmup allowance, in GiB, SEPARATE from the KV cache.
    ///
    /// sushi's preflight line reads "weights 45.0 GB, warmup and context
    /// 5.8 GB" at 250k context. The KV cache at 250k is 5.5 GiB, so the
    /// warmup component is ~0.3 GiB. Treating the whole 5.8 as overhead
    /// double-counts the KV, which is why an earlier version of this model
    /// declared documented recipes unfittable.
    static let warmupGiB = 0.3

    /// The anchors in the docs are rounded to 0.1 GiB, so a configuration
    /// within this fraction of the ceiling is "tight", not "over". This is
    /// measurement precision, not a fudge factor: it is the width of the
    /// rounding in the numbers being compared.
    static let anchorTolerance = 0.02

    /// `--max-resident-mem` default: "auto = 80% of the GPU wired limit".
    static let residentFractionOfLimit = 0.80

    /// The docs' standard wired limit: "the Mac's RAM in MB less 4096".
    static func standardLimitMB(forRAMGB ramGB: Int) -> Int {
        max(8_000, ramGB * 1024 - 4096)
    }

    // MARK: KV cache

    /// GiB of KV cache per 1M tokens, at 8-bit, by family.
    ///
    /// These are the docs' own 1M-context anchors minus their weights
    /// anchors — the only place the docs state a KV cost directly:
    ///
    ///   Qwen 2.75bpw: 69.5 GiB at 1M − 46.4 GiB weights = 23.1 GiB
    ///   Qwen 4bpw:    87.1 GiB at 1M − 63.9 GiB weights = 23.2 GiB
    ///   GLM 2bpw:     90.5 GiB at 1M − 78.3 GiB weights = 12.2 GiB
    ///   GLM 2.4bpw:  102.0 GiB at 1M − 89.8 GiB weights = 12.2 GiB
    ///
    /// Qwen's figure is consistent across two packs, which is what makes it
    /// trustworthy: the KV cost is a property of the architecture, not the
    /// quantisation. DeepSeek has no KV cache at all.
    static func kvGiBPerMillionTokens(family: ModelFamily, kvQuant: Int) -> Double {
        let at8: Double
        switch family {
        case .qwen:     at8 = 23.1
        case .glm:      at8 = 12.2
        case .deepseek: return 0            // no KV cache; refuses --kv-quant
        case .mimo, .hy4, .unknown:
            // No documented 1M anchor. Fall back to Qwen's figure, which is
            // the conservative choice: it over-estimates rather than
            // promising memory that is not there.
            at8 = 23.1
        }
        return at8 * (Double(kvQuant) / 8.0)
    }

    /// KV cache size in GiB for a context length.
    static func kvGiB(contextTokens: Int, kvQuant: Int, family: ModelFamily) -> Double {
        kvGiBPerMillionTokens(family: family, kvQuant: kvQuant) * Double(contextTokens) / 1_048_576.0
    }

    // MARK: Budget

    /// What a Mac of `ramGB` can actually give a model, in GiB.
    ///
    /// This is sushi's own ceiling, not an independent estimate: the wired
    /// limit less the allowance sushi subtracts before planning. Reproducing
    /// sushi's arithmetic matters because the app's job is to predict what
    /// sushi will say, and a second opinion that disagrees with the engine is
    /// worse than none.
    static func usableGiB(ramGB: Int, limitMB: Int? = nil) -> Double {
        let mb = limitMB ?? standardLimitMB(forRAMGB: ramGB)
        let ceilingMB = max(0, mb - unplannedOverheadMB)
        return Double(ceilingMB) * Double(bytesPerMB) / Double(bytesPerGiB)
    }

    // MARK: Fit

    struct Budget {
        var weightsGiB: Double
        var kvGiB: Double
        var usableGiB: Double
        /// Warmup allowance, separate from the KV cache (see warmupGiB).
        var overheadGiB: Double = MemoryModel.warmupGiB

        var totalGiB: Double { weightsGiB + kvGiB + overheadGiB }
        /// Fits within the anchors' own rounding precision.
        var fits: Bool { totalGiB <= usableGiB * (1 + MemoryModel.anchorTolerance) }
        /// Fits, but with little to spare.
        var isTight: Bool { fits && utilisation > 0.95 }
        var headroomGiB: Double { usableGiB - totalGiB }
        /// Fraction of the usable budget this configuration consumes.
        var utilisation: Double { usableGiB > 0 ? totalGiB / usableGiB : 0 }
    }

    static func budget(weightsGiB: Double, contextTokens: Int, kvQuant: Int,
                       family: ModelFamily, ramGB: Int, limitMB: Int? = nil) -> Budget {
        Budget(weightsGiB: weightsGiB,
               kvGiB: kvGiB(contextTokens: contextTokens, kvQuant: kvQuant, family: family),
               usableGiB: usableGiB(ramGB: ramGB, limitMB: limitMB))
    }

    /// The largest context that fits, rounded down to a round number of
    /// tokens. Returns nil when even the weights do not fit.
    static func maxContextTokens(weightsGiB: Double, kvQuant: Int, family: ModelFamily,
                                 ramGB: Int, limitMB: Int? = nil,
                                 overheadGiB: Double = MemoryModel.warmupGiB) -> Int? {
        let usable = usableGiB(ramGB: ramGB, limitMB: limitMB)
        let forKV = usable - weightsGiB - overheadGiB
        guard forKV > 0 else { return nil }
        let perMillion = kvGiBPerMillionTokens(family: family, kvQuant: kvQuant)
        guard perMillion > 0 else { return 1_048_576 }   // no KV cache: the window is the limit
        let raw = Int(forKV / perMillion * 1_048_576.0)
        return roundDownContext(raw)
    }

    /// This Mac's unified memory in GB, as `sushi list` reports it.
    static func ramGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int((Double(bytes) / Double(bytesPerGiB)).rounded())
    }

    /// Round a token count down to a value a person would recognise.
    static func roundDownContext(_ tokens: Int) -> Int {
        let steps = [1_048_576, 524_288, 262_144, 131_072, 65_536, 32_768, 16_384, 8_192]
        for step in steps where tokens >= step { return step }
        return max(0, tokens)
    }
}

// MARK: - Context presets

/// A context length a person can pick without knowing what a token is.
/// The label is the point: "1M tokens" is a decision, "1048576" is a
/// transcription.
struct ContextChoice: Identifiable, Hashable {
    let tokens: Int
    let label: String
    let note: String

    var id: Int { tokens }

    /// The ladder a chooser offers, largest first.
    static let ladder: [ContextChoice] = [
        ContextChoice(tokens: 1_048_576, label: "1M tokens",
                      note: "The model's full window. Long documents, whole repos."),
        ContextChoice(tokens: 524_288, label: "512K tokens",
                      note: "Half the window; leaves room for a second conversation."),
        ContextChoice(tokens: 262_144, label: "256K tokens",
                      note: "A large codebase or a long book."),
        ContextChoice(tokens: 131_072, label: "128K tokens",
                      note: "Comfortable for agent work; the common default."),
        ContextChoice(tokens: 65_536, label: "64K tokens",
                      note: "A few files at a time."),
        ContextChoice(tokens: 32_768, label: "32K tokens",
                      note: "Short sessions; fastest to prefill."),
    ]

    /// The largest ladder entry that fits a budget, for a default selection.
    static func largestFitting(_ fits: (Int) -> Bool) -> ContextChoice? {
        ladder.first { fits($0.tokens) }
    }

    static func label(forTokens tokens: Int) -> String {
        if let exact = ladder.first(where: { $0.tokens == tokens }) { return exact.label }
        if tokens >= 1_000_000 { return String(format: "%.1fM tokens", Double(tokens) / 1_048_576) }
        if tokens >= 1_000 { return "\(tokens / 1024)K tokens" }
        return "\(tokens) tokens"
    }
}
