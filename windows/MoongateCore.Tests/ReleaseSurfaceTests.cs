namespace MoongateCore.Tests;

public class ReleaseSurfaceTests
{
    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Package.swift"))
                && Directory.Exists(Path.Combine(dir.FullName, "windows")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("Could not locate repository root.");
    }

    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([RepoRoot(), .. parts]));

    [Fact]
    public void ReleaseVersionSurfacesUse061()
    {
        Assert.Contains("VERSION=\"0.6.1\"", Read("build-windows.sh"));
        Assert.Contains("<string>0.6.1</string>", Read("build.sh"));

        var workflow = Read(".github", "workflows", "windows-release.yml");
        Assert.Contains("default: v0.6.1", workflow);
        Assert.Contains("default: 0.6.1", workflow);
        Assert.Contains("$expectedTag = \"v${{ inputs.version }}\"", workflow);
        Assert.Contains("Release tag/version mismatch", workflow);

        Assert.Contains("!define APPVERSION \"0.6.1\"", Read("windows", "installer", "installer.nsi"));
    }

    [Fact]
    public void WindowsInstallerIconPathIsPortableForLocalNsis()
    {
        var installer = Read("windows", "installer", "installer.nsi");

        Assert.Contains("!define ICON_PATH \"windows/assets/app-nsis.ico\"", installer);
        Assert.Contains("!define MUI_ICON \"${ICON_PATH}\"", installer);
        Assert.Contains("!define MUI_UNICON \"${ICON_PATH}\"", installer);
        Assert.True(File.Exists(Path.Combine(RepoRoot(), "windows", "assets", "app-nsis.ico")));
        Assert.Contains("-DICON_PATH=\"$WIN_DIR/assets/app-nsis.ico\"", Read("build-windows.sh"));
        Assert.Contains("/DICON_PATH=$iconPath", Read(".github", "workflows", "windows-release.yml"));
    }

    [Fact]
    public void WindowsInstallerDoesNotOfferRecursiveCustomInstallDirectoryRemoval()
    {
        var installer = Read("windows", "installer", "installer.nsi");

        Assert.DoesNotContain("MUI_PAGE_DIRECTORY", installer);
        Assert.Contains("!define INSTALL_MARKER", installer);
        Assert.Contains("IfFileExists \"$INSTDIR\\${INSTALL_MARKER}\"", installer);
        Assert.Contains("StrCmp \"$INSTDIR\" \"$LOCALAPPDATA\\Programs\\${APPNAME}\"", installer);
        Assert.Contains("skipRecursiveRemove", installer);
    }

    [Fact]
    public void WindowsStartupGuardsAgainstSilentWhiteScreen()
    {
        var app = Read("windows", "MoongateApp", "App.xaml.cs");

        // 启动期建窗失败必须显式退出，而不是被吞成「进程活着但没有窗口」的白屏。
        Assert.Contains("new MainWindow()", app);
        Assert.Contains("Shutdown(1)", app);
        Assert.True(
            app.IndexOf("new MainWindow()", StringComparison.Ordinal)
            < app.IndexOf("Shutdown(1)", StringComparison.Ordinal),
            "建主窗口必须在 try 块内，失败走 Shutdown 兜底");

        // 硬件渲染初始化失败（部分显卡/远程桌面/虚拟机）时回退软件渲染，规避白屏。
        Assert.Contains("RenderCapability.Tier", app);
        Assert.Contains("RenderMode.SoftwareOnly", app);
        Assert.Contains("MOONGATE_SOFTWARE_RENDER", app);

        // 启动诊断日志：让只在部分机器复现的白屏可被用户回传排查。
        var diag = Read("windows", "MoongateApp", "StartupDiagnostics.cs");
        Assert.Contains("startup.log", diag);
        Assert.Contains("RecordException", diag);
    }

    [Fact]
    public void WindowsUpdaterValidatesDownloadedInstallerVersionBeforeLaunch()
    {
        var source = Read("windows", "MoongateApp", "UpdateService.cs");

        Assert.Contains("InstallerNameMatchesVersion(installerPath, info.Version)", source);
        Assert.Contains("throw MoongateException.DownloadFailed", source);
        Assert.True(
            source.IndexOf("InstallerNameMatchesVersion(installerPath, info.Version)", StringComparison.Ordinal)
            < source.IndexOf("Process.Start(new ProcessStartInfo(installerPath)", StringComparison.Ordinal));
        Assert.Contains("DownloadSha256Async(info.Sha256Url", source);
        Assert.Contains("FileSha256Matches(installerPath, expectedSha256)", source);
        Assert.True(
            source.IndexOf("FileSha256Matches(installerPath, expectedSha256)", StringComparison.Ordinal)
            < source.IndexOf("Process.Start(new ProcessStartInfo(installerPath)", StringComparison.Ordinal));
    }

    [Fact]
    public void WindowsReleaseArtifactsUseVersionedNamesAndChecksums()
    {
        var localScript = Read("build-windows.sh");
        var workflow = Read(".github", "workflows", "windows-release.yml");
        var docs = Read("docs", "WINDOWS.md");
        var readme = Read("README.md");

        Assert.Contains("月之门-Windows-Setup-v$VERSION.exe", localScript);
        Assert.Contains("月之门-Windows-Setup-v${{ inputs.version }}.exe", workflow);
        Assert.Contains("$outFile.sha256", workflow);
        Assert.Contains("$OUT.sha256", localScript);
        Assert.Contains("月之门-Windows-Setup-v0.6.1.exe", docs);
        Assert.Contains("月之门-Windows-Setup-v0.6.1.exe", readme);
    }

    [Fact]
    public void ReadmeUsesPublishedCliProductName()
    {
        var readme = Read("README.md");

        Assert.Contains("moongate-cli", readme);
        Assert.Contains("Sources/moongate-cli/", readme);
        Assert.DoesNotContain("vdl-cli", readme);
    }

    [Fact]
    public void WindowsDocumentedTestCountMatchesCurrentSuite()
    {
        var docs = Read("docs", "WINDOWS.md");

        Assert.Contains("242", docs);
        Assert.DoesNotContain("241", docs);
        Assert.DoesNotContain("240", docs);
        Assert.DoesNotContain("232", docs);
        Assert.DoesNotContain("225", docs);
        Assert.DoesNotContain("217", docs);
        Assert.DoesNotContain("144", docs);
    }
}
