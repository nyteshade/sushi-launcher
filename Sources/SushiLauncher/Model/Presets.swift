import Foundation

// MARK: - Presets ("launch recipes")
//
// Built from docs/usage.md's launch recipes; the first mirrors the user's
// own start-sushi script. Each carries a group (menu organization) and an
// explanation (what the recipe is for, which Mac, what to set first).
// Applying a preset REPLACES all assignments.

struct Preset: Identifiable {
    let id: String
    let name: String
    let assignments: [String: OptionAssignment]
    var group: String = "Recipes"
    var explain: String = ""

    var config: LaunchConfig { LaunchConfig(assignments: assignments) }

    private static func map(_ pairs: [(String, FlagValue)]) -> [String: OptionAssignment] {
        var d = [String: OptionAssignment]()
        for (id, value) in pairs {
            d[id] = OptionAssignment(included: true, value: value)
        }
        return d
    }

    static let brie128 = Preset(
        id: "brie-qwen-4bpw-128",
        name: "Qwen 4bpw · 128 GB (your start-sushi)",
        assignments: map([
            ("model", .string("~/.sushi/models/Qwen3.8-Flash-Next-Sushi-4bpw")),
            ("mtp", .bool(true)),
            ("kv-quant", .string("8")),
            ("mtp-head-kv-quant", .bool(true)),
            ("ctx-size", .int(1_048_576)),
            ("prefill-chunk", .int(2048)),
            ("max-tokens", .int(64_000)),
            ("prefix-cache-disk", .string("20GB")),
            ("prefix-cache-entries", .int(1)),
            ("temp", .double(1)),
        ]),
        group: "This machine",
        explain: "Your own launch script: the 4 bpw Qwen pack at the full 1M context on a 128 GB Mac — MTP on, 8-bit KV (also in the MTP head), 20 GB SSD prefix cache sized for one conversation. Raise the GPU limit to 120000 MB first (Server ▸ Raise GPU Memory Limit, ⌥⌘G)."
    )

    static let builtIn: [Preset] = [
        brie128,
        Preset(
            id: "qwen-2bpw-48",
            name: "Qwen 2bpw · 48 GB",
            assignments: map([
                ("model", .string("~/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-2bpw")),
                ("mtp", .bool(true)),
                ("kv-quant", .string("8")),
                ("mtp-head-kv-quant", .bool(true)),
                ("qwen-gdn", .string("16")),
                ("ctx-size", .int(131_072)),
                ("max-tokens", .int(32_000)),
                ("prefix-cache-disk", .string("20GB")),
                ("prefix-cache-entries", .int(1)),
                ("temp", .double(1)),
            ]),
            group: "Reference recipes",
            explain: "Docs recipe for 48 GB Macs: the 2 bpw pack, 128k context, bf16 GatedDeltaNet state (--qwen-gdn 16) to fit. GPU limit 43000 MB."
        ),
        Preset(
            id: "qwen-stq-275-64",
            name: "Qwen STQ 2.75bpw · 64 GB",
            assignments: map([
                ("model", .string("~/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw")),
                ("mtp", .bool(true)),
                ("kv-quant", .string("8")),
                ("mtp-head-kv-quant", .bool(true)),
                ("qwen-gdn", .string("16")),
                ("ctx-size", .int(250_000)),
                ("max-tokens", .int(32_000)),
                ("prefix-cache-disk", .string("20GB")),
                ("prefix-cache-entries", .int(1)),
                ("temp", .double(1)),
            ]),
            group: "Reference recipes",
            explain: "64 GB, STQ 2.75bpw at 250k context with 8-bit KV (the quality default). For ~1.8× the context switch the KV quant to 4 and raise ctx-size to ~450000 by hand. GPU limit 59000 MB — above it macOS kernel-panics, so don't."
        ),
        Preset(
            id: "glm-2-96",
            name: "GLM 2bpw · 96 GB",
            assignments: map([
                ("model", .string("~/.sushi/models/beamster/GLM-5.3-Flash-Sushi-2bpw")),
            ]),
            group: "Reference recipes",
            explain: "GLM 2 bpw with sushi's defaults: auto context (512k at 8-bit KV), DFlash2 drafter when the pack ships it. GPU limit 90000 MB."
        ),
        Preset(
            id: "mimo-23-128",
            name: "MiMo 2.3bpw · 128 GB · full 1M ctx",
            assignments: map([
                ("model", .string("~/.sushi/models/beamster/MiMo-V2.6-Flash-Sushi-2.3bpw")),
                ("ctx-size", .int(1_048_576)),
            ]),
            group: "128 GB & streaming",
            explain: "MiMo at the full 1M context; MTP and the 8-bit KV cache are already on by default, so the recipe is just the size. GPU limit 120000 MB."
        ),
        Preset(
            id: "glm-24-128",
            name: "GLM 2.4bpw · 128 GB",
            assignments: map([
                ("model", .string("~/.sushi/models/beamster/GLM-5.3-Flash-Sushi-2.4bpw")),
            ]),
            group: "128 GB & streaming",
            explain: "GLM 2.4 bpw with defaults (images + video, DFlash2 built into the pack). GPU limit 120000 MB."
        ),
        Preset(
            id: "deepseek-175-128",
            name: "DeepSeek 1.75bpw · 128 GB (SSD-streamed)",
            assignments: map([
                ("model", .string("~/.sushi/models/beamster/DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw")),
                ("ssd-budget-gb", .int(108)),
                ("ctx-size", .int(1_000_000)),
                ("max-tokens", .int(128_000)),
            ]),
            group: "128 GB & streaming",
            explain: "DeepSeek streams its routed experts from SSD: 108 GiB resident (the recommended 128 GB budget), 1M context, 128k max tokens. This pack REQUIRES --ssd-budget-gb. GPU limit 120000 MB."
        ),
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
