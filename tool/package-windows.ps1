#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [string]$OutputDirectory = 'dist/windows',
    [string]$Flutter = 'flutter',
    [string]$InnoSetupCompiler = '',
    [string]$VCRuntimeDirectory = '',
    [switch]$SkipBuild
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows packages must be built and verified on Windows. macOS cross-compilation is not supported.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'windows/PortlyPackaging.psm1') -Force
$osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$processArch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($osArch -ne $Architecture -or $processArch -ne $Architecture) { throw "Use native $Architecture Windows and PowerShell (OS=$osArch, process=$processArch)." }
$flutterCommand = Get-Command $Flutter -ErrorAction Stop
$flutterPath = $flutterCommand.Source
if ([IO.Path]::GetFileName($flutterPath) -notin @('flutter.bat', 'flutter')) { throw 'Flutter must resolve to the SDK bin/flutter.bat executable.' }
$sdk = Split-Path (Split-Path $flutterPath -Parent) -Parent
$dartPath = Join-Path $sdk 'bin/cache/dart-sdk/bin/dart.exe'
if (-not (Test-Path -LiteralPath $dartPath)) { throw 'Flutter SDK is not bootstrapped. Run setup-windows-flutter.ps1 first.' }
$null = Assert-PortlyBinaryArchitecture $dartPath $Architecture
$sdkVersion = Get-Content -LiteralPath (Join-Path $sdk 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json
$pubspec = Get-Content -LiteralPath (Join-Path $repo 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$') { throw 'Cannot read release version from pubspec.yaml.' }
$version = $Matches[1]
$buildNumber = if ($Matches[2]) { $Matches[2] } else { '0' }
$baseName = "Portly-$version-windows-$Architecture"
$OutputDirectory = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
foreach ($name in @("$baseName-portable.zip", "$baseName-setup.exe", "$baseName-manifest.json", "$baseName-SHA256SUMS.txt")) {
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory $name)) { throw "Output already exists: $name. Choose a clean output directory to prevent mixing releases." }
}
if (-not $InnoSetupCompiler) {
    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($iscc) { $InnoSetupCompiler = $iscc.Source }
    else {
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if (-not $root) { continue }
            foreach ($major in @('7', '6')) {
                $candidate = Join-Path $root "Inno Setup $major/ISCC.exe"
                if (Test-Path -LiteralPath $candidate) { $InnoSetupCompiler = $candidate; break }
            }
            if ($InnoSetupCompiler) { break }
        }
    }
}
if (-not $InnoSetupCompiler -or -not (Test-Path -LiteralPath $InnoSetupCompiler)) { throw 'Inno Setup 6.3+ is required (ISCC.exe). Install it before packaging.' }
if (-not $VCRuntimeDirectory) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio vswhere is missing. Supply -VCRuntimeDirectory explicitly.' }
    $toolComponent = if ($Architecture -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    $vsPath = & $vswhere -latest -products '*' -requires $toolComponent -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'Visual Studio C++ desktop workload is missing.' }
    $redistRoot = Join-Path $vsPath 'VC/Redist/MSVC'
    $crt = @(Get-ChildItem -LiteralPath $redistRoot -Directory | Sort-Object { [version]$_.Name } -Descending | ForEach-Object {
        Get-ChildItem -Path (Join-Path $_.FullName "$Architecture/Microsoft.VC*.CRT") -Directory -ErrorAction SilentlyContinue
    }) | Select-Object -First 1
    if (-not $crt) { throw "Matching $Architecture MSVC redistributable CRT is missing. Install its Visual Studio component or supply -VCRuntimeDirectory." }
    $VCRuntimeDirectory = $crt.FullName
}
$VCRuntimeDirectory = [IO.Path]::GetFullPath($VCRuntimeDirectory)
$crtDlls = @(Get-ChildItem -LiteralPath $VCRuntimeDirectory -File -Filter '*.dll')
if ($crtDlls.Count -eq 0) { throw 'No redistributable CRT DLLs found.' }
foreach ($dll in $crtDlls) { $null = Assert-PortlyBinaryArchitecture $dll.FullName $Architecture }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("portly-windows-package-" + [guid]::NewGuid().ToString('N'))
$bundle = Join-Path $scratch 'Portly'
$published = [Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
Push-Location $repo
try {
    if (-not $SkipBuild) {
        # Flutter 3.47 chooses the Windows target from native Dart host ABI.
        & $flutterPath build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows release build failed.' }
    }
    $release = Join-Path $repo "build/windows/$Architecture/runner/Release"
    if (-not (Test-Path -LiteralPath (Join-Path $release 'portly.exe'))) { throw "Release bundle is missing: $release" }
    Copy-Item -Path (Join-Path $release '*') -Destination $bundle -Recurse -Force
    # Symbols are not runtime payload. Do not publish PDBs by accident.
    Get-ChildItem -LiteralPath $bundle -Recurse -File -Filter '*.pdb' | Remove-Item
    foreach ($dll in $crtDlls) { Copy-Item -LiteralPath $dll.FullName -Destination $bundle -Force }
    foreach ($notice in @('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md')) {
        $path = Join-Path $repo $notice
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required distribution notice is missing: $notice" }
        Copy-Item -LiteralPath $path -Destination $bundle
    }
    $licenses = Join-Path $repo 'third_party_licenses'
    foreach ($required in @('FLUTTER-NOTICES.txt', 'sources', 'SHA256SUMS')) {
        if (-not (Test-Path -LiteralPath (Join-Path $licenses $required))) { throw "Required third-party licenses/corresponding source is missing: third_party_licenses/$required" }
    }
    $licenseDestination = Join-Path $bundle 'third_party_licenses'
    if (Test-Path -LiteralPath $licenseDestination) { Remove-Item -LiteralPath $licenseDestination -Recurse -Force }
    Copy-Item -LiteralPath $licenses -Destination $licenseDestination -Recurse -Force
    $peFiles = @(Assert-PortlyBundle $bundle $Architecture)
    $commit = (& git rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $commit = 'uncommitted' }
    $files = @(Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = [IO.Path]::GetRelativePath($bundle, $_.FullName).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{
        product = 'Portly'; version = $version; buildNumber = $buildNumber; architecture = $Architecture
        flutterVersion = $sdkVersion.flutterVersion; flutterRevision = $sdkVersion.frameworkRevision
        sourceCommit = $commit; createdUtc = [DateTime]::UtcNow.ToString('o'); signed = $false
        msvcCrtSource = (Split-Path $VCRuntimeDirectory -Leaf); peFiles = $peFiles; files = $files
        validation = 'PE architecture, ELF AOT architecture, required FFI assets, static/delay DLL dependency closure; no hardware certification'
    }
    $manifestPath = Join-Path $scratch "$baseName-manifest.json"
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $bundle 'release-manifest.json')
    $zipPath = Join-Path $scratch "$baseName-portable.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
    $verify = Join-Path $scratch 'verify'
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $verify)
    $extracted = Join-Path $verify 'Portly'
    $null = Assert-PortlyBundle $extracted $Architecture
    foreach ($file in $files) {
        if ((Get-FileHash -LiteralPath (Join-Path $extracted $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw "ZIP verification failed: $($file.path)" }
    }
    & $InnoSetupCompiler '/Qp' "/DAppVersion=$version" "/DBuildNumber=$buildNumber" "/DTargetArch=$Architecture" "/DBundleDir=$bundle" "/DOutputDir=$scratch" "/DOutputBaseName=$baseName-setup" (Join-Path $PSScriptRoot 'windows/portly.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
    $installerPath = Join-Path $scratch "$baseName-setup.exe"
    if (-not (Test-Path -LiteralPath $installerPath)) { throw 'Inno Setup did not create the installer.' }
    # Inno's setup bootstrap may be x86; target checks apply to payload, not it.
    $sumPath = Join-Path $scratch "$baseName-SHA256SUMS.txt"
    @($zipPath, $installerPath, $manifestPath) | ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($_) } | Set-Content -LiteralPath $sumPath -Encoding ascii
    foreach ($artifact in @($zipPath, $installerPath, $manifestPath, $sumPath)) {
        $destination = Join-Path $OutputDirectory ([IO.Path]::GetFileName($artifact))
        Move-Item -LiteralPath $artifact -Destination $destination
        $published.Add($destination)
    }
    $published | ForEach-Object { Write-Host "Created: $_" }
} catch {
    foreach ($path in $published) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    throw
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
