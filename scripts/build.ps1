param([switch]$SkipNativeBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $projectRoot '.tools\toolchain.json') -Raw | ConvertFrom-Json
$template = Join-Path $projectRoot '.tools\export-templates\windows_release_x86_64.exe'
if (-not (Test-Path -LiteralPath $template)) { throw 'Download the locked official Windows templates with scripts/download_windows_templates.py first.' }
if (-not $SkipNativeBuild) { & (Join-Path $projectRoot 'native\build.ps1') }
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'native\bin\desktop_native.dll'))) { throw 'Native DLL is missing.' }
$destination = Join-Path $projectRoot 'dist\DesktopFarm-v0.6.1'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
& $toolchain.godot_exe --headless --path $projectRoot --editor --import
if ($LASTEXITCODE -ne 0) { throw 'Project import failed.' }
& $toolchain.godot_exe --headless --path $projectRoot --export-release 'Windows Desktop' (Join-Path $destination 'DesktopFarm.exe')
if ($LASTEXITCODE -ne 0) { throw 'Windows export failed.' }
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\play-guide.txt') -Destination (Join-Path $destination '试玩说明.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses') -Destination $destination -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination $destination -Recurse -Force
Get-ChildItem -LiteralPath $destination -File -Recurse | Where-Object { $_.Name -ne 'manifest.json' } | ForEach-Object { [PSCustomObject]@{ path = $_.FullName.Substring($destination.Length + 1); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding utf8
$archive = Join-Path $projectRoot 'dist\DesktopFarm-v0.6.1-win64.zip'
Compress-Archive -LiteralPath $destination -DestinationPath $archive -Force
Write-Output "Playable build: $destination\DesktopFarm.exe"
Write-Output "Portable archive: $archive"
