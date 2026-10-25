# Crash evidence for the ephemeral installer smoke only. No app success criteria.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-PortlyCrashEventXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Xml, [string]$Message = '')
    $document = [xml]$Xml
    $fields = [ordered]@{}
    $index = 0
    foreach ($node in $document.SelectNodes("//*[local-name()='EventData']/*[local-name()='Data']")) {
        $name = $node.GetAttribute('Name')
        if (-not $name) { $name = "data_$index" }
        $fields[$name] = $node.InnerText
        $index++
    }
    $eventId = $document.SelectSingleNode("/*[local-name()='Event']/*[local-name()='System']/*[local-name()='EventID']")
    $time = $document.SelectSingleNode("/*[local-name()='Event']/*[local-name()='System']/*[local-name()='TimeCreated']")
    $provider = $document.SelectSingleNode("/*[local-name()='Event']/*[local-name()='System']/*[local-name()='Provider']")
    [pscustomobject]@{
        eventId = if ($eventId) { [int]$eventId.InnerText } else { 0 }
        timeUtc = if ($time) { $time.GetAttribute('SystemTime') } else { '' }
        provider = if ($provider) { $provider.GetAttribute('Name') } else { '' }
        faultingApplication = if ($fields.Contains('AppName')) { $fields['AppName'] } else { $null }
        faultingModule = if ($fields.Contains('ModuleName')) { $fields['ModuleName'] } else { $null }
        exceptionCode = if ($fields.Contains('ExceptionCode')) { $fields['ExceptionCode'] } else { $null }
        faultingOffset = if ($fields.Contains('FaultingOffset')) { $fields['FaultingOffset'] } else { $null }
        processId = if ($fields.Contains('ProcessId')) { $fields['ProcessId'] } else { $null }
        fields = $fields; message = $Message
    }
}

function Test-PortlyCrashEventMatch {
    param([Parameter(Mandatory)]$Event, [int]$TargetProcessId, [string]$Application = 'portly.exe')
    if ($Event.processId) {
        try {
            $value = [string]$Event.processId
            $number = if ($value.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { [Convert]::ToInt32($value.Substring(2), 16) } else { [int]$value }
            return $number -eq $TargetProcessId
        } catch { return $false }
    }
    # WER 1001 often omits the app PID. The clean runner/application/time filter
    # is recorded as weaker correlation, never presented as an exact PID match.
    $text = ($Event.fields.Values -join "`n") + "`n" + $Event.message
    return $text.IndexOf($Application, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Restore-PortlyWerSettings {
    param([Parameter(Mandatory)]$Context)
    if ($null -eq $Context.WerLease) { return }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $lease = $Context.WerLease
        if ($lease.Created) { $base.DeleteSubKeyTree($lease.Key, $false) }
        else {
            $key = $base.OpenSubKey($lease.Key, $true)
            try {
                foreach ($name in @('DumpFolder', 'DumpCount', 'DumpType')) {
                    if ($lease.Values.ContainsKey($name)) {
                        $old = $lease.Values[$name]
                        $key.SetValue($name, $old.Value, $old.Kind)
                    } else { $key.DeleteValue($name, $false) }
                }
            } finally { if ($key) { $key.Dispose() } }
        }
        $Context.Status.werSettingsRestored = $true
        $Context.WerLease = $null
    } finally { $base.Dispose() }
}

function Find-PortlyDebugTool {
    param([string[]]$Names, [string[]]$Candidates = @())
    $paths = @($Candidates)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { $paths += $command.Source }
    }
    foreach ($path in $paths | Select-Object -Unique) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Microsoft') { return [IO.Path]::GetFullPath($path) }
        } catch { }
    }
    return $null
}

function New-PortlyCrashDiagnostics {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $dumps = Join-Path $Directory 'dumps'
    New-Item -ItemType Directory -Path $dumps -Force | Out-Null
    $context = [pscustomobject]@{
        Directory = $Directory; Dumps = $dumps; StartUtc = [DateTime]::UtcNow
        TargetProcessId = 0; Exe = ''; WerLease = $null; Monitor = $null; ProcDump = $null; Cdb = $null
        Status = [ordered]@{ werConfigured = $false; werSettingsRestored = $false; debuggerAttached = $false; procDumpMonitorStarted = $false; errors = @() }
    }
    try {
        # Microsoft documents HKLM (admin required), not HKCU. Only this app's
        # three values are leased; previous values/types are restored in finally.
        $relative = 'SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\portly.exe'
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $key = $base.OpenSubKey($relative, $true)
            $created = $null -eq $key
            if ($created) { $key = $base.CreateSubKey($relative, $true) }
            try {
                $values = @{}
                foreach ($name in @('DumpFolder', 'DumpCount', 'DumpType')) {
                    if ($name -in $key.GetValueNames()) {
                        $values[$name] = @{ Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = $key.GetValueKind($name) }
                    }
                }
                $context.WerLease = @{ Key = $relative; Created = $created; Values = $values }
                $key.SetValue('DumpFolder', $dumps, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $key.SetValue('DumpCount', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
                $key.SetValue('DumpType', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                $context.Status.werConfigured = $true
                $context.Status['werRegistryKey'] = "HKLM\$relative"
                $context.Status['werDumpType'] = 'MiniDump (1)'
            } finally { if ($key) { $key.Dispose() } }
        } finally { $base.Dispose() }
    } catch {
        $context.Status.errors += "WER configuration unavailable: $($_.Exception.Message)"
        try { Restore-PortlyWerSettings $context } catch { $context.Status.errors += "WER rollback failed: $($_.Exception.Message)" }
    }
    $debuggerCandidates = @()
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root) {
            foreach ($arch in @($(if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }), 'x64')) {
                $debuggerCandidates += Join-Path $root "Windows Kits/10/Debuggers/$arch/cdb.exe"
            }
        }
    }
    $context.Cdb = Find-PortlyDebugTool -Names @('cdb.exe') -Candidates $debuggerCandidates
    $procNames = if ($Architecture -eq 'arm64') { @('procdump64a.exe') } else { @('procdump64.exe', 'procdump.exe') }
    $context.ProcDump = Find-PortlyDebugTool -Names $procNames
    $context.Status['procDumpToolFound'] = $null -ne $context.ProcDump
    $context.Status['procDumpEulaAcceptedPreviously'] = $false
    if ($context.ProcDump) {
        try {
            # Read only: diagnostics never accept terms or create/change this key.
            $eula = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Sysinternals\ProcDump')
            try {
                $value = if ($eula) { $eula.GetValue('EulaAccepted', 0) } else { 0 }
                $context.Status.procDumpEulaAcceptedPreviously = $value -is [int] -and $value -eq 1
            } finally { if ($eula) { $eula.Dispose() } }
        } catch { $context.Status['procDumpUnavailableReason'] = "Cannot read previously accepted ProcDump EULA: $($_.Exception.Message)" }
        if (-not $context.Status.procDumpEulaAcceptedPreviously) {
            if (-not $context.Status.Contains('procDumpUnavailableReason')) { $context.Status['procDumpUnavailableReason'] = 'HKCU Software\Sysinternals\ProcDump EulaAccepted is not already DWORD 1; no terms are accepted by diagnostics.' }
            $context.ProcDump = $null
        }
    } else { $context.Status['procDumpUnavailableReason'] = 'An already installed, Microsoft-signed, compatible ProcDump was not found.' }
    $context.Status['cdbAvailable'] = $null -ne $context.Cdb
    $context.Status['procDumpAvailable'] = $null -ne $context.ProcDump
    return $context
}

function Start-PortlyCrashDiagnostics {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][int]$TargetProcessId, [Parameter(Mandatory)][string]$Exe)
    $Context.TargetProcessId = $TargetProcessId
    $Context.Exe = $Exe
    $Context.Status['processId'] = $TargetProcessId
    $Context.Status['application'] = $Exe
    if (-not $Context.Status.werConfigured -and $Context.ProcDump) {
        try {
            # Only an installed Microsoft-signed ProcDump with prior EULA
            # acceptance is used. This path never accepts new license terms.
            # Unhandled exceptions only, one mini dump; no -k or first-chance trap.
            $Context.Monitor = Start-Process -FilePath $Context.ProcDump -ArgumentList "-mm -e -n 1 $TargetProcessId `"$($Context.Dumps)`"" -PassThru -RedirectStandardOutput (Join-Path $Context.Directory 'procdump.txt') -RedirectStandardError (Join-Path $Context.Directory 'procdump-stderr.txt')
            $Context.Status.procDumpMonitorStarted = $true
            # Starting ProcDump does not prove it attached; preserve its output
            # and leave that fact unknown instead of claiming a dump/stack exists.
            $Context.Status.debuggerAttached = $null
        } catch { $Context.Status.errors += "ProcDump fallback failed: $($_.Exception.Message)" }
    }
}

function Complete-PortlyCrashDiagnostics {
    param([Parameter(Mandatory)]$Context, [bool]$Failed, [string[]]$SymbolDirectories = @())
    try {
        if ($Failed) {
            $events = @()
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            do {
                try {
                    $found = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000, 1001, 1002, 1026); StartTime = $Context.StartUtc.AddSeconds(-2).ToLocalTime() } -MaxEvents 128 -ErrorAction Stop)
                    foreach ($event in $found) {
                        $xml = $event.ToXml()
                        $message = try { $event.Message } catch { '' }
                        $parsed = ConvertFrom-PortlyCrashEventXml -Xml $xml -Message $message
                        if (-not (Test-PortlyCrashEventMatch $parsed $Context.TargetProcessId)) { continue }
                        $parsed | Add-Member -NotePropertyName correlation -NotePropertyValue $(if ($parsed.processId) { 'exact EventData PID' } else { 'application name + smoke time range (PID unavailable)' })
                        $events += $parsed
                        [IO.File]::WriteAllText((Join-Path $Context.Directory "event-$($event.Id)-$($event.RecordId).xml"), $xml)
                    }
                } catch {
                    if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { $Context.Status.errors += "Event log query: $($_.Exception.Message)"; break }
                }
                if ($events.Count -gt 0) { break }
                Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $deadline)
            ConvertTo-Json -InputObject @($events) -Depth 12 | Set-Content -LiteralPath (Join-Path $Context.Directory 'application-events.json') -Encoding utf8
            ($events | ForEach-Object { "$($_.timeUtc) event $($_.eventId), module=$($_.faultingModule), exception=$($_.exceptionCode), correlation=$($_.correlation)`n$($_.message)" }) -join "`n`n" | Set-Content -LiteralPath (Join-Path $Context.Directory 'application-events.txt') -Encoding utf8
            $Context.Status['applicationEvents'] = $events.Count
            $werRoots = @()
            foreach ($root in @($env:LOCALAPPDATA, $env:ProgramData)) {
                if ($root) {
                    foreach ($sub in @('ReportArchive', 'ReportQueue')) { $werRoots += Join-Path $root "Microsoft/Windows/WER/$sub" }
                }
            }
            $reportNumber = 0
            foreach ($root in $werRoots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                try {
                    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -Filter '*portly.exe*' -ErrorAction Stop | Where-Object LastWriteTimeUtc -GE $Context.StartUtc.AddSeconds(-2) | Select-Object -First 4)) {
                        $wer = Join-Path $folder.FullName 'Report.wer'
                        if (Test-Path -LiteralPath $wer) { Copy-Item -LiteralPath $wer -Destination (Join-Path $Context.Directory "wer-$reportNumber.wer"); $reportNumber++ }
                        foreach ($dump in @(Get-ChildItem -LiteralPath $folder.FullName -File -Filter '*.dmp' | Select-Object -First 2)) {
                            Copy-Item -LiteralPath $dump.FullName -Destination (Join-Path $Context.Dumps "wer-$reportNumber-$($dump.Name)")
                        }
                    }
                } catch { $Context.Status.errors += "WER report access: $($_.Exception.Message)" }
            }
            $symbols = Join-Path $Context.Directory 'symbols'
            New-Item -ItemType Directory -Path $symbols -Force | Out-Null
            $symbolBytes = 0
            foreach ($folder in $SymbolDirectories) {
                if (-not (Test-Path -LiteralPath $folder)) { continue }
                foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.pdb' | Select-Object -First 8)) {
                    if ($symbolBytes + $file.Length -gt 128MB) { continue }
                    Copy-Item -LiteralPath $file.FullName -Destination $symbols -Force
                    $symbolBytes += $file.Length
                }
            }
            $Context.Status['copiedSymbolBytes'] = $symbolBytes
            $dumps = @(Get-ChildItem -LiteralPath $Context.Dumps -File -Filter '*.dmp')
            $Context.Status['dumps'] = @($dumps | ForEach-Object { [ordered]@{ file = "dumps/$($_.Name)"; bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
            if ($Context.Cdb) {
                foreach ($dump in $dumps | Select-Object -First 2) {
                    $log = Join-Path $Context.Directory "$($dump.BaseName)-cdb.txt"
                    $commands = '!analyze -v; .ecxr; kv; ~* kb; lm; q'
                    $cache = Join-Path (Split-Path $Context.Directory -Parent) 'debug-symbol-cache'
                    $search = (@($symbols) + @($SymbolDirectories) + @("srv*$cache*https://msdl.microsoft.com/download/symbols")) -join ';'
                    $analyzer = Start-Process -FilePath $Context.Cdb -ArgumentList "-z `"$($dump.FullName)`" -y `"$search`" -c `"$commands`"" -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $Context.Directory "$($dump.BaseName)-cdb-stderr.txt")
                    try {
                        if (-not $analyzer.WaitForExit(30000)) { $analyzer.Kill(); $null = $analyzer.WaitForExit(3000); $Context.Status.errors += 'Offline cdb analysis timed out; dump is retained.' }
                    } finally { $analyzer.Dispose() }
                }
            }
        }
    } catch { $Context.Status.errors += "Crash evidence collection: $($_.Exception.Message)" }
    finally {
        if ($Context.Monitor) {
            try {
                if (-not $Context.Monitor.HasExited) {
                    $cancel = $null
                    if ([Threading.EventWaitHandle]::TryOpenExisting("ProcDump-$($Context.TargetProcessId)", [ref]$cancel)) {
                        try { $null = $cancel.Set() } finally { $cancel.Dispose() }
                    }
                    if (-not $Context.Monitor.WaitForExit(3000)) { $Context.Status.errors += 'ProcDump did not acknowledge graceful cancellation; target cleanup remains a smoke failure.' }
                }
                if ($Context.Monitor.HasExited) { $Context.Status['procDumpExitCode'] = $Context.Monitor.ExitCode }
                # Never kill a live debugger and thereby accidentally its target.
                $Context.Monitor.Dispose()
            } catch { $Context.Status.errors += "ProcDump cancellation: $($_.Exception.Message)" }
        }
        try { Restore-PortlyWerSettings $Context } catch { $Context.Status.errors += "WER restore failed: $($_.Exception.Message)" }
        $Context.Status['finishedUtc'] = [DateTime]::UtcNow.ToString('o')
        $Context.Status | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Context.Directory 'crash-diagnostics.json') -Encoding utf8
    }
    return $Context.Status
}

Export-ModuleMember -Function ConvertFrom-PortlyCrashEventXml, Test-PortlyCrashEventMatch, New-PortlyCrashDiagnostics, Start-PortlyCrashDiagnostics, Complete-PortlyCrashDiagnostics
