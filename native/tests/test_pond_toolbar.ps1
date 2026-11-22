$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PondToolbarNative {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@

function Read-Fixture {
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        if ($fixture.HasExited) { throw 'Fixture exited' }
        try {
            $snapshot = Get-Content -LiteralPath $report -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($snapshot.root_id) { return $snapshot }
        } catch { }
        Start-Sleep -Milliseconds 75
    }
    throw 'No fixture report'
}

function Invoke-FixtureClick($coordinates) {
    $point = New-Object PondToolbarNative+Point
    $point.X = [int]$coordinates[0]
    $point.Y = [int]$coordinates[1]
    $hit = [PondToolbarNative]::WindowFromPoint($point)
    if ($hit -notin @($rootHandle, $toolbarHandle)) { throw "Point is outside fixture: $($point.X),$($point.Y) ($hit)" }
    $null = [PondToolbarNative]::SetCursorPos($point.X, $point.Y)
    Start-Sleep -Milliseconds 50
    [PondToolbarNative]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [PondToolbarNative]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 180
    return $hit.ToInt64()
}

$null = [PondToolbarNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
$origin = New-Object PondToolbarNative+Point
$null = [PondToolbarNative]::GetCursorPos([ref]$origin)
$focusBefore = [PondToolbarNative]::GetForegroundWindow()
$project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$review = Join-Path $project ".review\pond-toolbar-$PID"
$env:APPDATA = Join-Path $review 'profile'
New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null
$godot = Get-Content -LiteralPath (Join-Path $project '.tools\toolchain.json') -Raw | ConvertFrom-Json
$binary = $godot.godot_exe -replace '_console\.exe$', '.exe'
$log = Join-Path $review 'engine.log'
$fixture = Start-Process -FilePath $binary -WorkingDirectory $project -ArgumentList @(
    '--path', ('"' + $project + '"'), '--log-file', ('"' + $log + '"'), '--quit-after', '650',
    '--script', 'res://native/tests/test_pond_toolbar.gd', '--', '--benchmark-fixture'
) -WindowStyle Hidden -PassThru
$null = $fixture.Handle
$report = Join-Path $project ".review\pond-toolbar-$($fixture.Id).json"
try {
    $first = Read-Fixture
    $rootHandle = [IntPtr][long]$first.root_id
    $toolbarHandle = [IntPtr][long]$first.bar_id
    $null = [PondToolbarNative]::SetWindowPos($toolbarHandle, [IntPtr]::Zero, 0,0,0,0,0x13)
    $null = Invoke-FixtureClick $first.pond_button
    $pond = Read-Fixture
    if ($pond.scene -ne 'pond' -or $pond.pond_tile.Count -ne 2) { throw ('Pond did not open: ' + ($pond | ConvertTo-Json -Compress)) }
    $firstHit = Invoke-FixtureClick $pond.pond_tile
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $status = Read-Fixture
        $null = Invoke-FixtureClick $status.pond_tile
    }
    $afterFishing = Read-Fixture
    $firstBarHit = Invoke-FixtureClick $afterFishing.farm_button
    $afterSwitch = Read-Fixture
    Write-Output "REAL_FISH root=$rootHandle toolbar=$toolbarHandle fishHit=$firstHit count=$($pond.fish)->$($afterFishing.fish) cooldown=$($afterFishing.net) rootEvents=$($afterFishing.root_events) toolbarHit=$firstBarHit resultingScene=$($afterSwitch.scene)"
    if ($afterFishing.fish -ge $pond.fish -or $afterFishing.net -le 0) { throw 'Native fish click did not capture a fish' }

    $null = [PondToolbarNative]::SetWindowPos($rootHandle, [IntPtr]::Zero, 0,0,0,0,0x13)
    $raisedHit = Invoke-FixtureClick $afterSwitch.pond_button
    $afterRaised = Read-Fixture
    Write-Output "AFTER_SCENERY_REORDER toolbarHit=$raisedHit resultingScene=$($afterRaised.scene)"
    if ($afterSwitch.scene -ne 'farm' -or $raisedHit -ne $toolbarHandle.ToInt64() -or $afterRaised.scene -ne 'pond') {
        throw 'Toolbar click was blocked'
    }
    Write-Output 'POND_TOOLBAR_WIN32_PASS'
} finally {
    $null = [PondToolbarNative]::SetCursorPos($origin.X, $origin.Y)
    $null = [PondToolbarNative]::SetForegroundWindow($focusBefore)
    if (-not $fixture.HasExited) { $null = $fixture.CloseMainWindow() }
    if (-not $fixture.WaitForExit(24000)) { $fixture.Kill() }
}
