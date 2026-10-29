import Foundation

// MARK: - Option model
//
// Everything the GUI knows about sushi's serve flags lives in this file's
// registry. To support a new sushi option, add ONE SushiOption row to
// SushiOptionRegistry.all — the launch form, the argument builder,
// presets, the copyable command line and persistence all pick it up.

enum OptionCategory: String, CaseIterable, Identifiable {
    case serving     = "Serving, network & auth"
    case modelMemory = "Model, memory & context"
    case kv          = "KV & attention"
    case speculation = "Speculation (MTP & drafters)"
    case prefixCache = "Prefix cache"
    case sampling    = "Sampling & reasoning"
    case logging     = "Logging & diagnostics"

    var id: String { rawValue }
}

enum SushiOptionKind {
    case presence          // pass --flag when on (no value)
    case onOff             // choose between --flag and its negation, or nothing
    case int(Int)          // associated value: displayed default
    case double(Double)
    case text(String)      // displayed default; "" = none
    case choice([String])  // first entry is sushi's documented default
}

struct SushiOption: Identifiable {
    let id: String          // "ctx-size" → flag "--ctx-size"
    let title: String       // human label
    let category: OptionCategory
    let kind: SushiOptionKind
    var negation: String? = nil       // for .onOff; defaults to --no-<id>
    var help: String = ""
    var unsupported: Set<ModelFamily> = []   // families that REFUSE this at load
    var important: Bool = false       // surface in the "Quick settings" group

    var flagName: String { "--" + id }
    var negationName: String { negation ?? "--no-\(id)" }

    var shortHelp: String {
        help.split(separator: ".").first.map(String.init) ?? help
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
        SushiOption(id: "prefill-chunk", title: "Prefill chunk", category: .modelMemory,
                    kind: .int(8192),
                    help: "Ceiling on tokens per prefill chunk (auto-capped per model).",
                    important: true),
        SushiOption(id: "kv-quant", title: "KV quantization", category: .kv,
                    kind: .choice(["8", "6", "4", "16"]),
                    help: "KV scheme: 8 (default), 6, 4 (≈1.8× context) or 16 (BF16). GLM takes 8/6/16; DeepSeek refuses this flag.",
                    unsupported: [.deepseek], important: true),
        SushiOption(id: "qwen-gdn", title: "Qwen GDN state width", category: .kv,
                    kind: .choice(["32", "16"]),
                    help: "GatedDeltaNet state bits (Qwen only). 16 = bf16, halves state per cache checkpoint; the 48/64 GB recipes pass 16.",
                    unsupported: [.deepseek]),
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
                    help: "Keep this many GiB resident and stream routed experts from SSD. Required by DeepSeek-V4.1 (108 on a 128 GB Mac).",
                    important: true),
        SushiOption(id: "expert-pick-tolerance", title: "Expert pick tolerance", category: .modelMemory,
                    kind: .double(0),
                    help: "0…0.6, lossy: swap a missed streamed expert for a cached near-ranked one. 0 = exact."),
        SushiOption(id: "drop-expert", title: "Drop experts (n)", category: .modelMemory,
                    kind: .int(0),
                    help: "Never load the n least-used routed experts (multiple of 8). DeepSeek-V4.1 only; every other arch refuses.",
                    unsupported: [.qwen, .mimo, .glm]),
        SushiOption(id: "skip-mem-preflight", title: "Skip memory preflight", category: .modelMemory,
                    kind: .presence,
                    help: "Bypass the free-RAM check before a load."),
        SushiOption(id: "wired-margin-gib", title: "Wired margin (GiB)", category: .modelMemory,
                    kind: .int(1),
                    help: "Headroom kept under iogpu.wired_limit_mb (1…32)."),
        SushiOption(id: "vision", title: "Vision tower", category: .modelMemory,
                    kind: .onOff, negation: "--no-vision",
                    help: "Force the vision tower on, or --no-vision to skip it and save its memory."),
        SushiOption(id: "prefill-decode-share", title: "Prefill/decode share", category: .modelMemory,
                    kind: .double(0),
                    help: "0…0.9 target decode share of wall time during another request's prefill."),

        // ── Speculation ────────────────────────────────────────────────
        SushiOption(id: "mtp", title: "MTP (speculative decode)", category: .speculation,
                    kind: .onOff, negation: "--no-mtp",
                    help: "On by default for Qwen/MiMo/DeepSeek(DSpark), off for GLM. Required ON for streamed packs.",
                    important: true),
        SushiOption(id: "mtp-head-kv-quant", title: "MTP head KV quant", category: .kv,
                    kind: .presence,
                    help: "Store Qwen's MTP-head KV at --kv-quant width too. DeepSeek refuses.",
                    unsupported: [.deepseek], important: true),
        SushiOption(id: "mtp-min-depth", title: "MTP min depth", category: .speculation,
                    kind: .int(1),
                    help: "Fewest tokens a round drafts (1…8). Launch-only."),
        SushiOption(id: "mtp-max-depth", title: "MTP max depth", category: .speculation,
                    kind: .int(8),
                    help: "Most tokens a round drafts (1…8; adaptive default, up to 8 on eligible M5)."),
        SushiOption(id: "mtp-typical", title: "Typical acceptance (p)", category: .speculation,
                    kind: .double(0),
                    help: "Typical draft acceptance, lossy for sampled requests; 0 = exact. DeepSeek refuses.",
                    unsupported: [.deepseek]),
        SushiOption(id: "mtp-tokenv3", title: "TokenV3 cascade (0…1)", category: .speculation,
                    kind: .double(0),
                    help: "TokenV3 cascade acceptance, lossy. DeepSeek refuses.",
                    unsupported: [.deepseek]),
        SushiOption(id: "mtp-greedy-tail", title: "Greedy draft tail", category: .speculation,
                    kind: .presence,
                    help: "Sampled requests draft only the first token by sampling. DeepSeek refuses.",
                    unsupported: [.deepseek]),
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
        SushiOption(id: "prefix-cache-entries", title: "Prefix cache entries", category: .prefixCache,
                    kind: .int(32),
                    help: "Hot-cache capacity; 0 disables prefix reuse. Use 1 for a solo agent, 4–8 when several share the server.",
                    important: true),
        SushiOption(id: "prefix-cache-mem", title: "Prefix cache RAM", category: .prefixCache,
                    kind: .text(""),
                    help: "RAM tier budget (e.g. 1GB); off unless set. Faster than the SSD tier.",
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
        SushiOption(id: "reasoning-budget", title: "Reasoning budget", category: .sampling,
                    kind: .int(0),
                    help: "Max thinking tokens per request."),
        SushiOption(id: "preserve-thinking", title: "Preserve thinking", category: .sampling,
                    kind: .choice(["on", "off"]),
                    help: "off keeps only the latest turn's thinking in the prompt (shorter context, re-prefills older thoughts)."),
        SushiOption(id: "think-penalty", title: "Think penalty", category: .sampling,
                    kind: .double(0),
                    help: "Lower overthinking-marker logits inside the reasoning span; 0 = off."),

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
        SushiOption(id: "metrics", title: "Prometheus metrics", category: .serving,
                    kind: .presence,
                    help: "Expose /metrics and /metrics.json."),
        SushiOption(id: "timeout", title: "Stall timeout (s)", category: .serving,
                    kind: .int(300),
                    help: "Request stall timeout in seconds; 0 = none."),
        SushiOption(id: "gpu-warm-secs", title: "GPU warm secs", category: .serving,
                    kind: .int(60),
                    help: "Keep the GPU awake this long after the last request; 0 = off (avoids the ~1 s idle-GPU stall)."),
        SushiOption(id: "parent-pid", title: "Parent pid watchdog", category: .serving,
                    kind: .int(0),
                    help: "sushi exits when this pid dies. Sushi Launcher sets its own automatically unless you pin a value (App ▸ Settings)."),
        SushiOption(id: "max-concurrent", title: "Max concurrent (legacy)", category: .serving,
                    kind: .int(1),
                    help: "Only sizes the submit queue and floors prefix-cache capacity; batching is the model's call."),
        SushiOption(id: "no-prevent-sleep", title: "Allow idle sleep", category: .serving,
                    kind: .presence,
                    help: "Do not inhibit system sleep during inference."),
        SushiOption(id: "no-update-check", title: "No update check", category: .serving,
                    kind: .presence,
                    help: "Never ask GitHub for a newer sushi release."),
        SushiOption(id: "no-tool-autocorrect", title: "No tool autocorrect", category: .serving,
                    kind: .presence,
                    help: "Stop coercing tool-call arguments to the schema's types."),

        // ── Logging & diagnostics ──────────────────────────────────────
        SushiOption(id: "log-level", title: "Log level", category: .logging,
                    kind: .choice(["info", "error", "warn", "debug"]),
                    help: "error, warn, info (default) or debug."),
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
