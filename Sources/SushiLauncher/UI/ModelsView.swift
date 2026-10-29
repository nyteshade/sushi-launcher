import SwiftUI

// MARK: - Models window (`sushi list` + `sushi pull`)

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var catalog: ModelCatalog

    init(catalog: ModelCatalog) {
        self.catalog = catalog
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            pullPanel
        }
        .onAppear { model.refreshCatalog() }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            openWindow(id: "main")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("This Mac: \(catalog.macTier ?? "…")")
                .font(.headline)
            if catalog.isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                model.revealModelsDir()
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal ~/.sushi/models")
            Button("Refresh") {
                catalog.refresh(customPath: model.settings.sushiPathOverride)
            }
            .disabled(catalog.isLoading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if catalog.packs.isEmpty && !catalog.isLoading {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(catalog.lastError ?? "No packs listed yet.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Refresh") {
                    catalog.refresh(customPath: model.settings.sushiPathOverride)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 0) {
                Table(catalog.packs) {
                    TableColumn("Pack") { pack in
                        HStack(spacing: 5) {
                            if pack.recommended {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Recommended for this Mac")
                            }
                            Text(pack.name)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .width(min: 230)
                    TableColumn("Size") { pack in
                        Text(pack.sizeLabel)
                    }
                    .width(86)
                    TableColumn("Downloaded") { pack in
                        if pack.downloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(95)
                    TableColumn("This Mac") { pack in
                        Text(pack.status.isEmpty ? "—" : pack.status)
                            .foregroundStyle(statusColor(for: pack))
                            .lineLimit(1)
                    }
                    .width(min: 150)
                    TableColumn("Actions") { pack in
                        HStack(spacing: 6) {
                            Button("Use") { model.usePack(pack) }
                            if catalog.pullingPack == pack.name {
                                Button("Cancel") { catalog.cancelPull() }
                            } else {
                                Button("Pull") {
                                    catalog.pull(pack.name, customPath: model.settings.sushiPathOverride)
                                }
                                .disabled(pack.downloaded || catalog.pullingPack != nil)
                                .help("sushi pull \(pack.name)")
                            }
                        }
                    }
                }
                if let error = catalog.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var pullPanel: some View {
        if catalog.pullingPack != nil || !catalog.pullLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if catalog.pullingPack != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(catalog.pullingPack.map { "Pulling \($0) — packs land in ~/.sushi/models/beamster/" } ?? "Pull finished")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Button("Hide") { catalog.dismissPullLog() }
                        .disabled(catalog.pullingPack != nil)
                    Button("Cancel", role: .destructive) { catalog.cancelPull() }
                        .disabled(catalog.pullingPack == nil)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(catalog.pullLog.enumerated()), id: \.offset) { index, text in
                                Text(text.isEmpty ? " " : text)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onChange(of: catalog.pullLog.count) { _, _ in
                        if let last = catalog.pullLog.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func statusColor(for pack: SushiPack) -> Color {
        let status = pack.status.lowercased()
        if status.contains("fits") { return .green }
        if status.contains("may stream") { return .orange }
        if status.contains("not yet published") { return .secondary }
        return .primary
    }
}
