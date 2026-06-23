using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Xml.Linq;
using Xunit;

namespace MoongateCore.Tests;

/// <summary>
/// XAML 无障碍静态检查（跨平台，无需 WPF runtime，故放在 net10.0 的 Core 测试里而非 WPF 测试项目）：
/// 确保窗口中与可见 label 分离的输入控件（ComboBox / TextBox / PasswordBox）都带 AutomationProperties.Name，
/// 否则屏幕阅读器（Narrator）只能读出控件类型、读不出字段含义。对应 v0.8 Windows 无障碍系统性补齐。
/// </summary>
public class UiAccessibilityLintTests
{
    private static readonly XNamespace Pres = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly string[] InputControls = { "ComboBox", "TextBox", "PasswordBox" };

    private static string AppDir([CallerFilePath] string thisFile = "")
    {
        // 本测试源文件在 windows/MoongateCore.Tests/，目标 XAML 在姊妹目录 windows/MoongateApp/。
        var testsDir = Path.GetDirectoryName(thisFile)!;
        return Path.GetFullPath(Path.Combine(testsDir, "..", "MoongateApp"));
    }

    public static IEnumerable<object[]> WindowFiles() => new List<object[]>
    {
        new object[] { "MainWindow.xaml" },
        new object[] { "SettingsWindow.xaml" },
        new object[] { "OnboardingWindow.xaml" },
    };

    [Theory]
    [MemberData(nameof(WindowFiles))]
    public void SeparatedInputControlsHaveAutomationName(string fileName)
    {
        var path = Path.Combine(AppDir(), fileName);
        Assert.True(File.Exists(path), $"找不到 XAML：{path}");

        var doc = XDocument.Load(path);
        var missing = doc.Descendants()
            .Where(e => e.Name.Namespace == Pres && InputControls.Contains(e.Name.LocalName))
            .Where(e => !HasAutomationName(e))
            .Select(Describe)
            .ToList();

        Assert.True(missing.Count == 0,
            $"{fileName} 中以下输入控件缺少 AutomationProperties.Name（屏幕阅读器无法朗读字段名）：\n  "
            + string.Join("\n  ", missing));
    }

    private static bool HasAutomationName(XElement element) =>
        element.Attributes().Any(a => a.Name.LocalName == "AutomationProperties.Name");

    private static string Describe(XElement element)
    {
        var hint = element.Attributes()
            .FirstOrDefault(a => a.Name.LocalName is "Name" or "Text" or "SelectedItem" or "SelectedIndex");
        return $"<{element.Name.LocalName} {hint?.Name.LocalName}=\"{hint?.Value}\">";
    }
}
