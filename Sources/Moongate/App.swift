import AppKit
import MoongateCore
import SwiftUI

@main
struct MoongateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewModel()
    // 0.7 i18n：运行时界面语言切换器。持久化权威是 AppSettings.appLanguage，运行时权威是 localizer。
    @StateObject private var localizer = Localizer(language: AppLanguage(rawValue: ViewModel.persistedAppLanguage) ?? .auto)

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let localizer, let message = abortConfirmationMessage(for: model, localizer: localizer) else {
            return .terminateNow
        }
        guard confirmAbortDownload(message: message, localizer: localizer) else { return .terminateCancel }
        abortAllTasks(model)
        return .terminateNow
    }
}
