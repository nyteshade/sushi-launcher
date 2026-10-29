import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Working height of the console drawer while the window is open.
    /// (VSplitView drags don't write back here; reopening uses the default.)
    @State private var consoleHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(server: model.server)
            Divider()
            if model.settings.consoleVisible {
                VSplitView {
                    LaunchPane()
                        .frame(minHeight: 280)
                    LogView(server: model.server)
                        .frame(height: consoleHeight)
                        .frame(minHeight: 80)
                }
            } else {
                LaunchPane()
                Divider()
                ConsoleDrawerBar(server: model.server)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title),
                  message: Text(notice.message),
                  dismissButton: .default(Text("OK")))
        }
        .onReceive(model.server.$status) { status in
            model.handleServerStatus(status)
        }
        .onAppear {
            model.refreshCatalog()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            openWindow(id: "main")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelsWindow)) { _ in
            openWindow(id: "models")
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var server: ServerController

    init(server: ServerController) {
        self.server = server
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusChip(status: server.status)

            if case .running(let since) = server.status {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(uptimeText(since: since, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("pid \(server.pid)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button("Open \(model.serverURL)/v1/models") { model.openServerURL() }
                .buttonStyle(.link)
                .font(.callout)

            Spacer()

            Button {
                model.toggleConsole()
            } label: {
                Image(systemName: model.settings.consoleVisible ? "chevron.down" : "chevron.up")
                    .frame(width: 20)
            }
            .help((model.settings.consoleVisible ? "Hide" : "Show") + " console (⇧⌘L)")

            if server.isBusy {
                Button("Restart") { model.restart() }
                Button("Stop", role: .destructive) { model.stop() }
            } else {
                Button("Start Server") { model.start() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Slim bar shown when the console drawer is closed

struct ConsoleDrawerBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var server: ServerController

    init(server: ServerController) {
        self.server = server
    }

    var body: some View {
        Button {
            model.toggleConsole()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up.circle")
                Text("Console")
                    .fontWeight(.medium)
                Text("(\(server.lines.count) lines)")
                    .foregroundStyle(.tertiary)
                if server.isBusy {
                    Circle()
                        .fill(server.status.color)
                        .frame(width: 7, height: 7)
                        .help(server.status.label)
                }
                Spacer()
                Text("click to open")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
