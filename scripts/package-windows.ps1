[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("exe", "windows")]
  [string]$Target
)

$ErrorActionPreference = "Stop"

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

$tauriArguments = if ($Target -eq "exe") { "--no-bundle" } else { "--bundles msi,nsis" }
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoTargetDir = Join-Path $projectRoot "src-tauri\target"
if (Test-Path -LiteralPath $cargoTargetDir) {
  Remove-Item -LiteralPath $cargoTargetDir -Recurse -Force
}

$command = "call `"$devCmd`" -arch=x64 -host_arch=x64 >nul && cd /d `"$projectRoot`" && set `"CARGO_TARGET_DIR=$cargoTargetDir`" && npx tauri build $tauriArguments"
cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
