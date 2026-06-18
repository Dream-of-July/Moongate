using System.IO.Compression;
using System.Net;
using System.Text;
using Moongate.Core;

namespace MoongateCore.Tests;

public class DependencyPlanTests : IDisposable
{
    private readonly string _binDir;

    public DependencyPlanTests()
    {
        _binDir = Path.Combine(Path.GetTempPath(), $"moongate-bin-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_binDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_binDir, true); } catch { /* 忽略 */ }
    }

    private void Touch(string fileName) =>
        File.WriteAllText(Path.Combine(_binDir, fileName), "stub");

    [Fact]
    public void EmptyDirectory_PlansAllThreeDownloads()
    {
        var plans = DependencyManager.PlanMissing(_binDir);
        Assert.Equal(3, plans.Count);
        Assert.Equal(new[] { "yt-dlp", "ffmpeg", "deno" }, plans.Select(p => p.Name).ToArray());

        var ytdlp = plans[0];
        Assert.Equal(DependencyDownload.DownloadKind.Executable, ytdlp.Kind);
        Assert.Equal("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe", ytdlp.Url);

        var ffmpeg = plans[1];
        Assert.Equal(DependencyDownload.DownloadKind.Zip, ffmpeg.Kind);
        Assert.Contains("BtbN/FFmpeg-Builds", ffmpeg.Url);
        Assert.Equal(2, ffmpeg.ZipEntries.Count);
        Assert.Equal("ffmpeg.exe", ffmpeg.ZipEntries["bin/ffmpeg.exe"]);
        Assert.Equal("ffprobe.exe", ffmpeg.ZipEntries["bin/ffprobe.exe"]);

        var deno = plans[2];
        Assert.Equal(DependencyDownload.DownloadKind.Zip, deno.Kind);
        Assert.Contains("denoland/deno", deno.Url);
    }

    [Fact]
    public void AllPresent_NoPlans()
    {
        foreach (var file in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe" })
        {
            Touch(file);
        }
        Assert.Empty(DependencyManager.PlanMissing(_binDir));
    }

    /// <summary>ffmpeg/ffprobe 同包：任一缺失都重下整个 zip。</summary>
    [Fact]
    public void FfprobeMissing_PlansFfmpegZip()
    {
        Touch("yt-dlp.exe");
        Touch("ffmpeg.exe");
        Touch("deno.exe");
        var plans = DependencyManager.PlanMissing(_binDir);
        var plan = Assert.Single(plans);
        Assert.Equal("ffmpeg", plan.Name);
    }

    [Fact]
    public void OnlyYtDlpMissing_PlansSingleExecutable()
    {
        Touch("ffmpeg.exe");
        Touch("ffprobe.exe");
        Touch("deno.exe");
        var plans = DependencyManager.PlanMissing(_binDir);
        var plan = Assert.Single(plans);
        Assert.Equal("yt-dlp", plan.Name);
        Assert.Equal(DependencyDownload.DownloadKind.Executable, plan.Kind);
    }
}

public class ZipExtractionTests : IDisposable
{
    private readonly string _binDir;

    public ZipExtractionTests()
    {
        _binDir = Path.Combine(Path.GetTempPath(), $"moongate-zip-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_binDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_binDir, true); } catch { /* 忽略 */ }
    }

    private static MemoryStream BuildZip(params (string EntryName, string Content)[] entries)
    {
        var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, content) in entries)
            {
                var entry = archive.CreateEntry(name);
                using var writer = new StreamWriter(entry.Open(), Encoding.UTF8);
                writer.Write(content);
            }
        }
        stream.Position = 0;
        return stream;
    }

    /// <summary>BtbN zip 顶层带版本号目录：按 entry 后缀匹配提取。</summary>
    [Fact]
    public void ExtractsBySuffix_IntoBinDirectory()
    {
        using var zip = BuildZip(
            ("ffmpeg-master-latest-win64-gpl/README.txt", "readme"),
            ("ffmpeg-master-latest-win64-gpl/bin/ffmpeg.exe", "FFMPEG_BINARY"),
            ("ffmpeg-master-latest-win64-gpl/bin/ffprobe.exe", "FFPROBE_BINARY"));

        DependencyManager.ExtractZipEntries(zip, new Dictionary<string, string>
        {
            ["bin/ffmpeg.exe"] = "ffmpeg.exe",
            ["bin/ffprobe.exe"] = "ffprobe.exe",
        }, _binDir);

        Assert.Equal("FFMPEG_BINARY", File.ReadAllText(Path.Combine(_binDir, "ffmpeg.exe")));
        Assert.Equal("FFPROBE_BINARY", File.ReadAllText(Path.Combine(_binDir, "ffprobe.exe")));
        // 不提取无关条目，也不残留临时文件
        Assert.Equal(2, Directory.GetFiles(_binDir).Length);
    }

    [Fact]
    public void TopLevelEntry_DenoStyle_Extracted()
    {
        using var zip = BuildZip(("deno.exe", "DENO_BINARY"));
        DependencyManager.ExtractZipEntries(zip, new Dictionary<string, string>
        {
            ["deno.exe"] = "deno.exe",
        }, _binDir);
        Assert.Equal("DENO_BINARY", File.ReadAllText(Path.Combine(_binDir, "deno.exe")));
    }

    [Fact]
    public void MissingExpectedEntry_Throws()
    {
        using var zip = BuildZip(("readme.txt", "x"));
        Assert.Throws<InvalidDataException>(() =>
            DependencyManager.ExtractZipEntries(zip, new Dictionary<string, string>
            {
                ["bin/ffmpeg.exe"] = "ffmpeg.exe",
            }, _binDir));
    }
}

/// <summary>「重新下载依赖」事务化：先下后换，失败不破坏现有可用文件。</summary>
public class RedownloadTransactionTests : IDisposable
{
    private readonly string _binDir;

    public RedownloadTransactionTests()
    {
        _binDir = Path.Combine(Path.GetTempPath(), $"moongate-redl-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_binDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_binDir, true); } catch { /* 忽略 */ }
    }

    [Fact]
    public void PlanAll_ReturnsAllThree_RegardlessOfExisting()
    {
        foreach (var file in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe" })
        {
            File.WriteAllText(Path.Combine(_binDir, file), "OLD");
        }
        var manager = new DependencyManager(_binDir, new FailingHandler());
        var plans = manager.PlanAll();
        Assert.Equal(new[] { "yt-dlp", "ffmpeg", "deno" }, plans.Select(p => p.Name).ToArray());
    }

    [Fact]
    public async Task RedownloadAll_NetworkFailure_KeepsExistingBinaries()
    {
        // 现有可用环境。
        foreach (var file in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe" })
        {
            File.WriteAllText(Path.Combine(_binDir, file), "OLD");
        }
        var manager = new DependencyManager(_binDir, new FailingHandler());

        await Assert.ThrowsAnyAsync<Exception>(() => manager.RedownloadAllAsync());

        // 关键回归：旧实现会先删后下、断网即破坏环境；新实现先下后换，失败时旧文件原样保留。
        foreach (var file in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe" })
        {
            Assert.True(File.Exists(Path.Combine(_binDir, file)), $"{file} 应仍存在");
            Assert.Equal("OLD", File.ReadAllText(Path.Combine(_binDir, file)));
        }
        // 失败不残留 .tmp 临时文件。
        Assert.Empty(Directory.GetFiles(_binDir, "*.tmp"));
    }

    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(512, "512 B")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(5 * 1024 * 1024, "5.0 MB")]
    public void FormatBytes_HumanReadable(long bytes, string expected)
    {
        Assert.Equal(expected, DependencyManager.FormatBytes(bytes));
    }

    // DEP-SUPPLY-001：下载完整性校验（长度 + SHA-256）。
    [Fact]
    public void VerifyDownloadIntegrity_LengthMismatch_Throws()
    {
        var path = Path.Combine(_binDir, "f.bin");
        File.WriteAllText(path, "abc"); // 3 字节
        // 期望 10 字节 → 截断 → 抛错。
        Assert.Throws<IOException>(() =>
            DependencyManager.VerifyDownloadIntegrity("yt-dlp", path, expectedLength: 10, expectedSha256: null));
        // 长度匹配、无 sha256 → 通过。
        DependencyManager.VerifyDownloadIntegrity("yt-dlp", path, expectedLength: 3, expectedSha256: null);
    }

    [Fact]
    public void VerifyDownloadIntegrity_Sha256_MatchAndMismatch()
    {
        var path = Path.Combine(_binDir, "g.bin");
        File.WriteAllText(path, "hello");
        var good = DependencyManager.FileSha256Hex(path);
        // 正确哈希 → 通过。
        DependencyManager.VerifyDownloadIntegrity("ffmpeg", path, expectedLength: null, expectedSha256: good);
        // 大小写无关。
        DependencyManager.VerifyDownloadIntegrity("ffmpeg", path, expectedLength: null, expectedSha256: good.ToUpperInvariant());
        // 错误哈希 → 拒绝安装。
        Assert.Throws<IOException>(() =>
            DependencyManager.VerifyDownloadIntegrity("ffmpeg", path, expectedLength: null,
                expectedSha256: new string('0', 64)));
    }

    [Fact]
    public void FileSha256Hex_KnownValue()
    {
        var path = Path.Combine(_binDir, "h.bin");
        File.WriteAllText(path, "abc");
        // SHA-256("abc") 已知向量。
        Assert.Equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            DependencyManager.FileSha256Hex(path));
    }

    /// <summary>所有请求都失败的 handler（模拟断网/代理失败）。</summary>
    private sealed class FailingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)
            {
                Content = new StringContent(""),
            });
    }
}
