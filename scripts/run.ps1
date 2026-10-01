param([switch]$Editor)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchainFile = Join-Path $projectRoot '.tools\toolchain.json'
if (-not (Test-Path -LiteralPath $toolchainFile)) { throw 'Run scripts/setup_toolchain.ps1 and native/build.ps1 first.' }
$toolchain = Get-Content -LiteralPath $toolchainFile -Raw | ConvertFrom-Json
$arguments = @('--path', $projectRoot)
if ($Editor) { $arguments += '--editor' }
Start-Process -FilePath $toolchain.godot_exe -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $projectRoot
