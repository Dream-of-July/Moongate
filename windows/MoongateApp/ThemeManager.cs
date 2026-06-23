using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace Moongate.App;

internal static class ThemeManager
{
    private const string LightTheme = "Themes/Theme.Light.xaml";
    private const string DarkTheme = "Themes/Theme.Dark.xaml";
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string AppsUseLightThemeValue = "AppsUseLightTheme";
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaUseImmersiveDarkModeBefore20H1 = 19;
    private static bool _registered;
    private static bool _isDark;

    public static bool IsDark => _isDark;

    public static void ApplySystemTheme()
    {
        Apply(IsSystemDarkTheme());
        RegisterSystemThemeWatcher();
    }

    public static void ApplyWindowTheme(Window window)
    {
        if (window.IsInitialized)
        {
            ApplyWindowTitleBar(window, _isDark);
        }
        window.SourceInitialized -= OnWindowSourceInitialized;
        window.SourceInitialized += OnWindowSourceInitialized;
    }

    private static void Apply(bool dark)
    {
        _isDark = dark;
        var app = Application.Current;
        if (app is null) return;

        var source = new Uri(dark ? DarkTheme : LightTheme, UriKind.Relative);
        var existing = app.Resources.MergedDictionaries
            .FirstOrDefault(d => d.Source?.OriginalString.Contains("Themes/Theme.", StringComparison.Ordinal) == true);
        if (existing is not null)
        {
            app.Resources.MergedDictionaries.Remove(existing);
        }
        app.Resources.MergedDictionaries.Insert(0, new ResourceDictionary { Source = source });

        foreach (Window window in app.Windows)
        {
            ApplyWindowTitleBar(window, dark);
        }
    }

    private static void RegisterSystemThemeWatcher()
    {
        if (!OperatingSystem.IsWindows()) return;
        if (_registered) return;
        _registered = true;
        SystemEvents.UserPreferenceChanged += (_, args) =>
        {
            if (args.Category is not UserPreferenceCategory.General
                and not UserPreferenceCategory.VisualStyle
                and not UserPreferenceCategory.Color)
            {
                return;
            }
            Application.Current?.Dispatcher.BeginInvoke(() => Apply(IsSystemDarkTheme()));
        };
    }

    private static bool IsSystemDarkTheme()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue(AppsUseLightThemeValue) is int value && value == 0;
        }
        catch
        {
            return false;
        }
    }

    private static void OnWindowSourceInitialized(object? sender, EventArgs e)
    {
        if (sender is Window window)
        {
            ApplyWindowTitleBar(window, _isDark);
        }
    }

    private static void ApplyWindowTitleBar(Window window, bool dark)
    {
        if (!OperatingSystem.IsWindows()) return;
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;
        var enabled = dark ? 1 : 0;
        if (DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkMode, ref enabled, sizeof(int)) != 0)
        {
            _ = DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkModeBefore20H1, ref enabled, sizeof(int));
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int attributeValue, int attributeSize);
}
