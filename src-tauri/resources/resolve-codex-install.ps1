# Resolves the official OpenAI.Codex / OpenAI.CodexBeta Store package identity for CDP launch.
# Outputs a single-line JSON object on success; Write-Error + exit 1 on failure.
# Logic adapted from Codex-Dream-Skin ConvertTo-DreamSkinCodexInstall.

$ErrorActionPreference = 'Stop'

$script:CodexPackageNames = @('OpenAI.Codex', 'OpenAI.CodexBeta')
$script:CodexExecutables = @('app\ChatGPT.exe', 'app\ChatGPT (Beta).exe')

function Test-CodexMeterExecutablePath {
  param([AllowNull()][string]$Executable)
  if (-not $Executable) { return $false }
  $normalized = "$Executable".Replace('/', '\')
  foreach ($candidate in $script:CodexExecutables) {
    if ($normalized -ieq $candidate) { return $true }
  }
  return $false
}

function ConvertTo-CodexMeterInstall {
  param(
    [Parameter(Mandatory = $true)][object]$Package
  )
  if ($script:CodexPackageNames -inotcontains "$($Package.Name)" -or -not $Package.InstallLocation -or
    -not $Package.PackageFullName -or -not $Package.PackageFamilyName -or
    "$($Package.SignatureKind)" -ine 'Store' -or [bool]$Package.IsDevelopmentMode) {
    return $null
  }

  $packageRoot = "$($Package.InstallLocation)"

  try {
    $manifest = Get-AppxPackageManifest -Package $Package -ErrorAction Stop
    $applications = @($manifest.Package.Applications.Application | Where-Object {
      Test-CodexMeterExecutablePath -Executable "$($_.Executable)"
    })
  } catch {
    return $null
  }

  if ($applications.Count -eq 0) {
    return @{ Reason = 'missing-application' }
  }
  if ($applications.Count -ne 1) {
    return @{ Reason = 'ambiguous-application' }
  }

  $applicationId = "$($applications[0].Id)"
  $relativeExecutable = "$($applications[0].Executable)".Replace('/', '\')
  $executable = Join-Path $packageRoot $relativeExecutable
  if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    return $null
  }

  $packageFamilyName = "$($Package.PackageFamilyName)"
  if ($packageFamilyName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
    $applicationId -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
    return @{ Reason = 'invalid-identity' }
  }

  return [pscustomobject]@{
    packageRoot = $packageRoot
    executable = $executable
    version = "$($Package.Version)"
    packageFullName = "$($Package.PackageFullName)"
    packageFamilyName = $packageFamilyName
    applicationId = $applicationId
    appUserModelId = "$packageFamilyName!$applicationId"
    packageName = "$($Package.Name)"
  }
}

$packages = @()
foreach ($name in $script:CodexPackageNames) {
  try {
    $packages += @(Get-AppxPackage -Name $name -ErrorAction Stop)
  } catch {
    # Package name may be absent; continue scanning remaining names.
  }
}

$packages = @($packages | Sort-Object Version -Descending)
if ($packages.Count -eq 0) {
  Write-Error 'OpenAI.Codex Store package is not installed'
  exit 1
}

$lastReason = $null
foreach ($package in $packages) {
  $result = ConvertTo-CodexMeterInstall -Package $package
  if ($null -eq $result) {
    continue
  }
  if ($result -is [hashtable] -and $result.ContainsKey('Reason')) {
    $lastReason = "$($result.Reason)"
    continue
  }

  $payload = [ordered]@{
    appUserModelId = $result.appUserModelId
    packageRoot = $result.packageRoot
    executable = $result.executable
    version = $result.version
    packageName = $result.packageName
    packageFamilyName = $result.packageFamilyName
  }
  Write-Output ($payload | ConvertTo-Json -Compress)
  exit 0
}

switch ($lastReason) {
  'missing-application' {
    Write-Error 'Manifest has no Application for app\ChatGPT.exe'
  }
  'ambiguous-application' {
    Write-Error 'Application identity is invalid or ambiguous'
  }
  'invalid-identity' {
    Write-Error 'Application identity is invalid or ambiguous'
  }
  default {
    Write-Error 'Codex Store package found but identity failed validation'
  }
}
exit 1
