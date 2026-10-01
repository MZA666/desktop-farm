param(
    [string]$EnginePath = 'D:\game\dist\DesktopFarm-v0.6.1\DesktopFarm.exe',
    [string]$OutputDirectory = 'D:\game\.review\release-benchmark-normal-entry',
    [ValidateRange(24, 60)][int]$Seconds = 24
)
$ErrorActionPreference = 'Stop'
$engineAbsolute = [IO.Path]::GetFullPath($EnginePath)
$evidenceDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $engineAbsolute -PathType Leaf)) { throw 'Release executable does not exist.' }
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

# Every run uses the shipped main scene. No --script or --path override, and
# --benchmark-fixture selects user://test-data before any save is loaded.
$modes = @(
    @{ Id = 'farm_30'; Scene = 'farm'; Power = $false; Collapsed = $false },
    @{ Id = 'ranch_30'; Scene = 'ranch'; Power = $false; Collapsed = $false },
    @{ Id = 'pond_30'; Scene = 'pond'; Power = $false; Collapsed = $false },
    @{ Id = 'farm_15'; Scene = 'farm'; Power = $true; Collapsed = $false },
    @{ Id = 'collapsed_30'; Scene = 'farm'; Power = $false; Collapsed = $true }
)
$processors = @(Get-CimInstance Win32_Processor)
$logicalCount = [int](($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
if ($logicalCount -le 0) { throw 'Logical CPU count is unavailable.' }
$device = [ordered]@{
    OperatingSystem = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
    Processor = $processors | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
    PhysicalMemoryBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    Video = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution)
    LogicalProcessors = $logicalCount
}
$releaseFiles = @(Get-Item -LiteralPath $engineAbsolute)
foreach ($name in @('DesktopFarm.pck', 'desktop_native.dll')) {
    $candidate = Join-Path ([IO.Path]::GetDirectoryName($engineAbsolute)) $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $releaseFiles += Get-Item -LiteralPath $candidate }
}
$releaseIdentity = @($releaseFiles | ForEach-Object {
    [pscustomobject]@{ Path = $_.FullName; Bytes = $_.Length; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$playerDirectory = Join-Path $env:APPDATA 'Godot\app_userdata\桌面农场'
function Get-PlayerSaveEvidence {
    foreach ($name in @('desktop-farm-save.json', 'desktop-farm-save.json.bak')) {
        $saveFile = Join-Path $playerDirectory $name
        [pscustomobject]@{ Path = $saveFile; Exists = (Test-Path -LiteralPath $saveFile -PathType Leaf)
            Sha256 = if (Test-Path -LiteralPath $saveFile -PathType Leaf) { (Get-FileHash -LiteralPath $saveFile -Algorithm SHA256).Hash } else { $null } }
    }
}
$playerBefore = @(Get-PlayerSaveEvidence)
$phaseResults = [Collections.Generic.List[object]]::new()
$allSamples = [Collections.Generic.List[object]]::new()
$allStarted = [Diagnostics.Stopwatch]::StartNew()
foreach ($mode in $modes) {
    $modeDirectory = Join-Path $evidenceDirectory $mode.Id
    New-Item -ItemType Directory -Path $modeDirectory -Force | Out-Null
    $stagePath = Join-Path $modeDirectory 'benchmark-stage.json'
    $runtimePath = Join-Path $modeDirectory 'benchmark-runtime.json'
    # Remove only these two stale evidence files, never any game save.
    foreach ($evidenceFile in @($stagePath, $runtimePath)) {
        if (Test-Path -LiteralPath $evidenceFile) { Remove-Item -LiteralPath $evidenceFile }
    }
    $arguments = @('--log-file', (Join-Path $modeDirectory 'engine.log'), '--', '--benchmark-fixture',
        ('--benchmark-scene=' + $mode.Scene), ('--benchmark-seconds=' + $Seconds), ('--benchmark-output=' + $modeDirectory))
    if ($mode.Power) { $arguments += '--benchmark-power' }
    if ($mode.Collapsed) { $arguments += '--benchmark-collapsed' }
    # Windows Start-Process joins ArgumentList. Quote each argument so paths
    # containing spaces stay one command-line argument.
    $argumentLine = ($arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $launcher = Start-Process -FilePath $engineAbsolute -ArgumentList $argumentLine -WorkingDirectory ([IO.Path]::GetDirectoryName($engineAbsolute)) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $modeDirectory 'stdout.log') -RedirectStandardError (Join-Path $modeDirectory 'stderr.log') -PassThru
    $process = $null
    try {
        $startupDeadline = [DateTime]::UtcNow.AddSeconds(20)
        $rendererId = 0
        while ($rendererId -eq 0 -and [DateTime]::UtcNow -lt $startupDeadline) {
            $launcher.Refresh()
            if ($launcher.HasExited) { throw ('Release exited before reporting PID: ' + $mode.Id) }
            if (Test-Path -LiteralPath $stagePath) {
                try { $rendererId = [int](Get-Content -LiteralPath $stagePath -Raw | ConvertFrom-Json).process_id } catch { }
            }
            if ($rendererId -eq 0) { Start-Sleep -Milliseconds 100 }
        }
        if ($rendererId -eq 0) { throw ('Release did not report PID: ' + $mode.Id) }
        $process = [Diagnostics.Process]::GetProcessById($rendererId)
        if ([IO.Path]::GetFullPath($process.MainModule.FileName) -ine $engineAbsolute) { throw 'Actual renderer executable does not match the release EXE.' }
        Write-Output ('RELEASE_SAMPLE_STARTED ' + $mode.Id + ' renderer_pid=' + $rendererId + ' launcher_pid=' + $launcher.Id)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $lastWall = 0.0
        $lastCpu = $process.TotalProcessorTime.TotalSeconds
        $lastMeasuring = $false
        $samples = [Collections.Generic.List[object]]::new()
        while (-not $process.HasExited -and $watch.Elapsed.TotalSeconds -lt ($Seconds + 20)) {
            Start-Sleep -Milliseconds 1000
            $process.Refresh()
            if ($process.HasExited) { break }
            $wall = $watch.Elapsed.TotalSeconds
            $cpu = $process.TotalProcessorTime.TotalSeconds
            $measuring = $false
            try {
                $stage = Get-Content -LiteralPath $stagePath -Raw | ConvertFrom-Json
                $measuring = [bool]$stage.measuring -and $stage.phase -eq $mode.Id -and [int]$stage.process_id -eq $rendererId
            } catch { }
            $interval = $wall - $lastWall
            $cpuDelta = $cpu - $lastCpu
            $sample = [pscustomobject]@{
                Phase = $mode.Id; ProcessId = $rendererId; Measuring = ($measuring -and $lastMeasuring)
                StageMeasuring = $measuring; WallSeconds = $wall; IntervalSeconds = $interval; CpuSeconds = $cpuDelta
                CpuSystemPercent = 100.0 * $cpuDelta / $interval / $logicalCount
                WorkingSetBytes = $process.WorkingSet64; PrivateMemoryBytes = $process.PrivateMemorySize64
            }
            $samples.Add($sample)
            $allSamples.Add($sample)
            $lastWall = $wall
            $lastCpu = $cpu
            $lastMeasuring = $measuring
        }
        if (-not $process.HasExited) { throw ('Release exceeded sampling timeout: ' + $mode.Id) }
        $launcher.WaitForExit()
        $samples | Export-Csv -LiteralPath (Join-Path $modeDirectory 'process-samples.csv') -Encoding utf8 -NoTypeInformation
        if ($launcher.ExitCode -ne 0) { throw ('Release returned exit code ' + $launcher.ExitCode + ': ' + $mode.Id) }
        if (-not (Test-Path -LiteralPath $runtimePath)) { throw ('Release runtime evidence missing: ' + $mode.Id) }
        $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
        if ([int]$runtime.process_id -ne $rendererId -or [bool]$runtime.editor_feature -or [bool]$runtime.debug_feature -or $runtime.executable_path.Replace('/', '\') -ine $engineAbsolute -or [bool]$runtime.main_scene_physical_file_exists) { throw 'Runtime evidence did not prove an actual packed release executable.' }
        if ($runtime.phase -ne $mode.Id -or $runtime.scene -ne $mode.Scene -or [bool]$runtime.power_saving -ne $mode.Power -or [bool]$runtime.collapsed -ne $mode.Collapsed -or $runtime.fps_cap -ne $(if ($mode.Power) { 15 } else { 30 })) { throw 'Runtime mode does not match the requested sample.' }
        if ([bool]$runtime.visibility_start.scene_hwnd_visible -eq $mode.Collapsed -or [bool]$runtime.visibility_end.scene_hwnd_visible -eq $mode.Collapsed -or -not [bool]$runtime.visibility_start.toolbar_hwnd_visible -or -not [bool]$runtime.visibility_end.toolbar_hwnd_visible) { throw 'Runtime HWND visibility does not match the requested sample.' }
        if ($runtime.save_path -ne 'user://test-data/benchmark-save.json' -or -not [bool]$runtime.save_ok) { throw 'Benchmark save was not isolated and successful.' }
        if ($runtime.population.plots -ne 96 -or $runtime.population.grass -ne 96 -or $runtime.population.animals -ne 84 -or $runtime.population.farmers -ne 9 -or $runtime.population.fish -ne 12) { throw 'Benchmark population is incomplete.' }
        $steadySamples = @($samples | Where-Object Measuring)
        $wallSeconds = ($steadySamples | Measure-Object IntervalSeconds -Sum).Sum
        $cpuSeconds = ($steadySamples | Measure-Object CpuSeconds -Sum).Sum
        if ($wallSeconds -lt 20) { throw ('Fewer than 20 seconds of continuous process samples: ' + $mode.Id) }
        $workingPeak = [long]($steadySamples | Measure-Object WorkingSetBytes -Maximum).Maximum
        $privatePeak = [long]($steadySamples | Measure-Object PrivateMemoryBytes -Maximum).Maximum
        $row = [pscustomobject]@{
            Phase = $mode.Id; ProcessId = $rendererId; LauncherProcessId = $launcher.Id; ExitCode = $launcher.ExitCode
            Arguments = $arguments; SampleCount = $steadySamples.Count; SampledWallSeconds = $wallSeconds; CpuSeconds = $cpuSeconds
            CpuSystemPercent = 100.0 * $cpuSeconds / $wallSeconds / $logicalCount
            WorkingSetAverageBytes = ($steadySamples | Measure-Object WorkingSetBytes -Average).Average
            WorkingSetPeakBytes = $workingPeak; WorkingSetPeakMB = $workingPeak / 1000000.0
            PrivateMemoryAverageBytes = ($steadySamples | Measure-Object PrivateMemoryBytes -Average).Average
            PrivateMemoryPeakBytes = $privatePeak; PrivateMemoryPeakMB = $privatePeak / 1000000.0
            ObservedWorkingSetPeakBytes = [long]($samples | Measure-Object WorkingSetBytes -Maximum).Maximum
            CpuBelow2Percent = (100.0 * $cpuSeconds / $wallSeconds / $logicalCount -lt 2.0)
            WorkingSetBelow200MB = ($workingPeak -lt 200000000)
            Runtime = $runtime
        }
        $phaseResults.Add($row)
        $row | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $modeDirectory 'performance.json') -Encoding utf8
        Write-Output ('RELEASE_SAMPLE_COMPLETE ' + $mode.Id + ' CPU=' + $row.CpuSystemPercent.ToString('F3') + '% WS=' + $row.WorkingSetPeakMB.ToString('F2') + 'MB FPS=' + ([double]$runtime.process_fps).ToString('F2'))
    } finally {
        if ($null -ne $process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $launcher.Refresh()
        if (-not $launcher.HasExited) { $launcher.Kill(); $launcher.WaitForExit() }
    }
}
$playerAfter = @(Get-PlayerSaveEvidence)
$playerUnchanged = (ConvertTo-Json -InputObject $playerBefore -Compress) -eq (ConvertTo-Json -InputObject $playerAfter -Compress)
$result = [ordered]@{
    Date = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'; Engine = $engineAbsolute; ReleaseFiles = $releaseIdentity
    Device = $device; TotalWallSeconds = $allStarted.Elapsed.TotalSeconds
    Measurement = 'Actual renderer PID; CPUtime / wall / logical CPUs * 100; 1-second samples; 2-second warmup excluded; MB = 1,000,000 bytes'
    PlayerSaveBefore = $playerBefore; PlayerSaveAfter = $playerAfter; PlayerSaveUnchanged = $playerUnchanged; Phases = @($phaseResults.ToArray())
}
$allSamples | Export-Csv -LiteralPath (Join-Path $evidenceDirectory 'process-samples.csv') -Encoding utf8 -NoTypeInformation
$result | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'performance.json') -Encoding utf8
if (-not $playerUnchanged) { throw 'Player save evidence changed during benchmark.' }
Write-Output ('RELEASE_BENCHMARK_ALL_COMPLETE ' + (Join-Path $evidenceDirectory 'performance.json'))
