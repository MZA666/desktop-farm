$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $workspace '.tools\toolchain.json') -Raw | ConvertFrom-Json
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $workspace '.tools\zig-cache'
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $workspace '.tools\zig-local-cache'
foreach ($test in @('click_probe', 'power_probe', 'priority_probe')) {
    $source = Join-Path $PSScriptRoot "tests\$test.c"
    $output = Join-Path $PSScriptRoot "bin\$test.exe"
    $arguments = @('cc', '-target', 'x86_64-windows-gnu', '-O2', '-Wall', '-Wextra', $source, '-o', $output, '-luser32', '-lkernel32')
    if ($test -in @('click_probe', 'priority_probe')) { $arguments += '-municode' }
    & $toolchain.zig_exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$test compilation failed" }
}
