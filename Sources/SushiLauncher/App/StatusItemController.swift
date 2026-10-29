import AppKit

extension Notification.Name {
    /// Posted by the status-item "Open Sushi Launcher" action; any live
    /// SwiftUI surface receiving it calls openWindow(id: "main").
    static let openMainWindow = Notification.Name("sushiLauncher.openMainWindow")

    /// Same trick for the Models scene — needed because a `Window` scene
    /// has no NSWindow at all until openWindow(id:) first runs.
    static let openModelsWindow = Notification.Name("sushiLauncher.openModelsWindow")
}

/// Owns the menu bar NSStatusItem. Chosen over SwiftUI MenuBarExtra because
/// (a) MenuBarExtra force-renders its label as an alpha template (opaque
/// artwork = invisible/solid blob) and (b) its isInserted scene plumbing was
/// implicated in the launch-time scene-list recursion.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var visibilityObserver: NSObjectProtocol?
    private var pendingModelsOpen = false
    private static let visibleKey = "menuBarVisible"   // @AppStorage("menuBarVisible")

    private lazy var menu: NSMenu = {
        let m = NSMenu()
        m.delegate = self
        m.autoenablesItems = false
        return m
    }()

    // MARK: lifecycle

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = templateImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Sushi Launcher"
        }
        item.menu = menu
        statusItem = item
        applyVisibility()
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
    }

    private func applyVisibility() {
        let visible = UserDefaults.standard.object(forKey: Self.visibleKey) as? Bool ?? true
        statusItem?.isVisible = visible
    }

    // MARK: image → template glyph
    //
    // Works with black-on-white OR black-on-transparent artwork (and
    // tolerates colored art like the cannon). Pixel coverage is
    //   alpha − mean(premultiplied RGB)
    // on normalized RGBA8: opaque white → 0, opaque black → 1,
    // transparent → 0, dark-on-transparent → its own alpha.

    private func templateImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menu-icon", withExtension: "png"),
              let source = NSImage(contentsOf: url),
              let rep = source.representations.first,
              rep.pixelsWide > 1, rep.pixelsHigh > 1,
              let normalized = Self.rgbaBitmap(pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh),
              let out = Self.rgbaBitmap(pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh)
        else { return fallbackIcon() }

        let w = normalized.pixelsWide
        let h = normalized.pixelsHigh
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: normalized)
        source.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()

        guard let src = normalized.bitmapData, let dst = out.bitmapData else { return fallbackIcon() }
        let count = w * h
        for i in 0..<count {
            let p = i << 2
            let a = Int(src[p + 3])
            let coverage = a - (Int(src[p]) + Int(src[p + 1]) + Int(src[p + 2])) / 3
            dst[p] = 0
            dst[p + 1] = 0
            dst[p + 2] = 0
            dst[p + 3] = UInt8(max(0, min(255, coverage)))
        }
        guard let cg = out.cgImage else { return fallbackIcon() }
        let height: CGFloat = 18
        let width = height * CGFloat(w) / CGFloat(max(1, h))
        let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        image.isTemplate = true
        return image
    }

    private static func rgbaBitmap(pixelsWide w: Int, pixelsHigh h: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: 4 * w, bitsPerPixel: 32)
    }

    private func fallbackIcon() -> NSImage? {
        NSImage(systemSymbolName: "fish", accessibilityDescription: "Sushi Launcher")
    }

    // MARK: menu construction (rebuilt every time the menu opens)

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.buildMenu(menu)
        }
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = AppModel.shared
        let server = model.server

        var status = server.status.label
        if case .running(let since) = server.status {
            status += " · " + uptimeText(since: since)
            if server.pid > 0 { status += " · pid \(server.pid)" }
        }
        addInfo(menu, status, color: statusNSColor(server.status))
        addInfo(menu, "Model: \((model.config.modelText as NSString).lastPathComponent)", color: .labelColor)
        addInfo(menu, "\(model.serverURL) · \(server.lines.count) log lines", color: .secondaryLabelColor)
        menu.addItem(.separator())

        addAction(menu, "Open Sushi Launcher", #selector(openMainWindow), key: "0", mask: .command)
        menu.addItem(.separator())
        addAction(menu, "Start Server", #selector(startServer), key: "s", mask: .command,
                  enabled: !server.isBusy)
        addAction(menu, "Stop Server", #selector(stopServer), key: ".", mask: .command,
                  enabled: server.isBusy)
        addAction(menu, "Restart Server", #selector(restartServer), key: "r", mask: .command,
                  enabled: server.isBusy)
        menu.addItem(.separator())
        addAction(menu, "Models…", #selector(openModels), key: "m", mask: [.command, .shift])
        addAction(menu, "Settings…", #selector(openSettingsWindow), key: ",", mask: .command)
        addAction(menu, "Copy Command Line", #selector(copyCommandLine), key: "c",
                  mask: [.command, .shift])
        addAction(menu, "Raise GPU Memory Limit…", #selector(raiseGPU), key: "g",
                  mask: [.command, .option])
        menu.addItem(.separator())
        addAction(menu, "Quit Sushi Launcher", #selector(quit), key: "q", mask: .command)
    }

    private func addInfo(_ menu: NSMenu, _ text: String, color: NSColor) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ action: Selector,
                           key: String, mask: NSEvent.ModifierFlags, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func statusNSColor(_ status: ServerController.Status) -> NSColor {
        switch status {
        case .stopped:        return .secondaryLabelColor
        case .starting:       return .systemOrange
        case .running:        return .systemGreen
        case .exited(let c):  return c == 0 ? .secondaryLabelColor : .systemRed
        case .failed:         return .systemRed
        }
    }

    // MARK: actions

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Preferred: the Window scene's hidden-but-alive window instance.
        if let window = LauncherAppDelegate.mainWindow(includeHidden: true) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Otherwise ask any live SwiftUI surface to openWindow(id: "main").
            NotificationCenter.default.post(name: .openMainWindow, object: nil)

            // Last resort (no SwiftUI host alive at all): ask the responder
            // chain; harmless no-op when unhandled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if LauncherAppDelegate.mainWindow(includeHidden: true) == nil {
                    NSApp.sendAction(NSSelectorFromString("newWindowForTab:"), to: nil, from: nil)
                }
            }
        }

        // Chained request from openModels when nothing existed to hear it.
        if pendingModelsOpen {
            pendingModelsOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openModelsWindow, object: nil)
            }
        }
    }

    @objc private func openModels() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Already created (open or hidden): just show it.
        if let window = NSApp.windows.first(where: { $0.title == "Models" && $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Not created yet: a Window scene only springs to life through
        // SwiftUI's openWindow — ask any live host (hidden main window
        // included) to run it.
        NotificationCenter.default.post(name: .openModelsWindow, object: nil)

        // Nothing was alive to hear it (accessory mode, no windows shown
        // this run): raise main first, then retry once its host exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard NSApp.windows.first(where: { $0.title == "Models" && $0.contentView != nil }) == nil,
                  LauncherAppDelegate.firstAppWindow() == nil else { return }
            self.pendingModelsOpen = true
            self.openMainWindow()
        }
    }

    @objc private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // showSettingsWindow:/showPreferencesWindow: are private SwiftUI
        // app-delegate actions — not in headers, hence NSSelectorFromString.
        if !NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil) {
            NSApp.sendAction(NSSelectorFromString("showPreferencesWindow:"), to: nil, from: nil)
        }
    }

    @objc private func startServer() { AppModel.shared.start() }
    @objc private func stopServer() { AppModel.shared.stop() }
    @objc private func restartServer() { AppModel.shared.restart() }
    @objc private func copyCommandLine() { AppModel.shared.copyCommandLine() }
    @objc private func raiseGPU() { AppModel.shared.raiseGPULimitNow() }
    @objc private func quit() { NSApp.terminate(nil) }
}
