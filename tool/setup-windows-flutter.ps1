#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [string]$Version = '3.47.7',
    [Parameter(Mandatory)][string]$Destination
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this script on a native Windows runner.' }
$osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$processArch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($osArch -ne $Architecture -or $processArch -ne $Architecture) { throw "Native $Architecture Windows and PowerShell are required (OS=$osArch, process=$processArch)." }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be a stable Flutter version, for example 3.47.7.' }
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw "SDK destination already exists; use a clean directory to avoid cached x64 Dart: $Destination" }
Import-Module (Join-Path $PSScriptRoot 'windows/PortlyPackaging.psm1') -Force
& git clone --depth 1 --branch $Version https://github.com/flutter/flutter.git $Destination
if ($LASTEXITCODE -ne 0) { throw 'Flutter source checkout failed.' }
# The distributed Windows SDK archive contains x64 Dart. A clean source checkout
# bootstraps native Dart via bin/internal/update_dart_sdk.ps1 on ARM64 instead.
# Flutter may fall back to x64 if its engine has no ARM64 Dart; reject that below.
$env:PROCESSOR_ARCHITECTURE = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'AMD64' }
& (Join-Path $Destination 'bin/flutter.bat') --version
if ($LASTEXITCODE -ne 0) { throw 'Flutter bootstrap failed.' }
$dart = Join-Path $Destination 'bin/cache/dart-sdk/bin/dart.exe'
$null = Assert-PortlyBinaryArchitecture $dart $Architecture
$manifest = Get-Content -LiteralPath (Join-Path $Destination 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json
if ($manifest.flutterVersion -ne $Version) { throw "Unexpected SDK version $($manifest.flutterVersion), expected $Version." }
$bin = Join-Path $Destination 'bin'
$env:PATH = "$bin;$env:PATH"
if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin -Encoding utf8 }
Write-Host "Ready: Flutter $Version with native $Architecture Dart ($dart)"
