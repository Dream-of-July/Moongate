import AppKit
import Combine
import Foundation
import Sparkle
#if canImport(MoongateCore)
import MoongateCore
#endif

/// macOS 更新服务：交给 Sparkle 处理 appcast、下载、EdDSA 校验、替换与重启。
@MainActor
final class UpdateService: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
             options: [.initial, .new]
        ) { [weak self] updater, change in
            let value = change.newValue ?? updater.canCheckForUpdates
            Task { @MainActor in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// 当前 App 版本（来自 Info.plist）。
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var releasesPageURL: URL {
        URL(string: "https://github.com/Dream-of-July/moongate/releases")!
    }

    /// Sparkle 后台检查由 Info.plist 的自动检查配置驱动；silent 调用保持兼容，不额外干预调度。
    func check(silent: Bool = false) {
        guard !silent else { return }
        checkForUpdates()
    }

    func checkForUpdates() {
        state = .idle
        updaterController.checkForUpdates(nil)
    }

    func cancel() {
        state = .idle
    }

    func blockInstallDueToOpenTasks(count: Int) {
        state = .failed(t(L.Update.openTasksBeforeInstall, count))
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releasesPageURL)
    }

    private func t(_ key: String, _ args: CVarArg...) -> String {
        let language = (AppLanguage(rawValue: AppSettings.load().appLanguage) ?? .auto).resolved()
        return LocalizedStrings.format(key, language: language, args)
    }
}
