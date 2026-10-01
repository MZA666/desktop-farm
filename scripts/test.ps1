$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $projectRoot '.tools\toolchain.json') -Raw | ConvertFrom-Json
& $toolchain.godot_exe --headless --path $projectRoot --editor --import
if ($LASTEXITCODE -ne 0) { throw 'Godot import failed.' }
& $toolchain.godot_exe --headless --path $projectRoot --script res://tests/test_simulation.gd
if ($LASTEXITCODE -ne 0) { throw 'Simulation tests failed.' }
& $toolchain.godot_exe --headless --path $projectRoot --script res://native/tests/test_native.gd
if ($LASTEXITCODE -ne 0) { throw 'Native API tests failed.' }
& $toolchain.godot_exe --headless --path $projectRoot --script res://tests/test_controller.gd -- --benchmark-fixture
if ($LASTEXITCODE -ne 0) { throw 'Controller transaction tests failed.' }
Write-Output 'Simulation, persistence and native API checks passed.'
