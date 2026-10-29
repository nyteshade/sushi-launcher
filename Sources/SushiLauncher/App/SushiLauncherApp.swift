import AppKit
import SwiftUI

// MARK: - App entry

@main
struct SushiLauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // Single-instance Window, NOT WindowGroup: closing a WindowGroup
        // destroys its NSWindow, and with zero windows there is no SwiftUI
        // surface left to resurrect it (the "can't reopen from the menu bar"
        // bug). A Window scene survives closure hidden, and both
        // StatusItemController and the openMainWindow notification can
        // bring it back.
        Window("Sushi Launcher", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            AppCommands(model: model)
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
        }

        Window("Models", id: "models") {
            ModelsView(catalog: model.catalog)
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 440)
        }
        .defaultPosition(.center)

        // Menu bar item: hand-rolled NSStatusItem (StatusItemController).
        // MenuBarExtra is deliberately NOT used: it renders labels as alpha
        // templates (opaque artwork vanishes) and its isInserted plumbing
        // was a suspect in the launch-time scene-list recursion.

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

// MARK: - App delegate
//
// Optional menu-bar-life: when the last real window closes and the
// preference is on, the app flips to .accessory — the Dock icon goes away
// but sushi keeps serving and the MenuBarExtra item is the way back.

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIcon.installIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        MainActor.assumeIsolated {
            let controller = StatusItemController()
            controller.install()
            statusController = controller
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.setActivationPolicy(.regular)
            sender.unhide(nil)
            let window = LauncherAppDelegate.mainWindow(includeHidden: true)
                ?? LauncherAppDelegate.firstAppWindow()
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // Defer briefly so SwiftUI's window bookkeeping settles first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard AppModel.shared.settings.hideDockWhenNoWindows else { return }
            if LauncherAppDelegate.firstAppWindow() == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// The first visible titled window (real app windows only — panels,
    /// popover helpers and menu-bar windows are skipped).
    static func firstAppWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && window.contentView != nil
        }
    }

    /// The main window even when hidden — SwiftUI's single-instance `Window`
    /// scene keeps the NSWindow alive after the user closes it.
    static func mainWindow(includeHidden: Bool) -> NSWindow? {
        NSApp.windows.first { window in
            window.styleMask.contains(.titled)
                && !(window is NSPanel)
                && window.contentView != nil
                && window.title.hasPrefix("Sushi Launcher")
                && (includeHidden || window.isVisible)
        }
    }
}

// MARK: - Icon strategy
//
// macOS 26+ gets the PRE-RENDERED SQUIRCLE artwork (sushi-launcher-squircle.png,
// already on its rounded plate). Older systems keep the bundle icon
// (AppIcon.icns, built from the plate-free 832 artwork) so the window server
// applies its own rounding. The swap is runtime so one bundle serves both.

enum AppIcon {
    static func installIfNeeded() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else { return }
        guard let url = Bundle.main.url(forResource: "sushi-launcher-squircle", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}

// MARK: - About panel

struct AboutMenuItem: View {
    var body: some View {
        Button("About Sushi Launcher") {
            NSApp.activate(ignoringOtherApps: true)
            let credits = NSAttributedString(
                string: "A native macOS front end for the sushi serving engine.\n\n"
                    + "Launch presets, every serve flag, live stdout/stderr.\n\n"
                    + "sushi © beamivalice — github.com/beamivalice/sushi",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "Sushi Launcher",
                .credits: credits,
            ])
        }
    }
}

// MARK: - Shared time formatter

enum LogTime {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
