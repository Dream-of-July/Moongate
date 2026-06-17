using System.Windows;

namespace Moongate.App;

/// <summary>首次启动引导：只选择界面语言与默认译文目标，不强制配置 API。</summary>
public partial class OnboardingWindow : Window
{
    private readonly MainViewModel _main;

    public OnboardingWindow(MainViewModel main)
    {
        _main = main;
        InitializeComponent();
        AppLanguageBox.SelectedIndex = main.Settings.AppLanguage switch
        {
            "zh-Hans" => 1,
            "zh-Hant" => 2,
            "en" => 3,
            _ => 0,
        };
        TargetLanguageBox.SelectedIndex = main.Settings.TranslationTargetLanguage switch
        {
            "zh-Hant" => 1,
            "en" => 2,
            _ => 0,
        };
    }

    private string SelectedAppLanguage => AppLanguageBox.SelectedIndex switch
    {
        1 => "zh-Hans",
        2 => "zh-Hant",
        3 => "en",
        _ => "auto",
    };

    private string SelectedTargetLanguage => TargetLanguageBox.SelectedIndex switch
    {
        1 => "zh-Hant",
        2 => "en",
        _ => "zh-Hans",
    };

    private void OnStartClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var settings = _main.Settings with
            {
                AppLanguage = SelectedAppLanguage,
                TranslationTargetLanguage = SelectedTargetLanguage,
                OnboardingCompleted = true,
            };
            settings.Save();
            _main.Settings = settings;
            LocalizationManager.Apply(settings.AppLanguage);
            DialogResult = true;
        }
        catch (Exception error)
        {
            ErrorText.Text = Loc.F("L.Settings.SaveFailedFmt", error.Message);
        }
    }
}
