import Foundation

/// Maps a `sushi list` short name to its Hugging Face repo under the
/// beamster org. Exact table for documented packs; a heuristic for
/// new quants (which is how a :2.6bpw appears in the first place).
enum HFRepo {
    private static let exact: [String: String] = [
        "qwen3.8-flash-next:2bpw":      "Qwen3.8-Flash-Next-Sushi-2bpw",
        "qwen3.8-flash-next:2.75bpw":   "Qwen3.8-Flash-Next-Sushi-STQ-2.75bpw",
        "qwen3.8-flash-next:4bpw":      "Qwen3.8-Flash-Next-Sushi-4bpw",
        "mimo-v2.6-flash:2.3bpw":       "MiMo-V2.6-Flash-Sushi-2.3bpw",
        "glm-5.3-flash:2bpw":           "GLM-5.3-Flash-Sushi-2bpw",
        "glm-5.3-flash:2.4bpw":         "GLM-5.3-Flash-Sushi-2.4bpw",
        "deepseek-v4.1-flash:1.75bpw":  "DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw",
    ]

    static func repo(for packName: String) -> String? {
        if let known = exact[packName] { return known }
        guard let colon = packName.firstIndex(of: ":") else { return nil }
        let family = String(packName[..<colon])
        let tag = String(packName[packName.index(after: colon)])
        let famMap = [
            "qwen3.8-flash-next": "Qwen3.8-Flash-Next",
            "mimo-v2.6-flash":    "MiMo-V2.6-Flash",
            "glm-5.3-flash":      "GLM-5.3-Flash",
            "deepseek-v4.1-flash": "DeepSeek-V4.1-Flash",
        ]
        let head = famMap[family] ?? family
            .split(separator: "-")
            .map { token -> String in
                let s = String(token)
                if s.hasPrefix("v") { return s.uppercased() }
                return s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: "-")
        return "\(head)-Sushi-\(tag)"
    }

    static func url(for packName: String) -> String? {
        repo(for: packName).map { "https://huggingface.co/beamster/\($0)" }
    }
}

// MARK: - Live metadata (Hugging Face API)

/// Fetches parameter counts / download stats for packs, once each,
/// off the main thread. Everything is optional; the UI degrades to the
/// curated knowledge table when HF is unreachable.
@MainActor
final class PackEnricher: ObservableObject {
    struct PackDetails: Equatable {
        var parameters: Double?
        var downloadsLastMonth: Int?
        var likes: Int?
    }

    /// value nil = fetched but nothing available (or repo guess 404'd)
    @Published private(set) var details: [String: PackDetails] = [:]
    private var inflight: Set<String> = []

    var fetched: Set<String> { Set(details.keys) }

    func enrich(_ packs: [SushiPack]) {
        for pack in packs where !details.keys.contains(pack.name) && !inflight.contains(pack.name) {
            inflight.insert(pack.name)
            let name = pack.name
            let repo = HFRepo.repo(for: pack.name)
            Task { [weak self] in
                let fetchedDetails = await Self.fetch(repo: repo)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inflight.remove(name)
                    self.details[name] = fetchedDetails
                }
            }
        }
    }

    private static func fetch(repo: String?) async -> PackDetails? {
        guard let repo,
              let url = URL(string: "https://huggingface.co/api/models/beamster/\(repo)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let meta = try? JSONDecoder().decode(HFMeta.self, from: data) else {
            return PackDetails(parameters: nil, downloadsLastMonth: nil, likes: nil)
        }
        return PackDetails(parameters: meta.safetensors?.total,
                           downloadsLastMonth: meta.downloads,
                           likes: meta.likes)
    }

    private struct HFMeta: Decodable {
        struct Safetensors: Decodable {
            let total: Double?
        }
        let safetensors: Safetensors?
        let downloads: Int?
        let likes: Int?
    }
}
