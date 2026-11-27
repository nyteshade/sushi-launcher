import SwiftUI

/// Root observable: owns the launch config, app settings, the server
/// controller and the model catalog; hands out typed bindings to the form.
@MainActor
final class AppModel: ObservableObject {
    /// Shared so the AppKit-side window observer can read settings without
    /// a SwiftUI environment (the App scene uses this same instance).
    static let shared = AppModel()

    enum NoticeKind { case info, success, warning, error }

    struct Notice: Identifiable {
        let id = UUID()
        var kind: NoticeKind = .info
        var title: String
        var message: String
    }

    @Published var config: LaunchConfig {
        didSet { scheduleSaveConfig() }
    }
    @Published var settings: AppSettings {
        didSet { scheduleSaveSettings() }
    }
    @Published var notice: Notice?

    /// What the installed CLI actually accepts, diffed against the registry.
    /// nil until the first check completes.
    @Published private(set) var conformance: CLIConformance.Report?
    @Published private(set) var conformanceChecking = false

    let server = ServerController()
    let catalog = ModelCatalog()
    let enricher = PackEnricher()

    private var saveConfigTask: Task<Void, Never>?
    private var saveSettingsTask: Task<Void, Never>?

    init() {
        config = Storage.loadConfig() ?? LaunchConfig(assignments: Preset.thisMachine.assignments)
        settings = Storage.loadSettings() ?? AppSettings()
        // NOTE: no catalog refresh here — mutating published state during
        // AppModel.init runs while SwiftUI builds scenes and can re-enter
        // the app graph (launch crash). Views call refreshCatalog() from
        // their lifetime handlers instead.
    }

    /// Bring the loaded config up to the current schema and reconcile it
    /// against the installed CLI. Called once the conformance report exists,
    /// because the drop pass needs to know what the binary rejects.
    private func migrateConfigIfNeeded() {
        let outcome = ConfigMigration.migrate(config, conformance: conformance)
        if outcome.didChange {
            config = outcome.config
            notice = Notice(kind: .info, title: "Launch config updated",
                            message: outcome.changes.joined(separator: "\n"))
        }
        if !outcome.warnings.isEmpty {
            notice = Notice(kind: .warning, title: "Launch config",
                            message: outcome.warnings.joined(separator: "\n\n"))
        }
    }

    // MARK: Derived

    var resolvedBinary: URL? { SushiBinary.resolve(customPath: settings.sushiPathOverride) }

    var serverURL: String {
        let host = config.hostText == "0.0.0.0" ? "127.0.0.1" : config.hostText
        return "http://\(host):\(config.portInt)"
    }

    var family: ModelFamily { config.family }

    /// Everything wrong with the current configuration, given the installed
    /// CLI and the model family it targets. The single decision point: the
    /// Start button, the command preview and the drift banner all read it.
    var launchIssues: [LaunchValidator.Issue] {
        LaunchValidator.issues(config: config, conformance: conformance)
    }

    var blockingIssues: [LaunchValidator.Issue] {
        LaunchValidator.blocking(launchIssues)
    }

    // MARK: Conformance

    /// Re-read the installed binary's help and diff it against the registry.
    func checkConformance(force: Bool = false) {
        guard !conformanceChecking else { return }
        if !force, conformance != nil { return }
        conformanceChecking = true
        let custom = settings.sushiPathOverride
        Task.detached(priority: .utility) { [weak self] in
            let report = CLIConformance.check(customPath: custom)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.conformanceChecking = false
                self.conformance = report
                // The report is what the migration's drop pass needs, so the
                // config is reconciled the moment it lands.
                self.migrateConfigIfNeeded()
            }
        }
    }

    // MARK: Server actions

    func start() {
        guard !server.isBusy else { return }
        guard resolvedBinary != nil else {
            notice = Notice(kind: .error, title: "sushi not found",
                            message: "Install with `brew install beamivalice/tap/sushi`, or set the binary path in Settings (⌘,).")
            return
        }
        // Refuse a configuration the installed CLI will reject, rather than
        // launching into a failure 30 seconds into a model load.
        let blocking = blockingIssues
        if !blocking.isEmpty {
            notice = Notice(kind: .error, title: "Cannot launch",
                            message: blocking.map { "\($0.flag): \($0.message)" }.joined(separator: "\n\n"))
            return
        }
        if settings.raiseGPUBeforeLaunch {
            let mb = settings.gpuLimitMB
            Task.detached(priority: .userInitiated) { [weak self] in
                let ok = GPULimit.raise(mb: mb)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !ok {
                        self.notice = Notice(kind: .warning, title: "GPU wired limit",
                                             message: "sysctl was not applied (authorization declined or failed) — launching anyway.")
                    }
                    self.server.start(config: self.config, settings: self.settings)
                }
            }
        } else {
            server.start(config: config, settings: settings)
        }
    }

    func stop() { server.stop() }
    func restart() { guard server.isBusy else { return }; startFreshAfterStop() }

    private func startFreshAfterStop() { server.restart() }

    func handleServerStatus(_ status: ServerController.Status) {
        switch status {
        case .exited(let code):
            if code != 0 {
                notice = Notice(kind: .warning, title: "Server exited",
                                message: "sushi exited with status \(code). Check the log — common causes: port already in use, memory preflight refusal, or a missing model path.")
            }
        case .failed(let message):
            notice = Notice(kind: .error, title: "Launch failed", message: message)
        default:
            break
        }
    }

    // MARK: Presets & models

    func applyPreset(_ preset: Preset) {
        config = preset.config
        // A recipe's GPU limit is part of the recipe: the docs pair each one
        // with a specific wired limit, and getting it wrong is a refusal or a
        // panic. Carry it across so the two cannot drift apart.
        if let mb = preset.gpuLimitMB, settings.gpuLimitMB != mb {
            settings.gpuLimitMB = mb
        }
        notice = Notice(title: "Preset applied", message: preset.name)
    }

    var matchedPreset: Preset? {
        Preset.builtIn.first { $0.assignments == config.assignments }
    }

    var matchedPresetName: String {
        matchedPreset?.name ?? "Custom configuration"
    }

    /// Choose a curated pack from `sushi list` as the launch model.
    func selectPack(_ pack: SushiPack) {
        guard let option = SushiOptionRegistry.option("model") else { return }
        let value: String
        switch pack.source {
        case .catalog: value = pack.name                       // short name resolves once pulled
        case .disk:    value = "~/.sushi/models/\(pack.name)"  // folder already on disk
        }
        config.set(option, included: true, value: .string(value))
        if pack.source == .catalog, !pack.downloaded {
            notice = Notice(kind: .info, title: "Not installed yet",
                            message: "“\(pack.name)” is not downloaded. Hit Download in the Model section, or the server will fail to load it.")
        }
    }

    func toggleConsole() {
        settings.consoleVisible.toggle()
    }

    /// Point --model at an arbitrary installed folder (model picker footer).
    func setModelPath(_ path: String) {
        guard let option = SushiOptionRegistry.option("model") else { return }
        config.set(option, included: true, value: .string(path))
    }

    func usePack(_ pack: SushiPack) {
        guard let option = SushiOptionRegistry.option("model") else { return }
        config.set(option, included: true, value: .string(pack.name))
        notice = Notice(title: "Model set",
                        message: "Next launch serves “\(pack.name)”.\nPack short names resolve after `sushi pull`; a downloaded pack always works.")
    }

    // MARK: Utilities

    func copyCommandLine() {
        UIActions.copyToPasteboard(config.commandLinePreview)
        notice = Notice(title: "Command copied", message: config.commandLinePreview)
    }

    func copyLog() {
        let text = server.lines.map { "[\($0.label)] \($0.text)" }.joined(separator: "\n")
        UIActions.copyToPasteboard(text)
        notice = Notice(title: "Log copied", message: "\(server.lines.count) lines are on the pasteboard.")
    }

    func saveLog() {
        let stamp = LogTime.full.string(from: Date())
        let text = server.lines.map { "[\(stamp) \($0.label)] \($0.text)" }.joined(separator: "\n")
        UIActions.savePanel(suggestedName: "sushi-log-\(stamp).txt", content: text)
    }

    func revealSushiLogs() { UIActions.revealPath("~/.sushi/logs") }
    func revealModelsDir() { UIActions.revealPath("~/.sushi/models") }
    func openServerURL() { UIActions.openWeb(serverURL) }

    func refreshCatalog() {
        catalog.refreshIfNeeded(customPath: settings.sushiPathOverride)
    }

    // MARK: GPU wired limit

    func raiseGPULimitNow() {
        let mb = settings.gpuLimitMB
        let bytes = GPULimit.wireBytes(forMB: mb)
        notice = Notice(title: "Raise GPU wired limit",
                        message: "macOS will ask for your password or Touch ID to set \(GPULimit.sysctlKey)=\(mb) and both user-wire limits to \(bytes) bytes.")
        Task.detached(priority: .userInitiated) { [weak self] in
            let ok = GPULimit.raise(mb: mb)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.notice = Notice(kind: ok ? .success : .warning, title: "GPU wired limit",
                                     message: ok
                                        ? "\(GPULimit.sysctlKey)=\(mb) and both user-wire limits are set to \(bytes) bytes. Remember: all three reset at every reboot."
                                        : "Not applied (authorization declined or failed).")
            }
        }
    }

    func checkGPULimit() {
        let target = settings.gpuLimitMB
        Task.detached(priority: .utility) { [weak self] in
            let state = GPULimit.readState()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let gpu = state.gpuMB else {
                    self.notice = Notice(title: "GPU wired limit",
                                         message: "Could not read \(GPULimit.sysctlKey).")
                    return
                }
                if let problem = GPULimit.inconsistencyNote(state) {
                    self.notice = Notice(kind: .warning, title: "GPU wired limit",
                                         message: problem + "\n\nRaise it again to set all three.")
                } else {
                    self.notice = Notice(title: "GPU wired limit",
                                         message: "\(gpu) MB right now, with both user-wire limits matching at \(GPULimit.wireBytes(forMB: gpu)) bytes. This app targets \(target) MB. All three reset at every reboot.")
                }
            }
        }
    }

    // MARK: sushi --version

    func checkSushiVersion() {
        let custom = settings.sushiPathOverride
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SushiRunner.run(args: ["--version"], customPath: custom, timeout: 15)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let text: String
                if let result {
                    text = ([result.stdout.trimmed, result.stderr.trimmed]
                        .filter { !$0.isEmpty })
                        .joined(separator: "\n")
                } else {
                    text = "sushi not found — set its path in Settings."
                }
                self.notice = Notice(title: "sushi --version", message: text.isEmpty ? "(no output)" : text)
            }
        }
        // A version change is exactly when the registry can drift, so the
        // version check re-runs conformance too.
        checkConformance(force: true)
    }

    // MARK: Bindings for the form

    func includedBinding(_ option: SushiOption) -> Binding<Bool> {
        Binding(
            get: { self.config.assignment(for: option).included },
            set: { newValue in self.config.setIncluded(option, newValue) }
        )
    }

    /// presence flags: the toggle both includes the flag and turns it on.
    func presenceBinding(_ option: SushiOption) -> Binding<Bool> {
        Binding(
            get: {
                let a = self.config.assignment(for: option)
                return a.included && (a.value.boolValue ?? false)
            },
            set: { newValue in
                self.config.set(option, included: newValue, value: .bool(newValue))
            }
        )
    }

    /// onOff flags: -1 = server default (not passed), 1 = --flag, 0 = negation.
    func onOffBinding(_ option: SushiOption) -> Binding<Int> {
        Binding(
            get: {
                let a = self.config.assignment(for: option)
                guard a.included else { return -1 }
                return (a.value.boolValue ?? true) ? 1 : 0
            },
            set: { newValue in
                switch newValue {
                case 1:  self.config.set(option, included: true, value: .bool(true))
                case 0:  self.config.set(option, included: true, value: .bool(false))
                default: self.config.set(option, included: false, value: .bool(true))
                }
            }
        )
    }

    func intBinding(_ option: SushiOption) -> Binding<Int> {
        Binding(
            get: { self.config.assignment(for: option).value.intValue ?? 0 },
            set: { newValue in self.config.setValue(option, .int(newValue)) }
        )
    }

    func doubleBinding(_ option: SushiOption) -> Binding<Double> {
        Binding(
            get: { self.config.assignment(for: option).value.doubleValue ?? 0 },
            set: { newValue in self.config.setValue(option, .double(newValue)) }
        )
    }

    func stringBinding(_ option: SushiOption) -> Binding<String> {
        Binding(
            get: { self.config.assignment(for: option).value.stringValue ?? "" },
            set: { newValue in
                var assignment = self.config.assignment(for: option)
                assignment.value = .string(newValue)
                if option.id == "model", newValue.trimmed.nonEmpty != nil {
                    assignment.included = true
                }
                self.config.assignments[option.id] = assignment
            }
        )
    }

    // MARK: Persistence (debounced)

    private func scheduleSaveConfig() {
        saveConfigTask?.cancel()
        saveConfigTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            Storage.saveConfig(self.config)
        }
    }

    private func scheduleSaveSettings() {
        saveSettingsTask?.cancel()
        saveSettingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            Storage.saveSettings(self.settings)
        }
    }
}
