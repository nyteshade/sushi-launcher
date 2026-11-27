import Foundation

/// The model families sushi serves. Used to warn when a flag — or one of its
/// VALUES — is refused at load time (e.g. DeepSeek-V4.1 rejects `--kv-quant`
/// outright; GLM accepts it but refuses the value 4).
enum ModelFamily: String, CaseIterable, Codable {
    case qwen
    case mimo
    case glm
    case deepseek
    case hy4
    case unknown

    /// Ordered longest-match-first: "hy4" must not be shadowed by a shorter
    /// token, and a pack folder name carries the family in its first segment.
    static func detect(from modelString: String) -> ModelFamily {
        let lower = modelString.lowercased()
        if lower.contains("deepseek") { return .deepseek }
        if lower.contains("mimo") { return .mimo }
        if lower.contains("glm") { return .glm }
        if lower.contains("qwen") { return .qwen }
        if lower.contains("hy4") || lower.contains("hy-4") { return .hy4 }
        return .unknown
    }

    var label: String {
        switch self {
        case .qwen: return "Qwen"
        case .mimo: return "MiMo"
        case .glm: return "GLM"
        case .deepseek: return "DeepSeek"
        case .hy4: return "Hy4"
        case .unknown: return "unknown model"
        }
    }

    /// Families sushi still tests, benchmarks and tunes. MiMo loads but has
    /// been unsupported since 1.5.1 (1.5.0 was the last release that tuned it).
    var isSupported: Bool { self != .mimo }

    var supportNote: String? {
        switch self {
        case .mimo:
            return "MiMo still loads, but sushi has not tested, benchmarked or tuned it since 1.5.1 — 1.5.0 was the last release that supported it."
        default:
            return nil
        }
    }
}

// MARK: - Refusals

/// One reason sushi stops at load. A refusal is either about the FLAG (any
/// value is refused) or about specific VALUES of it — GLM takes `--kv-quant 8`
/// and refuses `--kv-quant 4`, which a flag-level set cannot express.
struct Refusal {
    var families: Set<ModelFamily>
    /// nil = the flag itself is refused for these families.
    /// Non-nil = only these values are refused; other values are fine.
    var values: Set<String>? = nil
    var reason: String

    func matches(family: ModelFamily, value: String?) -> Bool {
        guard families.contains(family) else { return false }
        guard let values else { return true }
        guard let value else { return false }
        return values.contains(value)
    }
}
