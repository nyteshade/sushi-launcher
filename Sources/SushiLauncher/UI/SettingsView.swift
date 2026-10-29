import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    /// Mirrors the App scene's MenuBarExtra(isInserted:) source of truth.
    @AppStorage("menuBarVisible") private var menuBarInserted = true

    var body: some View {
        Form {
            Section("sushi binary") {
                HStack {
                    TextField("", text: $model.settings.sushiPathOverride,
                              prompt: Text("Auto-detect — leave empty unless needed"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseBinary() }
                }
                HStack {
                    if let found = model.resolvedBinary {
                        Label(found.path, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Label("sushi not found", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Version…") { model.checkSushiVersion() }
                }
                .font(.callout)
                Text("Search order: override, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, /usr/bin. Install: brew install beamivalice/tap/sushi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GPU wired limit (\(GPULimit.sysctlKey))") {
                Stepper(value: $model.settings.gpuLimitMB, in: 8_000...250_000, step: 1_000) {
                    Text("\(model.settings.gpuLimitMB) MB")
                        .monospacedDigit()
                }
                Toggle("Raise before every launch (asks for authorization)",
                       isOn: $model.settings.raiseGPUBeforeLaunch)
                HStack {
                    Button("Raise now…") { model.raiseGPULimitNow() }
                    Button("Check current") { model.checkGPULimit() }
                }
                Text("sushi bills big contexts against this limit; it resets at every reboot. 120000 MB ≈ 117 GiB (128 GB Macs).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                Toggle("Watchdog: pass --parent-pid so sushi exits if the launcher quits",
                       isOn: $model.settings.autoParentPid)
            }

            Section("Menu bar") {
                Toggle("Show Sushi Launcher in the menu bar", isOn: $menuBarInserted)
                Toggle("Hide Dock icon when the last window closes", isOn: $model.settings.hideDockWhenNoWindows)
                Text("With the window closed, the menu bar dropdown keeps sushi alive: status, uptime, start/stop and Open Sushi Launcher (⌘0) to restore the window. Quit from the dropdown while it has the Dock icon's job.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Console") {
                Toggle("Show console drawer (⇧⌘L)", isOn: $model.settings.consoleVisible)
                Toggle("Autoscroll", isOn: $model.settings.autoscroll)
                Toggle("Show timestamps", isOn: $model.settings.showTimestamps)
            }

            Section("Config files") {
                HStack {
                    Button("Reset launch config to start-sushi preset") {
                        model.config = Preset.brie128.config
                    }
                    Button("Open config folder") {
                        UIActions.revealPath(Storage.applicationDirectory.path)
                    }
                }
                Text("\(Storage.applicationDirectory.path)/launch-config.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this binary"
        let homeBin = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin")
        let candidates = [URL(fileURLWithPath: "/opt/homebrew/bin"), homeBin,
                          URL(fileURLWithPath: "/usr/local/bin")]
        panel.directoryURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.sushiPathOverride = url.path
        }
    }
}
