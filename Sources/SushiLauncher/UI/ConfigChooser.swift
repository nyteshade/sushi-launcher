import SwiftUI

// MARK: - Config chooser
//
// Three questions a person can answer, and a live readout of what they cost:
//
//   Which pack?        → the model picker already answers this
//   How much context?  → a ladder in K/M tokens, not a raw integer
//   How much of my Mac? → a posture, not a GiB figure
//
// Everything else is derived and shown as a budget bar plus plain-language
// reasoning. The advanced flag editor remains for anyone who wants to set
// RoPE or anything else by hand — this pane never hides it, it just stops
// being the only way in.

struct ConfigChooser: View {
    @EnvironmentObject var model: AppModel

    private var ramGB: Int { MemoryModel.ramGB() }

    private var packName: String {
        let text = model.config.modelText
        let last = (text as NSString).lastPathComponent
        return last.isEmpty ? "~/.sushi/models" : last
    }

    private var profile: PackProfile { PackKnowledge.profile(for: packName) }

    private var derived: ConfigDeriver.Derived {
        ConfigDeriver.derive(packName: packName,
                             contextTokens: model.settings.chosenContextTokens,
                             ramGB: ramGB,
                             posture: model.settings.chosenPosture,
                             kv: model.settings.chosenKV,
                             profile: profile)
    }

    var body: some View {
        Section("Configuration") {
            contextRow
            postureRow
            kvRow
            Divider()
            BudgetBar(budget: derived.budget)
            rationaleRows
            if !derived.warnings.isEmpty {
                warningsRows
            }
            applyRow
        }
    }

    // MARK: Context

    private var contextRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Context window", selection: Binding(
                get: { model.settings.chosenContextTokens },
                set: { model.settings.chosenContextTokens = $0 }
            )) {
                ForEach(ContextChoice.ladder) { choice in
                    Text(choice.label).tag(choice.tokens)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            if let choice = ContextChoice.ladder.first(where: { $0.tokens == model.settings.chosenContextTokens }) {
                Text(choice.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The largest window that fits, offered as a one-click answer.
            if let maxTokens = MemoryModel.maxContextTokens(
                weightsGiB: profile.weightsGiB(atBPW: PackKnowledge.bpw(from: packName) ?? 4) ?? 0,
                kvQuant: model.settings.chosenKV.kvQuant,
                family: profile.family,
                ramGB: ramGB),
               maxTokens > model.settings.chosenContextTokens {
                Button("Use the largest that fits — \(ContextChoice.label(forTokens: maxTokens))") {
                    model.settings.chosenContextTokens = maxTokens
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: Posture

    private var postureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Memory posture", selection: Binding(
                get: { model.settings.chosenPosture },
                set: { model.settings.chosenPosture = $0 }
            )) {
                ForEach(MemoryPosture.allCases) { posture in
                    Text(posture.label).tag(posture)
                }
            }
            .pickerStyle(.segmented)

            Text(model.settings.chosenPosture.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: KV quality

    private var kvRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("KV cache", selection: Binding(
                get: { model.settings.chosenKV },
                set: { model.settings.chosenKV = $0 }
            )) {
                ForEach(KVQuality.allCases) { quality in
                    Text(quality.label)
                        .tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .disabled(profile.family == .deepseek)

            Text(profile.family == .deepseek
                 ? "DeepSeek-V4.1 has no KV cache, so this does not apply."
                 : model.settings.chosenKV.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rationale

    private var rationaleRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(derived.rationale.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 5) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var warningsRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(derived.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var applyRow: some View {
        HStack {
            Button("Apply this configuration") {
                model.applyDerived(derived)
            }
            .disabled(!derived.fits)

            if !derived.fits {
                Text("Does not fit — lower the context or the posture.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
    }
}

// MARK: - Budget bar
//
// The whole point of the chooser: show what the configuration costs against
// what the Mac can give, in one glance, with the numbers beside it.

struct BudgetBar: View {
    let budget: MemoryModel.Budget

    private var weightsFraction: Double { fraction(budget.weightsGiB) }
    private var kvFraction: Double { fraction(budget.kvGiB) }
    private var overheadFraction: Double { fraction(budget.overheadGiB) }

    private func fraction(_ gib: Double) -> Double {
        guard budget.usableGiB > 0 else { return 0 }
        return min(1, gib / budget.usableGiB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.accentColor).frame(width: geo.size.width * weightsFraction)
                        Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: geo.size.width * kvFraction)
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: geo.size.width * overheadFraction)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(height: 14)

            HStack(spacing: 12) {
                legend(color: .accentColor, label: "weights \(fmt(budget.weightsGiB))")
                legend(color: .accentColor.opacity(0.55), label: "KV \(fmt(budget.kvGiB))")
                legend(color: .secondary.opacity(0.4), label: "warmup \(fmt(budget.overheadGiB))")
                Spacer()
                Text("\(fmt(budget.totalGiB)) / \(fmt(budget.usableGiB)) GiB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(budget.fits ? Color.secondary : Color.red)
            }
            .font(.caption)

            Text(budget.fits
                 ? "\(fmt(budget.headroomGiB)) GiB headroom (\(Int(budget.utilisation * 100))% used)"
                 : "Over budget by \(fmt(-budget.headroomGiB)) GiB")
                .font(.caption)
                .foregroundStyle(budget.fits ? Color.secondary : Color.red)
        }
        .padding(.vertical, 2)
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
        .foregroundStyle(.secondary)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
