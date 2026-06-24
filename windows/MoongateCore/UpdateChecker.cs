using System.Text.Json;
using System.Text.RegularExpressions;

namespace Moongate.Core;

// MARK: - 语义版本

/// <summary>
/// 语义版本：major.minor.patch[-prerelease]，容忍前缀 "v" 和多余段；构建元数据（+ 之后）忽略。
/// 与 Swift 版 SemVer 同构。按 SemVer 2.0 优先级比较：正式版高于同号预发布版
/// （0.8.0 &gt; 0.8.0-rc.1 &gt; 0.8.0-beta），预发布标识按点分段逐段比较（数字段按数值、其余按 ASCII）。
/// </summary>
public readonly struct SemVer : IComparable<SemVer>, IEquatable<SemVer>
{
    public int Major { get; }
    public int Minor { get; }
    public int Patch { get; }
    /// <summary>预发布标识（"beta" / "rc.1" 等）；空串表示正式版。</summary>
    public string Prerelease { get; }

    /// <summary>是否为预发布版本（带 -beta / -rc 之类后缀）。</summary>
    public bool IsPrerelease => Prerelease.Length > 0;

    public SemVer(int major, int minor, int patch, string prerelease = "")
    {
        Major = major;
        Minor = minor;
        Patch = patch;
        Prerelease = prerelease ?? "";
    }

    /// <summary>从 "v0.4.0" / "0.4" / "0.4.0-beta" / "0.8.0-rc.1+build" 等解析；失败返回 null。</summary>
    public static SemVer? Parse(string raw)
    {
        var s = raw.Trim();
        if (s.StartsWith('v') || s.StartsWith('V')) s = s[1..];
        // 构建元数据（+ 之后）不参与版本语义，先丢弃。
        var plus = s.IndexOf('+');
        if (plus >= 0) s = s[..plus];
        // 预发布后缀（首个 - 之后）单独保留用于优先级比较。
        var prerelease = "";
        var dash = s.IndexOf('-');
        if (dash >= 0)
        {
            prerelease = s[(dash + 1)..];
            s = s[..dash];
        }
        var parts = s.Split('.');
        if (parts.Length == 0 || !int.TryParse(parts[0], out var major)) return null;
        var minor = parts.Length > 1 && int.TryParse(parts[1], out var mi) ? mi : 0;
        var patch = parts.Length > 2 && int.TryParse(parts[2], out var pa) ? pa : 0;
        return new SemVer(major, minor, patch, prerelease);
    }

    public override string ToString() =>
        Prerelease.Length > 0 ? $"{Major}.{Minor}.{Patch}-{Prerelease}" : $"{Major}.{Minor}.{Patch}";

    public int CompareTo(SemVer other)
    {
        if (Major != other.Major) return Major.CompareTo(other.Major);
        if (Minor != other.Minor) return Minor.CompareTo(other.Minor);
        if (Patch != other.Patch) return Patch.CompareTo(other.Patch);
        return ComparePrerelease(Prerelease, other.Prerelease);
    }

    /// <summary>
    /// SemVer 2.0 预发布优先级：无预发布段（正式版）高于有预发布段；
    /// 两者都有时按点分标识逐段比较（纯数字段按数值大小且低于非数字段，其余按 ASCII），
    /// 前缀相同则段更多者更高（rc.1.1 &gt; rc.1）。
    /// </summary>
    private static int ComparePrerelease(string a, string b)
    {
        if (a.Length == 0 && b.Length == 0) return 0;
        if (a.Length == 0) return 1;  // 正式版 > 预发布
        if (b.Length == 0) return -1;
        var ai = a.Split('.');
        var bi = b.Split('.');
        var count = Math.Min(ai.Length, bi.Length);
        for (var i = 0; i < count; i++)
        {
            var aNum = int.TryParse(ai[i], out var an);
            var bNum = int.TryParse(bi[i], out var bn);
            if (aNum && bNum)
            {
                if (an != bn) return an.CompareTo(bn);
            }
            else if (aNum != bNum)
            {
                return aNum ? -1 : 1;  // 数字段优先级低于非数字段
            }
            else
            {
                var cmp = string.CompareOrdinal(ai[i], bi[i]);
                if (cmp != 0) return cmp;
            }
        }
        return ai.Length.CompareTo(bi.Length);
    }

    public bool Equals(SemVer other) =>
        Major == other.Major && Minor == other.Minor && Patch == other.Patch
        && string.Equals(Prerelease, other.Prerelease, StringComparison.Ordinal);
    public override bool Equals(object? obj) => obj is SemVer s && Equals(s);
    public override int GetHashCode() => HashCode.Combine(Major, Minor, Patch, Prerelease);
    public static bool operator <(SemVer a, SemVer b) => a.CompareTo(b) < 0;
    public static bool operator >(SemVer a, SemVer b) => a.CompareTo(b) > 0;
    public static bool operator <=(SemVer a, SemVer b) => a.CompareTo(b) <= 0;
    public static bool operator >=(SemVer a, SemVer b) => a.CompareTo(b) >= 0;
}

// MARK: - 更新信息

/// <summary>一条可升级的 Windows 安装包信息。</summary>
public sealed record UpdateInfo(
    SemVer Version,
    string Tag,
    string Notes,
    string SetupUrl,
    string AssetName,
    string Sha256Url,
    string Sha256AssetName);

// MARK: - 更新检查

/// <summary>
/// 查询 GitHub releases，挑出比当前版本更新的 Windows 安装包。与 macOS UpdateChecker 同构，
/// 区别仅在资产匹配：Windows 认 .exe（名字含 "win" 或 "setup"）而非 .dmg。
/// </summary>
public sealed class UpdateChecker
{
    private static readonly Regex VersionTokenRegex = new(
        @"(?<![A-Za-z0-9])v?\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?(?=$|[^A-Za-z0-9]|\.[A-Za-z]{2,5}$)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public string Owner { get; }
    public string Repo { get; }

    public UpdateChecker(string owner = "Dream-of-July", string repo = "moongate")
    {
        Owner = owner;
        Repo = repo;
    }

    /// <summary>仓库 releases 页（失败兜底引导用户手动下载）。</summary>
    public string ReleasesPageUrl => $"https://github.com/{Owner}/{Repo}/releases";

    /// <summary>仓库主页（关于页「在 GitHub 打开」按钮跳转，对齐 macOS repoURL）。</summary>
    public string RepoPageUrl => $"https://github.com/{Owner}/{Repo}";

    /// <summary>
    /// 自动静默检查的节流判断（UPDATE-WIN-004）：设置页可频繁打开，但不应每次都请求 GitHub。
    /// 手动检查不走此函数，始终允许。
    /// </summary>
    public static bool ShouldRunAutomaticCheck(
        DateTimeOffset? lastCheckedAt,
        DateTimeOffset now,
        TimeSpan minimumInterval)
    {
        if (lastCheckedAt is null) return true;
        return now - lastCheckedAt.Value >= minimumInterval;
    }

    /// <summary>
    /// 查询 GitHub releases，返回比 currentVersion 更新的 Windows 版本；无更新返回 null。
    /// 公开仓库匿名访问即可；超时短、失败抛 MoongateException 由调用方决定是否静默。
    /// httpHandler 供测试注入。
    /// </summary>
    public async Task<UpdateInfo?> CheckForUpdateAsync(
        string currentVersion,
        HttpMessageHandler? httpHandler = null,
        CancellationToken ct = default,
        bool includePrerelease = true)
    {
        if (SemVer.Parse(currentVersion) is not { } current)
            throw MoongateException.UpdateFailed(L10n.T(
                $"无法解析当前版本号：{currentVersion}",
                $"無法解析目前版本號：{currentVersion}",
                $"Could not parse current version: {currentVersion}"));

        using var client = new HttpClient(httpHandler ?? new HttpClientHandler(), disposeHandler: httpHandler is null)
        {
            // 45s 而非 15s：中国大陆用户经代理/VPN 访问 api.github.com 时握手+TLS+收发常需 20-30s。
            Timeout = TimeSpan.FromSeconds(45),
        };
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            $"https://api.github.com/repos/{Owner}/{Repo}/releases?per_page=20");
        request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
        // GitHub 要求带 User-Agent，否则可能被拒。
        request.Headers.TryAddWithoutValidation("User-Agent", "MoongateUpdater");

        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw MoongateException.Cancelled();
        }
        catch (HttpRequestException)
        {
            throw MoongateException.UpdateFailed(L10n.T(
                "无法连接到更新服务器，请检查网络与代理设置。",
                "無法連線到更新伺服器，請檢查網路與代理設定。",
                "Could not connect to the update server. Check your network and proxy settings."));
        }
        catch (TaskCanceledException)
        {
            // 非用户取消的 TaskCanceledException 多为超时。
            throw MoongateException.UpdateFailed(L10n.T(
                "连接更新服务器超时。若在中国大陆，请检查代理/VPN 是否开启并能正常访问 GitHub。",
                "連線更新伺服器逾時。若在中國大陸，請檢查代理/VPN 是否已開啟並能正常存取 GitHub。",
                "The update server timed out. If you are in mainland China, check that your proxy or VPN can reach GitHub."));
        }

        using (response)
        {
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden)
                throw MoongateException.UpdateFailed(L10n.T(
                    "更新检查过于频繁（GitHub 限流），请稍后再试。",
                    "更新檢查過於頻繁（GitHub 限流），請稍後再試。",
                    "Update checks are too frequent (GitHub rate limit). Try again later."));
            if (!response.IsSuccessStatusCode)
                throw MoongateException.UpdateFailed($"HTTP {(int)response.StatusCode}。");
            var json = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return LatestWindowsUpdate(json, current, includePrerelease);
        }
    }

    /// <summary>
    /// 纯解析：从 releases 列表 JSON 里挑出含 Windows 安装包、版本号最高且 &gt; current 的 release。
    /// 与网络解耦，便于测试。includePrerelease=false 时跳过 GitHub 标记为 prerelease 的 release
    /// 以及 tag 带预发布后缀（如 -beta）的 release（稳定通道）。
    /// </summary>
    public static UpdateInfo? LatestWindowsUpdate(string json, SemVer current, bool includePrerelease = true)
    {
        JsonElement root;
        try
        {
            root = JsonDocument.Parse(json).RootElement;
        }
        catch (JsonException)
        {
            return null;
        }
        if (root.ValueKind != JsonValueKind.Array) return null;

        UpdateInfo? newest = null;
        foreach (var release in root.EnumerateArray())
        {
            // 草稿跳过；预发布按通道过滤（稳定通道跳过 GitHub prerelease=true 或 tag 带 -beta 等后缀）。
            if (release.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) continue;
            var tag = StringProp(release, "tag_name") ?? StringProp(release, "name") ?? "";
            if (SemVer.Parse(tag) is not { } version) continue;
            var githubPrerelease = release.TryGetProperty("prerelease", out var pre)
                && pre.ValueKind == JsonValueKind.True;
            if (!includePrerelease && (githubPrerelease || version.IsPrerelease)) continue;
            var notes = StringProp(release, "body") ?? "";
            if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) continue;

            var releaseAssets = assets.EnumerateArray()
                .Select(asset => (
                    Name: StringProp(asset, "name"),
                    Url: StringProp(asset, "browser_download_url")))
                .Where(asset => asset.Name is not null && asset.Url is not null)
                .Select(asset => (Name: asset.Name!, Url: asset.Url!, LowerName: asset.Name!.ToLowerInvariant()))
                .ToList();

            foreach (var asset in releaseAssets)
            {
                // Windows 安装包：.exe 且名字含 "win" 或 "setup"。
                if (!asset.LowerName.EndsWith(".exe")
                    || (!asset.LowerName.Contains("win") && !asset.LowerName.Contains("setup"))) continue;
                if (!AssetNameMatchesVersion(asset.LowerName, version)) continue;
                var shaName = asset.Name + ".sha256";
                var shaAsset = releaseAssets.FirstOrDefault(candidate =>
                    string.Equals(candidate.Name, shaName, StringComparison.OrdinalIgnoreCase));
                if (shaAsset.Name is null || shaAsset.Url is null) continue;
                var candidate = new UpdateInfo(version, tag, notes, asset.Url, asset.Name, shaAsset.Url, shaAsset.Name);
                if (newest is null || candidate.Version > newest.Version) newest = candidate;
                break;
            }
        }
        return newest is not null && newest.Version > current ? newest : null;
    }

    private static string? StringProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public static bool AssetNameMatchesVersion(string assetName, SemVer version)
    {
        // 只比较核心 major.minor.patch：资产名通常不带 -beta 等通道后缀，
        // 通道由 GitHub release 的 prerelease 标记决定，不靠文件名。
        foreach (Match match in VersionTokenRegex.Matches(assetName))
        {
            if (SemVer.Parse(match.Value) is { } parsed
                && parsed.Major == version.Major
                && parsed.Minor == version.Minor
                && parsed.Patch == version.Patch) return true;
        }
        return false;
    }

    // MARK: 安装辅助（纯函数，跨平台可测）

    /// <summary>
    /// 只接受 GitHub 该仓库 releases 下载地址的 https .exe。
    /// SetupUrl 始终来自 GitHub API 的 browser_download_url（规范 github.com 地址），
    /// 下载时由 HttpClient 内部跟随 302 到 objects.githubusercontent.com 的令牌地址——
    /// 那一步对本函数不可见。之前对 CDN 任意路径无脑放行等于放空校验，且实际从不传入 CDN
    /// 地址，属危险死分支，已与 macOS UpdateChecker 一致地收紧。
    /// </summary>
    public static bool IsTrustedSetupUrl(string urlString, string owner, string repo)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url)) return false;
        if (!string.Equals(url.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return false;
        if (!string.Equals(url.Host, "github.com", StringComparison.OrdinalIgnoreCase)) return false;
        if (!url.AbsolutePath.ToLowerInvariant().EndsWith(".exe")) return false;
        return url.AbsolutePath.StartsWith($"/{owner}/{repo}/releases/download/", StringComparison.Ordinal);
    }

    public static bool IsTrustedSetupChecksumUrl(
        string urlString,
        string setupAssetName,
        string owner,
        string repo)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var url)) return false;
        if (!string.Equals(url.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return false;
        if (!string.Equals(url.Host, "github.com", StringComparison.OrdinalIgnoreCase)) return false;
        if (!url.AbsolutePath.StartsWith($"/{owner}/{repo}/releases/download/", StringComparison.Ordinal)) return false;
        var fileName = Uri.UnescapeDataString(Path.GetFileName(url.AbsolutePath));
        return string.Equals(fileName, setupAssetName + ".sha256", StringComparison.OrdinalIgnoreCase);
    }
}
