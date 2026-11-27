import Foundation

// MARK: - Option model
//
// Everything the GUI knows about sushi's serve flags lives in this file's
// registry. To support a new sushi option, add ONE SushiOption row to
// SushiOptionRegistry.all — the launch form, the argument builder,
// presets, the copyable command line and persistence all pick it up.
//
// The registry is a TRANSCRIPTION of `sushi serve --help`, and a
// transcription drifts. CLIConformance.swift re-reads the installed
// binary's help and reports every row the CLI no longer accepts, every
// flag the registry lacks, and every flag the CLI has renamed — so drift
// is a reported fact rather than something someone has to remember.

enum OptionCategory: String, CaseIterable, Identifiable {
    case serving     = "Serving, network & auth"
    case modelMemory = "Model, memory & context"
    case kv          = "KV & attention"
    case speculation = "Speculation (MTP & drafters)"
    case prefixCache = "Prefix cache"
    case sampling    = "Sampling & reasoning"
    case engine      = "Engine & compatibility"
    case logging     = "Logging & diagnostics"

    var id: String { rawValue }
}

enum SushiOptionKind {
    case presence          // pass --flag when on (no value)
    case onOff             // choose between --flag and its negation, or nothing
    case int(Int)          // associated value: displayed default
    case double(Double)
    case text(String)      // displayed default; "" = none
    case choice([String])  // allowed values; see choiceDefault for the CLI's default
}

struct SushiOption: Identifiable {
    let id: String          // "ctx-size" → flag "--ctx-size"
    let title: String       // human label
    let category: OptionCategory
    let kind: SushiOptionKind
    var negation: String? = nil       // for .onOff; defaults to --no-<id>
    var help: String = ""
    /// Why sushi stops at load. Value-level refusals (GLM takes --kv-quant 8
    /// but refuses 4) cannot be expressed as a set of families.
    var refusals: [Refusal] = []
    var important: Bool = false       // surface in the "Quick settings" group
    /// For .choice: which value the CLI documents as its default. nil means
    /// no listed value is the default (e.g. --prefill-chunk-max defaults to
    /// the model's own prefill width, which is not one of the rungs).
    var choiceDefault: String? = nil

    var flagName: String { "--" + id }
    var negationName: String { negation ?? "--no-\(id)" }

    var shortHelp: String {
        help.split(separator: ".").first.map(String.init) ?? help
    }

    /// Families that refuse this flag at ANY value. Kept as a derived view so
    /// call sites that only need "is this flag refused here" stay simple.
    var unsupported: Set<ModelFamily> {
        Set(refusals.filter { $0.values == nil }.flatMap { $0.families })
    }

    /// The refusal that applies to this family and value, if any.
    func refusal(family: ModelFamily, value: String?) -> Refusal? {
        refusals.first { $0.matches(family: family, value: value) }
    }
}

// MARK: - Registry

enum SushiOptionRegistry {
    static let all: [SushiOption] = [
        // ── Model, memory & context ────────────────────────────────────
        SushiOption(id: "model", title: "Model", category: .modelMemory,
                    kind: .text("~/.sushi/models"),
                    help: "Pack directory, or a short name like qwen3.8-flash-next:4bpw (resolved after `sushi pull`).",
                    important: true),
        SushiOption(id: "model-dir", title: "Extra model dir", category: .modelMemory,
                    kind: .text(""),
                    help: "Repeatable discovery root (up to 8 in the CLI; this app passes one)."),
        SushiOption(id: "ctx-size", title: "Context size", category: .modelMemory,
                    kind: .int(0),
                    help: "Context length in tokens. Auto-detect reads free memory — recipes set it explicitly.",
                    important: true),
        SushiOption(id: "prefill-chunk-max", title: "Prefill chunk max", category: .modelMemory,
                    kind: .choice(["512", "1024", "2048", "4096", "8192"]),
                    help: "Widest prefill chunk any forward runs. Unset = the width the model's own prefill starts at. Replaces the removed --prefill-chunk.",
                    important: true),
        SushiOption(id: "prefill-chunk-min", title: "Prefill chunk min", category: .modelMemory,
                    kind: .choice(["512", "1024", "2048", "4096", "8192"]),
                    help: "Narrowest width a prompt may run at (default 512). Equal to the max, it pins every prompt to one width and turns adaptive chunking off."),
        SushiOption(id: "kv-quant", title: "KV quantization", category: .kv,
                    kind: .choice(["8", "6", "4", "16"]),
                    help: "KV scheme: 8 (default), 6, 4 (≈1.8× context) or 16 (BF16). GLM takes 8/6/16; DeepSeek refuses this flag.",
                    refusals: [
                        Refusal(families: [.deepseek],
                                reason: "DeepSeek-V4.1 has no KV cache and refuses --kv-quant."),
                        Refusal(families: [.glm], values: ["4"],
                                reason: "GLM refuses --kv-quant 4."),
                    ],
                    important: true,
                    choiceDefault: "8"),
        SushiOption(id: "qwen-gdn", title: "Qwen GDN state width", category: .kv,
                    kind: .choice(["32", "16"]),
                    help: "GatedDeltaNet state bits (Qwen only; no effect on GLM/MiMo/Hy4). 16 = bf16, halves state per cache checkpoint; the 32–64 GB recipes pass 16.",
                    choiceDefault: "32"),
        SushiOption(id: "max-resident-models", title: "Max resident models", category: .modelMemory,
                    kind: .int(3),
                    help: "Cap on loaded models."),
        SushiOption(id: "max-resident-mem", title: "Max resident memory", category: .modelMemory,
                    kind: .text("auto"),
                    help: "Cap on summed resident bytes. auto = 80% of the GPU wired limit."),
        SushiOption(id: "idle-evict-secs", title: "Idle evict (secs)", category: .modelMemory,
                    kind: .int(0),
                    help: "Unload a model that has been idle this long; 0 = never."),
        SushiOption(id: "config-overrides", title: "Config overrides (JSON)", category: .modelMemory,
                    kind: .text(""),
                    help: "JSON deep-merged into every model's config.json (e.g. YaRN context extension)."),
        SushiOption(id: "ssd-budget-gb", title: "SSD stream budget (GiB)", category: .modelMemory,
                    kind: .int(0),
                    help: "Keep this many GiB resident and stream routed experts from SSD. Required by DeepSeek-V4.1 (108 on a 128 GB Mac at limit 125000).",
                    important: true),
        SushiOption(id: "ssd-prefetch", title: "SSD prefetch cap (%)", category: .modelMemory,
                    kind: .int(0),
                    help: "Share (0…100) of this Mac's measured SSD read rate the expert reads of a streamed load may use. 0 = off; 65 is the tuned cap on a fast SSD."),
        SushiOption(id: "expert-pick-tolerance", title: "Expert pick tolerance", category: .modelMemory,
                    kind: .double(0),
                    help: "0…0.6, lossy: swap a missed streamed expert for a cached near-ranked one. 0 = exact."),
        SushiOption(id: "expert-cache-bias", title: "Expert cache bias", category: .modelMemory,
                    kind: .double(0),
                    help: "0…2, lossy, streamed STQ packs only (DeepSeek-V4.1, Qwen3.8, Hy4). Scores a cached expert n higher so it wins the pick. Ignored when --expert-pick-tolerance is set."),
        SushiOption(id: "drop-expert", title: "Drop experts (n)", category: .modelMemory,
                    kind: .int(0),
                    help: "Never load the n least-used routed experts (multiple of 8). DeepSeek-V4.1 only; every other arch refuses.",
                    refusals: [
                        Refusal(families: [.qwen, .mimo, .glm, .hy4],
                                reason: "Only DeepSeek-V4.1 accepts --drop-expert; every other architecture refuses it."),
                    ]),
        SushiOption(id: "skip-mem-preflight", title: "Skip memory preflight", category: .modelMemory,
                    kind: .presence,
                    help: "Bypass the free-RAM check before a load. A genuine over-commit can hard-crash the server."),
        SushiOption(id: "wired-margin-gib", title: "Wired margin (GiB)", category: .modelMemory,
                    kind: .int(1),
                    help: "Headroom kept under iogpu.wired_limit_mb (0…32)."),
        SushiOption(id: "vision", title: "Vision tower", category: .modelMemory,
                    kind: .onOff, negation: "--no-vision",
                    help: "Force the vision tower on, or --no-vision to skip it and save its memory."),
        SushiOption(id: "vision-bf16", title: "Vision tower bf16", category: .modelMemory,
                    kind: .presence,
                    help: "Keep a bf16 vision tower as stored instead of requantizing it to affine 8-bit at load (more memory, exact tower)."),
        SushiOption(id: "prefill-decode-share", title: "Prefill/decode share", category: .modelMemory,
                    kind: .double(0.25),
                    help: "0…0.9 target decode share of wall time during another request's prefill (default 0.25)."),

        // ── Speculation ────────────────────────────────────────────────
        SushiOption(id: "mtp", title: "MTP (speculative decode)", category: .speculation,
                    kind: .onOff, negation: "--no-mtp",
                    help: "On by default for Qwen/MiMo/DeepSeek(DSpark), off for GLM. Required ON for streamed packs.",
                    important: true),
        SushiOption(id: "mtp-head-kv-quant", title: "MTP head KV quant", category: .kv,
                    kind: .presence,
                    help: "Store Qwen's MTP-head KV at --kv-quant width too (default OFF: the head keeps dense bf16 KV). No effect on MiMo.",
                    refusals: [
                        Refusal(families: [.deepseek],
                                reason: "DeepSeek-V4.1 has no KV cache, so there is no MTP-head KV to quantize."),
                    ],
                    important: true),
        SushiOption(id: "mtp-min-depth", title: "MTP min depth", category: .speculation,
                    kind: .int(1),
                    help: "Fewest tokens a round drafts (1…8). Launch-only."),
        SushiOption(id: "mtp-max-depth", title: "MTP max depth", category: .speculation,
                    kind: .int(8),
                    help: "Most tokens a round drafts (1…8; adaptive default, up to 8 on eligible M5 NAX targets)."),
        SushiOption(id: "max-mtp-ctx", title: "MTP context ceiling", category: .speculation,
                    kind: .int(0),
                    help: "Turn MTP off past n context tokens; 0 = no ceiling."),
        SushiOption(id: "no-mtp-lookup", title: "No prompt-lookup drafts", category: .speculation,
                    kind: .presence,
                    help: "Drop prompt-lookup drafts inside MTP rounds and DFlash2 chains."),
        SushiOption(id: "drafter", title: "Drafter directory", category: .speculation,
                    kind: .text(""),
                    help: "Path to a DFlash2 assistant stored elsewhere (GLM, Qwen3.8-Flash-Next)."),
        SushiOption(id: "drafter-min-depth", title: "Drafter min rows", category: .speculation,
                    kind: .int(2),
                    help: "Verifier rows a DFlash2 round may carry (2…16)."),
        SushiOption(id: "drafter-max-depth", title: "Drafter max rows", category: .speculation,
                    kind: .int(8),
                    help: "Upper bound for DFlash2 rounds (2…16; 8 on Qwen and GLM)."),
        SushiOption(id: "no-drafter", title: "Disable drafter", category: .speculation,
                    kind: .presence,
                    help: "Never load the assistant; saves its memory (GLM then decodes one token at a time)."),

        // ── Prefix cache ───────────────────────────────────────────────
        SushiOption(id: "prefix-cache-mem", title: "Prefix cache RAM", category: .prefixCache,
                    kind: .text(""),
                    help: "RAM tier budget (e.g. 1GB); off unless set. Faster than the SSD tier. Replaces the removed --prefix-cache-entries.",
                    important: true),
        SushiOption(id: "prefix-cache-disk", title: "Prefix cache SSD", category: .prefixCache,
                    kind: .text(""),
                    help: "SSD tier budget (e.g. 20GB; 0/off disables). Unset = per-model default capped at 20GB.",
                    important: true),
        SushiOption(id: "ssm-checkpoint-max", title: "SSM checkpoints", category: .prefixCache,
                    kind: .int(16),
                    help: "Checkpoints kept per entry; 0 = unlimited."),

        // ── Sampling & reasoning ───────────────────────────────────────
        SushiOption(id: "max-tokens", title: "Max tokens", category: .sampling,
                    kind: .int(100),
                    help: "Default output-token cap for requests that omit it.",
                    important: true),
        SushiOption(id: "temp", title: "Temperature", category: .sampling,
                    kind: .double(0),
                    help: "Serve default temperature (before generation_config.json).",
                    important: true),
        SushiOption(id: "top-p", title: "Top-p", category: .sampling,
                    kind: .double(1),
                    help: "Serve default top-p."),
        SushiOption(id: "top-k", title: "Top-k", category: .sampling,
                    kind: .int(0),
                    help: "Serve default top-k."),
        SushiOption(id: "preserve-thinking", title: "Preserve thinking", category: .sampling,
                    kind: .choice(["on", "off"]),
                    help: "off keeps only the latest turn's thinking in the prompt (shorter context, re-prefills older thoughts).",
                    choiceDefault: "on"),
        SushiOption(id: "think-penalty", title: "Think penalty", category: .sampling,
                    kind: .double(0),
                    help: "Lower overthinking-marker logits inside the reasoning span; 0 = off."),
        SushiOption(id: "no-continue-after-thought", title: "Stop after thinking", category: .sampling,
                    kind: .presence,
                    help: "Return a reply that ends its turn with only its thinking — no answer or tool call. By default sushi closes the thought and lets the model continue once."),

        // ── Serving, network & auth ────────────────────────────────────
        SushiOption(id: "host", title: "Bind host", category: .serving,
                    kind: .text("127.0.0.1"),
                    help: "IPv4 literal, localhost, or 0.0.0.0 to open the LAN."),
        SushiOption(id: "port", title: "Port", category: .serving,
                    kind: .int(12345),
                    help: "TCP port (sushi default 12345).",
                    important: true),
        SushiOption(id: "api-key", title: "API key", category: .serving,
                    kind: .text(""),
                    help: "Required on every request (loopback exempt unless strict)."),
        SushiOption(id: "api-key-env", title: "API key env var", category: .serving,
                    kind: .text(""),
                    help: "Read the key from a named environment variable so argv does not carry it."),
        SushiOption(id: "api-key-strict", title: "Strict API key", category: .serving,
                    kind: .presence,
                    help: "Also require the key from loopback."),
        SushiOption(id: "no-metrics", title: "Disable metrics", category: .serving,
                    kind: .presence,
                    help: "Turn off GET /metrics and /metrics.json. Metrics are ON by default; --metrics is accepted by the CLI and does nothing."),
        SushiOption(id: "timeout", title: "Stall timeout (s)", category: .serving,
                    kind: .int(300),
                    help: "Request stall timeout in seconds; 0 = none."),
        SushiOption(id: "gpu-warm-secs", title: "GPU warm secs", category: .serving,
                    kind: .int(60),
                    help: "Keep the GPU awake this long after the last request; 0 = off (avoids the ~1 s idle-GPU stall)."),
        SushiOption(id: "parent-pid", title: "Parent pid watchdog", category: .serving,
                    kind: .int(0),
                    help: "sushi exits when this pid dies. Sushi Launcher sets its own automatically unless you pin a value (App ▸ Settings)."),
        SushiOption(id: "max-concurrent", title: "Max concurrent", category: .serving,
                    kind: .int(1),
                    help: "Requests of each model that run at once. Also sizes the RAM prefix cache: it keeps this many finished conversations. Held to the model's batch width (Qwen 8, GLM/MiMo 4).",
                    important: true),
        SushiOption(id: "no-prevent-sleep", title: "Allow idle sleep", category: .serving,
                    kind: .presence,
                    help: "Do not inhibit system sleep during inference."),
        SushiOption(id: "no-update-check", title: "No update check", category: .serving,
                    kind: .presence,
                    help: "Never ask GitHub for a newer sushi release."),
        SushiOption(id: "no-tool-autocorrect", title: "No tool autocorrect", category: .serving,
                    kind: .presence,
                    help: "Stop coercing tool-call arguments to the schema's types."),

        // ── Engine & compatibility ─────────────────────────────────────
        SushiOption(id: "qwen-mlx-engine", title: "Qwen: decode on MLX", category: .engine,
                    kind: .presence,
                    help: "Qwen3.8 only, STQ packs: decode on MLX instead of Sushi Cooler. An opt-out if Sushi Cooler misbehaves."),
        SushiOption(id: "ds41-mlx-engine", title: "DeepSeek: decode on MLX", category: .engine,
                    kind: .presence,
                    help: "DeepSeek-V4.1 only: decode on MLX instead of Sushi Cooler. An opt-out if Sushi Cooler misbehaves."),

        // ── Logging & diagnostics ──────────────────────────────────────
        SushiOption(id: "log-level", title: "Log level", category: .logging,
                    kind: .choice(["info", "error", "warn", "debug"]),
                    help: "error, warn, info (default) or debug.",
                    choiceDefault: "info"),
        SushiOption(id: "log-file", title: "Log file", category: .logging,
                    kind: .text(""),
                    help: "Path, or off to disable. Default ~/.sushi/logs/sushi-<port>.log — sushi already persists to that folder.",
                    important: true),
    ]

    static let byID: [String: SushiOption] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func option(_ id: String) -> SushiOption? { byID[id] }

    static func rows(in category: OptionCategory) -> [SushiOption] {
        all.filter { $0.category == category }
    }

    /// Rows surfaced in the "Quick settings" group (model has its own card).
    static var quickRows: [SushiOption] {
        all.filter { $0.important && $0.id != "model" }
    }

    static func rows(in category: OptionCategory, excluding ids: Set<String>) -> [SushiOption] {
        rows(in: category).filter { !ids.contains($0.id) }
    }
}
