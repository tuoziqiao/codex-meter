# Lightweight self-checks for CDP launch helpers.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-cdp-launch.ps1
# Or: npm run test:cdp

$ErrorActionPreference = 'Stop'
$failed = 0

function Assert-Equal {
  param($Actual, $Expected, [string]$Label)
  if ("$Actual" -cne "$Expected") {
    Write-Host "FAIL: $Label (expected=$Expected actual=$Actual)"
    $script:failed++
  } else {
    Write-Host "ok: $Label"
  }
}

function Test-CodexMeterCommandLineToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])'
  return [regex]::IsMatch($CommandLine, $pattern)
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

function Select-CodexMeterPort {
  param([int]$PreferredPort)
  $maxPort = [Math]::Min(65535, $PreferredPort + 100)
  for ($candidate = $PreferredPort; $candidate -le $maxPort; $candidate++) {
    $listener = $null
    try {
      $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
      $listener.Start()
      return $candidate
    } catch {
    } finally {
      if ($listener) { $listener.Stop() }
    }
  }
  throw "No free loopback port was found between $PreferredPort and $maxPort."
}

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
  $result = Invoke-CodexMeterNative -FilePath 'taskkill.exe' -ArgumentList @('/IM', $ImageName, '/F')
  if ($result.ExitCode -in @(0, 128)) { return }
  $detail = ($result.Output -join ' ').Trim()
  if ($detail -match '(?i)not found') { return }
  throw "taskkill failed for $ImageName exit=$($result.ExitCode) detail=$detail"
}

$forwarded = Get-CodexMeterCodexDebugArgumentStatus -Port 9335 -Processes @(
  [pscustomobject]@{ CommandLine = '"C:\app\ChatGPT.exe" --remote-debugging-port=9335' }
)
Assert-Equal $forwarded 'forwarded' 'raw CDP flag is forwarded'

$redirected = Get-CodexMeterCodexDebugArgumentStatus -Port 9335 -Processes @(
  [pscustomobject]@{ CommandLine = '"C:\app\ChatGPT.exe" codex://threads/new?path=--remote-debugging-port%3D9335' }
)
Assert-Equal $redirected 'protocol-redirected' 'owl protocol redirect is detected'

$notForwarded = Get-CodexMeterCodexDebugArgumentStatus -Port 9335 -Processes @(
  [pscustomobject]@{ CommandLine = '"C:\app\ChatGPT.exe" codex://threads/new' }
)
Assert-Equal $notForwarded 'not-forwarded' 'readable cmdline without flag is not-forwarded'

$uninspectable = Get-CodexMeterCodexDebugArgumentStatus -Port 9335 -Processes @(
  [pscustomobject]@{ CommandLine = '' }
)
Assert-Equal $uninspectable 'uninspectable' 'empty cmdline is uninspectable'

$blocker = $null
try {
  $testPort = 19235
  $blocker = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $testPort)
  $blocker.Start()
  $selected = Select-CodexMeterPort -PreferredPort $testPort
  if ($selected -le $testPort -or $selected -gt ($testPort + 100)) {
    Write-Host "FAIL: port scan after conflict (got $selected)"
    $script:failed++
  } else {
    Write-Host "ok: port conflict on $testPort selected $selected within +100"
  }
} finally {
  if ($blocker) { $blocker.Stop() }
}

try {
  $betaImage = 'ChatGPT' + ' (Beta).exe'
  Stop-CodexMeterByImageName -ImageName $betaImage
  Write-Host 'ok: taskkill missing ChatGPT (Beta).exe is non-fatal'
} catch {
  Write-Host "FAIL: taskkill missing process became fatal: $($_.Exception.Message)"
  $script:failed++
}

if ($failed -gt 0) {
  Write-Host "$failed assertion(s) failed."
  exit 1
}
Write-Host 'All CDP launch helper checks passed.'
exit 0
