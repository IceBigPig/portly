#requires -Version 7.2
# Pure XML/correlation checks; this never configures WER or starts a debugger.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PortlyCrashDiagnostics.psm1') -Force
$checks = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "FAILED: $Message" }
    $script:checks++
}
$xml = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event">
  <System><Provider Name="Application Error"/><EventID>1000</EventID><TimeCreated SystemTime="2026-10-25T09:00:00Z"/></System>
  <EventData><Data Name="AppName">portly.exe</Data><Data Name="ModuleName">flutter_windows.dll</Data><Data Name="ExceptionCode">c000041d</Data><Data Name="FaultingOffset">00000123</Data><Data Name="ProcessId">0x1234</Data><Data Name="AppPath">C:\test\portly.exe</Data></EventData>
</Event>
'@
$parsed = ConvertFrom-PortlyCrashEventXml -Xml $xml -Message 'Original localized crash message'
Assert-True ($parsed.eventId -eq 1000) 'Namespaced XML event id'
Assert-True ($parsed.faultingModule -eq 'flutter_windows.dll') 'Named faulting module survives parsing'
Assert-True ($parsed.exceptionCode -eq 'c000041d') 'Exact exception code retained'
Assert-True ($parsed.faultingOffset -eq '00000123') 'Module-relative fault offset retained'
Assert-True ($parsed.message -eq 'Original localized crash message') 'Original message retained'
Assert-True (Test-PortlyCrashEventMatch $parsed 4660) 'Hex process id matches exact target'
Assert-True (-not (Test-PortlyCrashEventMatch $parsed 9999)) 'Same app name with wrong PID is rejected'
$decimal = ConvertFrom-PortlyCrashEventXml -Xml ($xml.Replace('0x1234', '4660'))
Assert-True (Test-PortlyCrashEventMatch $decimal 4660) 'Decimal process id matches exact target'
$wer = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event">
  <System><Provider Name="Windows Error Reporting"/><EventID>1001</EventID><TimeCreated SystemTime="2026-10-25T09:00:00Z"/></System>
  <EventData><Data Name="EventName">APPCRASH</Data><Data Name="P1">portly.exe</Data><Data Name="P4">flutter_windows.dll</Data><Data Name="P7">c000041d</Data></EventData>
</Event>
'@
$report = ConvertFrom-PortlyCrashEventXml -Xml $wer
Assert-True (Test-PortlyCrashEventMatch $report 4660) 'WER with no PID uses explicitly weaker app/time correlation'
Assert-True ($report.fields['P7'] -eq 'c000041d') 'WER problem signature fields retained without speculative relabeling'
$unrelated = ConvertFrom-PortlyCrashEventXml -Xml ($wer.Replace('portly.exe', 'unrelated.exe'))
Assert-True (-not (Test-PortlyCrashEventMatch $unrelated 4660)) 'Unrelated app report rejected'
Write-Host "PASS: $checks crash XML/correlation checks. Actual WER/event/dump collection requires Windows."
