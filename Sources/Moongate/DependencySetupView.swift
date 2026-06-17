import AppKit
import SwiftUI
#if canImport(MoongateCore)
import MoongateCore
#endif

enum DependencyInstallFailure: Equatable {
    case brewLaunchFailed(String)
    case installCompletedButMissing
    case installIncomplete(Int32)
    case uninstallIncomplete(Int32)
}

/// 依赖组件安装：体检 → `brew install` 缺失项（流式日志）→ 完成后回到业务流程。
/// Homebrew 不存在时不静默装（curl|bash 不可接受），引导用户去 brew.sh。
@MainActor
final class DependencyInstaller: ObservableObject {
    // 初值为空：依赖体检会 spawn ffmpeg 子进程并 waitUntilExit（重入 runloop），
    // 绝不能在 @StateObject 初始化（SwiftUI 视图更新事务）里同步跑——会触发
    // AttributeGraph 重入崩溃。体检改为 refresh() 异步在后台线程执行。
    @Published var components: [DependencySetup.Component] = []
    @Published var hasChecked = false
    @Published var isRunning = false
    @Published var log = ""
    @Published var error: DependencyInstallFailure?
    /// 正在被 brew 安装/卸载的公式名集合：UI 据此让对应组件行显示旋转 loading。
    @Published var inFlightFormulas: Set<String> = []

    private var process: Process?
    /// 体检代际：每次 refresh 自增，只接受最新一次的结果，避免「卸载的慢刷新」覆盖「安装的新结果」。
    private var refreshGeneration = 0

    var brewAvailable: Bool { DependencySetup.brewPath() != nil }
    var missing: [DependencySetup.Component] { DependencySetup.missing(from: components) }
    var installed: [DependencySetup.Component] { components.filter(\.isInstalled) }
    var allInstalled: Bool { missing.isEmpty }
    var hasInstalled: Bool { !installed.isEmpty }
    var missingFormulaList: String { missing.map(\.formula).joined(separator: ", ") }
    var installedFormulaList: String { installed.map(\.formula).joined(separator: ", ") }

    /// 异步体检：阻塞的子进程探测放到后台线程，结果回主线程发布。
    /// 用代际守卫，丢弃过期结果（卸载后立刻重装时，旧的慢刷新不能覆盖新状态）。
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let checked = await Task.detached(priority: .userInitiated) {
            DependencySetup.check()
        }.value
        guard generation == refreshGeneration else { return }
        components = checked
        hasChecked = true
    }

    func install() {
        let formulas = missing.map(\.formula)
        runBrew(subcommand: "install", formulas: formulas)
    }

    /// 卸载已安装的依赖组件（brew uninstall）。删除操作，UI 侧必须先确认。
    func uninstall() {
        let formulas = installed.map(\.formula)
        runBrew(subcommand: "uninstall", formulas: formulas)
    }

    private func runBrew(subcommand: String, formulas: [String]) {
        guard !isRunning, let brew = DependencySetup.brewPath() else { return }
        guard !formulas.isEmpty else { return }
        isRunning = true
        error = nil
        // 安装时点亮缺失组件行的 loading；卸载时点亮已装组件行。
        inFlightFormulas = Set(formulas)
        log = "$ brew " + subcommand + " " + formulas.joined(separator: " ") + "\n"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: brew)
        task.arguments = [subcommand] + formulas
        // GUI App 的 PATH 只有系统目录，brew 自身与其子工具都需要 Homebrew 路径
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text) }
        }
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.finish(subcommand: subcommand, status: status) }
        }
        do {
            try task.run()
            process = task
        } catch {
            isRunning = false
            self.error = .brewLaunchFailed(error.localizedDescription)
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func append(_ text: String) {
        log += text
        // 防长日志膨胀：只留尾部
        if log.count > 20_000 { log = String(log.suffix(20_000)) }
    }

    private func finish(subcommand: String, status: Int32) {
        isRunning = false
        process = nil
        Task { await refreshAfterBrew(subcommand: subcommand, status: status) }
    }

    private func refreshAfterBrew(subcommand: String, status: Int32) async {
        await refresh()
        inFlightFormulas = []
        if subcommand == "install" {
            if !allInstalled {
                error = status == 0 ? .installCompletedButMissing : .installIncomplete(status)
            }
        } else {
            if status != 0 {
                error = .uninstallIncomplete(status)
            }
        }
    }
}

struct DependencySetupSheet: View {
    @ObservedObject var model: ViewModel
    @StateObject private var installer = DependencyInstaller()
    @State private var showUninstallConfirm = false
    @EnvironmentObject private var localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localizer.t(L.Dependency.title))
                .font(.title3.weight(.semibold))
            Text(localizer.t(L.Dependency.description))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                if !installer.hasChecked {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(localizer.t(L.Dependency.checkingAccessibility))
                        Text(localizer.t(L.Dependency.checking))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                } else {
                    ForEach(installer.components) { component in
                        HStack(spacing: 10) {
                            componentStatusIcon(component)
                                .frame(width: 18, height: 18)
                            Text(component.id)
                                .font(.body.monospaced())
                            Text(componentPurposeText(component))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(componentStatusText(component))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(componentAccessibilityLabel(component))
                        .accessibilityValue(componentStatusText(component))
                        if component.id != installer.components.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .animation(.smooth(duration: 0.35), value: installer.components)
            .animation(.smooth(duration: 0.35), value: installer.inFlightFormulas)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            )

            if installer.brewAvailable {
                if !installer.allInstalled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizer.t(L.Dependency.installNotice))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(installer.missingFormulaList)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary.opacity(0.35))
                    )
                }
                if !installer.log.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(installer.log)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .id("tail")
                        }
                        .frame(height: 140)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.quaternary.opacity(0.35))
                        )
                        .accessibilityLabel(localizer.t(L.Dependency.logAccessibility))
                        .onChange(of: installer.log) {
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localizer.t(L.Dependency.noBrewTitle))
                        .font(.callout)
                    Text(localizer.t(L.Dependency.noBrewDescription))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(localizer.t(L.Dependency.openBrew)) {
                        NSWorkspace.shared.open(URL(string: "https://brew.sh/zh-cn/")!)
                    }
                    .buttonStyle(.bordered)
                    .help(localizer.t(L.Dependency.openBrewHelp))
                    .accessibilityHint(localizer.t(L.Dependency.openBrewHint))
                }
            }

            if let errorText = dependencyErrorText(installer.error) {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(localizer.t(L.Dependency.refresh)) {
                    Task { await installer.refresh() }
                }
                .disabled(installer.isRunning || !installer.hasChecked)
                .help(localizer.t(L.Dependency.refreshHelp))
                .accessibilityHint(localizer.t(L.Dependency.refreshHint))
                if installer.hasChecked && installer.brewAvailable && installer.hasInstalled {
                    Button(localizer.t(L.Dependency.deleteDependencies), role: .destructive) {
                        showUninstallConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .foregroundStyle(.red)
                    .disabled(installer.isRunning)
                    .help(localizer.t(L.Dependency.deleteHelp))
                    .accessibilityHint(localizer.t(L.Dependency.deleteHint))
                }
                Spacer()
                Button {
                    installer.cancel()
                    model.closeDependencySetup()
                } label: {
                    Text(installer.isRunning ? localizer.t(L.Dependency.cancelInstallAndClose) : localizer.t(L.Common.close))
                }
                .help(closeButtonHelpText)
                .accessibilityHint(closeButtonHelpText)
                if installer.hasChecked {
                    if installer.allInstalled {
                        Button(localizer.t(L.Dependency.done)) {
                            model.completeDependencySetup()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if installer.brewAvailable {
                        Button {
                            installer.install()
                        } label: {
                            if installer.isRunning {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel(localizer.t(L.Dependency.installingMissingAccessibility))
                                    Text(localizer.t(L.Dependency.installing))
                                }
                            } else {
                                Text(localizer.t(L.Dependency.installMissing))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installer.isRunning)
                        .help(localizer.t(L.Dependency.installHelp))
                        .accessibilityHint(localizer.t(L.Dependency.installHint))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await installer.refresh() }
        .alert(localizer.t(L.Dependency.uninstallAlertTitle), isPresented: $showUninstallConfirm) {
            Button(localizer.t(L.Common.cancel), role: .cancel) {}
            Button(localizer.t(L.Dependency.delete), role: .destructive) {
                installer.uninstall()
            }
        } message: {
            Text(localizer.t(L.Dependency.uninstallMessage, installer.installedFormulaList))
        }
    }

    private func componentAccessibilityLabel(_ component: DependencySetup.Component) -> String {
        localizer.t(L.Dependency.componentAccessibilityLabel, component.id, componentPurposeText(component))
    }

    private func componentPurposeText(_ component: DependencySetup.Component) -> String {
        switch component.id {
        case "yt-dlp": return localizer.t(L.Dependency.purposeYtDlp)
        case "ffmpeg": return localizer.t(L.Dependency.purposeFfmpeg)
        case "deno": return localizer.t(L.Dependency.purposeDeno)
        default: return component.purpose
        }
    }

    /// 组件行状态图标：进行中=旋转 loading；已装=绿勾；待装=橙色感叹号。
    @ViewBuilder
    private func componentStatusIcon(_ component: DependencySetup.Component) -> some View {
        if installer.inFlightFormulas.contains(component.formula) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(localizer.t(L.Dependency.processingAccessibility))
        } else if component.isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private func componentStatusText(_ component: DependencySetup.Component) -> String {
        if installer.inFlightFormulas.contains(component.formula) {
            return localizer.t(L.Dependency.statusProcessing)
        }
        return component.isInstalled ? localizer.t(L.Dependency.statusInstalled) : localizer.t(L.Dependency.statusMissing)
    }

    private var closeButtonHelpText: String {
        if installer.isRunning {
            return localizer.t(L.Dependency.closeRunningHelp)
        }
        return localizer.t(L.Dependency.closeIdleHelp)
    }

    private func dependencyErrorText(_ failure: DependencyInstallFailure?) -> String? {
        switch failure {
        case .none:
            return nil
        case .brewLaunchFailed(let reason):
            return localizer.t(L.Dependency.brewLaunchFailed, reason)
        case .installCompletedButMissing:
            return localizer.t(L.Dependency.installCompletedButMissing)
        case .installIncomplete(let status):
            return localizer.t(L.Dependency.installIncomplete, Int(status))
        case .uninstallIncomplete(let status):
            return localizer.t(L.Dependency.uninstallIncomplete, Int(status))
        }
    }
}
