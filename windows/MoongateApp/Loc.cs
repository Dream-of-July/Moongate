using System.Globalization;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Media;
using Moongate.Core;

namespace Moongate.App;

/// <summary>代码侧取界面文案（XAML 侧用 DynamicResource 直接引用同一批 key）。</summary>
internal static class Loc
{
    /// <summary>取字符串资源；缺 key 时回退 key 本身（便于发现遗漏，不崩溃）。</summary>
    public static string S(string key) =>
        Application.Current?.TryFindResource(key) as string ?? key;

    /// <summary>S 的语义别名：按本地化 key 取界面/错误文案。</summary>
    public static string T(string key) => S(key);

    public static string F(string key, params object[] args) => string.Format(S(key), args);
}

/// <summary>
/// 界面语言管理：按设置（auto / zh-Hans / zh-Hant / en）换装字符串资源字典并同步核心库 L10n。
/// XAML 用 DynamicResource 的文案即时切换；代码侧已生成的字符串在下次刷新时切换。
/// </summary>
public static class LocalizationManager
{
    /// <summary>语言切换后触发（UI 线程）：ViewModel 据此重算代码侧派生文案。</summary>
    public static event Action? LanguageChanged;

    public static bool IsEnglish => CurrentLanguage == "en";
    public static string CurrentLanguage { get; private set; } = "zh-Hans";
    public static string CurrentCultureName => CurrentLanguage switch
    {
        "en" => "en-US",
        "zh-Hant" => "zh-Hant",
        _ => "zh-CN",
    };

    /// <summary>appLanguage："auto"（跟随系统 UI 语言）| "zh-Hans" | "zh-Hant" | "en"。</summary>
    public static void Apply(string appLanguage)
    {
        CurrentLanguage = appLanguage switch
        {
            "en" => "en",
            "zh-Hans" => "zh-Hans",
            "zh-Hant" => "zh-Hant",
            // auto：系统界面语言是中文则用中文，其余一律英文
            _ => ResolveSystemLanguage(),
        };
        var culture = CultureInfo.GetCultureInfo(CurrentCultureName);
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;

        // 核心库的状态文案、错误消息跟随同一语言
        L10n.Language = CurrentLanguage switch
        {
            "en" => CoreLanguage.English,
            "zh-Hant" => CoreLanguage.TraditionalChinese,
            _ => CoreLanguage.Chinese,
        };

        var app = Application.Current;
        if (app is not null)
        {
            var resourceName = CurrentLanguage switch
            {
                "en" => "Strings.en.xaml",
                "zh-Hant" => "Strings.zh-Hant.xaml",
                _ => "Strings.zh.xaml",
            };
            var source = new Uri(resourceName, UriKind.Relative);
            var dict = new ResourceDictionary { Source = source };
            var existing = app.Resources.MergedDictionaries
                .FirstOrDefault(d => d.Source?.OriginalString.Contains("Strings.") == true);
            if (existing is not null)
            {
                app.Resources.MergedDictionaries.Remove(existing);
            }
            app.Resources.MergedDictionaries.Add(dict);

            foreach (Window window in app.Windows)
            {
                ApplyTypography(window);
            }
        }
        LanguageChanged?.Invoke();
    }

    public static void ApplyTypography(Window window)
    {
        window.Language = XmlLanguage.GetLanguage(CurrentCultureName);
        window.FontFamily = CurrentLanguage switch
        {
            "en" => new FontFamily("Segoe UI"),
            "zh-Hant" => new FontFamily("Microsoft JhengHei UI, Microsoft YaHei UI, Segoe UI"),
            _ => new FontFamily("Microsoft YaHei UI, Microsoft JhengHei UI, Segoe UI"),
        };
    }

    private static string ResolveSystemLanguage()
    {
        var name = CultureInfo.CurrentUICulture.Name;
        if (!name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) return "en";
        return name.Contains("Hant", StringComparison.OrdinalIgnoreCase)
            || name.EndsWith("-TW", StringComparison.OrdinalIgnoreCase)
            || name.EndsWith("-HK", StringComparison.OrdinalIgnoreCase)
            || name.EndsWith("-MO", StringComparison.OrdinalIgnoreCase)
            ? "zh-Hant"
            : "zh-Hans";
    }
}
