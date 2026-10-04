param(
    [string]$GamePath = (Join-Path $PSScriptRoot "SpaceMinerGame.exe"),
    [ValidateSet("opengl3", "opengl3_angle")]
    [string]$RenderingDriver = "opengl3",
    [int]$HeartbeatMilliseconds = 5,
    [int]$CounterMilliseconds = 100
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $GamePath)) {
    throw "SpaceMinerGame.exe was not found at: $GamePath"
}

$GamePath = (Resolve-Path -LiteralPath $GamePath).Path
$OutputDirectory = Split-Path -Parent $GamePath
$driverTag = $RenderingDriver -replace '[^A-Za-z0-9_-]', '_'
$CsvPath = Join-Path $OutputDirectory "SpaceMinerWindowsDeep-$driverTag.csv"
$LogPath = Join-Path $OutputDirectory "SpaceMinerWindowsDeep-$driverTag.log"

$events = New-Object 'System.Collections.Generic.List[string]'
$rows = New-Object 'System.Collections.Generic.List[object]'
$logicalProcessors = [Environment]::ProcessorCount

function Add-EventLine {
    param([string]$Text)
    $events.Add(("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fff"), $Text))
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class SpaceMinerExternalHeartbeatDeep
{
    public static readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
    public static volatile bool StopRequested;
    public static Thread Worker;
    public static int GapCount;
    public static double MaxGapMs;

    private static int _intervalMs;
    private static double _thresholdMs;
    private static Stopwatch _stopwatch;
    private static readonly object _maxLock = new object();

    public static void Start(int intervalMs, double thresholdMs)
    {
        _intervalMs = intervalMs;
        _thresholdMs = thresholdMs;
        StopRequested = false;
        GapCount = 0;
        MaxGapMs = 0.0;
        _stopwatch = Stopwatch.StartNew();
        Worker = new Thread(Run);
        Worker.IsBackground = true;
        Worker.Name = "SpaceMinerExternalHeartbeatDeep";
        Worker.Start();
    }

    private static void Run()
    {
        long lastTicks = _stopwatch.ElapsedTicks;
        while (!StopRequested)
        {
            Thread.Sleep(_intervalMs);
            long nowTicks = _stopwatch.ElapsedTicks;
            double gapMs = (nowTicks - lastTicks) * 1000.0 / Stopwatch.Frequency;
            lastTicks = nowTicks;
            if (gapMs < _thresholdMs)
                continue;

            int count = Interlocked.Increment(ref GapCount);
            lock (_maxLock)
            {
                if (gapMs > MaxGapMs)
                    MaxGapMs = gapMs;
            }

            double elapsedSeconds = nowTicks / (double)Stopwatch.Frequency;
            Events.Enqueue(String.Format(
                "[{0}] EXTERNAL_SCHEDULER_GAP t={1:F3}s gap={2:F2}ms count={3}",
                DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss.fff"),
                elapsedSeconds,
                gapMs,
                count
            ));
        }
    }

    public static void Stop()
    {
        StopRequested = true;
        if (Worker != null && Worker.IsAlive)
            Worker.Join();
    }
}

public static class SpaceMinerWin32
{
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

function New-CounterSafe {
    param([string]$Category, [string]$Counter, [string]$Instance)
    try {
        $pc = [System.Diagnostics.PerformanceCounter]::new($Category, $Counter, $Instance, $true)
        [void]$pc.NextValue()
        return $pc
    }
    catch {
        Add-EventLine "COUNTER_UNAVAILABLE category=$Category counter=$Counter instance=$Instance error=$($_.Exception.Message)"
        return $null
    }
}

function Read-CounterSafe {
    param($CounterObject)
    if ($null -eq $CounterObject) { return [double]::NaN }
    try { return [double]$CounterObject.NextValue() }
    catch { return [double]::NaN }
}

function Get-GpuCountersForProcess {
    param([int]$GameProcessId)
    $result = New-Object 'System.Collections.Generic.List[object]'
    try {
        $category = [System.Diagnostics.PerformanceCounterCategory]::new("GPU Engine")
        $prefix = "pid_{0}_" -f $GameProcessId
        foreach ($instance in $category.GetInstanceNames()) {
            if (-not $instance.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            try {
                $counter = [System.Diagnostics.PerformanceCounter]::new(
                    "GPU Engine", "Utilization Percentage", $instance, $true
                )
                [void]$counter.NextValue()
                $result.Add($counter)
            }
            catch { }
        }
    }
    catch {
        Add-EventLine "GPU_COUNTER_DISCOVERY_FAILED error=$($_.Exception.Message)"
    }
    return $result
}

function Dispose-CounterList {
    param($List)
    if ($null -eq $List) { return }
    foreach ($counter in $List) {
        try { $counter.Dispose() } catch { }
    }
}

function Get-ProcessThreadSafe {
    param($Process, [uint32]$ThreadId)
    if ($ThreadId -eq 0) { return $null }
    try {
        foreach ($thread in $Process.Threads) {
            if ([uint32]$thread.Id -eq $ThreadId) { return $thread }
        }
    }
    catch { }
    return $null
}

$os = Get-CimInstance Win32_OperatingSystem
$video = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA|AMD|Intel" }
$powerScheme = (& powercfg /getactivescheme 2>$null) -join " "

Add-EventLine "WINDOWS_DEEP_DIAGNOSTICS_START"
Add-EventLine "GamePath=$GamePath"
Add-EventLine "RenderingDriver=$RenderingDriver"
Add-EventLine "Windows=$($os.Caption) version=$($os.Version) build=$($os.BuildNumber)"
Add-EventLine "LogicalProcessors=$logicalProcessors"
Add-EventLine "PowerScheme=$powerScheme"
foreach ($adapter in $video) {
    Add-EventLine "VideoAdapter=$($adapter.Name) DriverVersion=$($adapter.DriverVersion)"
}
Add-EventLine "External heartbeat=${HeartbeatMilliseconds}ms threshold=50ms counters=${CounterMilliseconds}ms"
Add-EventLine "All diagnostics are held in memory until the game exits."

$cpuTotal = New-CounterSafe "Processor" "% Processor Time" "_Total"
$dpcTotal = New-CounterSafe "Processor" "% DPC Time" "_Total"
$interruptTotal = New-CounterSafe "Processor" "% Interrupt Time" "_Total"
$queueLength = New-CounterSafe "System" "Processor Queue Length" ""
$contextSwitches = New-CounterSafe "System" "Context Switches/sec" ""
$pageReads = New-CounterSafe "Memory" "Page Reads/sec" ""
$diskLatency = New-CounterSafe "PhysicalDisk" "Avg. Disk sec/Transfer" "_Total"
$diskQueue = New-CounterSafe "PhysicalDisk" "Current Disk Queue Length" "_Total"

[SpaceMinerExternalHeartbeatDeep]::Start($HeartbeatMilliseconds, 50.0)
$game = Start-Process -FilePath $GamePath -WorkingDirectory $OutputDirectory -ArgumentList @("--rendering-driver", $RenderingDriver) -PassThru
Add-EventLine "GAME_STARTED pid=$($game.Id)"

$windowThreadId = [uint32]0
for ($attempt = 0; $attempt -lt 100 -and -not $game.HasExited; $attempt++) {
    Start-Sleep -Milliseconds 100
    try { $game.Refresh() } catch { break }
    if ($game.MainWindowHandle -ne [IntPtr]::Zero) {
        [uint32]$ownerPid = 0
        $windowThreadId = [SpaceMinerWin32]::GetWindowThreadProcessId($game.MainWindowHandle, [ref]$ownerPid)
        if ($windowThreadId -ne 0) { break }
    }
}
Add-EventLine "MAIN_WINDOW_THREAD tid=$windowThreadId hwnd=$($game.MainWindowHandle)"

Start-Sleep -Milliseconds 500
$gpuCounters = Get-GpuCountersForProcess $game.Id
Add-EventLine "GPU_ENGINE_COUNTERS initial=$($gpuCounters.Count)"

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$nextCounterMs = 0.0
$nextGpuRefreshMs = 10000.0
$previousCpuMs = 0.0
$previousCpuSampleMs = 0.0
$previousMainThreadCpuMs = 0.0

try {
    $game.Refresh()
    $previousCpuMs = $game.TotalProcessorTime.TotalMilliseconds
    $mainThread = Get-ProcessThreadSafe $game $windowThreadId
    if ($null -ne $mainThread) {
        $previousMainThreadCpuMs = $mainThread.TotalProcessorTime.TotalMilliseconds
    }
}
catch { }

try {
    while (-not $game.HasExited) {
        Start-Sleep -Milliseconds 20
        $nowMs = $stopwatch.Elapsed.TotalMilliseconds

        if ($nowMs -ge $nextGpuRefreshMs) {
            Dispose-CounterList $gpuCounters
            $gpuCounters = Get-GpuCountersForProcess $game.Id
            $nextGpuRefreshMs = $nowMs + 10000.0
        }

        if ($nowMs -lt $nextCounterMs) { continue }
        $nextCounterMs = $nowMs + $CounterMilliseconds

        try { $game.Refresh() } catch { continue }

        $cpuNowMs = 0.0
        try { $cpuNowMs = $game.TotalProcessorTime.TotalMilliseconds } catch { }
        $cpuIntervalMs = $nowMs - $previousCpuSampleMs
        $cpuDeltaMs = $cpuNowMs - $previousCpuMs
        $processCpuPct = 0.0
        if ($cpuIntervalMs -gt 0 -and $logicalProcessors -gt 0) {
            $processCpuPct = (($cpuDeltaMs / $cpuIntervalMs) * 100.0) / $logicalProcessors
        }
        $previousCpuMs = $cpuNowMs
        $previousCpuSampleMs = $nowMs

        $mainThreadState = "Unavailable"
        $mainThreadWaitReason = ""
        $mainThreadCpuMs = [double]::NaN
        $mainThreadCpuDeltaMs = [double]::NaN
        $mainThreadPriority = [double]::NaN
        $mainThread = Get-ProcessThreadSafe $game $windowThreadId
        if ($null -ne $mainThread) {
            try {
                $mainThreadState = $mainThread.ThreadState.ToString()
                $mainThreadCpuMs = $mainThread.TotalProcessorTime.TotalMilliseconds
                $mainThreadCpuDeltaMs = $mainThreadCpuMs - $previousMainThreadCpuMs
                $previousMainThreadCpuMs = $mainThreadCpuMs
                $mainThreadPriority = $mainThread.CurrentPriority
                if ($mainThread.ThreadState -eq [System.Diagnostics.ThreadState]::Wait) {
                    try { $mainThreadWaitReason = $mainThread.WaitReason.ToString() } catch { }
                }
            }
            catch { }
        }

        $gpuSum = 0.0
        $gpuMax = 0.0
        foreach ($counter in $gpuCounters) {
            try {
                $value = [double]$counter.NextValue()
                if (-not [double]::IsNaN($value)) {
                    $gpuSum += $value
                    if ($value -gt $gpuMax) { $gpuMax = $value }
                }
            }
            catch { }
        }

        $rows.Add([pscustomobject]@{
            Timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fff")
            ElapsedSeconds = [Math]::Round($nowMs / 1000.0, 3)
            RenderingDriver = $RenderingDriver
            MainWindowThreadId = $windowThreadId
            MainThreadState = $mainThreadState
            MainThreadWaitReason = $mainThreadWaitReason
            MainThreadCpuDeltaMs = if ([double]::IsNaN($mainThreadCpuDeltaMs)) { "" } else { [Math]::Round($mainThreadCpuDeltaMs, 3) }
            MainThreadPriority = if ([double]::IsNaN($mainThreadPriority)) { "" } else { $mainThreadPriority }
            ProcessCpuPercent = [Math]::Round($processCpuPct, 3)
            ProcessWorkingSetMB = [Math]::Round($game.WorkingSet64 / 1MB, 2)
            ProcessPrivateMB = [Math]::Round($game.PrivateMemorySize64 / 1MB, 2)
            ProcessThreads = $game.Threads.Count
            ProcessHandles = $game.HandleCount
            SystemCpuPercent = [Math]::Round((Read-CounterSafe $cpuTotal), 3)
            SystemDpcPercent = [Math]::Round((Read-CounterSafe $dpcTotal), 3)
            SystemInterruptPercent = [Math]::Round((Read-CounterSafe $interruptTotal), 3)
            ProcessorQueueLength = [Math]::Round((Read-CounterSafe $queueLength), 3)
            ContextSwitchesPerSec = [Math]::Round((Read-CounterSafe $contextSwitches), 3)
            PageReadsPerSec = [Math]::Round((Read-CounterSafe $pageReads), 3)
            DiskLatencyMs = [Math]::Round((Read-CounterSafe $diskLatency) * 1000.0, 3)
            DiskQueueLength = [Math]::Round((Read-CounterSafe $diskQueue), 3)
            GameGpuEngineSumPercent = [Math]::Round($gpuSum, 3)
            GameGpuEngineMaxPercent = [Math]::Round($gpuMax, 3)
            GameGpuEngineCounterCount = $gpuCounters.Count
        })
    }
}
finally {
    [SpaceMinerExternalHeartbeatDeep]::Stop()

    $heartbeatLine = ""
    while ([SpaceMinerExternalHeartbeatDeep]::Events.TryDequeue([ref]$heartbeatLine)) {
        $events.Add($heartbeatLine)
        $heartbeatLine = ""
    }

    try { $game.Refresh() } catch { }
    $exitCode = "unknown"
    try { $exitCode = $game.ExitCode } catch { }
    Add-EventLine "GAME_EXITED exit_code=$exitCode"
    Add-EventLine ("SUMMARY external_gaps_ge_50ms={0} max_external_gap={1:N2}ms rows={2}" -f [SpaceMinerExternalHeartbeatDeep]::GapCount, [SpaceMinerExternalHeartbeatDeep]::MaxGapMs, $rows.Count)

    Dispose-CounterList $gpuCounters
    foreach ($counter in @($cpuTotal, $dpcTotal, $interruptTotal, $queueLength, $contextSwitches, $pageReads, $diskLatency, $diskQueue)) {
        if ($null -ne $counter) {
            try { $counter.Dispose() } catch { }
        }
    }

    $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    $events | Set-Content -LiteralPath $LogPath -Encoding UTF8

    Write-Host ""
    Write-Host "Deep Windows diagnostics written after game exit:"
    Write-Host "  $CsvPath"
    Write-Host "  $LogPath"
    Write-Host "Renderer requested: $RenderingDriver"
    Write-Host "Main window thread ID: $windowThreadId"
    Write-Host "External scheduler gaps >=50 ms: $([SpaceMinerExternalHeartbeatDeep]::GapCount)"
    Write-Host ("Largest external scheduler gap: {0:N2} ms" -f [SpaceMinerExternalHeartbeatDeep]::MaxGapMs)
}
