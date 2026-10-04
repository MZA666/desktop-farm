param(
    [ValidateSet('All', 'Simulation', 'StageA', 'SaveMigration', 'Native', 'Controller', 'PixelArt', 'PondRules', 'RanchLife', 'GroundProducts', 'WorldLayout', 'WorldLayoutV4', 'WorldLayoutV5', 'CameraHay', 'DisplayModes', 'SceneAssets')][string]$Suite = 'All',
    [string]$PythonPath = '',
    [switch]$SkipConfig,
    [switch]$SkipImport
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$toolchainPath = Join-Path $projectRoot '.tools\toolchain.json'
if (-not (Test-Path -LiteralPath $toolchainPath -PathType Leaf)) {
    throw 'Run scripts/setup_toolchain.ps1 and native/build.ps1 before the Godot tests.'
}
$toolchain = Get-Content -LiteralPath $toolchainPath -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $toolchain.godot_exe -PathType Leaf)) { throw 'The locked Godot executable is missing.' }
New-Item -ItemType Directory -Path (Join-Path $projectRoot '.review') -Force | Out-Null

# Python is optional for gameplay. When present, include the independent
# workbook checks; an explicitly supplied interpreter must exist and work.
if (-not $SkipConfig) {
    $pythonArguments = @()
    if ($PythonPath) {
        if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw 'The requested Python interpreter does not exist.' }
    } else {
        $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
        if (Test-Path -LiteralPath $bundledPython -PathType Leaf) { $PythonPath = $bundledPython }
        else {
            foreach ($name in @('python.exe', 'python3.exe', 'py.exe')) {
                $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                # App execution aliases can open an installer instead of Python.
                if ($command -and $command.Source -notmatch '[\\/]WindowsApps[\\/]') {
                    $PythonPath = $command.Source
                    if ($name -eq 'py.exe') { $pythonArguments = @('-3') }
                    break
                }
            }
        }
    }
    if ($PythonPath) {
        & $PythonPath @pythonArguments (Join-Path $projectRoot 'tests\validate_config.py')
        if ($LASTEXITCODE -ne 0) { throw 'Workbook/runtime configuration checks failed.' }
        Write-Output 'CONFIG_VALIDATION_PASS'
    } else { Write-Warning 'Python was not found; configuration checks were skipped. Use -PythonPath to enable them.' }
}

if (-not $SkipImport) {
    & $toolchain.godot_exe --headless --path $projectRoot --log-file (Join-Path $projectRoot '.review\test-import.log') --editor --import
    if ($LASTEXITCODE -ne 0) { throw 'Godot import failed.' }
}
$checks = @(
    @{ Name = 'Simulation'; Script = 'res://tests/test_simulation.gd'; Fixture = $false },
    @{ Name = 'StageA'; Script = 'res://tests/test_stage_a_model.gd'; Fixture = $false },
    @{ Name = 'SaveMigration'; Script = 'res://tests/test_save_migration.gd'; Fixture = $false },
    @{ Name = 'Native'; Script = 'res://native/tests/test_native.gd'; Fixture = $true },
    @{ Name = 'Controller'; Script = 'res://tests/test_controller.gd'; Fixture = $true },
    @{ Name = 'PixelArt'; Script = 'res://tests/test_pixel_art.gd'; Fixture = $false },
    @{ Name = 'PondRules'; Script = 'res://tests/test_pond_rules.gd'; Fixture = $false },
    @{ Name = 'RanchLife'; Script = 'res://tests/test_ranch_life.gd'; Fixture = $false },
    @{ Name = 'GroundProducts'; Script = 'res://tests/test_ground_products.gd'; Fixture = $false },
    @{ Name = 'WorldLayout'; Script = 'res://tests/test_world_layout_v3.gd'; Fixture = $false },
    @{ Name = 'WorldLayoutV4'; Script = 'res://tests/test_world_layout_v4.gd'; Fixture = $false },
    @{ Name = 'WorldLayoutV5'; Script = 'res://tests/test_world_layout_v5.gd'; Fixture = $false },
    @{ Name = 'CameraHay'; Script = 'res://tests/test_camera_hay.gd'; Fixture = $false },
    @{ Name = 'DisplayModes'; Script = 'res://native/tests/test_display_modes.gd'; Fixture = $false },
    @{ Name = 'SceneAssets'; Script = 'res://tests/test_scene_assets.gd'; Fixture = $false }
)
foreach ($check in $checks) {
    if ($Suite -ne 'All' -and $Suite -ne $check.Name) { continue }
    $arguments = @('--headless', '--path', $projectRoot, '--log-file', (Join-Path $projectRoot ('.review\test-' + $check.Name + '.log')), '--script', $check.Script)
    if ($check.Fixture) { $arguments += @('--', '--benchmark-fixture') }
    # All scripts use test paths. Native/controller checks use isolated
    # fixtures before loading; the formal desktop-farm-save.json is never used.
    & $toolchain.godot_exe @arguments
    if ($LASTEXITCODE -ne 0) { throw ($check.Name + ' tests failed.') }
    Write-Output ($check.Name.ToUpperInvariant() + '_TEST_PASS')
}
Write-Output ('HEADLESS_TESTS_COMPLETE suite=' + $Suite)
