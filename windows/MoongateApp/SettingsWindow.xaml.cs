using System.Diagnostics;
using System.IO;
using System.Windows;
using Moongate.Core;

namespace Moongate.App;

/// <summary>
/// 设置窗口（模态，草稿模式）：点「完成」才保存；取消 / Esc 不落任何修改。
/// 并发数改动实时生效，关窗时统一回滚/确认为磁盘值（对齐 macOS onDisappear 行为）。
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly MainViewModel _main;
    private readonly SettingsViewModel _vm;

    /// <summary>远程更新服务（设置窗内「更新」区绑定）。</summary>
    public UpdateService Updater { get; }

    /// <summary>点了「登录 ××」关窗后由主窗口接力弹出登录窗（值为站点 host）。</summary>
    public string? PendingLoginSite { get; private set; }

    public SettingsWindow(MainViewModel main)
    {
        _main = main;
        _vm = new SettingsViewModel(main.Settings, main.Queue, main.ConsumePendingSettingsNotice());
        Updater = App.WindowsUpdater;
        DataContext = _vm;
        InitializeComponent();
        ThemeManager.ApplyWindowTheme(this);
        // PasswordBox 不支持数据绑定，初值与变更都走代码同步。
        AITokenBox.Password = _vm.AIAuthToken;
        TokenBox.Password = _vm.AuthToken;
        SummaryTokenBox.Password = _vm.SummaryAuthToken;
        // 安装更新前的队列闸：有未完成任务时先向用户确认（继续任务 / 取消全部任务并更新）。
        Updater.ConfirmInstallReady = ConfirmUpdateInstall;
        Closed += (_, _) =>
        {
            _vm.CancelOperations();
            if (Updater.IsDownloading) Updater.Cancel();
            Updater.ConfirmInstallReady = null;
            // 未保存的并发数改动回滚为磁盘值；已保存时等价于当前值，无副作用。
            _main.Settings = AppSettings.Load();
        };
        // 打开设置即静默检查更新：有新版本时「更新」区直接显示，失败不打扰。
        Loaded += (_, _) =>
        {
            Updater.CheckAutomaticSilent();
            // 结构化依赖体检（可执行性/能力），细化「已安装」之外的损坏/缺能力状态。
            _ = _vm.RefreshDependencyHealthAsync();
            // 计算 App-owned 目录占用（后台线程），填充存储管理页大小。
            _ = _vm.CalculateStorageSizesAsync();
        };
    }

    private void OnTokenChanged(object sender, RoutedEventArgs e)
    {
        _vm.AuthToken = TokenBox.Password;
    }

    private void OnAITokenChanged(object sender, RoutedEventArgs e)
    {
        _vm.AIAuthToken = AITokenBox.Password;
    }

    private void OnSummaryTokenChanged(object sender, RoutedEventArgs e)
    {
        _vm.SummaryAuthToken = SummaryTokenBox.Password;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void OnDoneClick(object sender, RoutedEventArgs e)
    {
        if (_vm.TrySave(out var error))
        {
            var saved = _vm.BuildSettings();
            _main.Settings = saved;
            // 界面语言点「完成」后生效（XAML 文案即时换装，代码侧派生文案随事件重算）。
            LocalizationManager.Apply(saved.AppLanguage);
            DialogResult = true;
        }
        else
        {
            _vm.Notice = Loc.F("L.Settings.SaveFailedFmt", error ?? "");
        }
    }

    // MARK: - 站点登录

    private void OnLoginYouTubeClick(object sender, RoutedEventArgs e) => RequestLogin("youtube.com");

    private void OnLoginBilibiliClick(object sender, RoutedEventArgs e) => RequestLogin("bilibili.com");

    /// <summary>点「登录 ××」：先把草稿保存下来再走登录流程。保存失败则保持设置窗打开、不进入登录。</summary>
    private void RequestLogin(string site)
    {
        if (!_vm.TrySave(out var error))
        {
            // 保存失败（磁盘满/权限/文件被锁）不再静默丢弃用户刚改的模型/Token/语言，
            // 也不设 pending、不关窗——保持设置窗打开并显示可复制的失败原因。
            _vm.Notice = Loc.F("L.Settings.SaveFailedFmt", error ?? "");
            return;
        }
        var saved = _vm.BuildSettings();
        _main.Settings = saved;
        LocalizationManager.Apply(saved.AppLanguage);
        PendingLoginSite = site;
        DialogResult = true;
    }

    private void OnClearLoginsClick(object sender, RoutedEventArgs e)
    {
        var confirmed = ConfirmWindow.Show(
            this,
            Loc.S("L.Settings.ClearLoginsConfirm"),
            Loc.S("L.Settings.ClearLoginsDetail"),
            confirmText: Loc.S("L.Settings.ClearLogins"));
        if (!confirmed) return;
        _vm.ClearAllLogins();
    }

    // MARK: - 存储管理

    /// <summary>在资源管理器中打开某 App-owned 目录（按钮 Tag 携带路径）。</summary>
    private void OnOpenStorageFolderClick(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button { Tag: string path } || path.Length == 0) return;
        try
        {
            if (!Directory.Exists(path)) Directory.CreateDirectory(path);
            if (!OperatingSystem.IsWindows()) return;
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception error)
        {
            _vm.Notice = Loc.F("L.Common.OperationFailedFmt", error.Message);
        }
    }

    private void OnDeleteAsrModelsClick(object sender, RoutedEventArgs e)
    {
        var confirmed = ConfirmWindow.Show(
            this,
            Loc.S("L.Settings.StorageDeleteModelsConfirm"),
            Loc.S("L.Settings.StorageDeleteModelsDetail"),
            confirmText: Loc.S("L.Settings.StorageDelete"));
        if (!confirmed) return;
        _vm.DeleteAllAsrModels();
    }

    private void OnClearUpdateCacheClick(object sender, RoutedEventArgs e)
    {
        var confirmed = ConfirmWindow.Show(
            this,
            Loc.S("L.Settings.StorageClearCacheConfirm"),
            Loc.S("L.Settings.StorageClearCacheDetail"),
            confirmText: Loc.S("L.Settings.StorageClear"));
        if (!confirmed) return;
        _vm.ClearUpdateCache();
    }

    // MARK: - 依赖组件

    private void OnRedownloadClick(object sender, RoutedEventArgs e)
    {
        try
        {
            // 不再先删旧文件：下载到 staging 校验成功后才原子替换，网络失败时原有可用环境完整保留。
            var manager = new DependencyManager();
            var window = new DependencyWindow(
                Loc.S("L.Settings.RedownloadTitle"),
                Loc.S("L.Settings.RedownloadCaption"),
                (progress, ct) => manager.RedownloadAllAsync(progress, ct))
            {
                Owner = this,
            };
            window.ShowDialog();
        }
        catch (Exception error)
        {
            _vm.Notice = Loc.F("L.Common.OperationFailedFmt", error.Message);
        }
        finally
        {
            _vm.RefreshDependencyStatus();
        }
    }

    private void OnUpdateYtDlpClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var manager = new DependencyManager();
            var window = new DependencyWindow(
                Loc.S("L.Settings.UpdateYtDlp"),
                Loc.S("L.Settings.UpdateYtDlpCaption"),
                (progress, ct) => manager.UpdateYtDlpAsync(progress, ct))
            {
                Owner = this,
            };
            window.ShowDialog();
        }
        catch (Exception error)
        {
            _vm.Notice = Loc.F("L.Common.OperationFailedFmt", error.Message);
        }
        finally
        {
            _vm.RefreshDependencyStatus();
        }
    }

    // MARK: - 远程更新

    private void OnCheckUpdateClick(object sender, RoutedEventArgs e) => Updater.Check();

    private void OnDownloadUpdateClick(object sender, RoutedEventArgs e) => Updater.DownloadAndInstall();

    private void OnCancelUpdateClick(object sender, RoutedEventArgs e) => Updater.Cancel();

    /// <summary>
    /// 安装更新前的队列闸：无未完成任务直接放行；有则弹确认，
    /// 用户选「取消全部任务并更新」才中止队列并放行，选「继续任务」则取消本次更新。
    /// </summary>
    private bool ConfirmUpdateInstall()
    {
        var open = _main.Queue.OpenTaskCount;
        if (open == 0) return true;
        var paused = _main.Queue.PausedOpenTaskCount;
        var message = paused > 0
            ? Loc.F("L.Update.QueueBusyPausedFmt", open, paused)
            : Loc.F("L.Update.QueueBusyFmt", open);
        var confirmed = ConfirmWindow.Show(
            this, message, Loc.S("L.Update.QueueBusyDetail"),
            confirmText: Loc.S("L.Update.CancelTasksAndUpdate"),
            cancelText: Loc.S("L.Update.KeepTasks"));
        if (!confirmed) return false;
        _main.AbortAllTasks();
        return true;
    }

    private void OnOpenReleasesClick(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(Updater.ReleasesPageUrl) { UseShellExecute = true });
        }
        catch (Exception error)
        {
            _vm.Notice = Loc.F("L.Common.OperationFailedFmt", error.Message);
        }
    }
}
