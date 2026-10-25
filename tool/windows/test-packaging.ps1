#requires -Version 7.2
# No Windows SDK, Flutter CLI, Pester, or compiler required. These are parser and
# binary-validator tests, not a claim of a Windows application build/install.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PortlyPackaging.psm1') -Force
$script:checks = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "FAILED: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $Message
}
function New-FixturePe([string]$Path, [uint16]$Machine, [string]$Import = '', [string]$DelayImport = '') {
    $bytes = [byte[]]::new(2048)
    $stream = [IO.MemoryStream]::new($bytes, $true)
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0x5A4D); $stream.Position = 0x3C; $writer.Write([uint32]0x80)
        $stream.Position = 0x80; $writer.Write([uint32]0x4550); $writer.Write($Machine); $writer.Write([uint16]1)
        $stream.Position = 0x80 + 20; $writer.Write([uint16]240)
        $optional = 0x80 + 24
        $stream.Position = $optional; $writer.Write([uint16]0x20B)
        $stream.Position = $optional + 60; $writer.Write([uint32]0x200)
        $stream.Position = $optional + 108; $writer.Write([uint32]16)
        $stream.Position = $optional + 240 + 8
        $writer.Write([uint32]0x600); $writer.Write([uint32]0x1000); $writer.Write([uint32]0x600); $writer.Write([uint32]0x200)
        if ($Import) {
            $stream.Position = $optional + 112 + 8
            $writer.Write([uint32]0x1000); $writer.Write([uint32]40)
            $stream.Position = 0x200; $writer.Write([uint32]0x1100)
            $stream.Position = 0x200 + 12; $writer.Write([uint32]0x1100)
            $stream.Position = 0x300; $writer.Write([Text.Encoding]::ASCII.GetBytes($Import + [char]0))
        }
        if ($DelayImport) {
            $stream.Position = $optional + 112 + 8 * 13
            $writer.Write([uint32]0x1200); $writer.Write([uint32]64)
            $stream.Position = 0x400; $writer.Write([uint32]1); $writer.Write([uint32]0x1300)
            $stream.Position = 0x500; $writer.Write([Text.Encoding]::ASCII.GetBytes($DelayImport + [char]0))
        }
        [IO.File]::WriteAllBytes($Path, $bytes)
    } finally { $writer.Dispose(); $stream.Dispose() }
}
function New-FixtureElf([string]$Path, [uint16]$Machine) {
    $bytes = [byte[]]::new(64)
    $bytes[0] = 0x7F; $bytes[1] = 0x45; $bytes[2] = 0x4C; $bytes[3] = 0x46; $bytes[4] = 2; $bytes[5] = 1
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 18)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function New-FixtureCrt([string]$Directory, [string]$Architecture) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $machine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll')) { New-FixturePe (Join-Path $Directory $name) $machine }
    # The Microsoft ARM64 directory also ships this x64 compatibility DLL.
    New-FixturePe (Join-Path $Directory 'vcruntime140_1.dll') 0x8664
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ("portly-packaging-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $toolRoot = Split-Path $PSScriptRoot -Parent
    foreach ($file in @(Get-ChildItem -LiteralPath $toolRoot -Recurse -File | Where-Object Extension -In @('.ps1', '.psm1'))) {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "PowerShell syntax: $($file.Name)"
    }
    $pe = Join-Path $temp 'sample.dll'
    New-FixturePe $pe 0x8664 'KERNEL32.dll' 'vcruntime140.dll'
    $info = Assert-PortlyBinaryArchitecture $pe x64
    Assert-True ($info.Imports.Count -eq 2 -and 'kernel32.dll' -in $info.Imports -and 'vcruntime140.dll' -in $info.Imports) 'Read normal and delay import tables.'
    Assert-Throws { Assert-PortlyBinaryArchitecture $pe arm64 } 'Refuse x64 payload marked ARM64.'
    New-FixturePe $pe 0xAA64
    Assert-True ((Assert-PortlyBinaryArchitecture $pe arm64).Architecture -eq 'arm64') 'Accept native ARM64 PE.'
    Assert-Throws { Assert-PortlyBinaryArchitecture $pe x64 } 'Refuse ARM64 payload marked x64.'
    [IO.File]::WriteAllBytes($pe, [byte[]]@(0x4D, 0x5A))
    Assert-Throws { Read-PortlyPe $pe } 'Refuse truncated PE.'
    New-FixturePe $pe 0x014C
    Assert-Throws { Assert-PortlyBinaryArchitecture $pe x64 } 'Refuse unsupported x86 payload.'
    $elf = Join-Path $temp 'app.so'
    New-FixtureElf $elf 183
    Assert-PortlyAotArchitecture $elf arm64
    Assert-True $true 'Accept ARM64 ELF AOT snapshot.'
    Assert-Throws { Assert-PortlyAotArchitecture $elf x64 } 'Refuse mismatched AOT snapshot.'
    New-FixtureElf $elf 62
    Assert-PortlyAotArchitecture $elf x64
    Assert-True $true 'Accept x64 ELF AOT snapshot.'
    $crt = Join-Path $temp 'mixed-arm64-crt'
    New-Item -ItemType Directory -Path $crt | Out-Null
    New-FixturePe (Join-Path $crt 'msvcp140.dll') 0xAA64
    New-FixturePe (Join-Path $crt 'vcruntime140.dll') 0xAA64
    New-FixturePe (Join-Path $crt 'vcruntime140_1.dll') 0x8664
    $nativeCrt = @(Get-PortlyCrtFiles $crt arm64)
    Assert-True ($nativeCrt.Count -eq 2 -and 'vcruntime140_1.dll' -notin $nativeCrt.Name) 'Filter x64 compatibility CRT from ARM64 redist.'
    Assert-True (@(Get-PortlyCrtFiles $crt x64).Count -eq 1) 'Select matching CRT by PE architecture rather than folder name.'
    Remove-Item -LiteralPath (Join-Path $crt 'vcruntime140_1.dll')
    Assert-Throws { Get-PortlyCrtFiles $crt x64 } 'Refuse a CRT directory with no native target runtime.'
    $redist = Join-Path $temp 'MSVC'
    $old9 = Join-Path $redist '14.9.12345/x64/Microsoft.VC143.CRT'
    $old40 = Join-Path $redist '14.40.33810/x64/Microsoft.VC143.CRT'
    New-FixtureCrt $old9 x64
    New-FixtureCrt $old40 x64
    Assert-True ((Find-PortlyCrtDirectory $redist x64) -eq $old40) 'Old flat CRT layout sorts numeric versions, not lexically.'
    $nestedOnly = Join-Path $temp 'MSVC-nested'
    $new44 = Join-Path $nestedOnly 'v143/14.44.35211/x64/Microsoft.VC143.CRT'
    New-FixtureCrt $new44 x64
    New-Item -ItemType Directory -Path (Join-Path $nestedOnly 'notes') -Force | Out-Null
    Assert-True ((Find-PortlyCrtDirectory $nestedOnly x64) -eq $new44) 'New v143/version layout is discovered without flat fallback.'
    $mixed44 = Join-Path $redist 'v143/14.44.35211/x64/Microsoft.VC143.CRT'
    New-FixtureCrt $mixed44 x64
    Assert-True ((Find-PortlyCrtDirectory $redist x64) -eq $mixed44) 'Choose the latest numeric CRT across old and new layouts.'
    $arm50 = Join-Path $redist 'v145/14.50.12345/arm64/Microsoft.VC145.CRT'
    New-FixtureCrt $arm50 arm64
    Assert-True ((Find-PortlyCrtDirectory $redist arm64) -eq $arm50) 'Select ARM64 in a v145 toolset while filtering its x64 compatibility CRT.'
    Assert-True ((Find-PortlyCrtDirectory $redist x64) -eq $mixed44) 'A newer ARM64-only toolset does not hide a valid x64 CRT.'
    $incomplete = Join-Path $redist 'v145/99.0.12345/x64/Microsoft.VC145.CRT'
    New-FixtureCrt $incomplete x64
    Remove-Item -LiteralPath (Join-Path $incomplete 'vcruntime140.dll')
    Assert-True ((Find-PortlyCrtDirectory $redist x64) -eq $mixed44) 'Skip an incomplete newer CRT and use the latest complete target candidate.'
    $foreign = Join-Path $redist 'v145/99.1.12345/x64/Microsoft.VC145.CRT'
    New-FixtureCrt $foreign arm64
    Assert-True ((Find-PortlyCrtDirectory $redist x64) -eq $mixed44) 'A directory named x64 cannot pass with ARM64 PE payload.'
    $emptyRedist = Join-Path $temp 'MSVC-empty'
    New-Item -ItemType Directory -Path (Join-Path $emptyRedist 'v143') -Force | Out-Null
    Assert-Throws { Find-PortlyCrtDirectory $emptyRedist arm64 } 'No valid target CRT fails explicitly rather than ignoring the toolset directory.'
    foreach ($arch in @('x64', 'arm64')) {
        $bundle = Join-Path $temp "bundle-$arch"
        New-Item -ItemType Directory -Path (Join-Path $bundle 'data/flutter_assets') -Force | Out-Null
        $machine = if ($arch -eq 'x64') { 0x8664 } else { 0xAA64 }
        $nativeNames = @('portly.exe', 'flutter_windows.dll', 'serialport.dll', 'sqlite3.dll', 'msvcp140.dll', 'vcruntime140.dll')
        if ($arch -eq 'x64') { $nativeNames += 'vcruntime140_1.dll' }
        foreach ($name in $nativeNames) {
            New-FixturePe (Join-Path $bundle $name) $machine 'KERNEL32.dll'
        }
        New-FixtureElf (Join-Path $bundle 'data/app.so') $(if ($arch -eq 'x64') { 62 } else { 183 })
        Set-Content -LiteralPath (Join-Path $bundle 'data/icudtl.dat') -Value 'fixture'
        Assert-True (@(Assert-PortlyBundle $bundle $arch).Count -eq $nativeNames.Count) "Accept complete $arch bundle."
        if ($arch -eq 'arm64') {
            New-FixturePe (Join-Path $bundle 'serialport.dll') $machine 'vcruntime140_1.dll'
            Assert-Throws { Assert-PortlyBundle $bundle $arch } 'Never ignore an actually imported runtime excluded by CRT architecture filtering.'
            New-FixturePe (Join-Path $bundle 'vcruntime140_1.dll') 0x8664
            Assert-Throws { Assert-PortlyBundle $bundle $arch } 'Never allow a foreign CRT to satisfy a native payload dependency.'
            Remove-Item -LiteralPath (Join-Path $bundle 'vcruntime140_1.dll')
        }
        New-FixturePe (Join-Path $bundle 'serialport.dll') $machine 'missing-vendor.dll'
        Assert-Throws { Assert-PortlyBundle $bundle $arch } "Refuse unbundled $arch vendor dependency."
        New-FixturePe (Join-Path $bundle 'serialport.dll') $machine 'KERNEL32.dll' 'missing-delay.dll'
        Assert-Throws { Assert-PortlyBundle $bundle $arch } "Refuse unbundled $arch delay dependency."
        Remove-Item -LiteralPath (Join-Path $bundle 'serialport.dll')
        Assert-Throws { Assert-PortlyBundle $bundle $arch } "Refuse missing $arch FFI serialport asset."
    }
    if (-not $IsWindows) {
        Assert-Throws { & (Join-Path $toolRoot 'package-windows.ps1') -Architecture x64 } 'macOS must not generate mislabeled Windows artifacts.'
        Assert-Throws { & (Join-Path $toolRoot 'setup-windows-flutter.ps1') -Architecture arm64 -Destination (Join-Path $temp 'sdk') } 'SDK bootstrap refuses non-Windows host.'
    }
    Write-Host "PASS: $script:checks packaging syntax/binary-validation checks. Windows build, Inno compilation, installation, and hardware tests still require Windows runners."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
