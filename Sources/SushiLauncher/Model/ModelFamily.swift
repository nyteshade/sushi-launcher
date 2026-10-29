import Foundation

/// The model families sushi serves. Used to warn when a flag that a family
/// refuses at load time (e.g. DeepSeek-V4.1 rejects `--kv-quant`) is enabled.
enum ModelFamily: String, CaseIterable, Codable {
    case qwen
    case mimo
    case glm
    case deepseek
    case unknown

    static func detect(from modelString: String) -> ModelFamily {
        let lower = modelString.lowercased()
        if lower.contains("deepseek") { return .deepseek }
        if lower.contains("mimo") { return .mimo }
        if lower.contains("glm") { return .glm }
        if lower.contains("qwen") { return .qwen }
        return .unknown
    }

    var label: String {
        switch self {
        case .qwen: return "Qwen"
        case .mimo: return "MiMo"
        case .glm: return "GLM"
        case .deepseek: return "DeepSeek"
        case .unknown: return "unknown model"
        }
    }
}
