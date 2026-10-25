# Pure PowerShell binary validation; this module also runs on macOS for tests.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-PortlyPe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE file: $Path" }
        $stream.Position = 0x3C
        $pe = $reader.ReadUInt32()
        if ($pe + 24 -gt $stream.Length) { throw "Truncated PE header: $Path" }
        $stream.Position = $pe
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
        $machine = $reader.ReadUInt16()
        $sectionCount = $reader.ReadUInt16()
        $stream.Position = $pe + 20
        $optionalSize = $reader.ReadUInt16()
        $optional = $pe + 24
        if ($optionalSize -lt 112 -or $optional + $optionalSize + 40 * $sectionCount -gt $stream.Length) {
            throw "Truncated PE optional/section header: $Path"
        }
        $stream.Position = $optional
        if ($reader.ReadUInt16() -ne 0x20B) { throw "Expected PE32+ executable: $Path" }
        $stream.Position = $optional + 60
        $headersSize = $reader.ReadUInt32()
        $stream.Position = $optional + 108
        $directoryCount = $reader.ReadUInt32()
        $sections = @()
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $stream.Position = $optional + $optionalSize + 40 * $i + 8
            $virtualSize = $reader.ReadUInt32()
            $virtualAddress = $reader.ReadUInt32()
            $rawSize = $reader.ReadUInt32()
            $rawOffset = $reader.ReadUInt32()
            $sections += [pscustomobject]@{ Rva = $virtualAddress; Size = [Math]::Max($virtualSize, $rawSize); RawSize = $rawSize; Offset = $rawOffset }
        }
        function Convert-Rva([uint32]$Rva) {
            if ($Rva -lt $headersSize -and $Rva -lt $stream.Length) { return [long]$Rva }
            foreach ($section in $sections) {
                if ($Rva -ge $section.Rva -and [long]$Rva -lt [long]$section.Rva + $section.Size) {
                    $delta = [long]$Rva - $section.Rva
                    if ($delta -ge $section.RawSize -or $section.Offset + $delta -ge $stream.Length) { break }
                    return [long]($section.Offset + $delta)
                }
            }
            throw "PE RVA outside file: $Path (0x$($Rva.ToString('X')))"
        }
        function Read-ImportName([uint32]$Rva) {
            $stream.Position = Convert-Rva $Rva
            $chars = [Collections.Generic.List[char]]::new()
            for ($n = 0; $n -lt 512 -and $stream.Position -lt $stream.Length; $n++) {
                $value = $reader.ReadByte()
                if ($value -eq 0) { return -join $chars }
                if ($value -lt 32 -or $value -gt 126) { throw "Invalid PE DLL name: $Path" }
                $chars.Add([char]$value)
            }
            throw "Unterminated PE DLL name: $Path"
        }
        $imports = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($directory in @(@{ Index = 1; Stride = 20; NameOffset = 12 }, @{ Index = 13; Stride = 32; NameOffset = 4 })) {
            if ($directoryCount -le $directory.Index) { continue }
            if (112 + 8 * ($directory.Index + 1) -gt $optionalSize) { throw "Truncated PE directories: $Path" }
            $stream.Position = $optional + 112 + 8 * $directory.Index
            $rva = $reader.ReadUInt32()
            $size = $reader.ReadUInt32()
            if ($rva -eq 0 -or $size -eq 0) { continue }
            $tableOffset = Convert-Rva $rva
            $maxEntries = [Math]::Min(4096, [Math]::Floor($size / $directory.Stride))
            for ($n = 0; $n -lt $maxEntries; $n++) {
                $entry = $tableOffset + $n * $directory.Stride
                if ($entry + $directory.Stride -gt $stream.Length) { throw "Truncated PE imports: $Path" }
                $stream.Position = $entry
                $first = $reader.ReadUInt32()
                $stream.Position = $entry + $directory.NameOffset
                $nameRva = $reader.ReadUInt32()
                if ($first -eq 0 -and $nameRva -eq 0) { break }
                if ($directory.Index -eq 13 -and ($first -band 1) -eq 0) { throw "Unsupported VA delay imports: $Path" }
                if ($nameRva -ne 0) { [void]$imports.Add((Read-ImportName $nameRva).ToLowerInvariant()) }
            }
        }
        [pscustomobject]@{ Path = $Path; Machine = $machine; Architecture = switch ($machine) { 0x8664 { 'x64' } 0xAA64 { 'arm64' } default { 'unknown' } }; Imports = @($imports | Sort-Object) }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Assert-PortlyBinaryArchitecture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    $info = Read-PortlyPe $Path
    if ($info.Architecture -ne $Architecture) { throw "Architecture mismatch: $Path is $($info.Architecture) (0x$($info.Machine.ToString('X4'))), expected $Architecture" }
    return $info
}

function Assert-PortlyAotArchitecture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    # Flutter's Windows app.so is an ELF AOT snapshot, not a Windows PE DLL.
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt32() -ne 0x464C457F -or $reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1) { throw "Expected little-endian ELF64 AOT snapshot: $Path" }
        $stream.Position = 18
        $machine = $reader.ReadUInt16()
        $expected = if ($Architecture -eq 'x64') { 62 } else { 183 }
        if ($machine -ne $expected) { throw "AOT architecture mismatch: $Path (ELF machine $machine), expected $Architecture" }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-PortlyCrtFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    # Microsoft's ARM64 redistributable also contains x64 compatibility DLLs
    # (notably vcruntime140_1.dll). Select only native payload; dependency closure
    # below still fails if an application actually imports an excluded DLL.
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.dll')
    $native = @()
    foreach ($file in $files) {
        $info = Read-PortlyPe $file.FullName
        if ($info.Architecture -eq $Architecture) { $native += $file }
        else { Write-Verbose "Excluded foreign-architecture CRT: $($file.Name) ($($info.Architecture))" }
    }
    if ($native.Count -eq 0) { throw "No native $Architecture redistributable CRT DLLs found: $Directory" }
    return $native
}

function Test-PortlySystemDll {
    param([string]$Name)
    if ($Name -match '^(api-ms-win-|ext-ms-win-)[a-z0-9_-]+\.dll$') { return $true }
    # Intentionally exclude the MSVC runtime and development-only DLLs.
    return $Name -in @('advapi32.dll', 'avrt.dll', 'bcrypt.dll', 'cfgmgr32.dll', 'combase.dll', 'comctl32.dll', 'comdlg32.dll', 'crypt32.dll', 'cryptbase.dll', 'd2d1.dll', 'd3d9.dll', 'd3d11.dll', 'd3d12.dll', 'd3dcompiler_47.dll', 'dcomp.dll', 'dbghelp.dll', 'dnsapi.dll', 'dsound.dll', 'dwmapi.dll', 'dwrite.dll', 'dxgi.dll', 'dxguid.dll', 'gdi32.dll', 'hid.dll', 'imm32.dll', 'iphlpapi.dll', 'kernel32.dll', 'kernelbase.dll', 'mmdevapi.dll', 'msimg32.dll', 'msvcrt.dll', 'netapi32.dll', 'ncrypt.dll', 'ntdll.dll', 'ole32.dll', 'oleacc.dll', 'oleaut32.dll', 'opengl32.dll', 'powrprof.dll', 'propsys.dll', 'psapi.dll', 'rpcrt4.dll', 'runtimeobject.dll', 'secur32.dll', 'setupapi.dll', 'shell32.dll', 'shcore.dll', 'shlwapi.dll', 'uiautomationcore.dll', 'ucrtbase.dll', 'user32.dll', 'userenv.dll', 'usp10.dll', 'uxtheme.dll', 'version.dll', 'winhttp.dll', 'wininet.dll', 'winmm.dll', 'winspool.drv', 'winsta.dll', 'wintrust.dll', 'wldap32.dll', 'ws2_32.dll', 'wtsapi32.dll')
}

function Assert-PortlyBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    $requiredFiles = @('portly.exe', 'flutter_windows.dll', 'serialport.dll', 'msvcp140.dll', 'vcruntime140.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets')
    if ($Architecture -eq 'x64') { $requiredFiles += 'vcruntime140_1.dll' }
    foreach ($required in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $required))) { throw "Missing bundle file: $required" }
    }
    $nativeFiles = @(Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') })
    if (-not ($nativeFiles | Where-Object Name -Like '*sqlite3*.dll')) { throw 'SQLite native asset DLL is missing.' }
    $rootDlls = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.dll' | ForEach-Object { $_.Name.ToLowerInvariant() })
    $results = @()
    foreach ($file in $nativeFiles) {
        $info = Assert-PortlyBinaryArchitecture $file.FullName $Architecture
        foreach ($dependency in $info.Imports) {
            # Standard LoadLibrary import lookup only searches the app root and
            # loader's directory; don't let an unrelated nested DLL satisfy it.
            if ((Test-PortlySystemDll $dependency) -or $dependency -in $rootDlls -or (Test-Path -LiteralPath (Join-Path $file.DirectoryName $dependency))) { continue }
            throw "Unbundled dependency '$dependency' imported by $($file.Name). Add the matching redistributable; do not copy from System32."
        }
        $results += [pscustomobject]@{ Path = [IO.Path]::GetRelativePath($Directory, $file.FullName).Replace('\', '/'); Machine = ('0x{0:X4}' -f $info.Machine); Architecture = $info.Architecture; Imports = $info.Imports }
    }
    Assert-PortlyAotArchitecture (Join-Path $Directory 'data/app.so') $Architecture
    return $results
}

Export-ModuleMember -Function Read-PortlyPe, Assert-PortlyBinaryArchitecture, Assert-PortlyAotArchitecture, Get-PortlyCrtFiles, Assert-PortlyBundle
