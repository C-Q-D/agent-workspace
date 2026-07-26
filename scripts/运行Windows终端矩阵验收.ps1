<#
.SYNOPSIS
运行 AgentWorkspace 第一版真实终端矩阵容量、切换和清理验收。

.DESCRIPTION
脚本启动指定的 Release 二进制，通过真实命名管道创建 N 个独立 workspace，
每个 workspace 运行一个真实 PowerShell/ConPTY 持续输出负载。随后点击左侧首个
窗口进入应用级放大，采样主进程和完整进程树，读取实验重绘指标，循环切换稳定
workspace，最后正常关闭并核对残留进程。

脚本会暂存 AgentWorkspace 的 settings.json 和 workspaces.json，并在 finally 中恢复。
测试期间不要同时启动另一个 AgentWorkspace 实例。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateRange(1, 20)]
    [int]$TerminalCount = 9,

    [ValidateRange(10, 3600)]
    [int]$DurationSeconds = 30,

    [ValidateRange(50, 60000)]
    [int]$OutputIntervalMilliseconds = 1000,

    [ValidateRange(1, 200)]
    [int]$SwitchCount = 32,

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Variant = 'capacity',

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\性能数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$appProcessName = [IO.Path]::GetFileNameWithoutExtension($binary)
$ipcPipeName = 'agent-workspace'
$workload = (Resolve-Path (Join-Path $PSScriptRoot '持续输出负载.ps1')).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runId = '{0}-{1:D2}终端-{2}' -f $Variant, $TerminalCount, $timestamp
$runDirectory = Join-Path $outputRoot $runId
$csvPath = Join-Path $runDirectory '进程采样.csv'
$resultPath = Join-Path $runDirectory '运行结果.json'
$overviewPath = Join-Path $runDirectory '矩阵总览.png'
$maximizedPath = Join-Path $runDirectory '单窗口放大.png'
$stateDirectory = Join-Path $runDirectory '状态备份'
$agentWorkspaceDataRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agent-workspace'
$actualConfigPath = Join-Path $agentWorkspaceDataRoot 'config\settings.json'
$actualSessionPath = Join-Path $agentWorkspaceDataRoot 'sessions\workspaces.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'
$experimentSessionPath = Join-Path $stateDirectory '实验会话.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory | Out-Null

function Invoke-PaneflowRpc {
    <# 通过一次一连接协议执行真实 AgentWorkspace JSON-RPC。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][object]$Params
    )

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $ipcPipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $request = [ordered]@{
            jsonrpc = '2.0'
            method = $Method
            params = $Params
            id = 1
        } | ConvertTo-Json -Depth 12 -Compress
        $writer.WriteLine($request)
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "AgentWorkspace IPC 对 $Method 返回空响应。"
        }
        $response = $line | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw "AgentWorkspace IPC $Method 失败：$($response.error | ConvertTo-Json -Compress)"
        }
        if ($response.PSObject.Properties.Name -notcontains 'result') {
            throw "AgentWorkspace IPC $Method 响应缺少 result。"
        }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-PaneflowReady {
    <# 有界等待 GUI 实例完成真实命名管道启动。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $pong = Invoke-PaneflowRpc -Method 'system.ping' -Params @{}
            if ($pong.pong) { return }
        }
        catch {
            # 冷启动阶段管道尚不存在是预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'AgentWorkspace IPC 在 30 秒内未就绪。'
}

function Initialize-IsolatedState {
    <# 暂存真实用户状态，保证容量点从一个空白 workspace 开始。 #>
    if (Get-Process -Name $appProcessName -ErrorAction SilentlyContinue) {
        throw "开始验收前仍存在 $appProcessName 进程。"
    }
    $script:hadConfig = Test-Path -LiteralPath $actualConfigPath -PathType Leaf
    $script:hadSession = Test-Path -LiteralPath $actualSessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $actualConfigPath -Parent), (Split-Path $actualSessionPath -Parent) | Out-Null
    if ($script:hadConfig) { Copy-Item -LiteralPath $actualConfigPath -Destination $configBackupPath }
    if ($script:hadSession) { Move-Item -LiteralPath $actualSessionPath -Destination $sessionBackupPath }
    Set-Content -LiteralPath $actualConfigPath -Encoding utf8 -Value '{"telemetry":{"enabled":false}}'
    $script:statePrepared = $true
}

function Restore-IsolatedState {
    <# 保存实验会话副本并原样恢复用户文件。 #>
    if (-not $script:statePrepared) { return }
    if (Test-Path -LiteralPath $actualSessionPath -PathType Leaf) {
        Move-Item -LiteralPath $actualSessionPath -Destination $experimentSessionPath -Force
    }
    if ($script:hadSession -and (Test-Path -LiteralPath $sessionBackupPath -PathType Leaf)) {
        Move-Item -LiteralPath $sessionBackupPath -Destination $actualSessionPath -Force
    }
    if ($script:hadConfig -and (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $configBackupPath -Destination $actualConfigPath -Force
    }
    elseif (Test-Path -LiteralPath $actualConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $actualConfigPath -Force
    }
    $script:statePrepared = $false
}

function Get-ProcessTreeIds {
    <# 用实时父子关系返回根进程及全部后代，避免 CIM 历史父 PID 误连。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    $children = @{}
    foreach ($item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } }
        catch { $parentId = 0 }
        if (-not $children.ContainsKey($parentId)) {
            $children[$parentId] = [Collections.Generic.List[int]]::new()
        }
        $children[$parentId].Add([int]$item.Id)
    }
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $seen.Add($current)) { continue }
        if ($children.ContainsKey($current)) {
            foreach ($child in $children[$current]) { $queue.Enqueue($child) }
        }
    }
    return @($seen | Sort-Object)
}

function Get-PowerShellTreeIds {
    <# 提取实验树中的真实 PowerShell PID，作为 PTY 生命周期稳定性近似事实。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    return @(
        Get-ProcessTreeIds -RootProcessId $RootProcessId |
            ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } |
            Where-Object { $null -ne $_ -and $_.ProcessName -in @('pwsh', 'powershell') } |
            Select-Object -ExpandProperty Id |
            Sort-Object
    )
}

function Initialize-WindowAutomation {
    <# 注册截图和真实鼠标点击所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspacePerfInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
}
'@
}

function Save-WindowScreenshot {
    <# 保存当前真实应用窗口，不截取桌面其他区域。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process, [Parameter(Mandatory = $true)][string]$Path)

    $handle = $Process.MainWindowHandle
    $rect = New-Object AgentWorkspacePerfInput+RECT
    if ($handle -eq [IntPtr]::Zero -or -not [AgentWorkspacePerfInput]::GetWindowRect($handle, [ref]$rect)) {
        throw '无法读取 Paneflow 主窗口。'
    }
    $bitmap = [Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Enter-ApplicationMaximize {
    <# 点击左侧第一个 workspace 卡片，走用户实际使用的应用级放大入口。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $handle = $Process.MainWindowHandle
    [AgentWorkspacePerfInput]::ShowWindow($handle, 3) | Out-Null
    [AgentWorkspacePerfInput]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
    [AgentWorkspacePerfInput]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 750
    $rect = New-Object AgentWorkspacePerfInput+RECT
    if (-not [AgentWorkspacePerfInput]::GetWindowRect($handle, [ref]$rect)) {
        throw '无法读取 Paneflow 主窗口坐标。'
    }
    # 当前布局中首个 workspace 卡片位于 248px 主栏内、标题栏下方约 88～136px。
    [AgentWorkspacePerfInput]::SetCursorPos($rect.Left + 120, $rect.Top + 110) | Out-Null
    [AgentWorkspacePerfInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspacePerfInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Seconds 2
}

function Get-RenderMetrics {
    <# 读取专用 feature 暴露的终端重绘计数；普通构建返回空值并导致门禁失败。 #>
    param([Parameter(Mandatory = $true)][uint64]$SurfaceId)

    $read = Invoke-PaneflowRpc -Method 'surface.read' -Params @{ surface_id = $SurfaceId; lines = 20; fenced = $false }
    if ($read.PSObject.Properties.Name -notcontains 'render_metrics') { return $null }
    return $read.render_metrics
}

function Get-MetricDelta {
    <# 计算同一终端单调指标的非负差值。 #>
    param([object]$Before, [object]$After)

    if ($null -eq $Before -or $null -eq $After) { return $null }
    return [ordered]@{
        change_batches = [uint64]$After.change_batches - [uint64]$Before.change_batches
        immediate_redraw_requests = [uint64]$After.immediate_redraw_requests - [uint64]$Before.immediate_redraw_requests
        hidden_suppressed_redraw_requests = [uint64]$After.hidden_suppressed_redraw_requests - [uint64]$Before.hidden_suppressed_redraw_requests
        resume_redraw_requests = [uint64]$After.resume_redraw_requests - [uint64]$Before.resume_redraw_requests
    }
}

function Measure-ProcessTree {
    <# 按绝对一秒节拍记录应用外壳与真实 PowerShell 子进程，CPU 按逻辑处理器归一化。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId, [Parameter(Mandatory = $true)][int]$Seconds)

    function Get-MemorySumMiB {
        <# Windows PowerShell 严格模式下空集合的 Measure-Object 结果不稳定，显式累加保证 0 值可读。 #>
        param([object[]]$Items = @(), [Parameter(Mandatory = $true)][string]$PropertyName)
        $sum = 0.0
        foreach ($item in $Items) {
            if ($item.PSObject.Properties.Name -contains $PropertyName) {
                $sum += [double]$item.$PropertyName
            }
        }
        return $sum / 1MB
    }

    $rows = [Collections.Generic.List[object]]::new()
    $signatures = [Collections.Generic.HashSet[string]]::new()
    $root = Get-Process -Id $RootProcessId -ErrorAction Stop
    $previousCpu = $root.TotalProcessorTime.TotalSeconds
    $previousTime = [DateTimeOffset]::UtcNow
    $sampleClock = [Diagnostics.Stopwatch]::StartNew()
    for ($sample = 1; $sample -le $Seconds; $sample++) {
        # 进程树枚举本身需要约 100～200 ms；若每轮固定再睡一秒，1800 个样本会
        # 漂移到 30 分钟以后并让有界负载正常退出。这里等待绝对目标时刻来消除累计漂移。
        $remainingMilliseconds = ($sample * 1000.0) - $sampleClock.Elapsed.TotalMilliseconds
        # 系统待机或宿主长时间挂起后，不能通过高速补采样伪造连续长稳窗口。
        if ($remainingMilliseconds -lt -10000) {
            throw "连续采样时钟已落后 $([Math]::Round(-$remainingMilliseconds / 1000.0, 3)) 秒，可能发生系统待机或进程挂起，本轮证据无效。"
        }
        if ($remainingMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Ceiling($remainingMilliseconds))
        }
        $now = [DateTimeOffset]::UtcNow
        $root = Get-Process -Id $RootProcessId -ErrorAction Stop
        $cpu = (($root.TotalProcessorTime.TotalSeconds - $previousCpu) / [Math]::Max(0.001, ($now - $previousTime).TotalSeconds) / [Environment]::ProcessorCount) * 100
        $previousCpu = $root.TotalProcessorTime.TotalSeconds
        $previousTime = $now
        $ids = @(Get-ProcessTreeIds -RootProcessId $RootProcessId)
        $signatures.Add(($ids -join ',')) | Out-Null
        $tree = @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Where-Object { $null -ne $_ })
        $powershell = @($tree | Where-Object { $_.ProcessName -in @('pwsh', 'powershell') })
        $conhost = @($tree | Where-Object { $_.ProcessName -eq 'conhost' })
        $rows.Add([pscustomobject]@{
            Sample = $sample
            TimestampUtc = $now.ToString('O')
            AppCpuPercent = [Math]::Round($cpu, 4)
            AppWorkingSetMiB = [Math]::Round($root.WorkingSet64 / 1MB, 3)
            AppPrivateMiB = [Math]::Round($root.PrivateMemorySize64 / 1MB, 3)
            AppThreads = $root.Threads.Count
            AppHandles = $root.HandleCount
            TreeProcessCount = $tree.Count
            TreeWorkingSetMiB = [Math]::Round((Get-MemorySumMiB -Items $tree -PropertyName 'WorkingSet64'), 3)
            TreePrivateMiB = [Math]::Round((Get-MemorySumMiB -Items $tree -PropertyName 'PrivateMemorySize64'), 3)
            PowerShellCount = $powershell.Count
            PowerShellWorkingSetMiB = [Math]::Round((Get-MemorySumMiB -Items $powershell -PropertyName 'WorkingSet64'), 3)
            PowerShellPrivateMiB = [Math]::Round((Get-MemorySumMiB -Items $powershell -PropertyName 'PrivateMemorySize64'), 3)
            ConhostCount = $conhost.Count
            ConhostWorkingSetMiB = [Math]::Round((Get-MemorySumMiB -Items $conhost -PropertyName 'WorkingSet64'), 3)
            ConhostPrivateMiB = [Math]::Round((Get-MemorySumMiB -Items $conhost -PropertyName 'PrivateMemorySize64'), 3)
        })
    }
    $timestampSpan = if ($rows.Count -gt 1) {
        ([DateTimeOffset]::Parse($rows[-1].TimestampUtc) - [DateTimeOffset]::Parse($rows[0].TimestampUtc)).TotalSeconds
    }
    else { 0.0 }
    return [pscustomobject]@{
        Rows = @($rows)
        Stable = ($signatures.Count -eq 1)
        Signatures = @($signatures)
        ElapsedSeconds = $sampleClock.Elapsed.TotalSeconds
        TimestampSpanSeconds = $timestampSpan
    }
}

function Close-PaneflowAndCheck {
    <# 正常关闭窗口并按 PID+启动时间核对完整实验进程树残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $tracked = @(Get-ProcessTreeIds -RootProcessId $Process.Id)
    $starts = @{}
    foreach ($id in $tracked) {
        $item = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -ne $item) { $starts[$id] = $item.StartTime.ToUniversalTime().Ticks }
    }
    [AgentWorkspacePerfInput]::SetWindowPos($Process.MainWindowHandle, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
    $Process.CloseMainWindow() | Out-Null
    if (-not $Process.WaitForExit(15000)) { Stop-Process -Id $Process.Id -Force }
    $remaining = @()
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $remaining = @(foreach ($id in $tracked) {
            $item = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($null -ne $item -and $starts.ContainsKey($id) -and $item.StartTime.ToUniversalTime().Ticks -eq $starts[$id]) { $id }
        })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Tracked = $tracked; Remaining = $remaining }
}

$process = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false
$script:executionStateHeld = $false
Initialize-WindowAutomation

try {
    # 长稳期间阻止 Windows 因空闲进入系统待机；屏幕仍允许按用户策略关闭。
    $executionState = [AgentWorkspacePerfInput]::SetThreadExecutionState([uint32]2147483649)
    if ($executionState -eq 0) { throw '无法建立 Windows 连续采样防休眠请求。' }
    $script:executionStateHeld = $true
    Initialize-IsolatedState
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $process = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady

    # 首次启动保持零工作区；全部真实终端都必须通过显式目录的生产入口创建。
    for ($index = 0; $index -lt $TerminalCount; $index++) {
        Invoke-PaneflowRpc -Method 'workspace.create' -Params @{
            name = 'perf-{0:D2}' -f ($index + 1)
            cwd = $repoRoot
        } | Out-Null
    }
    Start-Sleep -Seconds 3
    $surfaceList = Invoke-PaneflowRpc -Method 'surface.list' -Params @{}
    $surfaces = @($surfaceList.surfaces | Where-Object { $_.scope -eq 'workspace' } | Sort-Object workspace)
    if ($surfaces.Count -ne $TerminalCount) {
        throw "预期 $TerminalCount 个 workspace 终端，实际为 $($surfaces.Count)。"
    }

    # 多工作区逐个启动负载、截图和进入放大都会消耗采样前时间；固定保留 45 秒尾部，
    # 确保 16 终端档位也不会在采样结束前退出并造成伪进程抖动。
    $loadTailSeconds = 45
    $loadSeconds = $DurationSeconds + $loadTailSeconds
    foreach ($surface in $surfaces) {
        $windowName = 'perf-{0:D2}' -f ([int]$surface.workspace + 1)
        $command = 'pwsh -NoLogo -NoProfile -File "{0}" -WindowName "{1}" -DurationSeconds {2} -IntervalMilliseconds {3}' -f $workload, $windowName, $loadSeconds, $OutputIntervalMilliseconds
        Invoke-PaneflowRpc -Method 'surface.send_text' -Params @{
            surface_id = [uint64]$surface.surface_id
            text = $command
            submit = $true
            paste = $false
        } | Out-Null
    }
    Start-Sleep -Seconds 4
    $process.Refresh()
    [AgentWorkspacePerfInput]::ShowWindow($process.MainWindowHandle, 3) | Out-Null
    # 截图前临时置顶，避免其他前台窗口覆盖应用区域形成错误视觉证据。
    [AgentWorkspacePerfInput]::SetWindowPos($process.MainWindowHandle, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
    [AgentWorkspacePerfInput]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
    Start-Sleep -Seconds 1
    Save-WindowScreenshot -Process $process -Path $overviewPath
    Enter-ApplicationMaximize -Process $process

    # 左栏会为当前活动项保持滚动位置，因此固定屏幕坐标不保证命中 workspace 0。
    # 先用真实重绘计数确认已经进入单窗口态；若前台切换瞬间吞掉首次点击，最多
    # 重试两次。这里不接受“截图看起来像放大”的主观判断。
    if ($TerminalCount -gt 1) {
        $focusConfirmed = $false
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            $probeFirstBefore = Get-RenderMetrics -SurfaceId ([uint64]$surfaces[0].surface_id)
            $probeLastBefore = Get-RenderMetrics -SurfaceId ([uint64]$surfaces[-1].surface_id)
            if ($null -eq $probeFirstBefore -or $null -eq $probeLastBefore) {
                throw '当前二进制未启用 terminal-perf-metrics，不能完成隐藏重绘门禁。'
            }
            Start-Sleep -Seconds 1
            $probeFirst = Get-MetricDelta -Before $probeFirstBefore -After (Get-RenderMetrics -SurfaceId ([uint64]$surfaces[0].surface_id))
            $probeLast = Get-MetricDelta -Before $probeLastBefore -After (Get-RenderMetrics -SurfaceId ([uint64]$surfaces[-1].surface_id))
            $focusConfirmed = ([uint64]$probeFirst.hidden_suppressed_redraw_requests -gt 0) -or
                ([uint64]$probeLast.hidden_suppressed_redraw_requests -gt 0)
            if ($focusConfirmed) { break }
            Enter-ApplicationMaximize -Process $process
        }
        if (-not $focusConfirmed) { throw '真实点击后三次仍未进入单窗口态。' }
    }
    Save-WindowScreenshot -Process $process -Path $maximizedPath

    # 坐标点击可能命中当前滚动区域中的任意工作区；以生产 workspace.list 的活动
    # 身份选择聚焦样本，再从其他工作区选择隐藏样本，避免把中间窗口误判为失败。
    $workspaceState = Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}
    $activeWorkspace = @($workspaceState.workspaces | Where-Object { [bool]$_.active } | Select-Object -First 1)
    if ($activeWorkspace.Count -ne 1) { throw '单窗口态缺少唯一活动工作区。' }
    $focusedSurface = @($surfaces | Where-Object { [int]$_.workspace -eq [int]$activeWorkspace[0].index } | Select-Object -First 1)
    if ($focusedSurface.Count -ne 1) { throw '无法把活动工作区映射到真实终端。' }
    $hiddenSurface = @($surfaces | Where-Object { [int]$_.workspace -ne [int]$activeWorkspace[0].index } | Select-Object -First 1)
    $firstId = [uint64]$focusedSurface[0].surface_id
    $lastId = if ($hiddenSurface.Count -gt 0) { [uint64]$hiddenSurface[0].surface_id } else { $firstId }
    $firstBefore = Get-RenderMetrics -SurfaceId $firstId
    $lastBefore = Get-RenderMetrics -SurfaceId $lastId
    if ($null -eq $firstBefore -or $null -eq $lastBefore) {
        throw '当前二进制未启用 terminal-perf-metrics，不能完成隐藏重绘门禁。'
    }

    $processIdsBefore = @(Get-ProcessTreeIds -RootProcessId $process.Id)
    $samples = Measure-ProcessTree -RootProcessId $process.Id -Seconds $DurationSeconds
    @($samples.Rows) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    $firstAfter = Get-RenderMetrics -SurfaceId $firstId
    $lastAfter = Get-RenderMetrics -SurfaceId $lastId
    $processIdsAfter = @(Get-ProcessTreeIds -RootProcessId $process.Id)
    # 固定保存采样结束时的真实进程树明细，便于区分桌面外壳、PowerShell 和
    # conhost 开销；PID 只用于本轮证据，不作为跨运行的稳定标识。
    $processTreeSnapshot = @($processIdsAfter | ForEach-Object {
        $item = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } } catch { $parentId = 0 }
            [pscustomobject]@{
                Id = [int]$item.Id
                ParentId = $parentId
                Name = [string]$item.ProcessName
                WorkingSetMiB = [Math]::Round($item.WorkingSet64 / 1MB, 3)
                PrivateMiB = [Math]::Round($item.PrivateMemorySize64 / 1MB, 3)
            }
        }
    })

    # 等待有界负载写出最终标记，逐窗口读取真实 scrollback 证明后台未丢尾部。
    Start-Sleep -Seconds ($loadTailSeconds + 2)
    $completion = @()
    foreach ($surface in $surfaces) {
        $read = Invoke-PaneflowRpc -Method 'surface.read' -Params @{ surface_id = [uint64]$surface.surface_id; lines = 40; fenced = $false }
        $completion += [pscustomobject]@{
            SurfaceId = [uint64]$surface.surface_id
            Workspace = [int]$surface.workspace
            OutputGeneration = [uint64]$read.output_generation
            Completed = ([string]$read.text).Contains('AGENTWORKSPACE_DONE')
        }
    }

    # 负载结束后循环切换，避免把 PowerShell 输出 CPU 混入导航延迟。
    $switchLatencies = [Collections.Generic.List[double]]::new()
    $switchPidsBefore = @(Get-PowerShellTreeIds -RootProcessId $process.Id)
    for ($iteration = 0; $iteration -lt $SwitchCount; $iteration++) {
        $target = $surfaces[$iteration % $surfaces.Count]
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-PaneflowRpc -Method 'surface.focus' -Params @{ surface_id = [uint64]$target.surface_id } | Out-Null
        $watch.Stop()
        $switchLatencies.Add($watch.Elapsed.TotalMilliseconds)
    }
    $switchPidsAfter = @(Get-PowerShellTreeIds -RootProcessId $process.Id)
    $sortedLatency = @($switchLatencies | Sort-Object)
    $p95Index = [Math]::Max(0, [Math]::Ceiling($sortedLatency.Count * 0.95) - 1)
    $p95 = $sortedLatency[$p95Index]

    $close = Close-PaneflowAndCheck -Process $process
    $process = $null
    $rows = @($samples.Rows)
    $result = [ordered]@{
        RunId = $runId
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        TerminalCount = $TerminalCount
        DurationSeconds = $DurationSeconds
        OutputIntervalMilliseconds = $OutputIntervalMilliseconds
        AppCpuAveragePercent = [Math]::Round((($rows | Measure-Object AppCpuPercent -Average).Average), 4)
        AppWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object AppWorkingSetMiB -Maximum).Maximum), 3)
        AppWorkingSetFirstMiB = $rows[0].AppWorkingSetMiB
        AppWorkingSetLastMiB = $rows[-1].AppWorkingSetMiB
        AppPrivatePeakMiB = [Math]::Round((($rows | Measure-Object AppPrivateMiB -Maximum).Maximum), 3)
        AppPrivateFirstMiB = $rows[0].AppPrivateMiB
        AppPrivateLastMiB = $rows[-1].AppPrivateMiB
        TreeProcessCountPeak = (($rows | Measure-Object TreeProcessCount -Maximum).Maximum)
        TreeWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object TreeWorkingSetMiB -Maximum).Maximum), 3)
        TreePrivatePeakMiB = [Math]::Round((($rows | Measure-Object TreePrivateMiB -Maximum).Maximum), 3)
        PowerShellCountPeak = (($rows | Measure-Object PowerShellCount -Maximum).Maximum)
        PowerShellWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object PowerShellWorkingSetMiB -Maximum).Maximum), 3)
        PowerShellPrivatePeakMiB = [Math]::Round((($rows | Measure-Object PowerShellPrivateMiB -Maximum).Maximum), 3)
        ConhostCountPeak = (($rows | Measure-Object ConhostCount -Maximum).Maximum)
        ConhostWorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object ConhostWorkingSetMiB -Maximum).Maximum), 3)
        ConhostPrivatePeakMiB = [Math]::Round((($rows | Measure-Object ConhostPrivateMiB -Maximum).Maximum), 3)
        ProcessTreeStableDuringSample = [bool]$samples.Stable
        ProcessIdsStableDuringSample = (($processIdsBefore -join ',') -eq ($processIdsAfter -join ','))
        SampleElapsedSeconds = [Math]::Round([double]$samples.ElapsedSeconds, 3)
        SampleTimestampSpanSeconds = [Math]::Round([double]$samples.TimestampSpanSeconds, 3)
        ProcessTreeSnapshot = $processTreeSnapshot
        FirstSurfaceRenderDelta = Get-MetricDelta -Before $firstBefore -After $firstAfter
        LastSurfaceRenderDelta = Get-MetricDelta -Before $lastBefore -After $lastAfter
        AllFinalMarkersObserved = (@($completion | Where-Object { -not $_.Completed }).Count -eq 0)
        Completion = $completion
        SwitchCount = $SwitchCount
        SwitchP95Milliseconds = [Math]::Round($p95, 3)
        SwitchMaxMilliseconds = [Math]::Round((($switchLatencies | Measure-Object -Maximum).Maximum), 3)
        SwitchProcessIdsStable = (($switchPidsBefore -join ',') -eq ($switchPidsAfter -join ','))
        TrackedProcessIds = $close.Tracked
        RemainingProcessIds = $close.Remaining
        OverviewScreenshot = $overviewPath
        MaximizedScreenshot = $maximizedPath
        SamplesCsv = $csvPath
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
    [pscustomobject]$result
}
finally {
    try {
        if ($null -ne $process -and $null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            Close-PaneflowAndCheck -Process $process | Out-Null
        }
    }
    finally {
        try {
            Restore-IsolatedState
        }
        finally {
            if ($script:executionStateHeld) {
                [AgentWorkspacePerfInput]::SetThreadExecutionState([uint32]2147483648) | Out-Null
                $script:executionStateHeld = $false
            }
        }
    }
}
