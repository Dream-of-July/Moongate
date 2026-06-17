import Foundation
import AppKit
#if canImport(MoongateCore)
import MoongateCore
#endif

/// 远程更新服务（仅 macOS）：检查 → 下载 DMG → 挂载 → 替换自身 → 重启。
/// App 为 ad-hoc 签名，自下载的 DMG 不带 quarantine，可直接替换 /Applications 中的自身。
@MainActor
final class UpdateService: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let checker = UpdateChecker()
    private var downloadTask: Task<Void, Never>?

    var hasAvailableUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    /// 当前 App 版本（来自 Info.plist）。
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var releasesPageURL: URL { checker.releasesPageURL }

    private func t(_ key: String, _ args: CVarArg...) -> String {
        let language = (AppLanguage(rawValue: AppSettings.load().appLanguage) ?? .auto).resolved()
        return LocalizedStrings.format(key, language: language, args)
    }

    /// 检查更新。silent=true 时失败不改状态（启动静默检查用）。
    func check(silent: Bool = false) {
        if case .downloading = state { return }
        if case .installing = state { return }
        downloadTask?.cancel()
        if !silent { state = .checking }
        let version = currentVersion
        downloadTask = Task { [checker] in
            do {
                let info = try await checker.checkForUpdate(currentVersion: version)
                if Task.isCancelled { return }
                if let info {
                    self.state = .available(info)
                } else if !silent {
                    self.state = .upToDate
                }
            } catch {
                if Task.isCancelled { return }
                if !silent {
                    let reason = (error as? MoongateError)?.errorDescription ?? error.localizedDescription
                    self.state = .failed(reason)
                }
            }
        }
    }

    /// 下载并安装给定更新。
    func downloadAndInstall(_ info: UpdateInfo) {
        guard UpdateChecker.isTrustedDMGURL(info.dmgURL, owner: checker.owner, repo: checker.repo) else {
            state = .failed(t(L.Update.untrustedPackageURL))
            return
        }
        downloadTask?.cancel()
        state = .downloading(0)
        downloadTask = Task {
            do {
                let dmg = try await self.download(info.dmgURL) { fraction in
                    self.state = .downloading(fraction)
                }
                if Task.isCancelled { return }
                self.state = .installing
                try await self.install(dmgPath: dmg, expectedVersion: info.version)
                // install 成功会重启 App，不会走到这里。
            } catch {
                if Task.isCancelled { return }
                let reason = (error as? MoongateError)?.errorDescription ?? error.localizedDescription
                self.state = .failed(reason)
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    // MARK: 下载

    private func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dmgPath = tempDir.appendingPathComponent("update.dmg")

        let delegate = DownloadProgressDelegate { fraction in
            Task { @MainActor in progress(fraction) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempFile, response) = try await session.download(from: url)
        if Task.isCancelled { throw MoongateError.cancelled }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MoongateError.downloadFailed(t(L.Update.downloadPackageFailed))
        }
        try? FileManager.default.removeItem(at: dmgPath)
        try FileManager.default.moveItem(at: tempFile, to: dmgPath)
        await MainActor.run { progress(1) }
        return dmgPath
    }

    // MARK: 安装（挂载 DMG → 校验 → 脱离进程替换自身 → 重启）

    private func install(dmgPath: URL, expectedVersion: SemVer) async throws {
        let appURL = Bundle.main.bundleURL
        // 安装目录必须可写：替换脚本在本进程退出后才运行，那时失败无法回传 UI，
        // 只会表现成「下载完却没更新」。在退出前就拦住不可写场景（如非管理员的 /Applications），
        // 给出明确指引，而不是静默失败。
        let installParent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installParent.path) else {
            throw MoongateError.updateFailed(t(L.Update.installDirectoryNotWritable, installParent.path))
        }
        // 必须在 /Applications 或可写位置；校验是同一个 App。
        let mountPoint = try await Self.attachDMG(dmgPath, mountFailedMessage: t(L.Update.mountFailed))
        // 默认任何提前返回/抛错都由本进程卸载 DMG；一旦把卸载职责交给替换脚本（成功路径），置 false。
        // 关键：成功路径绝不能由本进程卸载——脚本是先等本进程退出再从挂载点 ditto，
        // 若 NSApp.terminate 期间触发卸载会让源消失，ditto 失败、静默装不上。
        var ownsMount = true
        defer { if ownsMount { Task { await Self.detachDMG(mountPoint) } } }

        // 找挂载点里的 .app。
        let mounted = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: mountPoint), includingPropertiesForKeys: nil)) ?? []
        guard let newApp = mounted.first(where: { $0.pathExtension == "app" }) else {
            throw MoongateError.downloadFailed(t(L.Update.packageMissingApp))
        }
        // 校验 bundle id 一致，避免替换错对象。
        guard let newPlist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              let newID = newPlist["CFBundleIdentifier"] as? String,
              newID == (Bundle.main.bundleIdentifier ?? "") else {
            throw MoongateError.downloadFailed(t(L.Update.packageMismatch))
        }
        guard let newVersionRaw = newPlist["CFBundleShortVersionString"] as? String,
              SemVer(newVersionRaw) == expectedVersion else {
            throw MoongateError.downloadFailed(t(L.Update.versionMismatch))
        }

        // 写替换脚本：等本进程退出 → 从挂载点复制新 App → 卸载 DMG → 备份交换 → 去隔离 → 重开。
        let script = UpdateChecker.installScript(
            mountPoint: mountPoint,
            mountedAppPath: newApp.path,
            targetAppPath: appURL.path,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moongate-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
        // 卸载职责移交脚本：它会等本进程退出后从挂载点复制，复制完再自行卸载，避免竞态。
        ownsMount = false
        // 退出当前 App，脚本会在退出后完成替换并重开。
        NSApp.terminate(nil)
    }

    private static func attachDMG(_ dmg: URL, mountFailedMessage: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", "-plist", dmg.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw MoongateError.downloadFailed(mountFailedMessage)
        }
        return mount
    }

    private static func detachDMG(_ mountPoint: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-force"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

/// URLSession 下载进度代理：把 totalBytesWritten/expected 换算成 0...1。
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        onProgress(frac)
    }

    // 必须实现（async download(from:) 不用它落地文件，留空即可）。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
