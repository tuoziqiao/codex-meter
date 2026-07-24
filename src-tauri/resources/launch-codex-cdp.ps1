# Ensures Codex Desktop exposes a verified loopback CDP endpoint.
# Identity is supplied by the caller (from resolve-codex-install.ps1).
# Outputs a single-line JSON object on stdout (ok true/false).
# Logic adapted from Codex-Dream-Skin (debug launch) and Codex-QQ-Skin (port/process checks).

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$PreferredPort,
  [Parameter(Mandatory = $true)][string]$AppUserModelId,
  [Parameter(Mandatory = $true)][string]$Executable,
  [Parameter(Mandatory = $true)][string]$PackageRoot,
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$PackageName = '',
  [string]$PackageFamilyName = '',
  [string]$PackageFullName = '',
  [int[]]$PreserveProcessIds = @(),
  [switch]$AllowPortScan,
  [switch]$SkipLaunch,
  [int]$CdpTimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'

function Write-CodexMeterResult {
  param([hashtable]$Payload)
  Write-Output (($Payload | ConvertTo-Json -Compress -Depth 6))
}

function Write-CodexMeterFailure {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message
  )
  Write-CodexMeterResult @{
    ok = $false
    code = $Code
    message = $Message
  }
  exit 1
}

function Test-CodexMeterPathEqual {
  param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return [System.IO.Path]::GetFullPath($Left).Equals(
      [System.IO.Path]::GetFullPath($Right),
      [StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function ConvertTo-CodexMeterProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.Contains('"')) { throw 'Process arguments containing a double quote are not supported.' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '\s') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function ConvertTo-CodexMeterArgumentLine {
  param([AllowEmptyCollection()][string[]]$Arguments = @())
  return (($Arguments | ForEach-Object { ConvertTo-CodexMeterProcessArgument -Value $_ }) -join ' ')
}

function Test-CodexMeterCommandLineToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])'
  return [regex]::IsMatch($CommandLine, $pattern)
}

# Windows PowerShell 5.1 promotes native stderr to terminating errors when
# $ErrorActionPreference is Stop. Relax it for taskkill / other native tools.
function Invoke-CodexMeterNative {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $nativeOutput = @(& $FilePath @ArgumentList 2>&1)
    return [pscustomobject]@{
      Output = @($nativeOutput | ForEach-Object { "$_" })
      ExitCode = [int]$LASTEXITCODE
    }
  } finally {
    $ErrorActionPreference = $previousPreference
  }
}

function Stop-CodexMeterByImageName {
  param([Parameter(Mandatory = $true)][string]$ImageName)
  if (-not $ImageName) { return }
  # 0 = success, 128 = process not found — both are fine for stop.
  $result = Invoke-CodexMeterNative -FilePath 'taskkill.exe' -ArgumentList @('/IM', $ImageName, '/F')
  if ($result.ExitCode -in @(0, 128)) { return }
  $detail = ($result.Output -join ' ').Trim()
  if ($detail -match '(?i)not found') { return }
  Write-Host "[codex-meter] taskkill /IM $ImageName exited $($result.ExitCode): $detail"
}

function Get-CodexMeterProcessExecutablePath {
  param([Parameter(Mandatory = $true)][object]$ProcessInfo)
  if ($ProcessInfo.ExecutablePath) { return "$($ProcessInfo.ExecutablePath)" }
  # Get-Process.Path often works when Win32 ExecutablePath is blank for Store apps.
  # Do not touch MainModule — it can hang on protected processes.
  try {
    $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction Stop
    if ($process.Path) { return "$($process.Path)" }
  } catch {
  }
  return $null
}

function Test-CodexMeterProcessMatchesCodex {
  param(
    [Parameter(Mandatory = $true)][object]$ProcessInfo,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  $leaf = [IO.Path]::GetFileName($Codex.Executable)
  if ("$($ProcessInfo.Name)" -ine $leaf) { return $false }

  $path = Get-CodexMeterProcessExecutablePath -ProcessInfo $ProcessInfo
  if ($path -and (Test-CodexMeterPathEqual -Left $path -Right $Codex.Executable)) {
    return $true
  }
  $commandLine = "$($ProcessInfo.CommandLine)"
  if ($commandLine -and $Codex.PackageRoot -and
    $commandLine.IndexOf($Codex.PackageRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    return $true
  }
  if ($commandLine -and $Codex.PackageFamilyName -and
    $commandLine.IndexOf($Codex.PackageFamilyName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    return $true
  }
  # Store/Beta often exposes a readable path/cmdline that does not include the
  # package root, or hides both. The unique image name is enough once matched.
  return $true
}

function Initialize-CodexMeterPackageLauncher {
  if ('CodexMeter.PackageLauncher' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexMeter {
  [Flags]
  internal enum ActivateOptions : uint {
    None = 0
  }

  [ComImport]
  [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      ActivateOptions options,
      out uint processId);
  }

  [ComImport]
  [Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  internal class ApplicationActivationManager {}

  public static class PackageLauncher {
    public static uint Launch(string appUserModelId, string arguments) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      try {
        uint processId;
        int result = manager.ActivateApplication(
          appUserModelId,
          arguments ?? string.Empty,
          ActivateOptions.None,
          out processId);
        Marshal.ThrowExceptionForHR(result);
        return processId;
      } finally {
        if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
      }
    }
  }
}
'@
}

function New-CodexMeterInstallObject {
  if ($AppUserModelId -cnotmatch '^[A-Za-z0-9._-]{1,128}![A-Za-z0-9._-]{1,64}$') {
    Write-CodexMeterFailure -Code 'invalid-identity' -Message 'AppUserModelId is invalid.'
  }
  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    Write-CodexMeterFailure -Code 'invalid-identity' -Message 'Codex executable path does not exist.'
  }
  if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    Write-CodexMeterFailure -Code 'invalid-identity' -Message 'Codex package root does not exist.'
  }
  $relativeOk = $Executable.StartsWith($PackageRoot, [StringComparison]::OrdinalIgnoreCase)
  if (-not $relativeOk) {
    Write-CodexMeterFailure -Code 'invalid-identity' -Message 'Executable is outside the provided package root.'
  }
  $family = if ($PackageFamilyName) { $PackageFamilyName } else { ($AppUserModelId -split '!')[0] }
  $appId = ($AppUserModelId -split '!', 2)[1]
  return [pscustomobject]@{
    AppUserModelId = $AppUserModelId
    Executable = [System.IO.Path]::GetFullPath($Executable)
    PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
    Version = $Version
    PackageName = $PackageName
    PackageFamilyName = $family
    ApplicationId = $appId
    PackageFullName = $PackageFullName
    SignatureKind = 'Store'
  }
}

function Get-CodexMeterCodexProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $leaf = [IO.Path]::GetFileName($Codex.Executable)
  # Avoid WQL Name filters with parentheses (ChatGPT (Beta).exe).
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      "$($_.Name)" -ieq $leaf -and
      (Test-CodexMeterProcessMatchesCodex -ProcessInfo $_ -Codex $Codex)
    })
}

function Get-CodexMeterCodexProcessesExcept {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @()
  )
  $preserved = @{}
  foreach ($processId in $PreserveProcessIds) {
    if ($processId -gt 0) { $preserved[$processId] = $true }
  }
  return @(
    Get-CodexMeterCodexProcesses -Codex $Codex | Where-Object {
      -not $preserved.ContainsKey([int]$_.ProcessId)
    }
  )
}

function Stop-CodexMeterCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @(),
    [switch]$AllowForce
  )
  $leaf = [IO.Path]::GetFileName($Codex.Executable)
  $processes = Get-CodexMeterCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($processes.Count -eq 0) {
    # Path matching can miss Store processes; force by image name when allowed.
    if ($AllowForce -and $leaf) {
      Stop-CodexMeterByImageName -ImageName $leaf
      Start-Sleep -Milliseconds 500
    }
    return
  }
  foreach ($item in $processes) {
    try { [void](Get-Process -Id $item.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
  }
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-CodexMeterCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds).Count -gt 0 -and
    (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  $remaining = Get-CodexMeterCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($remaining.Count -eq 0) { return }
  if (-not $AllowForce) {
    throw 'Codex did not close within 8 seconds.'
  }
  foreach ($item in $remaining) {
    Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
  }
  if ($leaf) {
    Stop-CodexMeterByImageName -ImageName $leaf
  }
  Start-Sleep -Milliseconds 800
  if ((Get-CodexMeterCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds).Count -gt 0) {
    throw 'Codex could not be stopped safely.'
  }
}

function Start-CodexMeterCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][string[]]$Arguments = @()
  )
  Initialize-CodexMeterPackageLauncher
  $argumentLine = ConvertTo-CodexMeterArgumentLine -Arguments $Arguments
  $processId = [CodexMeter.PackageLauncher]::Launch($Codex.AppUserModelId, $argumentLine)
  if ($processId -le 0) { throw 'Windows did not return a Codex process ID after package activation.' }
  return $processId
}

function Assert-CodexMeterDirectLaunchTarget {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $expectedAumid = "$($Codex.PackageFamilyName)!$($Codex.ApplicationId)"
  if ("$($Codex.SignatureKind)" -ine 'Store' -or
    "$($Codex.AppUserModelId)" -cne $expectedAumid -or
    -not (Test-Path -LiteralPath $Codex.Executable -PathType Leaf) -or
    -not $Codex.Executable.StartsWith($Codex.PackageRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Direct launch requires the exact executable from the validated Codex Store package.'
  }
}

function Start-CodexMeterCodexDirect {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
  )
  Assert-CodexMeterDirectLaunchTarget -Codex $Codex
  $argumentLine = ConvertTo-CodexMeterArgumentLine -Arguments $Arguments
  $process = Start-Process -FilePath "$($Codex.Executable)" -ArgumentList $argumentLine `
    -PassThru -ErrorAction Stop
  try {
    if ($process.Id -le 0) { throw 'Windows did not return a Codex process ID after direct launch.' }
    return $process.Id
  } finally {
    $process.Dispose()
  }
}

function Get-CodexMeterDirectLaunchFailureKind {
  param([Parameter(Mandatory = $true)][System.Exception]$Exception)
  $current = $Exception
  while ($null -ne $current) {
    if ($current -is [System.UnauthorizedAccessException] -or
      ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 5) -or
      $current.HResult -eq -2147024891) {
      return 'access-denied'
    }
    $current = $current.InnerException
  }
  return 'start-failed'
}

function Get-CodexMeterCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
    [Parameter(Mandatory = $true)][int]$Port
  )
  $flag = "--remote-debugging-port=$Port"
  $encodedFlag = [Uri]::EscapeDataString($flag)
  $sawReadableCommandLine = $false
  $sawProtocolRedirect = $false
  foreach ($process in $Processes) {
    $commandLine = "$($process.CommandLine)"
    if (-not $commandLine) { continue }
    $sawReadableCommandLine = $true
    $protocolPattern = '(?i)(?<!\S)"?(?<url>codex://[^\s"]*)"?'
    $protocolMatches = [regex]::Matches($commandLine, $protocolPattern)
    foreach ($protocolMatch in $protocolMatches) {
      $protocolArgument = $protocolMatch.Groups['url'].Value
      if ($protocolArgument.IndexOf($encodedFlag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $protocolArgument.IndexOf($flag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $sawProtocolRedirect = $true
      }
    }
    $rawArguments = [regex]::Replace($commandLine, $protocolPattern, ' ')
    if (Test-CodexMeterCommandLineToken -CommandLine $rawArguments -Token $flag) {
      return 'forwarded'
    }
  }
  if ($sawProtocolRedirect) { return 'protocol-redirected' }
  if ($sawReadableCommandLine) { return 'not-forwarded' }
  return 'uninspectable'
}

function Wait-CodexMeterCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutSeconds = 5
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = 'uninspectable'
  do {
    $processes = @(Get-CodexMeterCodexProcesses -Codex $Codex)
    $lastStatus = Get-CodexMeterCodexDebugArgumentStatus -Processes $processes -Port $Port
    if ($lastStatus -in @('forwarded', 'protocol-redirected')) { return $lastStatus }
    if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  } while ((Get-Date) -lt $deadline)
  return $lastStatus
}

function Test-CodexMeterWebSocketUrl {
  param([string]$Value, [int]$Port)
  try {
    $uri = [Uri]$Value
    $hostName = $uri.Host.ToLowerInvariant()
    return ($uri.IsAbsoluteUri -and $uri.Scheme -eq 'ws' -and $uri.Port -eq $Port -and
      $hostName -in @('127.0.0.1', 'localhost', '::1', '[::1]') -and -not $uri.UserInfo -and
      -not $uri.Query -and -not $uri.Fragment -and
      $uri.AbsolutePath -cmatch '^/devtools/(?:page|browser)/[A-Za-z0-9._-]{1,200}$')
  } catch {
    return $false
  }
}

function Test-CodexMeterBrowserId {
  param([string]$Value)
  return [bool]($Value -and $Value.Length -le 200 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Test-CodexMeterCdpPageTarget {
  param([AllowNull()][object]$Target, [int]$Port)
  if ($null -eq $Target -or "$($Target.type)" -cne 'page' -or
    "$($Target.url)" -notlike 'app://*') {
    return $false
  }
  if ($Target.id -isnot [string]) { return $false }
  $targetId = "$($Target.id)"
  $webSocketUrl = "$($Target.webSocketDebuggerUrl)"
  if (-not (Test-CodexMeterBrowserId -Value $targetId) -or
    -not (Test-CodexMeterWebSocketUrl -Value $webSocketUrl -Port $Port)) {
    return $false
  }
  try {
    return ([Uri]$webSocketUrl).AbsolutePath -ceq "/devtools/page/$targetId"
  } catch {
    return $false
  }
}

function Get-CodexMeterPortListeners {
  param([int]$Port)
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to verify CDP listener ownership.'
  }
  return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Get-CodexMeterListeningPortsInRange {
  param([int]$PreferredPort)
  $maxPort = [Math]::Min(65535, $PreferredPort + 100)
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    return @($PreferredPort)
  }
  # One query for the range — never probe 101 ports individually (Get-NetTCPConnection is slow).
  $listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object {
      [int]$_.LocalPort -ge $PreferredPort -and [int]$_.LocalPort -le $maxPort -and
      $_.LocalAddress -in @('127.0.0.1', '::1')
    } |
    ForEach-Object { [int]$_.LocalPort } |
    Select-Object -Unique |
    Sort-Object)
  $ports = [System.Collections.Generic.List[int]]::new()
  [void]$ports.Add($PreferredPort)
  foreach ($port in $listening) {
    if (-not $ports.Contains($port)) { [void]$ports.Add($port) }
  }
  return @($ports)
}

function Test-CodexMeterPortAvailable {
  param([int]$Port)
  # Prefer bind probe — faster and more reliable than Get-NetTCPConnection alone.
  $listener = $null
  try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) { $listener.Stop() }
  }
}

function Select-CodexMeterPort {
  param([int]$PreferredPort)
  $maxPort = [Math]::Min(65535, $PreferredPort + 100)
  for ($candidate = $PreferredPort; $candidate -le $maxPort; $candidate++) {
    if (Test-CodexMeterPortAvailable -Port $candidate) {
      return $candidate
    }
  }
  throw "No free loopback port was found between $PreferredPort and $maxPort."
}

function Get-CodexMeterPortProbeList {
  param(
    [int]$PreferredPort,
    [switch]$ScanRange
  )
  if (-not $ScanRange) { return @($PreferredPort) }
  return @(Get-CodexMeterListeningPortsInRange -PreferredPort $PreferredPort)
}

function Test-CodexMeterProcessDescendsFromCodex {
  param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  if ($ProcessId -le 0) { return $false }
  $seen = @{}
  $current = $ProcessId
  for ($depth = 0; $depth -lt 24 -and $current -gt 0; $depth++) {
    if ($seen.ContainsKey($current)) { return $false }
    $seen[$current] = $true
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if (Test-CodexMeterProcessMatchesCodex -ProcessInfo $process -Codex $Codex) { return $true }
    $current = [int]$process.ParentProcessId
  }
  return $false
}

function Test-CodexMeterIsLoopbackAddress {
  param([AllowNull()][string]$Address)
  if (-not $Address) { return $false }
  return $Address -in @('127.0.0.1', '::1', '[::1]', '0.0.0.0', '::')
}

function Test-CodexMeterForeignCdpOwner {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  $leaf = [IO.Path]::GetFileName($Codex.Executable)
  $foreign = @(
    'chrome.exe', 'msedge.exe', 'msedgewebview2.exe', 'brave.exe', 'chromium.exe',
    'opera.exe', 'vivaldi.exe', 'firefox.exe', 'slack.exe', 'discord.exe'
  )
  foreach ($listener in @(Get-CodexMeterPortListeners -Port $Port)) {
    $owning = [int]$listener.OwningProcess
    if ($owning -le 0) { continue }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$owning" -ErrorAction SilentlyContinue
    if (-not $process) { continue }
    $name = "$($process.Name)"
    if ($name -ieq $leaf) { continue }
    if ($foreign -contains $name.ToLowerInvariant()) { return $true }
  }
  return $false
}

function Test-CodexMeterCodexPortOwner {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  $listeners = @(Get-CodexMeterPortListeners -Port $Port | Where-Object {
      Test-CodexMeterIsLoopbackAddress -Address $_.LocalAddress
    })
  if ($listeners.Count -eq 0) { return $false }
  $checked = 0
  foreach ($listener in $listeners) {
    $owning = [int]$listener.OwningProcess
    if ($owning -le 0) { continue }
    $checked++
    if (-not (Test-CodexMeterProcessDescendsFromCodex -ProcessId $owning -Codex $Codex)) {
      return $false
    }
  }
  # OwningProcess is often 0 without elevation; treat as inconclusive, not owned.
  return ($checked -gt 0)
}

function Test-CodexMeterListenerOwnedByCodex {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  if (Test-CodexMeterCodexPortOwner -Port $Port -Codex $Codex) { return $true }
  $leaf = [IO.Path]::GetFileName($Codex.Executable)
  foreach ($listener in @(Get-CodexMeterPortListeners -Port $Port)) {
    if (-not (Test-CodexMeterIsLoopbackAddress -Address $listener.LocalAddress)) { continue }
    $owning = [int]$listener.OwningProcess
    if ($owning -le 0) { continue }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$owning" -ErrorAction SilentlyContinue
    if ($process -and "$($process.Name)" -ieq $leaf) { return $true }
    if ($process -and (Test-CodexMeterProcessDescendsFromCodex -ProcessId $owning -Codex $Codex)) {
      return $true
    }
  }
  return $false
}

function Get-CodexMeterCdpBrowserIdentity {
  param([int]$Port)
  try {
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    $webSocketUrl = "$($version.webSocketDebuggerUrl)"
    if (-not (Test-CodexMeterWebSocketUrl -Value $webSocketUrl -Port $Port)) { return $null }
    $uri = [Uri]$webSocketUrl
    $match = [regex]::Match($uri.AbsolutePath, '^/devtools/browser/(?<id>[A-Za-z0-9._-]{1,200})$')
    if (-not $match.Success -or $uri.Query -or $uri.Fragment) { return $null }
    $browserId = $match.Groups['id'].Value
    if (-not (Test-CodexMeterBrowserId -Value $browserId)) { return $null }
    return [pscustomobject]@{
      BrowserId = $browserId
      WebSocketDebuggerUrl = $webSocketUrl
    }
  } catch {
    return $null
  }
}

function Get-CodexMeterVerifiedCdpIdentity {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex,
    [switch]$AllowUnownedLoopback
  )
  $browser = Get-CodexMeterCdpBrowserIdentity -Port $Port
  if ($null -eq $browser) { return $null }

  # Never attach to a known foreign browser on this port.
  if (Test-CodexMeterForeignCdpOwner -Port $Port -Codex $Codex) { return $null }

  $owned = Test-CodexMeterListenerOwnedByCodex -Port $Port -Codex $Codex
  if (-not $owned -and -not $AllowUnownedLoopback) { return $null }

  $pageCount = 0
  try {
    $pageCount = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop |
      Where-Object { Test-CodexMeterCdpPageTarget -Target $_ -Port $Port }).Count
  } catch {
  }

  return [pscustomobject]@{
    BrowserId = $browser.BrowserId
    BrowserWebSocketDebuggerUrl = $browser.WebSocketDebuggerUrl
    TargetCount = $pageCount
    Owned = $owned
  }
}

function Get-CodexMeterCdpFailureHint {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  $parts = [System.Collections.Generic.List[string]]::new()
  $browser = Get-CodexMeterCdpBrowserIdentity -Port $Port
  if ($null -eq $browser) {
    [void]$parts.Add('browser=missing')
  } else {
    [void]$parts.Add("browser=$($browser.BrowserId)")
  }
  [void]$parts.Add("owned=$(Test-CodexMeterListenerOwnedByCodex -Port $Port -Codex $Codex)")
  [void]$parts.Add("foreign=$(Test-CodexMeterForeignCdpOwner -Port $Port -Codex $Codex)")
  $listenerInfo = @(Get-CodexMeterPortListeners -Port $Port | ForEach-Object {
      "$($_.LocalAddress)/pid=$($_.OwningProcess)"
    })
  [void]$parts.Add("listeners=[$($listenerInfo -join '; ')]")
  try {
    $all = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop)
    $urls = @($all | ForEach-Object {
        $url = "$($_.url)"
        if ($url.Length -gt 80) { $url = $url.Substring(0, 80) + '...' }
        "$($_.type):$url"
      })
    [void]$parts.Add("list=$($all.Count)[$($urls -join ' | ')]")
  } catch {
    [void]$parts.Add("list-error=$($_.Exception.Message)")
  }
  return ($parts -join ', ')
}

function Wait-CodexMeterVerifiedCdpIdentity {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex,
    [int]$TimeoutSeconds = 45,
    [switch]$AllowUnownedLoopback
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $identity = Get-CodexMeterVerifiedCdpIdentity -Port $Port -Codex $Codex `
      -AllowUnownedLoopback:$AllowUnownedLoopback
    if ($null -ne $identity) { return $identity }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

function Start-CodexMeterCodexForDebugging {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [Parameter(Mandatory = $true)][int]$Port,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds
  )
  $preservedProcessIds = if ($PSBoundParameters.ContainsKey('PreserveProcessIds')) {
    @($PreserveProcessIds)
  } else {
    @(Get-CodexMeterCodexProcesses -Codex $Codex | ForEach-Object { [int]$_.ProcessId })
  }
  $packageProcessId = Start-CodexMeterCodex -Codex $Codex -Arguments $Arguments
  $packageStatus = Wait-CodexMeterCodexDebugArgumentStatus -Codex $Codex -Port $Port
  Write-Host "[codex-meter] package-activation argumentStatus=$packageStatus"

  $needsDirectFallback = $false
  if ($packageStatus -eq 'protocol-redirected') {
    $needsDirectFallback = $true
  } elseif ($packageStatus -in @('uninspectable', 'not-forwarded')) {
    # Store/Beta often hides command lines, so owl redirect cannot be proven.
    # Give package activation a short window to expose CDP before trying direct.
    Write-Host '[codex-meter] cmdline unreadable/not-forwarded; waiting 8s for CDP before direct fallback'
    $early = Wait-CodexMeterVerifiedCdpIdentity -Port $Port -Codex $Codex -TimeoutSeconds 8 `
      -AllowUnownedLoopback
    if ($null -ne $early) {
      return [pscustomobject]@{
        ProcessId = $packageProcessId
        Strategy = 'package-activation'
        ArgumentStatus = $packageStatus
        PackageArgumentStatus = $packageStatus
      }
    }
    $needsDirectFallback = $true
  }

  if (-not $needsDirectFallback) {
    return [pscustomobject]@{
      ProcessId = $packageProcessId
      Strategy = 'package-activation'
      ArgumentStatus = $packageStatus
      PackageArgumentStatus = $packageStatus
    }
  }

  Write-Host "[codex-meter] attempting direct Store executable launch (reason=$packageStatus)"
  try {
    Stop-CodexMeterCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
  } catch {
    throw "Codex package activation did not retain CDP arguments, and its process could not be closed: $($_.Exception.Message)"
  }

  try {
    $directProcessId = Start-CodexMeterCodexDirect -Codex $Codex -Arguments $Arguments
  } catch {
    $failureKind = Get-CodexMeterDirectLaunchFailureKind -Exception $_.Exception
    throw [System.InvalidOperationException]::new(
      "protocol-redirect-$failureKind",
      $_.Exception)
  }

  $directStatus = Wait-CodexMeterCodexDebugArgumentStatus -Codex $Codex -Port $Port
  Write-Host "[codex-meter] direct-launch argumentStatus=$directStatus"
  if ($directStatus -in @('protocol-redirected', 'not-forwarded')) {
    try {
      Stop-CodexMeterCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
    } catch {
      throw "Direct Codex launch did not retain CDP arguments and could not be closed: $($_.Exception.Message)"
    }
    throw 'Codex did not retain the CDP argument during package activation or validated direct launch.'
  }

  return [pscustomobject]@{
    ProcessId = $directProcessId
    Strategy = 'direct-store-executable'
    ArgumentStatus = $directStatus
    PackageArgumentStatus = $packageStatus
  }
}

function Invoke-CodexMeterRollback {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @()
  )
  try {
    Stop-CodexMeterCodex -Codex $Codex -PreserveProcessIds $PreserveProcessIds -AllowForce
  } catch {
    # Best effort.
  }
  if ((Get-CodexMeterCodexProcesses -Codex $Codex).Count -eq 0) {
    try {
      [void](Start-CodexMeterCodex -Codex $Codex -Arguments @())
    } catch {
      # Best effort reopen without CDP.
    }
  }
}

# --- Main ---
$codex = New-CodexMeterInstallObject
Write-Host "[codex-meter] resolved $($codex.PackageName) $($codex.Version)"

# Probe PreferredPort and any currently-listening ports in +100 for verified CDP.
$portCandidates = @(Get-CodexMeterPortProbeList -PreferredPort $PreferredPort -ScanRange:$AllowPortScan)
Write-Host "[codex-meter] probing ports: $($portCandidates -join ',')"
$codexAlreadyRunning = ((Get-CodexMeterCodexProcesses -Codex $codex).Count -gt 0)
foreach ($probePort in $portCandidates) {
  # Store apps often leave OwningProcess=0 on the CDP listener. If Codex is
  # already running for this package (and the owner is not a known foreign
  # browser), accept the loopback /json/version endpoint for reuse.
  $existing = Get-CodexMeterVerifiedCdpIdentity -Port $probePort -Codex $codex `
    -AllowUnownedLoopback:$codexAlreadyRunning
  if ($null -ne $existing) {
    Write-CodexMeterResult @{
      ok = $true
      port = $probePort
      browserId = $existing.BrowserId
      strategy = 'reused-existing'
      packageName = $codex.PackageName
      version = $codex.Version
      packageFamilyName = $codex.PackageFamilyName
      owned = $existing.Owned
    }
    exit 0
  }
}

if ($SkipLaunch) {
  $rangeNote = if ($AllowPortScan) {
    "ports $PreferredPort-$([Math]::Min(65535, $PreferredPort + 100))"
  } else {
    "port $PreferredPort"
  }
  Write-CodexMeterFailure -Code 'cdp-unavailable' -Message "No verified Codex CDP endpoint is available on $rangeNote."
}

$preserved = if ($PreserveProcessIds.Count -gt 0) {
  @($PreserveProcessIds)
} else {
  @(Get-CodexMeterCodexProcesses -Codex $codex | ForEach-Object { [int]$_.ProcessId })
}

$debugLaunchAttempted = $false
try {
  Write-Host '[codex-meter] stopping existing Codex...'
  Stop-CodexMeterCodex -Codex $codex -PreserveProcessIds @() -AllowForce
  $preserved = @()
  $debugLaunchAttempted = $true

  if ($AllowPortScan) {
    $port = Select-CodexMeterPort -PreferredPort $PreferredPort
  } else {
    $port = $PreferredPort
    if (-not (Test-CodexMeterPortAvailable -Port $port)) {
      throw "Preferred port $port is busy and -AllowPortScan was not enabled."
    }
  }
  if ($port -ne $PreferredPort) {
    Write-Host "[codex-meter] preferred port $PreferredPort is busy; using $port (scan range +100)"
  } else {
    Write-Host "[codex-meter] launching with CDP on port $port"
  }

  $arguments = @(
    '--remote-debugging-address=127.0.0.1',
    "--remote-debugging-port=$port"
  )

  $launch = Start-CodexMeterCodexForDebugging -Codex $codex -Arguments $arguments -Port $port `
    -PreserveProcessIds $preserved
  Write-Host "[codex-meter] launch strategy=$($launch.Strategy) argumentStatus=$($launch.ArgumentStatus); waiting for CDP..."
  # After we launched with CDP flags, trust loopback /json/version even when
  # Get-NetTCPConnection cannot resolve OwningProcess (common for Store apps).
  $identity = Wait-CodexMeterVerifiedCdpIdentity -Port $port -Codex $codex `
    -TimeoutSeconds $CdpTimeoutSeconds -AllowUnownedLoopback
  if ($null -eq $identity) {
    $status = Wait-CodexMeterCodexDebugArgumentStatus -Codex $codex -Port $port -TimeoutSeconds 1
    $listenerCount = @(Get-CodexMeterPortListeners -Port $port).Count
    $httpHint = 'none'
    try {
      $ver = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 2 -MaximumRedirection 0
      $httpHint = "browser=$($ver.Browser); ws=$($ver.webSocketDebuggerUrl)"
    } catch {
      $httpHint = "http-error=$($_.Exception.Message)"
    }
    Write-Host "[codex-meter] CDP wait failed; cmdline status=$status listeners=$listenerCount http=$httpHint; $(Get-CodexMeterCdpFailureHint -Port $port -Codex $codex)"
    if ($status -eq 'protocol-redirected') {
      throw 'Codex converted CDP arguments into a codex:// path and no verified listener became available.'
    }
    if ($launch.Strategy -eq 'direct-store-executable') {
      throw 'Direct Store launch retained raw arguments but no verified CDP listener appeared.'
    }
    throw 'No verified loopback CDP endpoint became available within the timeout.'
  }
  Write-CodexMeterResult @{
    ok = $true
    port = $port
    browserId = $identity.BrowserId
    strategy = $launch.Strategy
    argumentStatus = $launch.ArgumentStatus
    packageName = $codex.PackageName
    version = $codex.Version
    packageFamilyName = $codex.PackageFamilyName
    preferredPort = $PreferredPort
  }
  exit 0
} catch {
  $message = $_.Exception.Message
  $code = 'launch-failed'
  if ($message -match 'protocol-redirect-access-denied') {
    $code = 'protocol-redirect-access-denied'
  } elseif ($message -match 'protocol-redirect-start-failed') {
    $code = 'protocol-redirect-start-failed'
  } elseif ($message -match 'codex://' -or $message -match 'did not retain the CDP') {
    $code = 'protocol-redirect-failed'
  } elseif ($message -match 'No free loopback port' -or $message -match 'AllowPortScan was not enabled') {
    $code = 'port-unavailable'
  } elseif ($message -match 'verified CDP' -or $message -match 'timeout' -or $message -match 'listener') {
    $code = 'cdp-timeout'
  }
  Write-Host "[codex-meter] launch error code=$code message=$message"
  if ($debugLaunchAttempted) {
    Invoke-CodexMeterRollback -Codex $codex -PreserveProcessIds $preserved
  }
  Write-CodexMeterFailure -Code $code -Message $message
}
