param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$OutputDirectory = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $root "clipy_android/build/windows"
$candidates = @(Get-ChildItem $buildRoot -Filter ClipyClone.exe -Recurse -File |
  Where-Object { $_.Directory.Name -eq "Release" })
if ($candidates.Count -ne 1) {
  throw "Expected one Windows Release executable; found $($candidates.Count)."
}
$bundle = $candidates[0].Directory.FullName
foreach ($required in @("ClipyClone.exe", "flutter_windows.dll", "data/flutter_assets")) {
  if (-not (Test-Path (Join-Path $bundle $required))) {
    throw "Missing Windows runtime item: $required"
  }
}

$output = Join-Path $root $OutputDirectory
New-Item -ItemType Directory -Force -Path $output | Out-Null
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$stage = Join-Path $temporaryRoot "clipy-windows-package"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $bundle "*") $stage -Recurse -Force

# Flutter's unpackaged ZIP needs the MSVC runtime on a clean machine.
foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
  $runtime = Join-Path $env:WINDIR "System32/$dll"
  if (-not (Test-Path $runtime)) { throw "Missing MSVC runtime: $runtime" }
  Copy-Item $runtime (Join-Path $stage $dll) -Force
}
Copy-Item (Join-Path $root "LICENSE") $stage
Copy-Item (Join-Path $root "THIRD_PARTY_NOTICES.md") $stage

$archive = Join-Path $output "ClipyClone-Windows-x64-v$Version.zip"
if (Test-Path $archive) { Remove-Item -Force $archive }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $archive -CompressionLevel Optimal

$verify = Join-Path $temporaryRoot "clipy-windows-verify"
if (Test-Path $verify) { Remove-Item -Recurse -Force $verify }
Expand-Archive -Path $archive -DestinationPath $verify
foreach ($required in @("ClipyClone.exe", "flutter_windows.dll", "data/flutter_assets", "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
  if (-not (Test-Path (Join-Path $verify $required))) {
    throw "Archive verification failed: $required"
  }
}
Write-Output $archive
