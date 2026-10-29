import AppKit
import SwiftUI

// MARK: - Menu bar
//
// Standard macOS scaffolding stays (Services, Hide, Quit, Edit, Window);
// this adds the app-specific Server menu, About, log commands and Help.
// Menu content lives in Views observing the controllers, so items
// enable/disable themselves live.

struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            ModelsMenuItem()
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Log…") { model.saveLog() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Server") {
            ServerMenuContent(model: model, server: model.server)
        }
        CommandGroup(after: .toolbar) {
            LogMenuContent(model: model)
        }
        CommandGroup(replacing: .help) {
            Button("sushi on GitHub") { UIActions.openWeb("https://github.com/beamivalice/sushi") }
            Button("sushi Docs — Launch Flags") { UIActions.openWeb("https://github.com/beamivalice/sushi/blob/main/docs/flags.md") }
            Button("sushi Docs — Usage & Recipes") { UIActions.openWeb("https://github.com/beamivalice/sushi/blob/main/docs/usage.md") }
        }
    }
}

private struct ModelsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Models…") { openWindow(id: "models") }
            .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}

private struct ServerMenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var server: ServerController

    var body: some View {
        Button("Start Server") { model.start() }
            .keyboardShortcut("s")
            .disabled(server.isBusy)
        Button("Stop Server") { model.stop() }
            .keyboardShortcut(".")
            .disabled(!server.isBusy)
        Button("Restart Server") { model.restart() }
            .keyboardShortcut("r")
            .disabled(!server.isBusy)
        Divider()
        Button("Copy Command Line") { model.copyCommandLine() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        Button("Open Server URL") { model.openServerURL() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Divider()
        Button("Raise GPU Memory Limit…") { model.raiseGPULimitNow() }
            .keyboardShortcut("g", modifiers: [.command, .option])
        Button("Check GPU Limit") { model.checkGPULimit() }
        Button("Reveal sushi Log Folder") { model.revealSushiLogs() }
        Divider()
        Button("Show sushi Version") { model.checkSushiVersion() }
    }
}

private struct LogMenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Divider()
        Toggle("Show Console", isOn: $model.settings.consoleVisible)
            .keyboardShortcut("l", modifiers: [.command, .shift])
        Divider()
        Toggle("Advanced Flag Editor", isOn: $model.settings.advancedOptions)
            .keyboardShortcut("f", modifiers: [.command, .option])
        Divider()
        Toggle("Autoscroll Log", isOn: $model.settings.autoscroll)
            .keyboardShortcut("a", modifiers: [.command, .option])
        Toggle("Show Timestamps", isOn: $model.settings.showTimestamps)
        Button("Clear Log") { model.server.clearLog() }
            .keyboardShortcut("k")
    }
}
