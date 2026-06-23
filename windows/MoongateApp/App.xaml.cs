using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Moongate.Core;

namespace Moongate.App;

/// <summary>应用入口：界面语言装载 + 未捕获异常兜底 + 首次启动依赖引导。</summary>
public partial class App : Application
{
    /// <summary>
    /// App 级共享更新服务（UPDATE-WIN-004）：设置页反复打开时复用状态与静默检查节流，
    /// 避免每个 SettingsWindow 都创建新 updater 并请求 GitHub。
    /// </summary>
    public static UpdateService WindowsUpdater { get; } = new();

    /// <summary>
    /// 正处于「更新退出」流程：UpdateService 启动安装器后置位，主窗口关窗确认据此放行，
    /// 不再用普通的「有未完成任务」确认拦截这次退出。
    /// </summary>
    public static bool IsUpdateShutdown { get; private set; }

    /// <summary>标记进入更新退出流程（由 UpdateService 在启动安装器前调用）。</summary>
    public static void MarkUpdateShutdown() => IsUpdateShutdown = true;

    /// <summary>
    /// 「清除全部登录」时若 WebView2 目录被占用删不掉，会留下待删标记；此时进程已重启、
    /// 目录不再被锁，在这里补删并移除标记。
    /// </summary>
    private static void TryCleanPendingWebView2Delete()
    {
        try
        {
            var marker = SettingsViewModel.WebView2PendingDeleteMarkerPath;
            if (!System.IO.File.Exists(marker)) return;
            var dataFolder = System.IO.Path.Combine(AppSettings.SupportDirectory, "WebView2");
            if (System.IO.Directory.Exists(dataFolder)) System.IO.Directory.Delete(dataFolder, recursive: true);
            if (!System.IO.Directory.Exists(dataFolder)) System.IO.File.Delete(marker);
        }
        catch { /* 仍被占用则下次再清 */ }
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        StartupDiagnostics.Mark("OnStartup begin");

        // 凭证安全存储（SEC-CRED-001）：在任何 AppSettings.Load() 之前注入 DPAPI 实现，
        // 这样旧版 settings.json 里的明文 Token 会在首次加载时迁移进 DPAPI 并从磁盘抹除。
        AppSettings.CredentialStore = new DpapiCredentialStore();

        // 清理上一轮更新遗留的临时安装器目录（成功安装后安装器无法自删所在目录）。
        UpdateService.CleanStaleUpdateDirs();

        // 凭证/登录隔离的启动维护：旧全局 cookies.txt 拆分到按站点 jar；清除登录时删不掉的
        // WebView2 目录在这里补删（标记存在时）。两步都尽力而为，失败不阻塞启动。
        try { CookieMigration.MigrateGlobalToPerSite(AppSettings.CookieFilePath, AppSettings.CookieDirectory); }
        catch { /* 迁移失败不阻塞启动；旧文件仍在，下次再试 */ }
        TryCleanPendingWebView2Delete();

        // 先注册全局异常处理器：任何后续步骤抛错都能落盘 + 提示，而不是变成无窗口僵尸进程。
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            StartupDiagnostics.RecordException("UnobservedTaskException", args.Exception);
            args.SetObserved();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception error)
            {
                StartupDiagnostics.RecordException("AppDomain.UnhandledException", error);
                try
                {
                    MessageBox.Show(
                        Loc.F("L.App.FatalFmt", error.Message),
                        Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
                }
                catch
                {
                    // 崩溃路径上弹窗失败就算了
                }
            }
        };

        // 部分机器（异常显卡驱动 / 远程桌面 / 虚拟机）WPF 硬件渲染初始化失败时只画窗口背景，
        // 表现为白屏。检测到无硬件加速（渲染层级 0）或用户用环境变量强制时，回退软件渲染。
        ApplyRenderModeFallback();
        ThemeManager.ApplySystemTheme();

        try
        {
            // 按设置装载界面语言（含核心库 L10n）。
            LocalizationManager.Apply(AppSettings.Load().AppLanguage);
            StartupDiagnostics.Mark("localization applied");

            var main = new MainWindow();
            MainWindow = main;
            main.Show();
            ThemeManager.ApplyWindowTheme(main);
            StartupDiagnostics.Mark("MainWindow shown");

            // 启动后静默检查更新（6 小时节流），让主窗设置入口的红点能在不打开设置时也亮起。
            // 只读观察：失败不改状态、不打扰用户；下载/安装仍由设置页显式触发。
            try { WindowsUpdater.CheckAutomaticSilent(); }
            catch (Exception updateError) { StartupDiagnostics.RecordException("startup update check", updateError); }
        }
        catch (Exception error)
        {
            // 启动期致命异常：之前会被 DispatcherUnhandledException 吞成「进程活着但没有窗口」。
            // 这里显式落盘 + 提示 + 退出，避免白屏僵尸进程。
            StartupDiagnostics.RecordException("startup", error);
            try
            {
                MessageBox.Show(
                    Loc.F("L.App.FatalFmt", error.Message),
                    Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
            }
            catch
            {
                // 弹窗本身也失败（极端环境），日志已落盘即可。
            }
            Shutdown(1);
            return;
        }
    }

    /// <summary>检测渲染能力并在必要时回退软件渲染，规避部分机器的白屏（硬件渲染初始化失败）。</summary>
    private static void ApplyRenderModeFallback()
    {
        var tier = RenderCapability.Tier >> 16;
        StartupDiagnostics.RecordEnvironment(tier);
        var forced = string.Equals(
            Environment.GetEnvironmentVariable("MOONGATE_SOFTWARE_RENDER"),
            "1", StringComparison.Ordinal);
        if (tier == 0 || forced)
        {
            try
            {
                RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
                StartupDiagnostics.Mark($"software render fallback applied (tier={tier}, forced={forced})");
            }
            catch (Exception error)
            {
                StartupDiagnostics.RecordException("ApplyRenderModeFallback", error);
            }
        }
    }

    /// <summary>未捕获异常兜底：展示错误而非闪退。</summary>
    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        StartupDiagnostics.RecordException("DispatcherUnhandledException", e.Exception);
        e.Handled = true;
        MessageBox.Show(
            Loc.F("L.Common.OperationFailedFmt", e.Exception.Message),
            Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
    }

    /// <summary>启动时检查依赖：缺失则弹模态进度窗逐项下载，完成前主窗口不可用。</summary>
    internal static void RunFirstLaunchDependencyCheck(Window owner)
    {
        try
        {
            var manager = new DependencyManager();
            if (manager.PlanMissing().Count == 0) return;
            var window = new DependencyWindow(
                Loc.S("L.Dep.FirstRunTitle"),
                Loc.S("L.Dep.FirstRunCaption"),
                (progress, ct) => manager.EnsureAsync(progress, ct))
            {
                Owner = owner,
            };
            window.ShowDialog();
        }
        catch (Exception error)
        {
            MessageBox.Show(
                Loc.F("L.Dep.CheckFailedFmt", error.Message),
                Loc.S("L.App.Title"), MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
