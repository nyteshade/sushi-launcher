import Foundation

// MARK: - Presets ("launch recipes")
//
// Built from docs/usage.md's "Recommended launch" section. Each carries a
// group (menu organization) and an explanation (what the recipe is for,
// which Mac, what to set first). Applying a preset REPLACES all assignments.
//
// Two rules keep these honest:
//
//  1. A recipe's flags are the DOCUMENTED ones, not a remembered version of
//     them. sushi 1.8.1 removed --prefill-chunk and --prefix-cache-entries;
//     the recipes below use --prefill-chunk-max and --max-concurrent, which
//     are what the CLI now accepts.
//  2. A recipe's model path is RESOLVED, not assumed. The docs write
//     `~/.sushi/models/beamster/<repo>`; `sushi pull` on this machine lands
//     the pack at `~/.sushi/models/<repo>`. ModelPath checks both.

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

struct Preset: Identifiable {
    let id: String
    let name: String
    let assignments: [String: OptionAssignment]
    var group: String = "Recipes"
    var explain: String = ""
    /// The GPU wired limit the docs pair with this recipe, in MB.
    var gpuLimitMB: Int? = nil

    var config: LaunchConfig { LaunchConfig(assignments: assignments) }

    private static func map(_ pairs: [(String, FlagValue)]) -> [String: OptionAssignment] {
        var d = [String: OptionAssignment]()
        for (id, value) in pairs {
            d[id] = OptionAssignment(included: true, value: value)
        }
        return d
    }

    /// A recipe's model row, resolved to a path that exists on this machine.
    private static func model(_ repo: String) -> (String, FlagValue) {
        ("model", .string(ModelPath.resolve(repo: repo)))
    }

    // MARK: This machine

    /// The pack actually installed here: Qwen3.8-Flash-Next STQ 2.75bpw.
    ///
    /// The docs give 2.75bpw a 64 GB recipe (250k context, 8-bit KV) because
    /// that is the smallest Mac it fits. This Mac is 128 GB, so the context
    /// is set from the memory arithmetic rather than from that tier:
    /// 46.4 GiB of resident weights + 23.1 GiB of 8-bit KV at 1M tokens =
    /// 69.5 GiB (the docs' own 1M-context anchor for this pack), inside the
    /// 117 GiB a 120000 MB wired limit allows. The 29.8 GiB n-gram table is
    /// memory-mapped from SSD and is not part of that sum.
    static let thisMachine = Preset(
        id: "machine-qwen-stq-275-128",
        name: "Qwen STQ 2.75bpw · 128 GB (this Mac)",
        assignments: map([
            model("Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw"),
            ("mtp", .bool(true)),
            ("kv-quant", .string("8")),
            ("mtp-head-kv-quant", .bool(true)),
            ("ctx-size", .int(1_048_576)),
            ("max-tokens", .int(64_000)),
            ("prefix-cache-disk", .string("20GB")),
            ("max-concurrent", .int(1)),
            ("temp", .double(1)),
        ]),
        group: "This machine",
        explain: "The 2.75bpw STQ pack at the full 1M context on a 128 GB Mac — MTP on, 8-bit KV (also in the MTP head), 20 GB SSD prefix cache sized for one conversation. The docs' 250k figure for this pack is the 64 GB tier; 46.4 GiB of weights plus 23.1 GiB of KV at 1M is 69.5 GiB, well inside a 120000 MB limit. Raise the limit first (Server ▸ Raise GPU Memory Limit, ⌥⌘G).",
        gpuLimitMB: 120_000
    )

    // MARK: Documented recipes

    static let builtIn: [Preset] = [
        thisMachine,

        // ── Qwen ──────────────────────────────────────────────────────
        Preset(
            id: "qwen-2bpw-48",
            name: "Qwen 2bpw · 48 GB",
            assignments: map([
                model("Qwen3.8-Flash-Next-Sushi-2bpw"),
                ("mtp", .bool(true)),
                ("kv-quant", .string("8")),
                ("mtp-head-kv-quant", .bool(true)),
                ("qwen-gdn", .string("16")),
                ("ctx-size", .int(131_072)),
                ("max-tokens", .int(32_000)),
                ("prefix-cache-disk", .string("20GB")),
                ("temp", .double(1)),
            ]),
            group: "Qwen",
            explain: "Docs recipe for 48 GB Macs: the 2 bpw pack, 128k context, bf16 GatedDeltaNet state (--qwen-gdn 16) to fit. GPU limit 43000 MB.",
            gpuLimitMB: 43_000
        ),
        Preset(
            id: "qwen-stq-275-64",
            name: "Qwen STQ 2.75bpw · 64 GB",
            assignments: map([
                model("Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw"),
                ("mtp", .bool(true)),
                ("kv-quant", .string("8")),
                ("mtp-head-kv-quant", .bool(true)),
                ("qwen-gdn", .string("16")),
                ("ctx-size", .int(250_000)),
                ("max-tokens", .int(32_000)),
                ("prefix-cache-disk", .string("20GB")),
                ("temp", .double(1)),
            ]),
            group: "Qwen",
            explain: "64 GB, STQ 2.75bpw at 250k context with 8-bit KV (the quality default). For ~1.8× the context switch the KV quant to 4 and raise ctx-size to ~450000 by hand. GPU limit 59000 MB — above it macOS runs out of memory first and the kernel panics, so don't.",
            gpuLimitMB: 59_000
        ),
        Preset(
            id: "qwen-4bpw-96",
            name: "Qwen 4bpw · 96 GB+",
            assignments: map([
                model("Qwen3.8-Flash-Next-Sushi-4bpw"),
                ("mtp", .bool(true)),
                ("kv-quant", .string("8")),
                ("mtp-head-kv-quant", .bool(true)),
                ("ctx-size", .int(500_000)),
                ("prefill-chunk-max", .string("2048")),
                ("max-tokens", .int(64_000)),
                ("prefix-cache-disk", .string("20GB")),
                ("temp", .double(1)),
            ]),
            group: "Qwen",
            explain: "The docs' 96 GB+ recipe: 4 bpw at 500k context, 8-bit KV, prefill capped at 2048 rows. GPU limit 90000 MB on 96 GB, 120000 on 128 GB. DFlash2 is opt-in on Qwen via --drafter; MTP stays the default.",
            gpuLimitMB: 120_000
        ),

        // ── MiMo ──────────────────────────────────────────────────────
        Preset(
            id: "mimo-23-128",
            name: "MiMo 2.3bpw · 128 GB (unsupported)",
            assignments: map([
                model("MiMo-V2.6-Flash-Sushi-2.3bpw"),
                ("ctx-size", .int(1_048_576)),
            ]),
            group: "MiMo",
            explain: "MiMo at the full 1M context; MTP, 8-bit KV and thinking are on by default, so the recipe is just the size. UNSUPPORTED: it still loads, but sushi has not tested, benchmarked or tuned it since 1.5.1 — 1.5.0 was the last release that supported it. GPU limit 120000 MB.",
            gpuLimitMB: 120_000
        ),

        // ── GLM ───────────────────────────────────────────────────────
        Preset(
            id: "glm-2-96",
            name: "GLM 2bpw · 96 GB",
            assignments: map([
                model("GLM-5.3-Flash-Sushi-2bpw"),
            ]),
            group: "GLM",
            explain: "GLM 2 bpw with sushi's defaults: images, video, 8-bit KV and DFlash2 on, up to four requests decoding together. Auto context is 512K at 8-bit KV, 300K with --kv-quant 16. GPU limit 90000 MB.",
            gpuLimitMB: 90_000
        ),
        Preset(
            id: "glm-24-128",
            name: "GLM 2.4bpw · 128 GB",
            assignments: map([
                model("GLM-5.3-Flash-Sushi-2.4bpw"),
            ]),
            group: "GLM",
            explain: "GLM 2.4 bpw with defaults (images + video, DFlash2 built into the pack). The pack ships Inco.ai's assistant under CC BY-NC-ND 4.0 — the smaller copy sushi builds in dflash2/ is a derivative, so keep it local. GPU limit 120000 MB.",
            gpuLimitMB: 120_000
        ),

        // ── DeepSeek ──────────────────────────────────────────────────
        Preset(
            id: "deepseek-175-128",
            name: "DeepSeek 1.75bpw · 128 GB (SSD-streamed)",
            assignments: map([
                model("DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw"),
                ("ssd-budget-gb", .int(108)),
                ("ctx-size", .int(1_000_000)),
                ("max-tokens", .int(128_000)),
            ]),
            group: "DeepSeek",
            explain: "DeepSeek streams its routed experts from SSD: 108 GiB resident (the recommended 128 GB budget), 1M context, 128k max tokens. The 108 default needs the GPU limit at 125000; without it sushi picks 96 and steps down further, saying so. Pass --ssd-budget-gb 96 to leave memory to other apps.",
            gpuLimitMB: 125_000
        ),
        Preset(
            id: "deepseek-27-256",
            name: "DeepSeek 2.7bpw · 256 GB (fully resident)",
            assignments: map([
                model("DeepSeek-V4.1-Flash-1017-Sushi-STQ-2.7bpw"),
            ]),
            group: "DeepSeek",
            explain: "KLD 0.0607 against 0.1525 for the 1.75bpw pack, and every routed expert resident at the RAM default — no SSD reads, no limit to raise. On 64/96 GB Macs it streams with --expert-cache-bias instead.",
            gpuLimitMB: 250_000
        ),

        // ── Hy4 ───────────────────────────────────────────────────────
        Preset(
            id: "hy4-225-48",
            name: "Hy4 2.25bpw · 48 GB (streamed)",
            assignments: map([
                model("Hy4-Flash-Sushi-STQ-2.25bpw"),
                ("ssd-budget-gb", .int(34)),
                ("expert-cache-bias", .double(0.2)),
                ("ctx-size", .int(200_000)),
            ]),
            group: "Hy4",
            explain: "48 GB: experts streamed within a 34 GB budget at a 200k context. --expert-cache-bias 0.2 favours the experts already in memory, which is lossy. GPU limit 44000 MB.",
            gpuLimitMB: 44_000
        ),
        Preset(
            id: "hy4-225-64",
            name: "Hy4 2.25bpw · 64 GB",
            assignments: map([
                model("Hy4-Flash-Sushi-STQ-2.25bpw"),
                ("ctx-size", .int(500_000)),
            ]),
            group: "Hy4",
            explain: "64 GB, 500k context. With no budget flag the load holds all 512 experts per layer when 46.2 GB is free (33-35 tok/s decode, 495-552 tok/s prefill at 1-7K tokens on an M5 Pro); otherwise it streams at the largest budget that fits. --no-vision --no-mtp holds them all in 44.8 GB. GPU limit 60000 MB.",
            gpuLimitMB: 60_000
        ),
        Preset(
            id: "hy4-4-96",
            name: "Hy4 4bpw · 96 GB",
            assignments: map([
                model("Hy4-Flash-Sushi-STQ-4bpw"),
                ("ctx-size", .int(500_000)),
            ]),
            group: "Hy4",
            explain: "96 GB, 4 bpw at a 500k context. GPU limit 92000 MB.",
            gpuLimitMB: 92_000
        ),
        Preset(
            id: "hy4-4-128",
            name: "Hy4 4bpw · 128 GB · full 1M ctx",
            assignments: map([
                model("Hy4-Flash-Sushi-STQ-4bpw"),
                ("ctx-size", .int(1_048_576)),
            ]),
            group: "Hy4",
            explain: "128 GB, 4 bpw at the full 1,048,576-token context. GPU limit 125000 MB.",
            gpuLimitMB: 125_000
        ),

        // ── Start over ────────────────────────────────────────────────
        Preset(
            id: "minimal",
            name: "No flags (sushi defaults)",
            assignments: map([
                ("model", .string("~/.sushi/models")),
            ]),
            group: "Start over",
            explain: "Clears everything: sushi picks the model directory, context, KV and cache defaults. A good base for a from-scratch config."
        ),
    ]

    static func preset(id: String) -> Preset? {
        builtIn.first { $0.id == id }
    }

    /// The recipe whose GPU limit matches a Mac of `ramGB`, preferring the
    /// documented tier. Used to suggest a starting point.
    static func suggested(forRAMGB ramGB: Int) -> Preset? {
        let tiers: [(Int, String)] = [
            (48, "qwen-2bpw-48"), (64, "qwen-stq-275-64"), (96, "qwen-4bpw-96"),
            (128, "machine-qwen-stq-275-128"), (256, "deepseek-27-256"),
        ]
        let match = tiers.first { ramGB <= $0.0 } ?? tiers.last!
        return preset(id: match.1)
    }
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case sushiPathOverride, gpuLimitMB, raiseGPUBeforeLaunch, autoParentPid
        case autoscroll, showTimestamps, consoleVisible, advancedOptions
        case hideDockWhenNoWindows
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
    }
}
