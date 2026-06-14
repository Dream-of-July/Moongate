using System.Text.Json;
using Moongate.Core;
using Xunit;

namespace Moongate.Core.Tests;

public class UpdateCheckerTests
{
    [Fact]
    public void SemVer_ParsingAndComparison()
    {
        Assert.Equal(new SemVer(0, 4, 0), SemVer.Parse("v0.4.0"));
        Assert.Equal(new SemVer(0, 4, 0), SemVer.Parse("0.4"));
        Assert.Equal(new SemVer(1, 2, 3), SemVer.Parse("1.2.3-beta"));
        Assert.Null(SemVer.Parse("not-a-version"));
        Assert.True(SemVer.Parse("0.4.0")!.Value > SemVer.Parse("0.3.9")!.Value);
        Assert.True(SemVer.Parse("v1.0.0")!.Value > SemVer.Parse("0.99.99")!.Value);
        Assert.False(SemVer.Parse("0.4.0")!.Value > SemVer.Parse("0.4.0")!.Value);
    }

    private static string ReleasesJson(params (string Tag, string[] Assets)[] entries)
    {
        var arr = entries.Select(e => new Dictionary<string, object>
        {
            ["tag_name"] = e.Tag,
            ["body"] = $"release notes for {e.Tag}",
            ["draft"] = false,
            ["prerelease"] = true,
            ["assets"] = e.Assets.Select(name => new Dictionary<string, object>
            {
                ["name"] = name,
                ["browser_download_url"] =
                    $"https://github.com/Dream-of-July/video-downloader-app/releases/download/{e.Tag}/{name}",
            }).ToArray(),
        }).ToArray();
        return JsonSerializer.Serialize(arr);
    }

    [Fact]
    public void PicksNewestWindowsUpdateAboveCurrent()
    {
        var json = ReleasesJson(
            ("v0.3.0", ["Moongate-macOS-v0.3.0.dmg", "月之门-Windows-Setup-v0.3.0.exe"]),
            ("v0.5.0", ["月之门-Windows-Setup-v0.5.0.exe"]),
            ("v0.4.0", ["月之门-Windows-Setup-v0.4.0.exe"]));
        var info = UpdateChecker.LatestWindowsUpdate(json, SemVer.Parse("0.4.0")!.Value);
        Assert.NotNull(info);
        Assert.Equal("v0.5.0", info!.Tag);
        Assert.Equal("月之门-Windows-Setup-v0.5.0.exe", info.AssetName);
        Assert.StartsWith("https://github.com/Dream-of-July/", info.SetupUrl);
        Assert.Contains("v0.5.0", info.Notes);
    }

    [Fact]
    public void ReturnsNullWhenAlreadyLatest()
    {
        var json = ReleasesJson(("v0.4.0", ["月之门-Windows-Setup-v0.4.0.exe"]));
        Assert.Null(UpdateChecker.LatestWindowsUpdate(json, SemVer.Parse("0.4.0")!.Value));
    }

    [Fact]
    public void IgnoresReleasesWithoutWindowsSetup()
    {
        // 只有 macOS 资产 → 不算可更新。
        var json = ReleasesJson(("v0.9.0", ["Moongate-macOS-v0.9.0.dmg"]));
        Assert.Null(UpdateChecker.LatestWindowsUpdate(json, SemVer.Parse("0.4.0")!.Value));
    }

    [Fact]
    public void SkipsUnparseableTagsAndBadData()
    {
        var json = ReleasesJson(
            ("nightly", ["月之门-Windows-Setup-nightly.exe"]),   // 无法解析版本 → 跳过
            ("v0.6.0", ["月之门-Windows-Setup-v0.6.0.exe"]));
        var info = UpdateChecker.LatestWindowsUpdate(json, SemVer.Parse("0.4.0")!.Value);
        Assert.Equal("v0.6.0", info!.Tag);

        Assert.Null(UpdateChecker.LatestWindowsUpdate("not json", SemVer.Parse("0.4.0")!.Value));
    }

    [Fact]
    public void TrustedSetupUrlWhitelist()
    {
        const string owner = "Dream-of-July", repo = "video-downloader-app";
        Assert.True(UpdateChecker.IsTrustedSetupUrl(
            "https://github.com/Dream-of-July/video-downloader-app/releases/download/v0.5.0/x.exe", owner, repo));
        // objects.githubusercontent.com 任意路径不再放行（与 macOS 一致：之前 return true 是漏洞，
        // 且 SetupUrl 实际只会是 github.com 规范地址，CDN 重定向由 HttpClient 内部跟随）。
        Assert.False(UpdateChecker.IsTrustedSetupUrl(
            "https://objects.githubusercontent.com/abc/x.exe", owner, repo));
        // 非 https / 非 GitHub / 非 exe / 错仓库 → 拒绝。
        Assert.False(UpdateChecker.IsTrustedSetupUrl(
            "http://github.com/Dream-of-July/video-downloader-app/releases/download/v1/x.exe", owner, repo));
        Assert.False(UpdateChecker.IsTrustedSetupUrl("https://evil.com/x.exe", owner, repo));
        Assert.False(UpdateChecker.IsTrustedSetupUrl(
            "https://github.com/Dream-of-July/video-downloader-app/releases/download/v1/x.zip", owner, repo));
        Assert.False(UpdateChecker.IsTrustedSetupUrl(
            "https://github.com/someone-else/evil/releases/download/v1/x.exe", owner, repo));
    }
}
