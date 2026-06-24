import AppKit
import MoongateCore
import SwiftUI
import UserNotifications

@main
struct MoongateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: ViewModel
    // 0.7 i18n：运行时界面语言切换器。持久化权威是 AppSettings.appLanguage，运行时权威是 localizer。
    @StateObject private var localizer: Localizer

    init() {
        // SEC-CRED-001：在任何 AppSettings.load()（ViewModel/Localizer 初始化即会触发）之前注入
        // Keychain 凭证存储，旧版 settings.json 里的明文 Token 会在首次加载时迁移进 Keychain 并从磁盘抹除。
        AppSettings.credentialStore = KeychainCredentialStore()
        _model = StateObject(wrappedValue: ViewModel())
        _localizer = StateObject(wrappedValue: Localizer(
            language: AppLanguage(rawValue: ViewModel.persistedAppLanguage) ?? .auto))
    }

    var body: some Scene {
        // Window（非 WindowGroup）：单窗口，天然禁掉 Cmd+N 多窗。
        Window(localizer.t(L.App.title), id: "main") {
            ContentView(model: model)
                .environmentObject(localizer)
                .background(WindowAccessor(model: model, localizer: localizer))
                .onAppear {
                    appDelegate.model = model
                    appDelegate.localizer = localizer
                }
        }
        .defaultSize(width: 560, height: 780)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(localizer.t(L.App.settingsMenu)) {
                    model.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // 独立设置窗口：只保留红灯关闭；设置项实时同步，无需「完成」按钮。
        Window(localizer.t(L.App.settingsWindowTitle), id: "settings") {
            SettingsView(model: model)
                .environmentObject(localizer)
                .background(SettingsWindowAccessor())
                .onDisappear {
                    // 关闭设置窗口：复位 showSettings 并消费挂起动作（登录 / 依赖配置）。
                    model.showSettings = false
                    model.consumePendingSettingsActions()
                }
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentSize)
    }
}

/// 设置窗口不是文档窗口：只允许红灯关闭，隐藏黄灯/绿灯。
struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.configure(window: nsView.window)
        }
    }

    private static func configure(window: NSWindow?) {
        guard let window else { return }
        window.styleMask.remove([.miniaturizable, .resizable])
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
    }
}

/// 关窗 / 退出确认文案：队列里有未到终态（含已暂停）的任务时给出提示，否则返回 nil。
@MainActor
private func abortConfirmationMessage(for model: ViewModel, localizer: Localizer) -> String? {
    let count = model.queue.openTaskCount
    guard count > 0 else { return nil }
    let paused = model.queue.pausedOpenTaskCount
    if paused > 0 {
        return localizer.t(L.App.abortPausedTasks, count, paused)
    }
    return localizer.t(L.App.abortRunningTasks, count)
}

/// 关窗 / 退出前的确认弹窗。返回 true 表示用户选择中止。
@MainActor
private func confirmAbortDownload(message: String, localizer: Localizer) -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = localizer.t(L.App.abortInformativeText)
    alert.alertStyle = .warning
    alert.addButton(withTitle: localizer.t(L.App.keepTasks))
    alert.addButton(withTitle: localizer.t(L.App.abortTasks))
    return alert.runModal() == .alertSecondButtonReturn
}

/// 中止队列所有进行中的任务。
@MainActor
private func abortAllTasks(_ model: ViewModel) {
    for item in model.queue.items {
        model.queue.cancel(item.id)
    }
}

/// 把 window.delegate 接到 Coordinator，下载中点关闭按钮时先确认。
struct WindowAccessor: NSViewRepresentable {
    let model: ViewModel
    let localizer: Localizer

    func makeCoordinator() -> Coordinator { Coordinator(model: model, localizer: localizer) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window, window.delegate !== context.coordinator {
                window.delegate = context.coordinator
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let model: ViewModel
        private let localizer: Localizer

        init(model: ViewModel, localizer: Localizer) {
            self.model = model
            self.localizer = localizer
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let message = abortConfirmationMessage(for: model, localizer: localizer) else { return true }
            guard confirmAbortDownload(message: message, localizer: localizer) else { return false }
            abortAllTasks(model)
            return true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ViewModel?
    weak var localizer: Localizer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 凭证/登录隔离的启动维护：把旧的全局 cookies.txt 拆分到按站点隔离的 jar，然后删除旧文件。
        // 尽力而为，失败不阻塞启动（旧文件仍在，下次再试）。
        CookieMigration.migrateGlobalToPerSite(
            legacyGlobal: AppSettings.cookieFileURL,
            cookieDirectory: AppSettings.cookieDirectory
        )

        // 队列完成通知必须先取得用户授权，否则 UNUserNotificationCenter.add(_:) 会被系统静默丢弃，
        // 下载完成既无横幅也无提示音——这是 0.8 上线前实测到「完全没有系统通知」的根因。
        Self.requestCompletionNotificationAuthorization()
    }

    /// 请求「下载完成」通知 + 提示音所需的系统授权。首次启动弹一次系统对话框，之后静默复用结果。
    /// 仅在打包为 .app（有 bundle id）时请求，避免 `swift run` / 单元测试等无 main bundle 的环境下
    /// `UNUserNotificationCenter.current()` 触发 NSInternalInconsistencyException 崩溃。
    static func requestCompletionNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Moongate: 通知授权请求失败：\(error.localizedDescription)")
            } else if !granted {
                NSLog("Moongate: 用户未授权完成通知；下载完成时仅在 App 前台播放提示音。")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let localizer, let message = abortConfirmationMessage(for: model, localizer: localizer) else {
            return .terminateNow
        }
        guard confirmAbortDownload(message: message, localizer: localizer) else { return .terminateCancel }
        abortAllTasks(model)
        return .terminateNow
    }
}
