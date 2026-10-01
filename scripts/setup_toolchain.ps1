param([switch]$ForceDownload)
$ErrorActionPreference = 'Stop'
# Versions validated for the current source and native ABI. Upgrade explicitly.
$godotTag = '4.7.2-stable'
$zigRelease = '0.16.0'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $projectRoot '.tools'
New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
$existingLock = Join-Path $toolsRoot 'toolchain.json'
if ((Test-Path -LiteralPath $existingLock) -and -not $ForceDownload) {
    $existing = Get-Content -LiteralPath $existingLock -Raw | ConvertFrom-Json
    if ($existing.godot_tag -eq $godotTag -and $existing.zig_version -eq $zigRelease -and (Test-Path -LiteralPath ([string]$existing.godot_exe)) -and (Test-Path -LiteralPath ([string]$existing.zig_exe))) {
        $existing | ConvertTo-Json
        return
    }
}
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/godotengine/godot-builds/releases/tags/$godotTag"
if ($release.tag_name -ne $godotTag -or $release.prerelease) { throw 'Pinned stable Godot release not found in official metadata.' }
$engineAsset = $release.assets | Where-Object { $_.name -match '^Godot_v[\d.]+-stable_win64.exe.zip$' } | Select-Object -First 1
$templateAsset = $release.assets | Where-Object { $_.name -match '^Godot_v[\d.]+-stable_export_templates.tpz$' } | Select-Object -First 1
if (-not $engineAsset) { throw 'Official release has no Windows x64 standard editor asset.' }
$engineZip = Join-Path $toolsRoot $engineAsset.name
if (-not (Test-Path -LiteralPath $engineZip) -or (Get-Item -LiteralPath $engineZip).Length -ne $engineAsset.size -or $ForceDownload) { Invoke-WebRequest -Uri $engineAsset.browser_download_url -OutFile $engineZip -MaximumRetryCount 3 -RetryIntervalSec 3 }
$engineHash = (Get-FileHash -LiteralPath $engineZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($engineAsset.digest -and $engineHash -ne ($engineAsset.digest -replace '^sha256:','')) { throw 'Godot editor checksum mismatch.' }
$engineDir = Join-Path $toolsRoot ("godot-" + $release.tag_name)
Expand-Archive -LiteralPath $engineZip -DestinationPath $engineDir -Force
$enginePath = Get-ChildItem -LiteralPath $engineDir -Filter '*_console.exe' | Select-Object -First 1 -ExpandProperty FullName
$zigIndex = Invoke-RestMethod -Uri 'https://ziglang.org/download/index.json'
$zigVersion = $zigIndex.PSObject.Properties | Where-Object { $_.Name -eq $zigRelease } | Select-Object -First 1
if (-not $zigVersion) { throw 'Pinned Zig release not found in official metadata.' }
$zigAsset = $zigVersion.Value.'x86_64-windows'
if (-not $zigAsset) { throw 'Official Zig index has no Windows x64 compiler.' }
$zigZip = Join-Path $toolsRoot ([System.IO.Path]::GetFileName([uri]$zigAsset.tarball))
if (-not (Test-Path -LiteralPath $zigZip) -or (Get-Item -LiteralPath $zigZip).Length -ne [long]$zigAsset.size -or $ForceDownload) { Invoke-WebRequest -Uri $zigAsset.tarball -OutFile $zigZip -MaximumRetryCount 3 -RetryIntervalSec 3 }
$actualHash = (Get-FileHash -LiteralPath $zigZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $zigAsset.shasum) { throw 'Zig compiler checksum mismatch.' }
$zigDir = Join-Path $toolsRoot 'zig'
Expand-Archive -LiteralPath $zigZip -DestinationPath $zigDir -Force
$zigPath = Get-ChildItem -LiteralPath $zigDir -Filter 'zig.exe' -Recurse | Select-Object -First 1 -ExpandProperty FullName
$nativeInclude = Join-Path $projectRoot 'native\include'
New-Item -ItemType Directory -Force -Path $nativeInclude | Out-Null
$engineTag = $release.tag_name
if (-not (Test-Path -LiteralPath (Join-Path $nativeInclude 'gdextension_interface.h'))) {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/godotengine/godot/$engineTag/core/extension/gdextension_interface.h" -OutFile (Join-Path $nativeInclude 'gdextension_interface.h')
}
$release.assets | Where-Object { $_.name -match 'export_templates|win64' } | Select-Object name,size,browser_download_url,digest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $toolsRoot 'release-assets.json') -Encoding utf8
$lock = @{ godot_tag=$release.tag_name; godot_exe=$enginePath; godot_sha256=$engineHash; engine_url=$engineAsset.browser_download_url; export_template_url=$templateAsset.browser_download_url; zig_version=$zigVersion.Name; zig_exe=$zigPath; zig_sha256=$actualHash }
$lock | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $toolsRoot 'toolchain.json') -Encoding utf8
$lock | ConvertTo-Json
