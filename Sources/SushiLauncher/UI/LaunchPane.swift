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
            ConformanceSection()
            ModelSection(catalog: model.catalog)
            ConfigChooser()
            RecipeSection()
            LaunchIssuesSection()
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
        .onAppear { model.checkConformance() }
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

// MARK: - CLI conformance banner
//
// The registry is a transcription of `sushi serve --help`, so it drifts when
// sushi updates. This section is the report: what the installed binary no
// longer accepts, what it accepts that the app cannot express, and what it
// accepts and ignores. It is the reason the next version bump is noticed.

private struct ConformanceSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let report = model.conformance, !report.isClean || report.failure != nil {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.summary, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)

                    if !report.dead.isEmpty {
                        Text("Removed by sushi — these flags now exit non-zero:")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(report.dead) { dead in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("--\(dead.id)")
                                    .font(.system(size: 11, design: .monospaced))
                                if dead.hasReplacement {
                                    Text("→ use \(dead.replacements.map { "--" + $0 }.joined(separator: " / "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(dead.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 8)
                        }
                    }

                    if !report.missing.isEmpty {
                        Text("Accepted by sushi, not modelled here: \(report.missing.map { "--" + $0 }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if !report.inert.isEmpty {
                        Text("Accepted and ignored by sushi: \(report.inert.map { "--" + $0 }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Re-check") { model.checkConformance(force: true) }
                            .controlSize(.small)
                        if model.conformanceChecking {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("sushi CLI conformance")
            }
        }
    }
}

// MARK: - Launch issues
//
// Blocking issues are what the Start button refuses on. Showing them here
// means the refusal is visible before the button is pressed.

private struct LaunchIssuesSection: View {
    @EnvironmentObject var model: AppModel

    private var issues: [LaunchValidator.Issue] { model.launchIssues }

    var body: some View {
        if !issues.isEmpty {
            Section {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.severity == .blocking
                              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.flag)
                                .font(.system(size: 11, design: .monospaced))
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(model.blockingIssues.isEmpty
                     ? "Warnings" : "Cannot launch — \(model.blockingIssues.count) blocking")
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

// MARK: - Documented recipes
//
// The docs' recipes, offered as starting points. Each is derived from intent
// rather than stored as a flag list, so picking one and then changing the
// context keeps the rest of the configuration coherent.

private struct RecipeSection: View {
    @EnvironmentObject var model: AppModel

    private var grouped: [(group: String, recipes: [DocumentedIntent])] {
        var out: [(String, [DocumentedIntent])] = []
        for recipe in DocumentedRecipes.all {
            if let index = out.firstIndex(where: { $0.0 == recipe.group }) {
                out[index].1.append(recipe)
            } else {
                out.append((recipe.group, [recipe]))
            }
        }
        return out.map { (group: $0.0, recipes: $0.1) }
    }

    var body: some View {
        Section("Documented recipes") {
            HStack {
                Menu {
                    ForEach(grouped, id: \.group) { entry in
                        Section(entry.group) {
                            ForEach(entry.recipes) { recipe in
                                Button(recipe.name) { model.applyRecipe(recipe) }
                            }
                        }
                    }
                } label: {
                    Label("Start from a documented recipe", systemImage: "list.bullet.rectangle.portrait")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            Text("Each recipe is the docs' recommendation for a specific Mac. Picking one fills in the chooser above, so you can then adjust the context or posture and everything else follows.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
