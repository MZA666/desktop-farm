param([switch]$SkipNativeBuild, [switch]$PackageOnly)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $projectRoot '.tools\toolchain.json') -Raw | ConvertFrom-Json
$template = Join-Path $projectRoot '.tools\export-templates\windows_release_x86_64.exe'
if (-not (Test-Path -LiteralPath $template)) { throw 'Download the locked official Windows templates with scripts/download_windows_templates.py first.' }
if (-not $PackageOnly -and -not $SkipNativeBuild) { & (Join-Path $projectRoot 'native\build.ps1') }
if (-not $PackageOnly -and -not (Test-Path -LiteralPath (Join-Path $projectRoot 'native\bin\desktop_native.dll'))) { throw 'Native DLL is missing.' }
$versionMatch = Select-String -LiteralPath (Join-Path $projectRoot 'project.godot') -Pattern '^config/version="([^"]+)"$'
if (-not $versionMatch) { throw 'Project version is missing.' }
$appVersion = $versionMatch.Matches[0].Groups[1].Value
if ($appVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Project version must use major.minor.patch.' }
$destination = Join-Path $projectRoot ("dist\DesktopFarm-v" + $appVersion)
New-Item -ItemType Directory -Force -Path $destination | Out-Null
if ($PackageOnly) {
    foreach ($fileName in @('DesktopFarm.exe', 'DesktopFarm.pck', 'desktop_native.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $fileName) -PathType Leaf)) { throw 'PackageOnly requires a previously exported complete build.' }
    }
    Write-Output 'Packaging existing game files; source changes are not compiled in PackageOnly mode.'
} else {
    & $toolchain.godot_exe --headless --path $projectRoot --log-file (Join-Path $projectRoot '.review\build-icons.log') --script 'res://scripts/bake_pixel_assets.gd'
    if ($LASTEXITCODE -ne 0) { throw 'Pixel atlas baking failed.' }
    & $toolchain.godot_exe --headless --path $projectRoot --log-file (Join-Path $projectRoot '.review\build-scenes.log') --script 'res://scripts/bake_scene_assets.gd'
    if ($LASTEXITCODE -ne 0) { throw 'Illustrated scene atlas baking failed.' }
    & $toolchain.godot_exe --headless --path $projectRoot --log-file (Join-Path $projectRoot '.review\build-scenes-v082.log') --script 'res://scripts/bake_scene_assets_v082.gd'
    if ($LASTEXITCODE -ne 0) { throw '0.8.2 border and walking atlas baking failed.' }
    & $toolchain.godot_exe --headless --path $projectRoot --log-file (Join-Path $projectRoot '.review\build-import.log') --editor --import
    if ($LASTEXITCODE -ne 0) { throw 'Project import failed.' }
    & $toolchain.godot_exe --headless --path $projectRoot --log-file (Join-Path $projectRoot '.review\build-export.log') --export-release 'Windows Desktop' (Join-Path $destination 'DesktopFarm.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Windows export failed.' }
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\play-guide.txt') -Destination (Join-Path $destination '试玩说明.txt') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses') -Destination $destination -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination $destination -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\pixel\generation-prompts.md') -Destination (Join-Path $destination 'docs\art-generation-prompts-v0.7.md') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\pixel\v0.8.1\generation-prompts.md') -Destination (Join-Path $destination 'docs\art-generation-prompts-v0.8.1.md') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\pixel\v0.8.2\generation-prompts.md') -Destination (Join-Path $destination 'docs\art-generation-prompts-v0.8.2.md') -Force
Get-ChildItem -LiteralPath $destination -File -Recurse | Where-Object { $_.Name -ne 'manifest.json' } | ForEach-Object { [PSCustomObject]@{ path = $_.FullName.Substring($destination.Length + 1); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'manifest.json') -Encoding utf8
$archive = Join-Path $projectRoot ("dist\DesktopFarm-v" + $appVersion + '-win64.zip')
Compress-Archive -LiteralPath $destination -DestinationPath $archive -Force
Write-Output "Playable build: $destination\DesktopFarm.exe"
Write-Output "Portable archive: $archive"
