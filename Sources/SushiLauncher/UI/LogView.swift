import SwiftUI

// MARK: - Live console for the serve process (stdout / stderr / app notes)

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var server: ServerController

    @State private var query = ""
    @State private var issuesOnly = false

    init(server: ServerController) {
        self.server = server
    }

    private var visible: [ServerController.Line] {
        var lines = server.lines
        if issuesOnly { lines = lines.filter { $0.level == .error || $0.level == .warning } }
        if !query.isEmpty { lines = lines.filter { $0.text.localizedCaseInsensitiveContains(query) } }
        if lines.count > 4000 { lines = Array(lines.suffix(4000)) }
        return lines
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { line in
                            LogLineRow(line: line, showTimestamps: model.settings.showTimestamps)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: server.lines.count) { _, _ in
                    guard model.settings.autoscroll, let last = visible.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.settings.consoleVisible = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Close console (⇧⌘L)")
            Divider().frame(height: 16)
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Toggle("Issues", isOn: $issuesOnly)
                .toggleStyle(.checkbox)
                .help("Show only lines classified as error or warning (content-based, since sushi logs everything to stderr)")
            Toggle("Autoscroll", isOn: $model.settings.autoscroll)
                .toggleStyle(.checkbox)
            Spacer()
            Text("\(visible.count)/\(server.lines.count) lines")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button("Copy") { model.copyLog() }
            Button("Save…") { model.saveLog() }
            Button("Clear") { server.clearLog() }
            Button {
                model.revealSushiLogs()
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal ~/.sushi/logs — sushi's own persistent log files")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct LogLineRow: View {
    let line: ServerController.Line
    let showTimestamps: Bool

    /// Level decides the color; the launcher's own narration keeps the
    /// accent tint unless it reports a failure.
    private var rowColor: Color {
        if line.stream == .system && line.level != .error { return .accentColor }
        return line.level.color
    }

    private var badgeColor: Color {
        line.stream == .system ? .accentColor : line.level.color
    }

    private var badgeText: String { line.label }

    /// "[subsystem]" prefix rendered as its own chip.
    private var bracketPrefix: String? {
        let text = line.text
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let idx = text.distance(from: text.startIndex, to: close)
        guard idx > 1, idx < 24 else { return nil }
        return String(text[text.startIndex...close])
    }

    private var displayText: String {
        guard let prefix = bracketPrefix,
              let space = line.text.firstIndex(of: "]") else { return line.text }
        return String(line.text[line.text.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if showTimestamps {
                Text(LogTime.short.string(from: line.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(badgeText)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(badgeColor)
                .frame(width: 26, alignment: .leading)
                .help(line.stream == .stdout ? "stdout" :
                      (line.stream == .stderr ? "stderr" : "Sushi Launcher"))
            if let prefix = bracketPrefix {
                Text(prefix)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SubsystemPalette.color(for: prefix))
                    .textSelection(.enabled)
            }
            Text(displayText.isEmpty ? " " : displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(rowColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
