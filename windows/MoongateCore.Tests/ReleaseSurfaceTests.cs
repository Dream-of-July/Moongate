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

    // Single source of truth for the release version surfaces. Bumping a release means changing
    // these two constants and running this test — every packaging/doc surface is asserted against
    // them, so a missed file fails loudly instead of shipping a split version (as 0.8.1 did).
    private const string ReleaseVersion = "0.8.2";
    private const string BuildNumber = "8201";

    [Fact]
    public void ReleaseVersionSurfacesAreConsistentAcrossMacAndWindows()
    {
        Assert.Contains($"VERSION=\"${{MOONGATE_VERSION:-{ReleaseVersion}}}\"", Read("build-windows.sh"));
        Assert.Contains($"VERSION=\"${{MOONGATE_VERSION:-{ReleaseVersion}}}\"", Read("make-dmg.sh"));
        Assert.Contains($"APP_VERSION=\"${{MOONGATE_VERSION:-{ReleaseVersion}}}\"", Read("build.sh"));
        Assert.Contains($"APP_BUILD_NUMBER=\"${{MOONGATE_BUILD_NUMBER:-{BuildNumber}}}\"", Read("build.sh"));
        Assert.Contains("<string>$APP_VERSION</string>", Read("build.sh"));
        Assert.Contains("<string>$APP_BUILD_NUMBER</string>", Read("build.sh"));
        Assert.Contains($"VERSION=\"${{MOONGATE_VERSION:-{ReleaseVersion}}}\"", Read("make-pkg.sh"));
        Assert.Contains($"VERSION=\"${{MOONGATE_VERSION:-{ReleaseVersion}}}\"", Read("make-sparkle-zip.sh"));
        Assert.Contains($"BUILD_NUMBER=\"${{MOONGATE_BUILD_NUMBER:-{BuildNumber}}}\"", Read("make-sparkle-zip.sh"));
        Assert.Contains($"VERSION=\"${{MOONGATE_VERSION:-{ReleaseVersion}}}\"", Read("make-appcast.sh"));
        Assert.Contains($"BUILD_NUMBER=\"${{MOONGATE_BUILD_NUMBER:-{BuildNumber}}}\"", Read("make-appcast.sh"));
        Assert.Contains("productbuild", Read("make-pkg.sh"));
        Assert.Contains("PKG_SIGN_IDENTITY", Read("make-pkg.sh"));
        Assert.Contains("INSTALL_DIR=\"$STAGING/Applications\"", Read("make-pkg.sh"));
        Assert.Contains("INSTALL_DIR=\"${INSTALL_DIR:-/Applications}\"", Read("build.sh"));
        Assert.Contains($"Moongate-macOS-v{ReleaseVersion}.zip", Read("README.md"));

        var workflow = Read(".github", "workflows", "windows-release.yml");
        Assert.Contains($"default: v{ReleaseVersion}", workflow);
        Assert.Contains($"default: {ReleaseVersion}", workflow);
        Assert.Contains("$expectedTag = \"v${{ inputs.version }}\"", workflow);
        Assert.Contains("Release tag/version mismatch", workflow);

        Assert.Contains($"!define APPVERSION \"{ReleaseVersion}\"", Read("windows", "installer", "installer.nsi"));

        // Prevent the 0.8.1-style split: the Sparkle build number must agree with build.sh.
        Assert.Contains($"BUILD_NUMBER=\"${{MOONGATE_BUILD_NUMBER:-{BuildNumber}}}\"", Read("make-sparkle-zip.sh"));
        Assert.Contains($"APP_BUILD_NUMBER=\"${{MOONGATE_BUILD_NUMBER:-{BuildNumber}}}\"", Read("build.sh"));

        // README badge + CHANGELOG section must track the release too.
        Assert.Contains($"version-{ReleaseVersion}-", Read("README.md"));
        Assert.Contains($"## {ReleaseVersion}", Read("CHANGELOG.md"));
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
    public void WindowsInstallerUpdateWaitContinuesWhenOpenProcessAlreadyExitedButAbortsOnTimeoutAndWaitFailure()
    {
        var installer = Read("windows", "installer", "installer.nsi");

        Assert.Contains("!define WAIT_OBJECT_0 0x00000000", installer);
        Assert.Contains("!define WAIT_TIMEOUT 0x00000102", installer);
        Assert.Contains("!define WAIT_FAILED 0xFFFFFFFF", installer);
        Assert.DoesNotContain("LangString UpdateWaitOpenFailed", installer);
        Assert.Contains("LangString UpdateWaitTimeout ${LANG_SIMPCHINESE}", installer);
        Assert.Contains("LangString UpdateWaitTimeout ${LANG_ENGLISH}", installer);
        Assert.Contains("LangString UpdateWaitTimeout ${LANG_TRADCHINESE}", installer);
        Assert.Contains("LangString UpdateWaitFailed ${LANG_SIMPCHINESE}", installer);
        Assert.Contains("LangString UpdateWaitFailed ${LANG_ENGLISH}", installer);
        Assert.Contains("LangString UpdateWaitFailed ${LANG_TRADCHINESE}", installer);
        Assert.Contains("System::Call 'kernel32::OpenProcess(i 0x00100000, i 0, i $R1) i .R2'", installer);
        Assert.Contains("System::Call 'kernel32::WaitForSingleObject(i $R2, i 15000) i .R3'", installer);
        Assert.Contains("${If} $R2 != 0", installer);
        Assert.DoesNotContain("MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitOpenFailed)\"", installer);
        Assert.Contains("${If} $R3 == ${WAIT_OBJECT_0}", installer);
        Assert.Contains("${ElseIf} $R3 == ${WAIT_TIMEOUT}", installer);
        Assert.Contains("${ElseIf} $R3 == ${WAIT_FAILED}", installer);
        Assert.Contains("MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitTimeout)\"", installer);
        Assert.Contains("MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitFailed)\"", installer);
        var installStart = installer.IndexOf("SetOutPath \"$INSTDIR\"", StringComparison.Ordinal);
        AssertAbortsBeforeInstall(installer, "MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitTimeout)\"", installStart);
        AssertAbortsBeforeInstall(installer, "MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitFailed)\"", installStart);
        Assert.True(
            installer.IndexOf("${If} $R2 != 0", StringComparison.Ordinal)
            < installer.IndexOf("WaitForSingleObject", StringComparison.Ordinal));
        Assert.True(
            installer.IndexOf("WaitForSingleObject", StringComparison.Ordinal)
            < installer.IndexOf("MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitTimeout)\"", StringComparison.Ordinal));
        Assert.True(
            installer.IndexOf("MessageBox MB_ICONSTOP|MB_OK \"$(UpdateWaitTimeout)\"", StringComparison.Ordinal)
            < installer.IndexOf("SetOutPath \"$INSTDIR\"", StringComparison.Ordinal));

        static void AssertAbortsBeforeInstall(string installer, string message, int installStart)
        {
            var messageIndex = installer.IndexOf(message, StringComparison.Ordinal);
            var abortIndex = installer.IndexOf("Abort", messageIndex, StringComparison.Ordinal);
            Assert.True(messageIndex >= 0);
            Assert.True(abortIndex > messageIndex);
            Assert.True(abortIndex < installStart);
        }
    }

    [Fact]
    public void WindowsUpdateInstallsSilentlyAndAutoRestartsAfterOverwrite()
    {
        var installer = Read("windows", "installer", "installer.nsi");
        var updateService = Read("windows", "MoongateApp", "UpdateService.cs");

        // App 触发的自动更新走静默安装（用户无需再点一遍安装向导）并带上当前 PID。
        Assert.Contains("/S /UPDATEPID=", updateService);
        // 安装器把「带 /UPDATEPID」记为更新安装，安装成功后在静默模式下自动重启 App（自动覆盖并重启）。
        Assert.Contains("Var UpdateRelaunch", installer);
        Assert.Contains("StrCpy $UpdateRelaunch \"1\"", installer);
        Assert.Contains("Function .onInstSuccess", installer);
        Assert.Contains("${If} $UpdateRelaunch == \"1\"", installer);
        Assert.Contains("${AndIf} ${Silent}", installer);
        Assert.Contains("Exec '\"$INSTDIR\\${EXENAME}\"'", installer);
        // UpdateRelaunch 仅在 /UPDATEPID 分支内置位：普通交互安装不自动重启（避免与 MUI_FINISHPAGE_RUN 双启动）。
        var updatePidBranch = installer.IndexOf("${GetOptions} $R0 \"/UPDATEPID=\" $R1", StringComparison.Ordinal);
        var relaunchSet = installer.IndexOf("StrCpy $UpdateRelaunch \"1\"", StringComparison.Ordinal);
        Assert.True(updatePidBranch >= 0 && relaunchSet > updatePidBranch);
    }

    [Fact]
    public void ContinuousCiCoversPrPushSwiftWindowsAndSubtitleEvalWithoutAsrModelDownloads()
    {
        var workflow = Read(".github", "workflows", "ci.yml");

        Assert.Contains("name: CI", workflow);
        Assert.Contains("pull_request:", workflow);
        Assert.Contains("push:", workflow);
        Assert.Contains("- master", workflow);
        Assert.Contains("permissions:", workflow);
        Assert.Contains("contents: read", workflow);

        Assert.Contains("runs-on: macos-15", workflow);
        Assert.Contains("run: swift test", workflow);
        Assert.Contains("run: swift build", workflow);

        Assert.Contains("runs-on: windows-latest", workflow);
        Assert.Contains("uses: actions/setup-dotnet@v4", workflow);
        Assert.Contains("dotnet-version: 10.0.x", workflow);
        Assert.Contains("dotnet test windows/Moongate.Win.sln", workflow);
        Assert.Contains("dotnet publish windows/MoongateApp/MoongateApp.csproj", workflow);
        Assert.Contains("-p:Version=\"0.0.0-ci\"", workflow);
        Assert.Contains("Moongate.exe", workflow);

        Assert.Contains("runs-on: ubuntu-latest", workflow);
        Assert.Contains("uses: actions/setup-python@v5", workflow);
        Assert.Contains("python-version: \"3.12\"", workflow);
        Assert.Contains("PYTHONPATH: tools/subtitle_timing_eval", workflow);
        Assert.Contains("python -m unittest discover -s tools/subtitle_timing_eval/tests", workflow);

        Assert.DoesNotContain("huggingface.co", workflow, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("ggml-", workflow, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("whisper.cpp/resolve", workflow, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("MOONGATE_WHISPER_CPP_RUNTIME_DIR", workflow, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void WhisperCppRuntimePackagingIsOptInAndUsesManagedRuntimeDirectories()
    {
        var macBuild = Read("build.sh");
        var winBuild = Read("build-windows.sh");
        var workflow = Read(".github", "workflows", "windows-release.yml");

        Assert.Contains("MOONGATE_WHISPER_CPP_RUNTIME_DIR", macBuild);
        Assert.Contains("Contents/Resources/asr/runtime", macBuild);
        Assert.Contains("whisper-cli", macBuild);
        Assert.Contains("ditto \"$MOONGATE_WHISPER_CPP_RUNTIME_DIR\"", macBuild);
        Assert.DoesNotContain("huggingface.co", macBuild, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("git clone", macBuild, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("curl ", macBuild, StringComparison.OrdinalIgnoreCase);

        Assert.Contains("MOONGATE_WHISPER_CPP_RUNTIME_DIR", winBuild);
        Assert.Contains("$PUBLISH_DIR/asr/runtime", winBuild);
        Assert.Contains("whisper-cli.exe", winBuild);
        Assert.Contains("cp -R \"$MOONGATE_WHISPER_CPP_RUNTIME_DIR\"", winBuild);
        Assert.DoesNotContain("huggingface.co", winBuild, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("git clone", winBuild, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("curl ", winBuild, StringComparison.OrdinalIgnoreCase);

        Assert.DoesNotContain("MOONGATE_WHISPER_CPP_RUNTIME_DIR", workflow, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("whisper.cpp/releases", workflow, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void WhisperCppRuntimePackagingWritesValidatedBundleManifest()
    {
        var macBuild = Read("build.sh");
        var winBuild = Read("build-windows.sh");

        Assert.Contains("asr-runtime-manifest.json", macBuild);
        Assert.Contains("\"platform\": \"macos\"", macBuild);
        Assert.Contains("\"architecture\": \"$runtime_arch\"", macBuild);
        Assert.Contains("\"executableRelativePath\": \"whisper-cli\"", macBuild);
        Assert.Contains("shasum -a 256 \"$runtime_dst/whisper-cli\"", macBuild);
        Assert.True(
            macBuild.IndexOf("ditto \"$MOONGATE_WHISPER_CPP_RUNTIME_DIR\" \"$runtime_dst\"", StringComparison.Ordinal)
            < macBuild.IndexOf("asr-runtime-manifest.json", StringComparison.Ordinal));

        Assert.Contains("asr-runtime-manifest.json", winBuild);
        Assert.Contains("\"platform\": \"windows\"", winBuild);
        Assert.Contains("\"architecture\": \"x64\"", winBuild);
        Assert.Contains("\"executableRelativePath\": \"whisper-cli.exe\"", winBuild);
        Assert.Contains("shasum -a 256 \"$PUBLISH_DIR/asr/runtime/whisper-cli.exe\"", winBuild);
        Assert.True(
            winBuild.IndexOf("cp -R \"$MOONGATE_WHISPER_CPP_RUNTIME_DIR\"/. \"$PUBLISH_DIR/asr/runtime/\"", StringComparison.Ordinal)
            < winBuild.IndexOf("asr-runtime-manifest.json", StringComparison.Ordinal));

        Assert.DoesNotContain("\"downloadUrl\"", macBuild, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"downloadUrl\"", winBuild, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LocalAsrRealRuntimeSmokeIsExplicitOptInAndNeverDownloadsModelsOrRuntimes()
    {
        var scriptPath = Path.Combine(RepoRoot(), "tools", "local_asr_smoke", "run-local-asr-smoke.sh");
        var readmePath = Path.Combine(RepoRoot(), "tools", "local_asr_smoke", "README.md");
        Assert.True(File.Exists(scriptPath), "Expected a manual local ASR smoke script.");
        Assert.True(File.Exists(readmePath), "Expected local ASR smoke runbook documentation.");

        var script = File.ReadAllText(scriptPath);
        var readme = File.ReadAllText(readmePath);
        var workflow = Read(".github", "workflows", "ci.yml");

        Assert.Contains("MOONGATE_ASR_QA_RUN=1", script);
        Assert.Contains("MOONGATE_ASR_QA_RUNTIME_DIR", script);
        Assert.Contains("MOONGATE_ASR_QA_WHISPER_CLI", script);
        Assert.Contains("MOONGATE_ASR_QA_MODEL", script);
        Assert.Contains("MOONGATE_ASR_QA_AUDIO", script);
        Assert.Contains("MOONGATE_ASR_QA_FFMPEG", script);
        Assert.Contains("asr-runtime-manifest.json", script);
        Assert.Contains("executableRelativePath", script);
        Assert.Contains("sha256", script);
        Assert.Contains("hashlib.sha256", script);
        Assert.Contains("-ar 16000", script);
        Assert.Contains("-ac 1", script);
        Assert.Contains("-c:a pcm_s16le", script);
        Assert.Contains("-ojf", script);
        Assert.Contains("-of", script);
        Assert.Contains("--prompt", script);
        Assert.Contains(".local-asr.${language}.srt", script);
        Assert.Contains("strictly manual", readme, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("MOONGATE_ASR_QA_RUNTIME_DIR", readme);
        Assert.Contains("packaged runtime manifest", readme, StringComparison.OrdinalIgnoreCase);

        foreach (var forbidden in new[] { "curl ", "wget ", "git clone", "Invoke-WebRequest", "huggingface.co", "whisper.cpp/resolve", "ggml-" })
        {
            Assert.DoesNotContain(forbidden, script, StringComparison.OrdinalIgnoreCase);
        }

        Assert.DoesNotContain("local_asr_smoke", workflow, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("MOONGATE_ASR_QA_", workflow, StringComparison.OrdinalIgnoreCase);
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
        Assert.Contains($"Moongate-Windows-Setup-v{ReleaseVersion}.exe", docs);
        Assert.Contains($"Moongate-Windows-Setup-v{ReleaseVersion}.exe", readme);
    }

    [Fact]
    public void ReleaseCandidatePreflightRunsLocalGatesAndKeepsVmAndRealAsrOptIn()
    {
        var preflightPath = Path.Combine(RepoRoot(), "tools", "release_candidate", "run-preflight.sh");
        var vmPreflightPath = Path.Combine(RepoRoot(), "tools", "release_candidate", "run-windows-vm-preflight.ps1");

        Assert.True(File.Exists(preflightPath), "Expected a v0.8 release-candidate preflight script.");
        Assert.True(File.Exists(vmPreflightPath), "Expected a Windows VM preflight helper.");

        var preflight = File.ReadAllText(preflightPath);
        var vmPreflight = File.ReadAllText(vmPreflightPath);

        Assert.Contains(ReleaseVersion, preflight);
        Assert.Contains("PROJ_DIR=\"${0:a:h:h:h}\"", preflight);
        Assert.Contains("git diff --check", preflight);
        Assert.Contains("python3 -m unittest discover -s tools/subtitle_timing_eval/tests", preflight);
        Assert.Contains("swift test", preflight);
        Assert.Contains("ASRContractsTests|MacOSContentBoundaryTests|MacOSViewModelBoundaryTests", preflight);
        Assert.Contains("MacOSQueueBoundaryTests|MacOSSettingsBoundaryTests|LocalizerTests|QueueProgressTests", preflight);
        Assert.Contains("EngineProgressTests|HDRSupportTests", preflight);
        Assert.Contains("dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj", preflight);
        Assert.Contains("AsrContractsTests|WindowsSettingsSurfaceTests|QueueTests|SettingsTests|ReleaseSurfaceTests", preflight);
        Assert.Contains("zsh -n build.sh build-windows.sh make-dmg.sh make-pkg.sh make-sparkle-zip.sh make-appcast.sh tools/local_asr_smoke/run-local-asr-smoke.sh", preflight);
        Assert.Contains("MOONGATE_RC_INCLUDE_VM", preflight);
        Assert.Contains("prlctl exec", preflight);
        Assert.Contains("--current-user", preflight);
        Assert.Contains("run-windows-vm-preflight.ps1", preflight);

        Assert.Contains("robocopy", vmPreflight, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("dotnet test windows\\MoongateCore.Tests\\MoongateCore.Tests.csproj", vmPreflight);
        Assert.Contains("dotnet build windows\\MoongateApp\\MoongateApp.csproj", vmPreflight);
        Assert.Contains("AsrContractsTests|WindowsSettingsSurfaceTests|QueueTests|SettingsTests|ReleaseSurfaceTests", vmPreflight);

        Assert.DoesNotContain("MOONGATE_ASR_QA_RUN=1", preflight, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("huggingface.co", preflight, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("whisper.cpp/resolve", preflight, StringComparison.OrdinalIgnoreCase);
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
    public void WindowsDocsDoNotCiteAStaleAbsoluteTestCount()
    {
        // The docs used to hardcode "470 unit tests", which drifted to ~764. Rather than chase a
        // brittle number on every test addition, the docs now describe the suite qualitatively.
        // Guard against regressing to any stale absolute count.
        var docs = Read("docs", "WINDOWS.md");

        Assert.Contains("mirrored unit-test suite", docs);
        foreach (var stale in new[] { "470", "414", "413", "412", "409", "392", "271", "247", "241", "240", "232", "225", "217", "144" })
        {
            Assert.DoesNotContain($"{stale} unit tests", docs);
        }
    }
}
