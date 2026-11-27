import Foundation

// MARK: - Model path resolution

enum ModelPath {
    /// Where `sushi pull` puts a pack on this machine, preferring whichever
    /// layout actually exists. Falls back to the documented path so a recipe
    /// for an un-pulled pack still shows the user what to fetch.
    static func resolve(repo: String) -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.sushi/models/beamster/\(repo)",
            "\(home)/.sushi/models/\(repo)",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "~/.sushi/models/beamster/\(repo)"
    }
}

// MARK: - Documented intent
//
// The docs' launch recipes, expressed as INTENT rather than as flag lists.
// Each one is (pack, context, posture, KV quality) — the same three answers
// the chooser asks for — so a recipe can be reproduced by the derivation and
// a new Mac size needs no new recipe.
//
// These exist to be *examples*: the chooser derives from intent, and these
// show what the docs recommend for a given Mac. A recipe that disagrees with
// the derivation is a signal that the memory model is wrong, which is why
// they are kept as data rather than as pre-built configs.

struct DocumentedIntent: Identifiable {
    let id: String
    let name: String
    let packRepo: String
    let contextTokens: Int
    let posture: MemoryPosture
    let kv: KVQuality
    let ramGB: Int
    var group: String = "Documented"
    var explain: String = ""

    /// Derive the configuration this intent describes.
    func derive() -> ConfigDeriver.Derived {
        ConfigDeriver.derive(packName: packRepo,
                             contextTokens: contextTokens,
                             ramGB: ramGB,
                             posture: posture,
                             kv: kv,
                             profile: PackKnowledge.profile(for: packRepo))
    }

    /// The GPU limit the docs pair with this recipe.
    var gpuLimitMB: Int { derive().gpuLimitMB }
}

enum DocumentedRecipes {
    static let all: [DocumentedIntent] = [
        // ── Qwen ──────────────────────────────────────────────────────
        DocumentedIntent(
            id: "qwen-2bpw-48",
            name: "Qwen 2bpw · 48 GB Mac",
            packRepo: "Qwen3.8-Flash-Next-Sushi-2bpw",
            contextTokens: 131_072, posture: .maximum, kv: .quality, ramGB: 48,
            group: "Qwen",
            explain: "The docs' 48 GB recipe: 128k context, bf16 GatedDeltaNet state to fit."),
        DocumentedIntent(
            id: "qwen-stq-275-64",
            name: "Qwen STQ 2.75bpw · 64 GB Mac",
            packRepo: "Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw",
            contextTokens: 262_144, posture: .maximum, kv: .quality, ramGB: 64,
            group: "Qwen",
            explain: "The docs' 64 GB recipe: 250k context at 8-bit KV. Above a 59000 MB limit macOS runs out of memory first and the kernel panics."),
        DocumentedIntent(
            id: "qwen-4bpw-96",
            name: "Qwen 4bpw · 96 GB Mac",
            packRepo: "Qwen3.8-Flash-Next-Sushi-4bpw",
            contextTokens: 524_288, posture: .maximum, kv: .quality, ramGB: 96,
            group: "Qwen",
            explain: "The docs' 96 GB+ recipe: 500k context, 8-bit KV, prefill capped at 2048 rows."),

        // ── MiMo ──────────────────────────────────────────────────────
        DocumentedIntent(
            id: "mimo-23-128",
            name: "MiMo 2.3bpw · 128 GB Mac",
            packRepo: "MiMo-V2.6-Flash-Sushi-2.3bpw",
            contextTokens: 1_048_576, posture: .maximum, kv: .quality, ramGB: 128,
            group: "MiMo",
            explain: "Full 1M context; MTP, 8-bit KV and thinking are on by default. UNSUPPORTED since sushi 1.5.1 — it loads, but is no longer tested or tuned."),

        // ── GLM ───────────────────────────────────────────────────────
        DocumentedIntent(
            id: "glm-2-96",
            name: "GLM 2bpw · 96 GB Mac",
            packRepo: "GLM-5.3-Flash-Sushi-2bpw",
            contextTokens: 524_288, posture: .maximum, kv: .quality, ramGB: 96,
            group: "GLM",
            explain: "Images, video, 8-bit KV and DFlash2 on by default; up to four requests decode together."),
        DocumentedIntent(
            id: "glm-24-128",
            name: "GLM 2.4bpw · 128 GB Mac",
            packRepo: "GLM-5.3-Flash-Sushi-2.4bpw",
            contextTokens: 524_288, posture: .maximum, kv: .quality, ramGB: 128,
            group: "GLM",
            explain: "GLM 2.4 bpw with defaults. The pack ships Inco.ai's DFlash2 assistant under CC BY-NC-ND 4.0 — keep the built copy local."),

        // ── DeepSeek ──────────────────────────────────────────────────
        DocumentedIntent(
            id: "deepseek-175-128",
            name: "DeepSeek 1.75bpw · 128 GB (streamed)",
            packRepo: "DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw",
            contextTokens: 1_000_000, posture: .maximum, kv: .quality, ramGB: 128,
            group: "DeepSeek",
            explain: "Routed experts stream from SSD. The 108 GiB default needs the GPU limit at 125000; without it sushi picks 96 and steps down further, saying so."),
        DocumentedIntent(
            id: "deepseek-27-256",
            name: "DeepSeek 2.7bpw · 256 GB (resident)",
            packRepo: "DeepSeek-V4.1-Flash-1017-Sushi-STQ-2.7bpw",
            contextTokens: 1_000_000, posture: .maximum, kv: .quality, ramGB: 256,
            group: "DeepSeek",
            explain: "KLD 0.0607 against 0.1525 for the 1.75bpw pack, every routed expert resident — no SSD reads, no limit to raise."),

        // ── Hy4 ───────────────────────────────────────────────────────
        DocumentedIntent(
            id: "hy4-225-48",
            name: "Hy4 2.25bpw · 48 GB (streamed)",
            packRepo: "Hy4-Flash-Sushi-STQ-2.25bpw",
            contextTokens: 200_000, posture: .maximum, kv: .quality, ramGB: 48,
            group: "Hy4",
            explain: "Experts streamed within a 34 GB budget at a 200k context; --expert-cache-bias 0.2 favours experts already in memory, which is lossy."),
        DocumentedIntent(
            id: "hy4-225-64",
            name: "Hy4 2.25bpw · 64 GB",
            packRepo: "Hy4-Flash-Sushi-STQ-2.25bpw",
            contextTokens: 524_288, posture: .maximum, kv: .quality, ramGB: 64,
            group: "Hy4",
            explain: "500k context. With no budget flag the load holds all 512 experts per layer when 46.2 GB is free; otherwise it streams at the largest budget that fits."),
        DocumentedIntent(
            id: "hy4-4-96",
            name: "Hy4 4bpw · 96 GB",
            packRepo: "Hy4-Flash-Sushi-STQ-4bpw",
            contextTokens: 524_288, posture: .maximum, kv: .quality, ramGB: 96,
            group: "Hy4",
            explain: "4 bpw at a 500k context."),
        DocumentedIntent(
            id: "hy4-4-128",
            name: "Hy4 4bpw · 128 GB · full 1M",
            packRepo: "Hy4-Flash-Sushi-STQ-4bpw",
            contextTokens: 1_048_576, posture: .maximum, kv: .quality, ramGB: 128,
            group: "Hy4",
            explain: "4 bpw at the full 1,048,576-token context."),
    ]

    static func recipe(id: String) -> DocumentedIntent? { all.first { $0.id == id } }
}

// MARK: - App settings
//
// Custom decoder so files written by older versions keep loading
// (missing keys fall back to defaults instead of failing).

struct AppSettings: Codable, Equatable {
    var sushiPathOverride: String = ""
    var gpuLimitMB: Int = 120_000
    var raiseGPUBeforeLaunch: Bool = false
    var autoParentPid: Bool = true
    var autoscroll: Bool = true
    var showTimestamps: Bool = true
    var consoleVisible: Bool = true
    var advancedOptions: Bool = false
    var hideDockWhenNoWindows: Bool = true

    /// The chooser's remembered intent, so reopening the app shows the same
    /// answers rather than re-deriving from scratch.
    var chosenPack: String = ""
    var chosenContextTokens: Int = 131_072
    var chosenPosture: MemoryPosture = .balanced
    var chosenKV: KVQuality = .quality

    init() {}

    private enum CodingKeys: String, CodingKey {
        case sushiPathOverride, gpuLimitMB, raiseGPUBeforeLaunch, autoParentPid
        case autoscroll, showTimestamps, consoleVisible, advancedOptions
        case hideDockWhenNoWindows
        case chosenPack, chosenContextTokens, chosenPosture, chosenKV
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sushiPathOverride    = try c.decodeIfPresent(String.self, forKey: .sushiPathOverride) ?? ""
        gpuLimitMB           = try c.decodeIfPresent(Int.self, forKey: .gpuLimitMB) ?? 120_000
        raiseGPUBeforeLaunch = try c.decodeIfPresent(Bool.self, forKey: .raiseGPUBeforeLaunch) ?? false
        autoParentPid        = try c.decodeIfPresent(Bool.self, forKey: .autoParentPid) ?? true
        autoscroll           = try c.decodeIfPresent(Bool.self, forKey: .autoscroll) ?? true
        showTimestamps       = try c.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
        consoleVisible       = try c.decodeIfPresent(Bool.self, forKey: .consoleVisible) ?? true
        advancedOptions       = try c.decodeIfPresent(Bool.self, forKey: .advancedOptions) ?? false
        hideDockWhenNoWindows = try c.decodeIfPresent(Bool.self, forKey: .hideDockWhenNoWindows) ?? true
        chosenPack            = try c.decodeIfPresent(String.self, forKey: .chosenPack) ?? ""
        chosenContextTokens   = try c.decodeIfPresent(Int.self, forKey: .chosenContextTokens) ?? 131_072
        chosenPosture         = try c.decodeIfPresent(MemoryPosture.self, forKey: .chosenPosture) ?? .balanced
        chosenKV              = try c.decodeIfPresent(KVQuality.self, forKey: .chosenKV) ?? .quality
    }
}
