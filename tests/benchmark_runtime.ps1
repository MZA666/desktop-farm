param(
    [string]$EnginePath = 'D:\game\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe',
    [string]$Workspace = 'D:\game',
    [switch]$Exported,
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$benchDirectory = if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory } elseif ($Exported) { Join-Path $Workspace '.review\release-benchmark' } else { Join-Path $Workspace '.review\source-benchmark' }
$stagePath = Join-Path $benchDirectory 'benchmark-stage.json'
$runtimePath = Join-Path $benchDirectory 'benchmark-runtime.json'
$outputPath = Join-Path $benchDirectory 'benchmark-performance.json'
$samplesPath = Join-Path $benchDirectory 'benchmark-process-samples.csv'
$outLog = Join-Path $benchDirectory 'benchmark-stdout.log'
$errLog = Join-Path $benchDirectory 'benchmark-stderr.log'
New-Item -ItemType Directory -Path $benchDirectory -Force | Out-Null
if ($Exported) {
    # Official 4.7 templates may disable OVERRIDE_PATH_ENABLED and ignore
    # --script entirely. Detect that before accidentally launching normal play.
    $helpLog = Join-Path $benchDirectory 'release-help.log'
    $helpErr = Join-Path $benchDirectory 'release-help-stderr.log'
    $helpProcess = Start-Process -FilePath $EnginePath -ArgumentList @('--help') -WorkingDirectory ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EnginePath))) -WindowStyle Hidden -RedirectStandardOutput $helpLog -RedirectStandardError $helpErr -PassThru
    $helpProcess.WaitForExit()
    $helpText = Get-Content -LiteralPath $helpLog -Raw
    $plainHelp = [regex]::Replace($helpText, '\x1B\[[0-9;]*m', '')
    if (-not [regex]::IsMatch($plainHelp, '(?m)^\s+-s,\s+--script(?:\s|$)')) {
        throw 'This release template does not expose --script. External benchmark helper unsupported; no game window was launched by this preflight.'
    }
}
# Only stale benchmark result files are removed. Player saves are never touched.
foreach ($benchFile in @($stagePath, $runtimePath, $outputPath, $samplesPath, $outLog, $errLog)) {
    if (Test-Path -LiteralPath $benchFile) { Remove-Item -LiteralPath $benchFile }
}
$processors = @(Get-CimInstance Win32_Processor)
$logicalCount = [int](($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
$device = [ordered]@{
    OperatingSystem = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber
    Processor = $processors | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
    PhysicalMemoryBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    Video = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution)
    LogicalProcessors = $logicalCount
}
$scriptPath = Join-Path $Workspace 'tests\benchmark_runtime.gd'
$engineLog = Join-Path $benchDirectory 'engine.log'
$arguments = if ($Exported) {
    @('--script', $scriptPath, '--log-file', $engineLog, '--', '--benchmark-fixture', ('--benchmark-output=' + $benchDirectory))
} else {
    @('--path', $Workspace, '--script', 'res://tests/benchmark_runtime.gd', '--log-file', $engineLog, '--', '--benchmark-fixture', ('--benchmark-output=' + $benchDirectory))
}
$benchWorkingDirectory = if ($Exported) { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EnginePath)) } else { $Workspace }
$launcher = Start-Process -FilePath $EnginePath -ArgumentList $arguments -WorkingDirectory $benchWorkingDirectory -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
# Godot's Windows console executable is a wrapper. Sample the PID reported by
# OS.get_process_id(), which belongs to the actual renderer, not that wrapper.
$startupDeadline = [DateTime]::UtcNow.AddSeconds(20)
$rendererId = 0
while ($rendererId -eq 0 -and [DateTime]::UtcNow -lt $startupDeadline) {
    if ($launcher.HasExited) { throw 'Godot exited before reporting the renderer PID.' }
    if (Test-Path -LiteralPath $stagePath) {
        try {
            $startupStage = Get-Content -LiteralPath $stagePath -Raw | ConvertFrom-Json
            $rendererId = [int]$startupStage.process_id
        } catch { }
    }
    if ($rendererId -eq 0) { Start-Sleep -Milliseconds 100 }
}
if ($rendererId -eq 0) { $launcher.Kill(); throw 'Godot did not report its actual renderer PID.' }
$process = [Diagnostics.Process]::GetProcessById($rendererId)
Write-Output ('BENCHMARK_STARTED renderer_pid=' + $process.Id + ' launcher_pid=' + $launcher.Id)
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$samples = [Collections.Generic.List[object]]::new()
$lastWall = 0.0
$lastCpu = $process.TotalProcessorTime.TotalSeconds
$lastPhase = 'initializing'
$lastMeasuring = $false
while (-not $process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep -Milliseconds 1000
    $process.Refresh()
    if ($process.HasExited) { break }
    $wall = $stopwatch.Elapsed.TotalSeconds
    $cpu = $process.TotalProcessorTime.TotalSeconds
    $phase = 'initializing'
    $measuring = $false
    if (Test-Path -LiteralPath $stagePath) {
        try {
            $stage = Get-Content -LiteralPath $stagePath -Raw | ConvertFrom-Json
            $phase = $stage.phase
            $measuring = [bool]$stage.measuring
        } catch { }
    }
    $interval = $wall - $lastWall
    $cpuDelta = $cpu - $lastCpu
    $continuousMeasurement = $measuring -and $lastMeasuring -and $lastPhase -eq $phase
    $samples.Add([pscustomobject]@{
        Phase = $phase
        Measuring = $continuousMeasurement
        StageMeasuring = $measuring
        WallSeconds = $wall
        IntervalSeconds = $interval
        CpuSeconds = $cpuDelta
        CpuSystemPercent = 100.0 * $cpuDelta / $interval / $logicalCount
        WorkingSetBytes = $process.WorkingSet64
        PrivateMemoryBytes = $process.PrivateMemorySize64
    })
    $lastWall = $wall
    $lastCpu = $cpu
    $lastPhase = $phase
    $lastMeasuring = $measuring
}
if (-not $process.HasExited) {
    $process.Kill()
    throw 'Benchmark exceeded 180 seconds and was terminated.'
}
$process.WaitForExit()
$launcher.WaitForExit()
$samples | Export-Csv -LiteralPath $samplesPath -Encoding utf8 -NoTypeInformation
$phaseResults = @()
foreach ($phaseName in @('farm_30', 'ranch_30', 'pond_30', 'farm_15', 'collapsed_30')) {
    $phaseSamples = @($samples | Where-Object { $_.Measuring -and $_.Phase -eq $phaseName })
    if ($phaseSamples.Count -eq 0) { continue }
    $seconds = ($phaseSamples | Measure-Object IntervalSeconds -Sum).Sum
    $cpuSeconds = ($phaseSamples | Measure-Object CpuSeconds -Sum).Sum
    $phaseResults += [pscustomobject]@{
        Phase = $phaseName
        SampleCount = $phaseSamples.Count
        SampledWallSeconds = $seconds
        CpuSeconds = $cpuSeconds
        CpuSystemPercent = 100.0 * $cpuSeconds / $seconds / $logicalCount
        WorkingSetAverageMiB = ($phaseSamples | Measure-Object WorkingSetBytes -Average).Average / 1MB
        WorkingSetPeakMiB = ($phaseSamples | Measure-Object WorkingSetBytes -Maximum).Maximum / 1MB
        PrivateMemoryAverageMiB = ($phaseSamples | Measure-Object PrivateMemoryBytes -Average).Average / 1MB
        PrivateMemoryPeakMiB = ($phaseSamples | Measure-Object PrivateMemoryBytes -Maximum).Maximum / 1MB
    }
}
$runtimeResult = if (Test-Path -LiteralPath $runtimePath) { Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json } else { $null }
if ($null -eq $runtimeResult -or [int]$runtimeResult.process_id -ne $rendererId) {
    throw 'Renderer PID/result mismatch. Refusing to report wrapper CPU or incomplete phases.'
}
if ($Exported) {
    $expectedExecutable = [IO.Path]::GetFullPath($EnginePath).Replace('\', '/')
    if ([bool]$runtimeResult.editor_feature -or [bool]$runtimeResult.debug_feature -or $runtimeResult.executable_path.Replace('\', '/') -ne $expectedExecutable -or [bool]$runtimeResult.main_scene_physical_file_exists) {
        throw 'Exported benchmark did not prove a release executable with packed scene resources.'
    }
}
if ($phaseResults.Count -ne 5 -or @($phaseResults | Where-Object { $_.SampledWallSeconds -lt 20 }).Count -gt 0) {
    throw 'Each of the five phases must contain at least 20 seconds of continuous renderer-process samples.'
}
$result = [ordered]@{
    Date = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    Command = '& tests/benchmark_runtime.ps1 -EnginePath ' + $EnginePath + $(if ($Exported) { ' -Exported' } else { '' })
    # GetProcessById cannot reliably retain ExitCode on all Windows/.NET builds.
    # The launcher forwards its renderer's exit code and was started by us.
    ExitCode = $launcher.ExitCode
    RendererExitCode = $process.ExitCode
    RendererHasExited = $process.HasExited
    Engine = $EnginePath
    Exported = [bool]$Exported
    ProcessId = $process.Id
    LauncherProcessId = $launcher.Id
    Device = $device
    Measurement = 'CPU seconds / elapsed seconds / logical processor count * 100; 1-second process sampling; per-phase warmup excluded'
    WallSeconds = $stopwatch.Elapsed.TotalSeconds
    Phases = $phaseResults
    Runtime = $runtimeResult
}
$result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Output ($result | ConvertTo-Json -Depth 14)
if ($launcher.ExitCode -ne 0) { exit $launcher.ExitCode }
