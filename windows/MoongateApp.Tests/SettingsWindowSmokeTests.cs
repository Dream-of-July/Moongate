using System.Threading;
using System.Windows;
using Moongate.App;

namespace MoongateApp.Tests;

public class SettingsWindowSmokeTests
{
    // WPF 每进程只能有一个 Application 实例，故在同一个 App / STA 线程里依次实例化各窗口，
    // 一次性验证 App.xaml 控件模板与各窗口 XAML/绑定在真实 WindowsDesktop 运行时不抛错。
    [Fact]
    public void Windows_InitializeWithoutRuntimeXamlOrBindingFailure()
    {
        Exception? captured = null;
        var completed = new ManualResetEventSlim(false);

        var thread = new Thread(() =>
        {
            try
            {
                var app = Application.Current as App ?? new App();
                app.InitializeComponent();

                // 设置窗：v0.8 深色控件模板、存储管理、复合「更新与关于」tab 头（带红点）。
                var settings = new SettingsWindow(new MainViewModel());
                settings.Close();

                // onboarding：v0.8 内联完整 API 编辑器（复用 APIEndpointActions）+ 新控件模板。
                var onboarding = new OnboardingWindow(new MainViewModel());
                onboarding.Close();
            }
            catch (Exception error)
            {
                captured = error;
            }
            finally
            {
                Application.Current?.Shutdown();
                completed.Set();
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.True(completed.Wait(TimeSpan.FromSeconds(20)), "Window initialization timed out.");
        Assert.Null(captured);
    }
}
