using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Moongate.App;

namespace MoongateApp.Tests;

/// <summary>
/// 可视化转储（opt-in，不进常规 CI）：把各窗口/设置分页离屏渲染成 PNG，用于人工核对深色/浅色观感。
/// 仅当环境变量 MOONGATE_UI_QA_DUMP=1 时运行；输出目录由 MOONGATE_UI_QA_DIR 指定（默认临时目录）。
/// 对应 v0.8 Windows 原生控件主题化 + 设置页信息架构的可视化验收。
/// </summary>
public class UiVisualDumpTests
{
    [Fact]
    public void DumpModeWindowRenders()
    {
        if (Environment.GetEnvironmentVariable("MOONGATE_UI_QA_DUMP") != "1") return; // 默认跳过

        var outDir = Environment.GetEnvironmentVariable("MOONGATE_UI_QA_DIR");
        if (string.IsNullOrWhiteSpace(outDir)) outDir = Path.GetTempPath();
        Directory.CreateDirectory(outDir);

        Exception? captured = null;
        var completed = new ManualResetEventSlim(false);

        var thread = new Thread(() =>
        {
            try
            {
                var app = Application.Current as App ?? new App();
                app.InitializeComponent();

                // App.xaml 默认并入浅色主题：先渲染浅色分页验证浅色未被控件模板改动破坏。
                DumpSettingsTab(outDir, 6, "settings-storage-light");

                // 切深色，渲染各关键分页验证深色控件主题化与信息架构。
                ForceTheme(app, dark: true);
                DumpSettingsTab(outDir, 0, "settings-general-dark");
                DumpSettingsTab(outDir, 1, "settings-subtitles-dark");
                DumpSettingsTab(outDir, 3, "settings-ai-dark");
                DumpSettingsTab(outDir, 6, "settings-storage-dark");
                Dump(outDir, "onboarding-dark", () => new OnboardingWindow(new MainViewModel()));
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

        Assert.True(completed.Wait(TimeSpan.FromSeconds(60)), "Visual dump timed out.");
        Assert.Null(captured);
    }

    private static void ForceTheme(Application app, bool dark)
    {
        var existing = app.Resources.MergedDictionaries
            .FirstOrDefault(d => d.Source?.OriginalString.Contains("Themes/Theme.", StringComparison.Ordinal) == true);
        if (existing is not null) app.Resources.MergedDictionaries.Remove(existing);
        var which = dark ? "Theme.Dark.xaml" : "Theme.Light.xaml";
        app.Resources.MergedDictionaries.Insert(0, new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/Moongate;component/Themes/{which}", UriKind.Absolute),
        });
    }

    private static void DumpSettingsTab(string outDir, int tabIndex, string name)
    {
        var window = new SettingsWindow(new MainViewModel())
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -10000,
            Top = -10000,
            ShowInTaskbar = false,
        };
        window.Show();
        window.UpdateLayout();
        var tabs = FindDescendant<TabControl>(window);
        if (tabs is not null && tabIndex >= 0 && tabIndex < tabs.Items.Count)
        {
            tabs.SelectedIndex = tabIndex;
            window.UpdateLayout();
        }
        RenderToPng(window, outDir, name);
        window.Close();
    }

    private static void Dump(string outDir, string name, Func<Window> make)
    {
        var window = make();
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000;
        window.Top = -10000;
        window.ShowInTaskbar = false;
        window.Show();
        window.UpdateLayout();
        RenderToPng(window, outDir, name);
        window.Close();
    }

    private static void RenderToPng(Window window, string outDir, string name)
    {
        var width = (int)Math.Ceiling(window.ActualWidth);
        var height = (int)Math.Ceiling(window.ActualHeight);
        if (width <= 0 || height <= 0) return;
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(Path.Combine(outDir, $"mg-{name}.png"));
        encoder.Save(stream);
    }

    private static T? FindDescendant<T>(DependencyObject root) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T hit) return hit;
            var deeper = FindDescendant<T>(child);
            if (deeper is not null) return deeper;
        }
        return null;
    }
}
