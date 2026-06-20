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
    public void ReleaseVersionSurfacesUse076ForMacAndWindows()
    {
        Assert.Contains("VERSION=\"0.7.6\"", Read("build-windows.sh"));
        Assert.Contains("VERSION=\"${MOONGATE_VERSION:-0.7.6}\"", Read("make-dmg.sh"));
        Assert.Contains("APP_VERSION=\"${MOONGATE_VERSION:-0.7.6}\"", Read("build.sh"));
        Assert.Contains("APP_BUILD_NUMBER=\"${MOONGATE_BUILD_NUMBER:-706}\"", Read("build.sh"));
        Assert.Contains("<string>$APP_VERSION</string>", Read("build.sh"));
        Assert.Contains("<string>$APP_BUILD_NUMBER</string>", Read("build.sh"));
        Assert.Contains("VERSION=\"${MOONGATE_VERSION:-0.7.6}\"", Read("make-pkg.sh"));
        Assert.Contains("VERSION=\"${MOONGATE_VERSION:-0.7.6}\"", Read("make-sparkle-zip.sh"));
        Assert.Contains("VERSION=\"${MOONGATE_VERSION:-0.7.6}\"", Read("make-appcast.sh"));
        Assert.Contains("productbuild", Read("make-pkg.sh"));
        Assert.Contains("PKG_SIGN_IDENTITY", Read("make-pkg.sh"));
        Assert.Contains("INSTALL_DIR=\"$STAGING/Applications\"", Read("make-pkg.sh"));
        Assert.Contains("INSTALL_DIR=\"${INSTALL_DIR:-/Applications}\"", Read("build.sh"));
        Assert.Contains("Moongate-macOS-v0.7.6.zip", Read("README.md"));

        var workflow = Read(".github", "workflows", "windows-release.yml");
        Assert.Contains("default: v0.7.6", workflow);
        Assert.Contains("default: 0.7.6", workflow);
        Assert.Contains("$expectedTag = \"v${{ inputs.version }}\"", workflow);
        Assert.Contains("Release tag/version mismatch", workflow);

        Assert.Contains("!define APPVERSION \"0.7.6\"", Read("windows", "installer", "installer.nsi"));
    }

    [Fact]
    public void MacSparkleReleaseSurfaceUsesZipAppcastAndPublicKey()
    {
        var package = Read("Package.swift");
        var build = Read("build.sh");
        var zip = Read("make-sparkle-zip.sh");
        var appcast = Read("make-appcast.sh");
        var publicKey = Read("sparkle-public-ed-key.txt").Trim();
        var readme = Read("README.md");
        var changelog = Read("CHANGELOG.md");

        Assert.Contains("https://github.com/sparkle-project/Sparkle", package);
        Assert.Contains(".product(name: \"Sparkle\", package: \"Sparkle\")", package);
        Assert.Contains("Sparkle.framework", build);
        Assert.Contains("SUFeedURL", build);
        Assert.Contains("https://dream-of-july.github.io/moongate/appcast.xml", build);
        Assert.Contains("SUPublicEDKey", build);
        Assert.Contains("SUAutomaticallyUpdate", build);
        Assert.Contains("ditto -c -k --sequesterRsrc --keepParent", zip);
        Assert.Contains("sign_update", appcast);
        Assert.Contains("sparkle:edSignature", appcast);
        Assert.Contains("docs/appcast.xml", appcast);
        Assert.Equal(44, publicKey.Length);
        Assert.Contains("Sparkle", readme);
        Assert.Contains("make-sparkle-zip.sh", readme);
        Assert.Contains("Sparkle", changelog);
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
        Assert.Contains("Delete /REBOOTOK \"$INSTDIR\\Uninstall.exe\"", installer);
        Assert.Contains("RMDir /REBOOTOK \"$INSTDIR\"", installer);
    }

    [Fact]
    public void WindowsSilentUninstallKeepsUserDataByDefault()
    {
        var installer = Read("windows", "installer", "installer.nsi");

        Assert.Contains("MessageBox MB_YESNO|MB_ICONQUESTION \"$(DataPrompt)\" /SD IDNO IDNO keepUserData", installer);
        Assert.True(
            installer.IndexOf("/SD IDNO IDNO keepUserData", StringComparison.Ordinal)
            < installer.IndexOf("RMDir /r \"$APPDATA\\Moongate\"", StringComparison.Ordinal));
        Assert.True(
            installer.IndexOf("/SD IDNO IDNO keepUserData", StringComparison.Ordinal)
            < installer.IndexOf("RMDir /r \"$LOCALAPPDATA\\Moongate\"", StringComparison.Ordinal));
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
    public void WindowsSettingsUsesSharedThrottledUpdater()
    {
        var app = Read("windows", "MoongateApp", "App.xaml.cs");
        var settings = Read("windows", "MoongateApp", "SettingsWindow.xaml.cs");
        var updateService = Read("windows", "MoongateApp", "UpdateService.cs");

        Assert.Contains("public static UpdateService WindowsUpdater { get; } = new();", app);
        Assert.Contains("Updater = App.WindowsUpdater;", settings);
        Assert.DoesNotContain("public UpdateService Updater { get; } = new();", settings);
        Assert.Contains("Updater.CheckAutomaticSilent();", settings);
        Assert.Contains("ShouldRunAutomaticCheck", updateService);
        Assert.Contains("TimeSpan.FromHours(6)", updateService);
    }

    [Fact]
    public void WindowsReleaseArtifactsUseVersionedNamesAndChecksums()
    {
        var localScript = Read("build-windows.sh");
        var workflow = Read(".github", "workflows", "windows-release.yml");
        var docs = Read("docs", "WINDOWS.md");
        var readme = Read("README.md");

        Assert.Contains("Moongate-Windows-Setup-v$VERSION.exe", localScript);
        Assert.Contains("Moongate-Windows-Setup-v${{ inputs.version }}.exe", workflow);
        Assert.Contains("$outFile.sha256", workflow);
        Assert.Contains("$OUT.sha256", localScript);
        Assert.Contains("Moongate-Windows-Setup-v0.7.6.exe", docs);
        Assert.Contains("Moongate-Windows-Setup-v0.7.6.exe", readme);
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

        Assert.Contains("470", docs);
        Assert.DoesNotContain("414", docs);
        Assert.DoesNotContain("413", docs);
        Assert.DoesNotContain("412", docs);
        Assert.DoesNotContain("409", docs);
        Assert.DoesNotContain("392", docs);
        Assert.DoesNotContain("271", docs);
        Assert.DoesNotContain("247", docs);
        Assert.DoesNotContain("241", docs);
        Assert.DoesNotContain("240", docs);
        Assert.DoesNotContain("232", docs);
        Assert.DoesNotContain("225", docs);
        Assert.DoesNotContain("217", docs);
        Assert.DoesNotContain("144", docs);
    }
}
