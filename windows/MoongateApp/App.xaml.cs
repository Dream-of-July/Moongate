using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Moongate.Core;

namespace Moongate.App;

/// <summary>应用入口：界面语言装载 + 未捕获异常兜底 + 首次启动依赖引导。</summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        StartupDiagnostics.Mark("OnStartup begin");

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

        try
        {
            // 按设置装载界面语言（含核心库 L10n）。
            LocalizationManager.Apply(AppSettings.Load().AppLanguage);
            StartupDiagnostics.Mark("localization applied");

            var main = new MainWindow();
            MainWindow = main;
            main.Show();
            StartupDiagnostics.Mark("MainWindow shown");
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

        RunFirstLaunchDependencyCheck(MainWindow!);
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
    private static void RunFirstLaunchDependencyCheck(Window owner)
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
