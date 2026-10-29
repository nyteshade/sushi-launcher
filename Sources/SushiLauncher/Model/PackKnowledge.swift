import Foundation

// MARK: - Curated pack knowledge
//
// `sushi list` gives us name/size/downloaded/fit. The richer facts shown in
// the model picker come from this table — anchors taken from the README
// memory matrix (weights-only GiB and 1M-context GiB per pack, 8-bit KV).
// For quants that aren't listed (e.g. a new :2.6bpw) we interpolate between
// the family's anchors and mark everything with ≈.

struct PackInfo {
    let summary: String
    let modalities: String
    let license: String
    let weights: [(Double, Double)]   // (bpw, weights-only GiB)
    let ctx1M: [(Double, Double)]     // (bpw, GiB at 1M ctx, 8-bit KV)
    let minMac: [(Double, Int)]       // (bpw, smallest Mac that admits it)
}

struct PackFacts {
    var quantLabel: String?
    var weightsGiB: Double?
    var ctx1MGiB: Double?
    var minMacGB: Int?
    var modalities: String
    var summary: String
    var license: String
}

enum PackKnowledge {
    static let familyInfo: [ModelFamily: PackInfo] = [
        .qwen: PackInfo(
            summary: "Qwen3.8 Flash-Next — a gated-deltanet MoE with MTP speculative decoding on by default and an n-gram table that lives on SSD. DFlash2 drafter optional via --drafter. The 32/48/64 GB launch recipes add --qwen-gdn 16 (bf16 recurrent state).",
            modalities: "text + images",
            license: "Qwen Community License",
            weights: [(2, 35.2), (2.75, 46.4), (4, 63.9)],
            ctx1M: [(2, 58.4), (2.75, 69.5), (4, 87.1)],
            minMac: [(2, 48), (2.75, 64), (4, 96)]
        ),
        .mimo: PackInfo(
            summary: "MiMo V2.6 Flash — MTP and the 8-bit KV cache are on by default, and thinking is on as in Xiaomi's chat template. A full 1M context fits on a 128 GB Mac at the documented GPU limit.",
            modalities: "text + images",
            license: "Xiaomi MIT",
            weights: [(2.3, 89.7)],
            ctx1M: [(2.3, 108.2)],
            minMac: [(2.3, 128)]
        ),
        .glm: PackInfo(
            summary: "GLM-5.3 Flash — ships Inco.ai's DFlash2 assistant inside the pack (built down to a local copy on first load; CC BY-NC-ND, keep it private). Up to four requests decode together; auto context is 512K at 8-bit KV.",
            modalities: "text + images + video",
            license: "GLM family license (see pack page)",
            weights: [(2, 78.3), (2.4, 89.8)],
            ctx1M: [(2, 90.5), (2.4, 102.0)],
            minMac: [(2, 96), (2.4, 128)]
        ),
        .deepseek: PackInfo(
            summary: "DeepSeek V4.1 Flash — routed experts stream from SSD inside --ssd-budget-gb; 189 GiB of Engram tables are read a row at a time and never loaded. DSpark drafter on by default; thinking at high.",
            modalities: "text + images",
            license: "see pack page",
            weights: [(1.75, 120)],
            ctx1M: [],
            minMac: [(1.75, 128)]
        ),
    ]

    /// Parse "…:2.75bpw" → 2.75
    static func bpw(from packName: String) -> Double? {
        guard let range = packName.range(of: #"(\d+(?:\.\d+)?)bpw"#, options: .regularExpression) else { return nil }
        let numeric = packName[range].dropLast(3)   // strip "bpw"
        return Double(numeric)
    }

    static func facts(for pack: SushiPack) -> PackFacts {
        let family = ModelFamily.detect(from: pack.name)
        let bpw = bpw(from: pack.name)
        let label = bpw.map { "\($0.formattedLabel()) bpw" }

        guard let info = familyInfo[family] else {
            return PackFacts(quantLabel: label, weightsGiB: nil, ctx1MGiB: nil,
                             minMacGB: nil, modalities: "—",
                             summary: "No curated notes for this family yet — sushi lists it, so it should serve.",
                             license: "—")
        }
        let weights = bpw.flatMap { interpolate(info.weights, $0) }
        let ctx = bpw.flatMap { interpolate(info.ctx1M, $0) }
        let mac = bpw.flatMap { nearestTier(info.minMac, $0) }
        return PackFacts(quantLabel: label, weightsGiB: weights, ctx1MGiB: ctx,
                         minMacGB: mac, modalities: info.modalities,
                         summary: info.summary, license: info.license)
    }

    // MARK: estimation

    private static func interpolate(_ anchors: [(Double, Double)], _ x: Double) -> Double? {
        guard !anchors.isEmpty else { return nil }
        let a = anchors.sorted { $0.0 < $1.0 }
        if x <= a[0].0 || a.count == 1 {
            let (b, g) = a[0]
            return b > 0 ? g * x / b : nil          // scale by bpw ratio
        }
        if x >= a[a.count - 1].0 {
            let (b, g) = a[a.count - 1]
            return b > 0 ? g * x / b : nil
        }
        for i in 1..<a.count where x <= a[i].0 {
            let (x0, y0) = a[i - 1]
            let (x1, y1) = a[i]
            guard x1 > x0 else { continue }
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return nil
    }

    /// The tier documented for the nearest anchor at-or-above this bpw.
    private static func nearestTier(_ anchors: [(Double, Int)], _ x: Double) -> Int? {
        guard !anchors.isEmpty else { return nil }
        let a = anchors.sorted { $0.0 < $1.0 }
        for (bpw, gb) in a where x <= bpw + 0.001 { return gb }
        return a.last?.1
    }
}

extension Double {
    /// 2.0 → "2", 2.75 → "2.75"
    func formattedLabel() -> String {
        if rounded() == self && !isNaN { return String(Int(self)) }
        return String(format: "%g", self)
    }
}
