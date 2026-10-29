import AppKit
import SwiftUI

// MARK: - Launch configuration form
//
// Beginner path: pick a curated model (custom picker with inline install)
// and a launch recipe, tune a handful of Quick settings, hit Start.
// Everything deep (all 50+ flags, raw --model row) sits behind the
// advanced toggle.

struct LaunchPane: View {
    @EnvironmentObject var model: AppModel

    private var surfacedElsewhere: Set<String> {
        Set(SushiOptionRegistry.quickRows.map { $0.id }).union(["model"])
    }

    var body: some View {
        Form {
            ModelSection(catalog: model.catalog)
            PresetSection()
            QuickSection()
            if model.settings.advancedOptions {
                ForEach(OptionCategory.allCases) { category in
                    categorySection(category)
                }
            }
            CommandSection()
            Section {
                Toggle("Advanced flag editor — list every serve option by category",
                       isOn: $model.settings.advancedOptions)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func categorySection(_ category: OptionCategory) -> some View {
        let rows = SushiOptionRegistry.rows(in: category, excluding: surfacedElsewhere)
        if !rows.isEmpty {
            Section(category.rawValue) {
                ForEach(rows) { option in
                    OptionRow(option: option)
                }
            }
        }
    }
}

// MARK: - Model (curated picker popover + quick actions)

private struct ModelSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var catalog: ModelCatalog

    @State private var showPicker = false

    private var option: SushiOption { SushiOptionRegistry.option("model")! }

    init(catalog: ModelCatalog) {
        self.catalog = catalog
    }

    private var selectedPack: SushiPack? {
        SushiPack.match(modelText: model.config.modelText, in: catalog.packs)
    }

    private var modelDisplayText: String {
        if let pack = selectedPack {
            return pack.downloaded ? pack.name : "\(pack.name) — not installed"
        }
        let text = model.config.modelText
        if text.trimmed.isEmpty || text == "~/.sushi/models" { return "Default models folder" }
        return "Custom: \((text as NSString).lastPathComponent)"
    }

    var body: some View {
        Section("Model") {
            HStack(spacing: 10) {
                Button {
                    showPicker.toggle()
                    model.enricher.enrich(catalog.packs)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cube.box")
                        Text(modelDisplayText)
                            .fontWeight(.medium)
                        if let pack = selectedPack, pack.recommended {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                        Image(systemName: "chevron.up.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showPicker) {
                    ModelPickerPopover(isPresented: $showPicker,
                                       catalog: catalog,
                                       enricher: model.enricher)
                        .environmentObject(model)
                }

                Spacer()

                if catalog.pullingPack != nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let pack = selectedPack, !pack.downloaded,
                          !pack.status.lowercased().contains("not yet published") {
                    Button {
                        catalog.pull(pack.name, customPath: model.settings.sushiPathOverride)
                    } label: {
                        Label("Download \(pack.sizeLabel)", systemImage: "arrow.down.circle")
                    }
                }
            }

            installProgress

            if model.settings.advancedOptions {
                OptionRow(option: option)
            }
        }
    }

    @ViewBuilder
    private var installProgress: some View {
        if catalog.pullingPack == nil, !catalog.pullLog.isEmpty {
            HStack(spacing: 6) {
                Text(catalog.pullLog.last.map { "Last pull: \($0)" } ?? "Download finished")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Hide") { catalog.dismissPullLog() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Launch recipes

private struct PresetSection: View {
    @EnvironmentObject var model: AppModel

    private var grouped: [(group: String, presets: [Preset])] {
        var out: [(String, [Preset])] = []
        for preset in Preset.builtIn {
            if let index = out.firstIndex(where: { $0.0 == preset.group }) {
                out[index].1.append(preset)
            } else {
                out.append((preset.group, [preset]))
            }
        }
        return out.map { (group: $0.0, presets: $0.1) }
    }

    var body: some View {
        Section("Launch recipe") {
            HStack {
                Menu {
                    ForEach(grouped, id: \.group) { entry in
                        Section(entry.group) {
                            ForEach(entry.presets) { preset in
                                Button(preset.name) { model.applyPreset(preset) }
                            }
                        }
                    }
                } label: {
                    Label(model.matchedPresetName, systemImage: "list.bullet.rectangle.portrait")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            if let explain = model.matchedPreset?.explain, !explain.isEmpty {
                Text(explain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Custom configuration — pick a recipe to start with, then tune anything below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Quick settings

private struct QuickSection: View {
    var body: some View {
        Section("Quick settings") {
            ForEach(SushiOptionRegistry.quickRows) { option in
                OptionRow(option: option)
            }
        }
    }
}

// MARK: - Command preview

private struct CommandSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Command") {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.config.commandLinePreview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy command line") { model.copyCommandLine() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            Text(model.settings.autoParentPid
                 ? "At launch the app appends --parent-pid so sushi exits if the launcher is killed. An unset flag means sushi's own default applies."
                 : "An unset flag means sushi's own default applies. --parent-pid is not auto-added (see Settings).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
