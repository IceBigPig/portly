#requires -Version 7.2
# Runs the real installer and application on an ephemeral Windows CI runner.
# It never opens a port, sends data, or interacts with external hardware.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [string]$ReportPath = '',
    [ValidateRange(5, 180)][int]$StartupTimeoutSeconds = 45,
    [ValidateRange(5, 180)][int]$ExitTimeoutSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Installer smoke tests require a real Windows runner.' }
if (-not $env:RUNNER_TEMP -or ($env:GITHUB_ACTIONS -ne 'true' -and $env:CI -ne 'true')) {
    throw 'Run this installer smoke test only on an ephemeral Windows CI runner with RUNNER_TEMP set.'
}
$osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$processArch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($osArch -ne $Architecture -or $processArch -ne $Architecture) { throw "Native $Architecture Windows and PowerShell are required." }
$Installer = (Resolve-Path -LiteralPath $Installer).Path
Import-Module (Join-Path $PSScriptRoot 'PortlyPackaging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PortlyCrashDiagnostics.psm1') -Force
$runRoot = Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) ("portly-install-smoke-" + [guid]::NewGuid().ToString('N'))
$installDir = Join-Path $runRoot 'installed'
New-Item -ItemType Directory -Path $runRoot | Out-Null
if (-not $ReportPath) { $ReportPath = Join-Path $runRoot 'result.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$reportDirectory = Split-Path $ReportPath -Parent
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\Portly.SerialDebugger_is1'
if (Get-Process -Name 'portly' -ErrorAction SilentlyContinue) { throw 'An existing Portly process is running; use a clean CI runner.' }
foreach ($hive in @('HKCU:', 'HKLM:')) {
    foreach ($key in @("$hive\$uninstallKey", "$hive\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Portly.SerialDebugger_is1")) {
        if (Test-Path -LiteralPath $key) { throw "Existing Portly installation found; smoke test will not alter it: $key" }
    }
}
# path_provider_windows uses the stable VERSIONINFO CompanyName/ProductName.
# Do not change those fields to rebrand the app: doing so loses existing data.
$supportDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)) 'com.haike/portly'
if (Test-Path -LiteralPath $supportDir) { throw "Existing Portly data found; use a clean CI account: $supportDir" }
$report = [ordered]@{
    architecture = $Architecture; startedUtc = [DateTime]::UtcNow.ToString('o')
    installerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
    installed = $false; nativePayloadVerified = $false; windowCreated = $false
    gracefulExit = $false; databaseClosed = $false; uninstalled = $false; userDataPreserved = $false
    passed = $false; forcedCleanup = $false; error = $null
    scope = 'Real installer/startup/window/graceful shutdown/uninstall/data preservation; no hardware or serial send test'
}
$app = $null
$activeInstaller = $null
$crashDiagnostics = $null
$exe = ''
function Invoke-InstallerProcess([string]$File, [string]$Arguments) {
    $script:activeInstaller = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (-not $script:activeInstaller.WaitForExit(120000)) { throw 'Installer/uninstaller timed out.' }
    if ($script:activeInstaller.ExitCode -ne 0) { throw "Installer/uninstaller failed with exit code $($script:activeInstaller.ExitCode)." }
    $script:activeInstaller.Dispose()
    $script:activeInstaller = $null
}
try {
    $installLog = Join-Path $runRoot 'install.log'
    Invoke-InstallerProcess $Installer "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$installDir`" /LOG=`"$installLog`""
    $report.installed = $true
    $exe = Join-Path $installDir 'portly.exe'
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    if ($version.CompanyName -ne 'com.haike' -or $version.ProductName -ne 'portly') { throw 'VERSIONINFO changed the application-support path; preserve CompanyName/ProductName.' }
    $manifest = Get-Content -LiteralPath (Join-Path $installDir 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.architecture -ne $Architecture) { throw 'Installed manifest architecture does not match runner.' }
    # Inno's own uninstaller can be x86 even with a native ARM64 payload. Check
    # exactly the manifest payload rather than incorrectly treating unins*.exe
    # as one of Portly's native application binaries.
    $payloadCheck = Join-Path $runRoot 'payload-validation'
    New-Item -ItemType Directory -Path $payloadCheck | Out-Null
    foreach ($file in $manifest.files) {
        $relative = [string]$file.path
        $candidate = [IO.Path]::GetFullPath((Join-Path $installDir $relative))
        if (-not $candidate.StartsWith($installDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path.' }
        if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw "Installed payload hash mismatch: $relative" }
        $verificationFile = Join-Path $payloadCheck $relative
        New-Item -ItemType Directory -Path (Split-Path $verificationFile -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $candidate -Destination $verificationFile
    }
    $null = Assert-PortlyBundle $payloadCheck $Architecture
    $report.nativePayloadVerified = $true
    $crashDiagnostics = New-PortlyCrashDiagnostics -Directory (Join-Path $runRoot 'diagnostics') -Architecture $Architecture
    $report['appLaunchRequestedUtc'] = [DateTime]::UtcNow.ToString('o')
    $app = Start-Process -FilePath $exe -WorkingDirectory $installDir -PassThru
    $report['processId'] = $app.Id
    Start-PortlyCrashDiagnostics -Context $crashDiagnostics -TargetProcessId $app.Id -Exe $exe
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $app.Refresh()
        if ($app.HasExited) { throw "Portly exited before creating a window (code $($app.ExitCode))." }
        if ($app.MainWindowHandle -ne [IntPtr]::Zero) { $report.windowCreated = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $report.windowCreated) { throw 'Portly did not create a native main window before timeout.' }
    # Allow initial config/SQLite setup to finish, without any UI automation or
    # port opening. Startup survival alone is not a feature/hardware test.
    Start-Sleep -Seconds 3
    $app.Refresh()
    if ($app.HasExited) { throw "Portly exited unexpectedly during startup (code $($app.ExitCode))." }
    $report['closeRequestedUtc'] = [DateTime]::UtcNow.ToString('o')
    if (-not $app.CloseMainWindow()) { throw 'Could not request the normal window-close shutdown path.' }
    if (-not $app.WaitForExit($ExitTimeoutSeconds * 1000)) { throw 'Graceful shutdown timed out; data safety was not verified.' }
    if ($app.ExitCode -ne 0) { throw "Portly shutdown returned exit code $($app.ExitCode)." }
    $report.gracefulExit = $true
    $db = Join-Path $supportDir 'portly.sqlite'
    if (-not (Test-Path -LiteralPath $db -PathType Leaf) -or (Get-Item -LiteralPath $db).Length -eq 0) { throw 'Expected application-support SQLite database was not created.' }
    # Require handles to be released before uninstall. This also catches an
    # unexpected surviving main process; it does not infer device task success.
    foreach ($path in @($db, "$db.owner.lock")) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $handle = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $handle.Dispose()
    }
    $report.databaseClosed = $true
    $sentinel = Join-Path $supportDir 'installer-smoke-preserve.txt'
    [IO.File]::WriteAllText($sentinel, 'Portly CI uninstall must retain user configuration, history and logs.')
    $dbHash = (Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash
    $sentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
    $uninstall = Join-Path $installDir 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstall -PathType Leaf)) { throw 'Inno uninstaller is missing.' }
    $uninstallLog = Join-Path $runRoot 'uninstall.log'
    Invoke-InstallerProcess $uninstall "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$uninstallLog`""
    $report.uninstalled = $true
    if (Test-Path -LiteralPath $exe) { throw 'Installed application remains after uninstall.' }
    if ((Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash -ne $dbHash -or (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -ne $sentinelHash) { throw 'Uninstaller removed or changed application-support data.' }
    if (Test-Path -LiteralPath "HKCU:\$uninstallKey") { throw 'Inno uninstall registry entry remains.' }
    $report.userDataPreserved = $true
    $report.passed = $true
    Write-Host 'PASS: native Windows installer, window startup, graceful shutdown, uninstall, and user-data preservation.'
} catch {
    $report.error = $_.Exception.Message
    throw
} finally {
    if ($app) {
        try {
            $app.Refresh()
            $report['appHasExitedBeforeCleanup'] = $app.HasExited
            if ($app.HasExited) {
                $report['appExitCode'] = $app.ExitCode
                $report['appExitCodeHex'] = '0x{0:X8}' -f ([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$app.ExitCode), 0))
            }
        } catch { $report['exitCodeReadError'] = $_.Exception.Message }
    }
    if ($crashDiagnostics) {
        $symbols = Join-Path (Split-Path $PSScriptRoot -Parent) "../build/windows/$Architecture/runner/Release"
        try { $report['crashDiagnostics'] = Complete-PortlyCrashDiagnostics -Context $crashDiagnostics -Failed (-not $report.passed) -SymbolDirectories @($installDir, $symbols) }
        catch { $report['crashDiagnosticsError'] = $_.Exception.Message }
    }
    # Force termination is cleanup of this failed ephemeral CI run only, and is
    # always recorded as failure. It never substitutes for graceful shutdown.
    foreach ($process in @($app, $activeInstaller)) {
        if ($null -eq $process) { continue }
        try {
            if (-not $process.HasExited) { $report.forcedCleanup = $true; $report.passed = $false; $process.Kill($true); $null = $process.WaitForExit(10000) }
        } catch { $report.forcedCleanup = $true; $report.passed = $false }
        $process.Dispose()
    }
    $report['finishedUtc'] = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    Write-Host "Smoke report: $ReportPath"
    Write-Host "Installer logs: $runRoot"
}
