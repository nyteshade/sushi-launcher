import AppKit
import SwiftUI

// MARK: - Custom model picker popover
//
// Replaces the HTML-<select>-style Menu with a real picker: a filterable
// list (recommended packs on top, rule, then the rest) with a detail pane
// on the right showing curated + live (Hugging Face) metadata and actions.

struct ModelPickerPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var isPresented: Bool
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var enricher: PackEnricher

    @State private var query = ""
    @State private var selectedName: String?

    init(isPresented: Binding<Bool>, catalog: ModelCatalog, enricher: PackEnricher) {
        self._isPresented = isPresented
        self.catalog = catalog
        self.enricher = enricher
    }

    private var filtered: [SushiPack] {
        let q = query.trimmed
        guard !q.isEmpty else { return catalog.packs }
        return catalog.packs.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var recommended: [SushiPack] { filtered.filter { $0.recommended } }
    private var others: [SushiPack] { filtered.filter { !$0.recommended } }
    private var selected: SushiPack? {
        guard let name = selectedName else { return nil }
        return catalog.packs.first { $0.name == name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                listPane.frame(width: 400)
                Divider()
                detailPane.frame(width: 372)
            }
            .frame(height: 440)
            Divider()
            footer
        }
        .onAppear {
            if selectedName == nil {
                selectedName =
                    SushiPack.match(modelText: model.config.modelText, in: catalog.packs)?.name
                    ?? recommended.first?.name ?? others.first?.name
            }
            enricher.enrich(catalog.packs)
        }
    }

    // MARK: list

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Filter packs", text: $query).textFieldStyle(.plain)
                if catalog.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(10)
            Divider()
            if catalog.packs.isEmpty {
                VStack(spacing: 10) {
                    Text(catalog.lastError ?? "The pack list has not loaded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Open Models window") {
                        openWindow(id: "models")
                        isPresented = false
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(recommended) { pack in row(pack) }
                    if !recommended.isEmpty && !others.isEmpty {
                        Divider().padding(.horizontal, 6)
                    }
                    ForEach(others) { pack in row(pack) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ pack: SushiPack) -> some View {
        Button {
            selectedName = pack.name
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if pack.recommended {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(pack.name)
                        .font(.system(.callout, design: .monospaced))
                    Spacer(minLength: 4)
                    if pack.downloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text(pack.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(subline(pack))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedName == pack.name ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .help(pack.status.isEmpty ? pack.name : "\(pack.name) — \(pack.status)")
    }

    private func subline(_ pack: SushiPack) -> String {
        let facts = PackKnowledge.facts(for: pack)
        var bits: [String] = []
        if let q = facts.quantLabel { bits.append(q) }
        if let w = facts.weightsGiB { bits.append("≈\(Int(w.rounded())) GiB weights") }
        if let m = facts.minMacGB { bits.append("\(m) GB Mac+") }
        if !pack.status.isEmpty, !pack.downloaded { bits.append(pack.status) }
        bits.append(facts.modalities)
        return bits.joined(separator: " · ")
    }

    // MARK: detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let pack = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(pack.name)
                            .font(.headline.monospaced())
                            .textSelection(.enabled)
                        if pack.recommended {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                    badges(for: pack)
                    Text(PackKnowledge.facts(for: pack).summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    specs(for: pack)
                    actions(for: pack)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a pack to see details.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func badges(for pack: SushiPack) -> some View {
        let status = pack.status.lowercased()
        HStack(spacing: 6) {
            if pack.downloaded { badge("Installed", color: .green) }
            if pack.recommended { badge("Recommended", color: .accentColor) }
            if status.contains("may stream") { badge(pack.status, color: .orange) }
            if status.contains("not yet published") { badge("Not yet published", color: .secondary) }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private func specs(for pack: SushiPack) -> some View {
        let facts = PackKnowledge.facts(for: pack)
        return VStack(alignment: .leading, spacing: 5) {
            if let details = enricher.details[pack.name] {
                if let params = details.parameters, params > 0 {
                    spec("Parameters", String(format: "%.1fB", params / 1_000_000_000))
                }
                if let downloads = details.downloadsLastMonth {
                    spec("Hugging Face", hfLine(downloads: downloads, likes: details.likes))
                }
            }
            spec("Quantization", facts.quantLabel ?? "—")
            spec("Download size", pack.sizeLabel)
            if let w = facts.weightsGiB { spec("Resident weights", "≈\(Int(w.rounded())) GiB") }
            if let c = facts.ctx1MGiB { spec("1M-ctx footprint", "≈\(Int(c.rounded())) GiB (8-bit KV)") }
            if let m = facts.minMacGB { spec("Runs from", "\(m) GB Mac") }
            spec("Modalities", facts.modalities)
            spec("License", facts.license)
            spec("This Mac", pack.status.isEmpty ? (pack.downloaded ? "on disk" : "—") : pack.status)
            if let url = HFRepo.url(for: pack.name) {
                Button("Open on Hugging Face ↗") { UIActions.openWeb(url) }
                    .buttonStyle(.link)
                    .padding(.top, 2)
            }
        }
    }

    /// Plain-string helper (no ViewBuilder) for the Hugging Face stats line.
    private func hfLine(downloads: Int, likes: Int?) -> String {
        var line = "\(downloads) / last month"
        if let likes { line += " · ♥ \(likes)" }
        return line
    }

    private func spec(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func actions(for pack: SushiPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if catalog.pullingPack == pack.name {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading… (rerun Download to resume an interrupted pull)")
                        .font(.caption)
                    Spacer()
                    Button("Cancel", role: .destructive) { catalog.cancelPull() }
                }
                if let last = catalog.pullLog.last, !last.isEmpty {
                    Text(last)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack {
                    if !pack.downloaded, !pack.status.lowercased().contains("not yet published") {
                        Button(pack.sizeLabel == "—" ? "Download…" : "Download \(pack.sizeLabel)…") {
                            catalog.pull(pack.name, customPath: model.settings.sushiPathOverride)
                        }
                    }
                    Spacer()
                    Button(pack.downloaded ? "Use this model" : "Use anyway") {
                        model.selectPack(pack)
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.config.modelText == pack.name)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Choose installed folder…") {
                if let path = chooseFolder() {
                    model.setModelPath(path)
                    isPresented = false
                }
            }
            Button("Manage downloads…") {
                openWindow(id: "models")
                isPresented = false
            }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Serve this"
        let modelsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".sushi/models")
        if FileManager.default.fileExists(atPath: modelsDir) {
            panel.directoryURL = URL(fileURLWithPath: modelsDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
