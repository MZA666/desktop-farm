param(
    [string]$Executable = '',
    [ValidateRange(30, 60)][int]$Seconds = 30,
    [string]$OutputPath = '',
    [string]$RunDirectory = '',
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Executable) { $Executable = Join-Path $projectRoot 'dist\DesktopFarm-v0.8.2\DesktopFarm.exe' }
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot 'docs\evidence\performance-v0.8.2.json' }
if (-not $RunDirectory) { $RunDirectory = Join-Path $projectRoot ('.review\performance-v0.8.2-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
$executablePath = [IO.Path]::GetFullPath($Executable)
$evidencePath = [IO.Path]::GetFullPath($OutputPath)
$runPath = [IO.Path]::GetFullPath($RunDirectory)
$releaseDirectory = [IO.Path]::GetDirectoryName($executablePath)
$workspacePrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
foreach ($outputLocation in @($evidencePath, $runPath)) {
    if (-not $outputLocation.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence and run directories must stay inside this workspace; player locations are not permitted.' }
}
$expectedVersion = '0.8.2'
$modes = @(
    @{ Id = 'farm30'; Phase = 'farm_30'; Scene = 'farm'; Power = $false; Compact = $false; Collapsed = $false },
    @{ Id = 'ranch30'; Phase = 'ranch_30'; Scene = 'ranch'; Power = $false; Compact = $false; Collapsed = $false },
    @{ Id = 'pond30'; Phase = 'pond_30'; Scene = 'pond'; Power = $false; Compact = $false; Collapsed = $false },
    @{ Id = 'farm15'; Phase = 'farm_15'; Scene = 'farm'; Power = $true; Compact = $false; Collapsed = $false },
    @{ Id = 'compact30'; Phase = 'farm_compact_30'; Scene = 'farm'; Power = $false; Compact = $true; Collapsed = $false },
    @{ Id = 'collapsed30'; Phase = 'collapsed_30'; Scene = 'farm'; Power = $false; Compact = $false; Collapsed = $true }
)
if ($PlanOnly) {
    [pscustomobject]@{ Executable = $executablePath; Version = $expectedVersion; SecondsPerMode = $Seconds;
        WarmupSeconds = 2; Modes = @($modes | ForEach-Object { $_.Id }); OutputPath = $evidencePath;
        RunDirectory = $runPath; FixtureSave = 'user://test-data/benchmark-save.json'; StartsGame = $false;
        PlayerSaveReadOrWrite = $false } | ConvertTo-Json -Depth 5
    return
}

function Get-ReleaseIdentity {
    foreach ($name in @('DesktopFarm.exe', 'DesktopFarm.pck', 'desktop_native.dll')) {
        $filePath = if ($name -eq 'DesktopFarm.exe') { $executablePath } else { Join-Path $releaseDirectory $name }
        $item = Get-Item -LiteralPath $filePath -ErrorAction Stop
        if ($item.PSIsContainer) { throw "Release file is not a file: $filePath" }
        [pscustomobject]@{ Name = $name; Path = $item.FullName; Bytes = $item.Length;
            Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
    }
}

# ArgumentList is a Win32 command line, not a shell. Preserve quoted paths,
# including trailing backslashes, without evaluating any text as commands.
function Quote-WindowsArgument([string]$Value) {
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
        } else {
            if ($slashes) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-Stage([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Test-Measuring($Stage, [int]$ProcessId, [string]$Phase) {
    return $null -ne $Stage -and [int]$Stage.process_id -eq $ProcessId -and $Stage.phase -ceq $Phase -and [bool]$Stage.measuring
}

function Get-SampleSummary([object[]]$Samples, [int]$LogicalProcessors) {
    $valid = @($Samples | Where-Object { $_.Measuring })
    if ($valid.Count -eq 0) { return $null }
    $wall = [double](($valid | Measure-Object IntervalSeconds -Sum).Sum)
    $cpu = [double](($valid | Measure-Object CpuDeltaSeconds -Sum).Sum)
    $rates = @($valid | ForEach-Object CpuSystemPercent | Sort-Object)
    [pscustomobject]@{
        SampleCount = $valid.Count; SampledWallSeconds = $wall; CpuSeconds = $cpu;
        CpuSystemPercent = 100.0 * $cpu / $wall / $LogicalProcessors;
        CpuSystemPeakPercent = ($valid | Measure-Object CpuSystemPercent -Maximum).Maximum;
        CpuSystemP95Percent = $rates[[Math]::Max(0, [Math]::Ceiling($rates.Count * 0.95) - 1)];
        WorkingSetAverageBytes = ($valid | Measure-Object WorkingSetBytes -Average).Average;
        WorkingSetPeakBytes = ($valid | Measure-Object WorkingSetBytes -Maximum).Maximum;
        PrivateBytesAverage = ($valid | Measure-Object PrivateBytes -Average).Average;
        PrivateBytesPeak = ($valid | Measure-Object PrivateBytes -Maximum).Maximum;
        WorkingSetAverageMB = ($valid | Measure-Object WorkingSetBytes -Average).Average / 1000000.0;
        WorkingSetPeakMB = ($valid | Measure-Object WorkingSetBytes -Maximum).Maximum / 1000000.0;
        PrivateAverageMB = ($valid | Measure-Object PrivateBytes -Average).Average / 1000000.0;
        PrivatePeakMB = ($valid | Measure-Object PrivateBytes -Maximum).Maximum / 1000000.0
    }
}

# Never enumerate, hash, read or write a player's save. Isolation is proven
# from the fixture flag, PID-specific native namespace and reported test path.
# Never obtain a process handle from an untrusted reported PID. Only the
# process returned by our own Start-Process may be sampled or cleaned up.
$releaseBefore = @(Get-ReleaseIdentity)
$logicalCount = [Environment]::ProcessorCount
if ($logicalCount -lt 1) { throw 'Logical processor count is unavailable.' }
if (Test-Path -LiteralPath $runPath) { throw 'RunDirectory already exists; use a new evidence directory to exclude stale PID reports.' }
New-Item -ItemType Directory -Path $runPath -Force | Out-Null
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($evidencePath)) -Force | Out-Null
$started = [DateTimeOffset]::Now
$allWatch = [Diagnostics.Stopwatch]::StartNew()
$phaseResults = [Collections.Generic.List[object]]::new()
foreach ($mode in $modes) {
    $modeDirectory = Join-Path $runPath $mode.Id
    New-Item -ItemType Directory -Path $modeDirectory | Out-Null
    $stagePath = Join-Path $modeDirectory 'benchmark-stage.json'
    $runtimePath = Join-Path $modeDirectory 'benchmark-runtime.json'
    $arguments = @('--log-file', (Join-Path $modeDirectory 'engine.log'), '--', '--benchmark-fixture',
        ('--benchmark-scene=' + $mode.Scene), ('--benchmark-seconds=' + $Seconds), ('--benchmark-output=' + $modeDirectory))
    if ($mode.Power) { $arguments += '--benchmark-power' }
    if ($mode.Compact) { $arguments += '--benchmark-compact' }
    if ($mode.Collapsed) { $arguments += '--benchmark-collapsed' }
    $argumentLine = ($arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' '
    $samples = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $launcher = $null
    $launcherId = $null
    $rendererId = $null
    $exitCode = $null
    $runtime = $null
    $runtimeHash = $null
    $visibilityMatches = $false
    $fixtureMatches = $false
    $releaseMatches = $false
    $terminatedOwnedFixture = $false
    $phaseWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Hide only the launcher console. main.gd/native host explicitly show
        # the game toolbar/scenery and prove HWND visibility in the report.
        $launcher = Start-Process -FilePath $executablePath -ArgumentList $argumentLine -WorkingDirectory $releaseDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $modeDirectory 'stdout.log') -RedirectStandardError (Join-Path $modeDirectory 'stderr.log') -PassThru
        $launcherId = $launcher.Id
        $null = $launcher.Handle
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        $stage = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            $launcher.Refresh()
            if ($launcher.HasExited) { throw 'Release exited before its own PID report.' }
            $stage = Read-Stage $stagePath
            if ($null -ne $stage -and [int]$stage.process_id -gt 0) { break }
            Start-Sleep -Milliseconds 100
        }
        if ($null -eq $stage) { throw 'Release PID report timed out.' }
        $rendererId = [int]$stage.process_id
        if ($rendererId -ne $launcher.Id) { throw 'Renderer PID does not match the benchmark-owned release process; wrapper/foreign PID rejected.' }
        if ([IO.Path]::GetFullPath($launcher.MainModule.FileName) -ine $executablePath) { throw 'Actual process executable is not the selected release.' }
        Write-Output ("MEASURE_RELEASE_STARTED mode=$($mode.Id) pid=$rendererId")
        $sampleWatch = [Diagnostics.Stopwatch]::StartNew()
        $lastWall = 0.0
        $lastCpu = $launcher.TotalProcessorTime.TotalSeconds
        $lastMeasuring = Test-Measuring $stage $rendererId $mode.Phase
        $lastProgress = 0.0
        while (-not $launcher.HasExited -and $sampleWatch.Elapsed.TotalSeconds -lt ($Seconds + 30)) {
            Start-Sleep -Milliseconds 1000
            $launcher.Refresh()
            if ($launcher.HasExited) { break }
            $wall = $sampleWatch.Elapsed.TotalSeconds
            $cpu = $launcher.TotalProcessorTime.TotalSeconds
            $stage = Read-Stage $stagePath
            $measuring = Test-Measuring $stage $rendererId $mode.Phase
            $interval = $wall - $lastWall
            $cpuDelta = $cpu - $lastCpu
            $samples.Add([pscustomobject]@{ Mode = $mode.Id; Phase = $mode.Phase; ProcessId = $rendererId;
                WallSeconds = $wall; IntervalSeconds = $interval; CpuTotalSeconds = $cpu; CpuDeltaSeconds = $cpuDelta;
                LogicalProcessors = $logicalCount; CpuSystemPercent = 100.0 * $cpuDelta / $interval / $logicalCount;
                WorkingSetBytes = $launcher.WorkingSet64; PrivateBytes = $launcher.PrivateMemorySize64;
                StageMeasuring = $measuring; Measuring = ($lastMeasuring -and $measuring) })
            $lastWall = $wall; $lastCpu = $cpu; $lastMeasuring = $measuring
            if ($wall - $lastProgress -ge 15.0) {
                Write-Output ("MEASURE_RELEASE_PROGRESS mode=$($mode.Id) elapsed=$([Math]::Round($wall,1))s")
                $lastProgress = $wall
            }
        }
        if (-not $launcher.HasExited) { throw 'Benchmark-owned release exceeded its shutdown deadline.' }
        $launcher.WaitForExit()
        $exitCode = $launcher.ExitCode
        if ($exitCode -ne 0) { $errors.Add("Release exit code: $exitCode") }
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { throw 'benchmark-runtime.json is missing.' }
        $runtime = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $runtimeHash = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash
        $releaseMatches = [int]$runtime.process_id -eq $rendererId -and $runtime.app_version -ceq $expectedVersion -and
            [IO.Path]::GetFullPath($runtime.executable_path.Replace('/', '\')) -ieq $executablePath -and
            -not [bool]$runtime.editor_feature -and -not [bool]$runtime.debug_feature -and
            $runtime.main_scene_resource -ceq 'res://scenes/main.tscn' -and -not [bool]$runtime.main_scene_physical_file_exists -and [bool]$runtime.native_ready
        $fixtureMatches = [bool]$runtime.benchmark_fixture -and [bool]$runtime.native_diagnostics.test_instance -and
            $runtime.test_instance_namespace -ceq ('Local\DesktopFarm.v07.test.' + $rendererId) -and
            $runtime.save_path -ceq 'user://test-data/benchmark-save.json' -and
            $runtime.save_absolute_path.Replace('/', '\').EndsWith('\test-data\benchmark-save.json', [StringComparison]::OrdinalIgnoreCase) -and [bool]$runtime.save_ok
        $visibilityMatches = $true
        foreach ($visibility in @($runtime.visibility_start, $runtime.visibility_end)) {
            if ($null -eq $visibility -or [bool]$visibility.scene_hwnd_visible -eq [bool]$mode.Collapsed -or
                -not [bool]$visibility.toolbar_hwnd_visible -or [bool]$visibility.scene_animation_processing -eq [bool]$mode.Collapsed) { $visibilityMatches = $false }
        }
        if (-not $releaseMatches) { $errors.Add('Packed release identity/native/PID checks failed.') }
        if (-not $fixtureMatches) { $errors.Add('Fixture namespace/path/save checks failed; player files were not inspected.') }
        if (-not $visibilityMatches) { $errors.Add('Actual start/end HWND visibility or scene processing does not match the mode.') }
        if ($runtime.phase -cne $mode.Phase -or $runtime.scene -cne $mode.Scene -or [bool]$runtime.power_saving -ne [bool]$mode.Power -or
            [bool]$runtime.collapsed -ne [bool]$mode.Collapsed -or $runtime.display_mode -cne $(if ($mode.Compact) { 'compact' } else { 'expanded' })) { $errors.Add('Actual runtime mode differs from the requested mode.') }
    } catch {
        $errors.Add($_.Exception.Message)
    } finally {
        if ($null -ne $launcher) {
            $launcher.Refresh()
            if (-not $launcher.HasExited) {
                # This retained handle belongs exclusively to Start-Process
                # above. No existing user process is found or terminated.
                try {
                    $launcher.Kill()
                    $terminatedOwnedFixture = $true
                    if (-not $launcher.WaitForExit(5000)) { $errors.Add('Owned fixture did not exit after cleanup.') }
                } catch { $errors.Add('Owned fixture cleanup failed: ' + $_.Exception.Message) }
            }
            if ($null -eq $exitCode -and $launcher.HasExited) { $exitCode = $launcher.ExitCode }
            $launcher.Dispose()
        }
    }
    $summary = Get-SampleSummary @($samples.ToArray()) $logicalCount
    if ($null -eq $summary -or $summary.SampledWallSeconds -lt ($Seconds - 3)) { $errors.Add('Too little continuous measuring-stage CPU coverage; boundary/warmup intervals are excluded.') }
    $samples | Export-Csv -LiteralPath (Join-Path $modeDirectory 'process-samples.csv') -Encoding UTF8 -NoTypeInformation
    $phaseResults.Add([pscustomobject]@{ Mode = $mode.Id; Phase = $mode.Phase; RequestedSeconds = $Seconds;
        ProcessId = $rendererId; LauncherProcessId = $launcherId; TerminatedOwnedFixtureOnFailure = $terminatedOwnedFixture;
        ExitCode = $exitCode; Passed = ($errors.Count -eq 0); Errors = @($errors.ToArray()); WallSeconds = $phaseWatch.Elapsed.TotalSeconds;
        ReleaseIdentityVerified = $releaseMatches; FixtureVerified = $fixtureMatches; VisibilityMatchesMode = $visibilityMatches;
        Summary = $summary; Samples = @($samples.ToArray()); RuntimeReportPath = $runtimePath; RuntimeReportSha256 = $runtimeHash; Runtime = $runtime })
    Write-Output ("MEASURE_RELEASE_MODE_COMPLETE mode=$($mode.Id) passed=$($errors.Count -eq 0) exit=$exitCode")
}
$releaseAfter = @(Get-ReleaseIdentity)
$unchanged = ($releaseBefore | ConvertTo-Json -Depth 4 -Compress) -ceq ($releaseAfter | ConvertTo-Json -Depth 4 -Compress)
$passed = $unchanged -and @($phaseResults | Where-Object { -not $_.Passed }).Count -eq 0
$result = [ordered]@{ Date = $started.ToString('o'); Completed = [DateTimeOffset]::Now.ToString('o'); ExpectedVersion = $expectedVersion;
    Engine = $executablePath; RunDirectory = $runPath; RequestedSecondsPerMode = $Seconds; WarmupSeconds = 2; SampleIntervalSeconds = 1;
    LogicalProcessors = $logicalCount; LogicalProcessorCountSource = 'Environment.ProcessorCount';
    OperatingSystem = [Environment]::OSVersion.VersionString; ProcessorIdentifier = $env:PROCESSOR_IDENTIFIER;
    Measurement = 'Owned release PID CPU delta seconds / interval seconds / logical CPUs * 100; intervals fully within measuring stage only; MB=1,000,000 bytes';
    ReleaseFiles = $releaseBefore; ReleaseFilesAfter = $releaseAfter; ReleaseFilesUnchanged = $unchanged;
    PlayerSaveReadOrWrite = $false; PlayerProcessStopped = $false;
    IsolationPolicy = 'No player file enumeration, hash, read or write; only PID-specific fixture namespace and user://test-data path are verified. Only a newly launched retained process handle can be stopped on failure.';
    TotalWallSeconds = $allWatch.Elapsed.TotalSeconds; Passed = $passed; Phases = @($phaseResults.ToArray()) }
$temporaryEvidence = $evidencePath + '.tmp'
$result | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $temporaryEvidence -Encoding UTF8
Move-Item -LiteralPath $temporaryEvidence -Destination $evidencePath -Force
Write-Output ("MEASURE_RELEASE_ALL_COMPLETE passed=$passed evidence=$evidencePath")
if (-not $passed) { throw 'One or more release measurements failed validation; partial evidence was preserved.' }
