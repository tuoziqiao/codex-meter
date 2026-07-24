[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("exe", "windows")]
  [string]$Target
)

$ErrorActionPreference = "Stop"

# Pinned Node.js LTS used for the with-node Windows installers only.
$NodeVersion = "22.22.2"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
  throw "Visual Studio Build Tools was not found. Install the Desktop development with C++ workload and try again."
}

$installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installationPath) {
  throw "MSVC C++ tools were not found. Install the Desktop development with C++ workload in Visual Studio Build Tools."
}

$devCmd = Join-Path $installationPath "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path -LiteralPath $devCmd)) {
  throw "VsDevCmd.bat was not found: $devCmd"
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoTargetDir = Join-Path $projectRoot "src-tauri\target"
$runtimeDir = Join-Path $projectRoot "src-tauri\resources\runtime"
$stagedNode = Join-Path $runtimeDir "node.exe"
$nodeCacheRoot = Join-Path $projectRoot "src-tauri\.node-runtime-cache"
$withNodeConfig = Join-Path $PSScriptRoot "tauri.with-node.json"

function Invoke-TauriBuild {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TauriArguments
  )

  if (Test-Path -LiteralPath $cargoTargetDir) {
    Remove-Item -LiteralPath $cargoTargetDir -Recurse -Force
  }

  $command = "call `"$devCmd`" -arch=x64 -host_arch=x64 >nul && cd /d `"$projectRoot`" && set `"CARGO_TARGET_DIR=$cargoTargetDir`" && npx tauri build $TauriArguments"
  cmd.exe /d /s /c $command
  if ($LASTEXITCODE -ne 0) {
    throw "tauri build failed with exit code $LASTEXITCODE"
  }
}

function Get-ExpectedNodeSha256 {
  param([Parameter(Mandatory = $true)][string]$Version)

  $shasumsUrl = "https://nodejs.org/dist/v$Version/SHASUMS256.txt"
  $shasums = (Invoke-WebRequest -Uri $shasumsUrl -UseBasicParsing).Content
  foreach ($line in ($shasums -split "`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^(?<hash>[a-fA-F0-9]{64})\s+win-x64/node\.exe\s*$') {
      return $Matches['hash'].ToLowerInvariant()
    }
  }
  throw "Could not find win-x64/node.exe checksum in SHASUMS256.txt for v$Version"
}

function Ensure-BundledNode {
  param([Parameter(Mandatory = $true)][string]$Version)

  $cacheDir = Join-Path $nodeCacheRoot "node-v$Version-win-x64"
  $cachedNode = Join-Path $cacheDir "node.exe"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

  $expectedHash = Get-ExpectedNodeSha256 -Version $Version

  if (Test-Path -LiteralPath $cachedNode) {
    $actualHash = (Get-FileHash -LiteralPath $cachedNode -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      Write-Host "[package] Cached node.exe hash mismatch; re-downloading v$Version"
      Remove-Item -LiteralPath $cachedNode -Force
    }
  }

  if (-not (Test-Path -LiteralPath $cachedNode)) {
    $downloadUrl = "https://nodejs.org/dist/v$Version/win-x64/node.exe"
    Write-Host "[package] Downloading Node.js v$Version win-x64/node.exe"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $cachedNode -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $cachedNode -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      Remove-Item -LiteralPath $cachedNode -Force -ErrorAction SilentlyContinue
      throw "Downloaded node.exe SHA256 mismatch. Expected $expectedHash, got $actualHash"
    }
  }

  Copy-Item -LiteralPath $cachedNode -Destination $stagedNode -Force
  Write-Host "[package] Staged bundled node.exe at $stagedNode"
}

function Copy-BundleArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$SourceBundleRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [string]$NameSuffix = ""
  )

  foreach ($kind in @("msi", "nsis")) {
    $sourceDir = Join-Path $SourceBundleRoot $kind
    if (-not (Test-Path -LiteralPath $sourceDir)) {
      throw "Expected bundle output missing: $sourceDir"
    }

    $destDir = Join-Path $DestinationRoot $kind
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Get-ChildItem -LiteralPath $destDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

    Get-ChildItem -LiteralPath $sourceDir -File | ForEach-Object {
      $destName = $_.Name
      if ($NameSuffix) {
        $destName = $_.BaseName + $NameSuffix + $_.Extension
      }
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destDir $destName) -Force
    }
  }
}

function Clear-StagedNode {
  if (Test-Path -LiteralPath $stagedNode) {
    Remove-Item -LiteralPath $stagedNode -Force
    Write-Host "[package] Removed staged resources/runtime/node.exe"
  }
}

if ($Target -eq "exe") {
  Clear-StagedNode
  Invoke-TauriBuild -TauriArguments "--no-bundle"
  Write-Host "[package] exe output: $(Join-Path $cargoTargetDir 'release\codex-meter.exe')"
  exit 0
}

# --- Dual Windows installers: lean + with-node ---
Clear-StagedNode

Write-Host "[package] Building lean MSI/NSIS (no bundled Node)..."
Invoke-TauriBuild -TauriArguments "--bundles msi,nsis"

$bundleRoot = Join-Path $cargoTargetDir "release\bundle"
$leanStaging = Join-Path $env:TEMP ("codex-meter-lean-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $leanStaging | Out-Null
try {
  Copy-BundleArtifacts -SourceBundleRoot $bundleRoot -DestinationRoot $leanStaging

  Write-Host "[package] Building with-node MSI/NSIS..."
  Ensure-BundledNode -Version $NodeVersion
  try {
    Invoke-TauriBuild -TauriArguments "--bundles msi,nsis --config `"$withNodeConfig`""

    $withNodeOut = Join-Path (Join-Path $cargoTargetDir "release\bundle") "with-node"
    if (Test-Path -LiteralPath $withNodeOut) {
      Remove-Item -LiteralPath $withNodeOut -Recurse -Force
    }
    $freshBundleRoot = Join-Path $cargoTargetDir "release\bundle"
    Copy-BundleArtifacts -SourceBundleRoot $freshBundleRoot `
      -DestinationRoot $withNodeOut `
      -NameSuffix "-with-node"

    # Restore lean installers as the default bundle/msi and bundle/nsis outputs.
    foreach ($kind in @("msi", "nsis")) {
      $defaultDir = Join-Path $freshBundleRoot $kind
      New-Item -ItemType Directory -Force -Path $defaultDir | Out-Null
      Get-ChildItem -LiteralPath $defaultDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
      Get-ChildItem -LiteralPath (Join-Path $leanStaging $kind) -File | Copy-Item -Destination $defaultDir -Force
    }
  }
  finally {
    Clear-StagedNode
  }
}
finally {
  if (Test-Path -LiteralPath $leanStaging) {
    Remove-Item -LiteralPath $leanStaging -Recurse -Force
  }
}

Write-Host "[package] Lean installers:      $(Join-Path $cargoTargetDir 'release\bundle\msi') and nsis"
Write-Host "[package] With-node installers: $(Join-Path $cargoTargetDir 'release\bundle\with-node')"
