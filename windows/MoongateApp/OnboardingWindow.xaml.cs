using System.Windows;
using System.Windows.Controls;
using Moongate.Core;

namespace Moongate.App;

/// <summary>首次启动引导：分阶段选择基础偏好，不强制配置 API 或下载本地 ASR 模型。</summary>
public partial class OnboardingWindow : Window
{
    private enum OnboardingStep
    {
        Language,
        SubtitleSource,
        TranslationMethod,
        Readiness,
    }

    private readonly MainViewModel _main;
    private readonly OnboardingApiEditorViewModel _apiEditor;
    private readonly OnboardingStep[] _steps =
    {
        OnboardingStep.Language,
        OnboardingStep.SubtitleSource,
        OnboardingStep.TranslationMethod,
        OnboardingStep.Readiness,
    };
    private int _stepIndex;

    public OnboardingWindow(MainViewModel main)
    {
        _main = main;
        LocalizationManager.ApplyTypography(this);
        InitializeComponent();
        ThemeManager.ApplyWindowTheme(this);
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
        _apiEditor = new OnboardingApiEditorViewModel(main.Settings);
        TranslationMethodPanel.DataContext = _apiEditor;
        OnboardingApiTokenBox.Password = main.Settings.AIAuthToken;
        Closed += (_, _) => _apiEditor.Endpoint.CancelOperations();
        PreferLocalSpeechRecognitionBox.IsChecked = main.Settings.LocalAsrEnabled;
        ShowStep(OnboardingStep.Language);
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

    private TranslationProvider SelectedTranslationProvider => _apiEditor.Provider;

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (_stepIndex <= 0) return;
        _stepIndex -= 1;
        ShowStep(_steps[_stepIndex]);
    }

    private void OnNextClick(object sender, RoutedEventArgs e)
    {
        if (_stepIndex >= _steps.Length - 1) return;
        _stepIndex += 1;
        ShowStep(_steps[_stepIndex]);
    }

    private void ShowStep(OnboardingStep step)
    {
        _stepIndex = Array.IndexOf(_steps, step);
        if (_stepIndex < 0) _stepIndex = 0;

        LanguagePanel.Visibility = step == OnboardingStep.Language ? Visibility.Visible : Visibility.Collapsed;
        SubtitleSourcePanel.Visibility = step == OnboardingStep.SubtitleSource ? Visibility.Visible : Visibility.Collapsed;
        TranslationMethodPanel.Visibility = step == OnboardingStep.TranslationMethod ? Visibility.Visible : Visibility.Collapsed;
        ReadinessPanel.Visibility = step == OnboardingStep.Readiness ? Visibility.Visible : Visibility.Collapsed;

        LanguageStepLabel.FontWeight = step == OnboardingStep.Language ? FontWeights.SemiBold : FontWeights.Normal;
        SubtitleSourceStepLabel.FontWeight = step == OnboardingStep.SubtitleSource ? FontWeights.SemiBold : FontWeights.Normal;
        TranslationMethodStepLabel.FontWeight = step == OnboardingStep.TranslationMethod ? FontWeights.SemiBold : FontWeights.Normal;
        ReadinessStepLabel.FontWeight = step == OnboardingStep.Readiness ? FontWeights.SemiBold : FontWeights.Normal;

        BackButton.IsEnabled = _stepIndex > 0;
        NextButton.Visibility = step == OnboardingStep.Readiness ? Visibility.Collapsed : Visibility.Visible;
        StartButton.Visibility = step == OnboardingStep.Readiness ? Visibility.Visible : Visibility.Collapsed;
        ErrorText.Text = "";

        if (step == OnboardingStep.Readiness)
        {
            UpdateSummary();
        }
    }

    private void UpdateSummary()
    {
        SummaryAppLanguage.Text = SelectedComboBoxText(AppLanguageBox);
        SummaryTargetLanguage.Text = SelectedComboBoxText(TargetLanguageBox);
        SummaryTranslationMethod.Text = SelectedComboBoxText(TranslationProviderBox);
        SummarySubtitleSource.Text = PreferLocalSpeechRecognitionBox.IsChecked == true
            ? Loc.S("L.Onboarding.LocalSpeechSummary")
            : Loc.S("L.Onboarding.PlatformSubtitleSummary");
    }

    private static string SelectedComboBoxText(ComboBox box)
    {
        if (box.SelectedItem is ComboBoxItem item)
        {
            return item.Content?.ToString() ?? "";
        }
        return box.Text;
    }

    private void OnApiTokenChanged(object sender, RoutedEventArgs e)
    {
        _apiEditor.AuthToken = OnboardingApiTokenBox.Password;
    }

    private void OnStartClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var provider = SelectedTranslationProvider;
            var baseUrl = _apiEditor.BaseUrl.Trim();
            if (baseUrl.Length == 0) baseUrl = provider.DefaultBaseUrl();
            var settings = _main.Settings with
            {
                AppLanguage = SelectedAppLanguage,
                TranslationTargetLanguage = SelectedTargetLanguage,
                AIProvider = provider,
                AIBaseUrl = baseUrl,
                AIAuthToken = _apiEditor.AuthToken,
                AIModel = _apiEditor.Model.Trim(),
                TranslationProvider = provider,
                TranslationBaseUrl = baseUrl,
                TranslationFollowsDefault = true,
                LocalAsrEnabled = PreferLocalSpeechRecognitionBox.IsChecked == true,
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

/// <summary>首次启动里的默认 AI 服务编辑器，复用设置页的 <see cref="APIEndpointActions"/>，避免两套拉模型/测试连接实现。</summary>
public sealed class OnboardingApiEditorViewModel : ObservableObject
{
    public APIEndpointActions Endpoint { get; }

    public OnboardingApiEditorViewModel(AppSettings current)
    {
        _provider = current.AIProvider;
        _baseUrl = string.IsNullOrWhiteSpace(current.AIBaseUrl)
            ? current.AIProvider.DefaultBaseUrl()
            : current.AIBaseUrl;
        _authToken = current.AIAuthToken;
        _model = current.AIModel;
        Endpoint = new APIEndpointActions(
            Loc.S("L.Settings.ModelPlaceholder"),
            () => new AppSettings
            {
                TranslationProvider = _provider,
                TranslationBaseUrl = (_baseUrl ?? "").Trim(),
                TranslationModel = (_model ?? "").Trim(),
                TranslationAuthToken = _authToken ?? "",
                TranslationFollowsDefault = false,
            },
            () => BaseUrl,
            () => AuthToken,
            () => Model,
            value => Model = value);
    }

    private TranslationProvider _provider;
    public int ProviderIndex
    {
        get => _provider == TranslationProvider.Openai ? 1 : 0;
        set
        {
            var next = value == 1 ? TranslationProvider.Openai : TranslationProvider.Anthropic;
            if (_provider == next) return;
            var previousDefault = _provider.DefaultBaseUrl();
            _provider = next;
            // 仅当用户未自定义 BaseUrl（空或仍是旧 provider 默认值）时，跟随新 provider 默认地址。
            if (string.IsNullOrWhiteSpace(_baseUrl) || _baseUrl.Trim() == previousDefault)
            {
                BaseUrl = next.DefaultBaseUrl();
            }
            RaisePropertyChanged();
            ResetEndpoint();
        }
    }

    public TranslationProvider Provider => _provider;

    private string _baseUrl;
    public string BaseUrl
    {
        get => _baseUrl;
        set { if (SetProperty(ref _baseUrl, value)) ResetEndpoint(); }
    }

    private string _authToken;
    public string AuthToken
    {
        get => _authToken;
        set { if (SetProperty(ref _authToken, value)) ResetEndpoint(); }
    }

    private string _model;
    public string Model
    {
        get => _model;
        set
        {
            if (SetProperty(ref _model, value))
            {
                Endpoint.OnModelChanged();
                Endpoint.ResetTestState();
                Endpoint.RaiseActionEnables();
            }
        }
    }

    private void ResetEndpoint()
    {
        Endpoint.ResetModelFetch();
        Endpoint.ResetTestState();
        Endpoint.RaiseActionEnables();
    }
}
