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

    /// 当前 App 版本（来自 Info.plist）。
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var releasesPageURL: URL { checker.releasesPageURL }

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
            state = .failed("更新包地址不可信，已阻止。请到 GitHub 手动下载。")
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
            throw MoongateError.downloadFailed("下载更新包失败。")
        }
        try? FileManager.default.removeItem(at: dmgPath)
        try FileManager.default.moveItem(at: tempFile, to: dmgPath)
        await MainActor.run { progress(1) }
        return dmgPath
    }

    // MARK: 安装（挂载 DMG → 校验 → 脱离进程替换自身 → 重启）

    private func install(dmgPath: URL, expectedVersion: SemVer) async throws {
        let appURL = Bundle.main.bundleURL
        // 必须在 /Applications 或可写位置；校验是同一个 App。
        let mountPoint = try await Self.attachDMG(dmgPath)
        defer { Task { await Self.detachDMG(mountPoint) } }

        // 找挂载点里的 .app。
        let mounted = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: mountPoint), includingPropertiesForKeys: nil)) ?? []
        guard let newApp = mounted.first(where: { $0.pathExtension == "app" }) else {
            throw MoongateError.downloadFailed("更新包里没有找到应用程序。")
        }
        // 校验 bundle id 一致，避免替换错对象。
        guard let newPlist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              let newID = newPlist["CFBundleIdentifier"] as? String,
              newID == (Bundle.main.bundleIdentifier ?? "") else {
            throw MoongateError.downloadFailed("更新包与当前应用不匹配，已停止安装。")
        }

        // 写替换脚本：等本进程退出 → 覆盖 → 去隔离 → 重开。
        let script = UpdateChecker.installScript(
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
        // 退出当前 App，脚本会在退出后完成替换并重开。
        NSApp.terminate(nil)
    }

    private static func attachDMG(_ dmg: URL) async throws -> String {
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
            throw MoongateError.downloadFailed("无法挂载更新包。")
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


