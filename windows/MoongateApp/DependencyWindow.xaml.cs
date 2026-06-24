using System.ComponentModel;
using System.Windows;

namespace Moongate.App;

/// <summary>
/// 依赖下载进度窗（模态）：逐项下载缺失组件，可取消、失败可重试。
/// 下载进行中点关闭会先确认「停止下载并关闭」，确认后取消下载并清理临时文件，而不是无条件拦截关窗。
/// </summary>
public partial class DependencyWindow : Window
{
    private readonly Func<IProgress<string>, CancellationToken, Task> _work;
    private CancellationTokenSource _cts = new();
    private bool _running;
    /// <summary>已进入关窗流程：避免在窗口关闭后再去设置 DialogResult（会抛异常）。</summary>
    private bool _closingHandled;

    public DependencyWindow(string title, string caption, Func<IProgress<string>, CancellationToken, Task> work)
    {
        _work = work;
        LocalizationManager.ApplyTypography(this);
        InitializeComponent();
        ThemeManager.ApplyWindowTheme(this);
        Title = title;
        CaptionText.Text = caption;
        Loaded += (_, _) => _ = RunAsync();
    }

    private async Task RunAsync()
    {
        // 重试时换一个全新 token（上一次可能已取消）。
        if (_cts.IsCancellationRequested)
        {
            _cts.Dispose();
            _cts = new CancellationTokenSource();
        }
        _running = true;
        CancelButton.Visibility = Visibility.Visible;
        CancelButton.IsEnabled = true;
        RetryButton.Visibility = Visibility.Collapsed;
        CloseButton.Visibility = Visibility.Collapsed;
        ErrorText.Visibility = Visibility.Collapsed;
        Bar.IsIndeterminate = true;
        StatusText.Text = Loc.S("L.Dep.Checking");
        // Progress<string> 在 UI 线程创建：回调自动回到 UI 线程更新文案。
        var progress = new Progress<string>(text => StatusText.Text = text);
        try
        {
            await _work(progress, _cts.Token);
            _running = false;
            if (!_closingHandled) DialogResult = true;
        }
        catch (OperationCanceledException)
        {
            // 用户取消：清理后关闭窗口（首次启动场景下返回主界面，仍可稍后在设置里重新下载）。
            _running = false;
            if (!_closingHandled) DialogResult = false;
        }
        catch (Exception error)
        {
            _running = false;
            Bar.IsIndeterminate = false;
            CancelButton.Visibility = Visibility.Collapsed;
            StatusText.Text = Loc.S("L.Dep.DownloadFailed");
            ErrorText.Text = error.Message;
            ErrorText.Visibility = Visibility.Visible;
            RetryButton.Visibility = Visibility.Visible;
            CloseButton.Visibility = Visibility.Visible;
        }
    }

    private void OnRetryClick(object sender, RoutedEventArgs e)
    {
        _ = RunAsync();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void OnCancelDownloadClick(object sender, RoutedEventArgs e)
    {
        CancelButton.IsEnabled = false;
        StatusText.Text = Loc.S("L.Dep.Cancelled");
        _cts.Cancel();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_running && !_closingHandled)
        {
            // 下载进行中点 X：先确认是否停止下载并关闭，而不是无条件拦截。
            var confirmed = ConfirmWindow.Show(
                this, Loc.S("L.Dep.CancelConfirm"), Loc.S("L.Dep.CancelConfirmDetail"),
                confirmText: Loc.S("L.Dep.StopAndClose"));
            if (!confirmed)
            {
                e.Cancel = true;
                return;
            }
            _cts.Cancel();
        }
        _closingHandled = true;
        base.OnClosing(e);
    }
}
