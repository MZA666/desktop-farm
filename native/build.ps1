param([string]$Compiler = "", [switch]$DebugBuild)
$ErrorActionPreference = "Stop"
$workspace = Split-Path -Parent $PSScriptRoot
$nativeRoot = $PSScriptRoot
if (-not $Compiler) {
    $lockPath = Join-Path $workspace '.tools\toolchain.json'
    if (Test-Path -LiteralPath $lockPath) {
        $lockedTools = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        foreach ($key in @('zig', 'zig_path', 'zig_exe')) {
            if ($lockedTools.$key -and (Test-Path -LiteralPath ([string]$lockedTools.$key))) {
                $Compiler = [string]$lockedTools.$key
                break
            }
        }
    }
    if (-not $Compiler) {
        $found = Get-ChildItem -LiteralPath (Join-Path $workspace '.tools') -Filter zig.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $Compiler = $found.FullName }
    }
    if (-not $Compiler) {
        $found = Get-Command zig -ErrorAction SilentlyContinue
        if ($found) { $Compiler = $found.Source }
    }
}
if (-not $Compiler -or -not (Test-Path -LiteralPath $Compiler)) {
    throw 'Portable Zig compiler not found. Run scripts/setup_toolchain.ps1 first, or provide -Compiler.'
}
$outputDirectory = Join-Path $nativeRoot 'bin'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$optimization = if ($DebugBuild) { '-O0' } else { '-O2' }
$source = Join-Path $nativeRoot 'desktop_native.c'
$library = Join-Path $outputDirectory 'desktop_native.dll'
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $workspace '.tools\zig-cache'
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $workspace '.tools\zig-local-cache'
& $Compiler cc -target x86_64-windows-gnu -shared $optimization -std=c11 -Wall -Wextra $source -o $library -luser32 -lkernel32 -lcomctl32 -lshell32 -lgdi32
if ($LASTEXITCODE -ne 0) { throw "Native build failed with exit code $LASTEXITCODE." }
Write-Output "Built $library"
