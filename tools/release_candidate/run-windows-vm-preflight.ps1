param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [string]$DestinationRoot = "$env:TEMP\moongate-v08-rc-preflight"
)

$ErrorActionPreference = "Stop"
$testFilter = "AsrContractsTests|WindowsSettingsSurfaceTests|QueueTests|SettingsTests|ReleaseSurfaceTests"

Write-Host "==> Moongate Windows VM preflight"
Write-Host "Source: $SourceRoot"
Write-Host "Destination: $DestinationRoot"

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    throw "SourceRoot does not exist: $SourceRoot"
}

$destinationLeaf = Split-Path -Leaf $DestinationRoot
if ($destinationLeaf -notlike "moongate-v08-*") {
    throw "DestinationRoot must end with a moongate-v08-* directory name: $DestinationRoot"
}

if (Test-Path -LiteralPath $DestinationRoot) {
    Remove-Item -LiteralPath $DestinationRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

$robocopyArgs = @(
    $SourceRoot,
    $DestinationRoot,
    "/MIR",
    "/XD", ".git", ".build", ".build-*", ".build-codex", ".swiftpm", ".agents", ".claude", ".codex", "artifacts", "bin", "obj",
    "/XF", ".DS_Store"
)

Write-Host "==> Mirroring repo into a Windows-local directory"
& robocopy @robocopyArgs | Write-Host
if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

Set-Location -LiteralPath $DestinationRoot

Write-Host "==> dotnet test windows\MoongateCore.Tests\MoongateCore.Tests.csproj"
dotnet test windows\MoongateCore.Tests\MoongateCore.Tests.csproj --filter $testFilter --nologo

Write-Host "==> dotnet build windows\MoongateApp\MoongateApp.csproj"
dotnet build windows\MoongateApp\MoongateApp.csproj --nologo

Write-Host "==> Windows VM preflight completed"
