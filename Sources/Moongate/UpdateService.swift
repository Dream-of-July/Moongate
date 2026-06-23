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
    /// Sparkle 已发现可用更新时为 true；用于驱动设置按钮红点。
    @Published private(set) var updateAvailable = false
    var prepareForUpdateUI: (@MainActor () -> Void)?

    private var updaterController: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
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

    var repoURL: URL {
        URL(string: "https://github.com/Dream-of-July/moongate")!
    }

    /// 后台更新检查由 Sparkle 的调度驱动（Info.plist: SUEnableAutomaticChecks +
    /// SUScheduledCheckInterval）。此处只暴露用户主动触发的显式检查；不再保留之前那个
    /// silent=true 直接 return 的 no-op（它从不真正检查，注释却声称会，属误导）。
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

    func openRepoPage() {
        NSWorkspace.shared.open(repoURL)
    }

    private func t(_ key: String, _ args: CVarArg...) -> String {
        let language = (AppLanguage(rawValue: AppSettings.load().appLanguage) ?? .auto).resolved()
        return LocalizedStrings.format(key, language: language, args)
    }
}

extension UpdateService: SPUStandardUserDriverDelegate {
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor [weak self] in
            self?.updateAvailable = true
            self?.prepareForUpdateUI?()
        }
    }
}
