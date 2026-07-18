<#
.SYNOPSIS
运行 AgentWorkspace Review 稳定窗口导航的真实 Windows 验收。

.DESCRIPTION
脚本隔离用户状态，创建两个真实 Git 仓库和两个真实 PowerShell/ConPTY，通过真实
鼠标点击与 Ctrl+Shift+G 进入 Review，并执行 A→B→A 窗口切换。验收同时保存宽屏、
窄屏截图，检查活动工作区、后台输出、终端 PID、应用资源和关闭零残留。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateRange(3, 60)]
    [int]$SampleSeconds = 8,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\Review导航数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实Review导航-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$fixtureRoot = "F:\AWReview-$timestamp"
$repoA = Join-Path $fixtureRoot 'repo-a'
$repoB = Join-Path $fixtureRoot 'repo-b'
$resultPath = Join-Path $runDirectory '运行结果.json'
$wideAPath = Join-Path $runDirectory '宽屏-工作区A.png'
$wideBPath = Join-Path $runDirectory '宽屏-工作区B.png'
$narrowBPath = Join-Path $runDirectory '窄屏-工作区B.png'
$returnAPath = Join-Path $runDirectory '返回-工作区A.png'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'paneflow\paneflow.json'
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'paneflow\session.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory, $repoA, $repoB | Out-Null

function Invoke-PaneflowRpc {
    <# 通过一次一连接协议调用真实 Paneflow JSON-RPC。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][object]$Params)

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'paneflow', [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine(([ordered]@{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Depth 12 -Compress))
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { throw "Paneflow IPC 对 $Method 返回空响应。" }
        $response = $line | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw "Paneflow IPC $Method 失败：$($response.error | ConvertTo-Json -Compress)"
        }
        if ($response.PSObject.Properties.Name -notcontains 'result') { throw "Paneflow IPC $Method 缺少 result。" }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-PaneflowReady {
    <# 有界等待 GUI 命名管道就绪。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ((Invoke-PaneflowRpc -Method 'system.ping' -Params @{}).pong) { return }
        }
        catch {
            # 冷启动阶段命名管道尚不存在属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Paneflow IPC 在 30 秒内未就绪。'
}

function Initialize-IsolatedState {
    <# 暂存真实用户状态，保证验收不会污染日常会话。 #>
    if (Get-Process paneflow -ErrorAction SilentlyContinue) { throw '开始验收前仍存在 Paneflow 进程。' }
    $script:hadConfig = Test-Path -LiteralPath $actualConfigPath -PathType Leaf
    $script:hadSession = Test-Path -LiteralPath $actualSessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $actualConfigPath -Parent), (Split-Path $actualSessionPath -Parent) | Out-Null
    if ($script:hadConfig) { Copy-Item -LiteralPath $actualConfigPath -Destination $configBackupPath }
    if ($script:hadSession) { Move-Item -LiteralPath $actualSessionPath -Destination $sessionBackupPath }
    [ordered]@{ telemetry = [ordered]@{ enabled = $false } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $actualConfigPath -Encoding utf8
    $script:statePrepared = $true
}

function Restore-IsolatedState {
    <# 删除实验会话并原样恢复用户配置与会话。 #>
    if (-not $script:statePrepared) { return }
    if (Test-Path -LiteralPath $actualSessionPath -PathType Leaf) { Remove-Item -LiteralPath $actualSessionPath -Force }
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

function Initialize-ReviewRepository {
    <# 创建有一次真实提交并留下唯一工作区改动的本地 Git 仓库。 #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$FileName)

    git -C $Path init --quiet
    git -C $Path config user.name 'AgentWorkspace Review Test'
    git -C $Path config user.email 'review-test@example.invalid'
    Set-Content -LiteralPath (Join-Path $Path $FileName) -Encoding utf8 -Value "baseline-$FileName"
    git -C $Path add -- $FileName
    git -C $Path commit --quiet -m '建立验收基线'
    Add-Content -LiteralPath (Join-Path $Path $FileName) -Encoding utf8 -Value "changed-$timestamp"
    if ($LASTEXITCODE -ne 0) { throw "初始化 Git 仓库失败：$Path" }
}

function Get-ProcessTreeIds {
    <# 使用实时父子关系返回根进程和全部后代 PID。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    $children = @{}
    foreach ($item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } }
        catch { $parentId = 0 }
        if (-not $children.ContainsKey($parentId)) { $children[$parentId] = [Collections.Generic.List[int]]::new() }
        $children[$parentId].Add([int]$item.Id)
    }
    $seen = [Collections.Generic.HashSet[int]]::new()
    $queue = [Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $seen.Add($current)) { continue }
        if ($children.ContainsKey($current)) { foreach ($child in $children[$current]) { $queue.Enqueue($child) } }
    }
    return @($seen | Sort-Object)
}

function Get-PowerShellTreeIds {
    <# 返回实验进程树中的真实 PowerShell PID。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    return @(Get-ProcessTreeIds -RootProcessId $RootProcessId | ForEach-Object {
        Get-Process -Id $_ -ErrorAction SilentlyContinue
    } | Where-Object { $null -ne $_ -and $_.ProcessName -in @('pwsh', 'powershell') } | Select-Object -ExpandProperty Id | Sort-Object)
}

function Initialize-WindowAutomation {
    <# 注册真实鼠标、键盘、窗口定位和截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceReviewInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@
}

function Get-RealMainWindow {
    <# 恢复并返回达到最小尺寸的真实 GPUI 主窗口句柄。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $Process.Refresh()
        $handle = $Process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) {
            [AgentWorkspaceReviewInput]::ShowWindow($handle, 9) | Out-Null
            [AgentWorkspaceReviewInput]::SetWindowPos($handle, [IntPtr](-1), 20, 20, 1440, 900, 0x0040) | Out-Null
            [AgentWorkspaceReviewInput]::SetForegroundWindow($handle) | Out-Null
            Start-Sleep -Milliseconds 500
            return $handle
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow 真实主窗口在 15 秒内未就绪。'
}

function Get-WindowRectValue {
    <# 返回当前真实主窗口的屏幕坐标。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    $rect = New-Object AgentWorkspaceReviewInput+RECT
    if (-not [AgentWorkspaceReviewInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取主窗口坐标。' }
    return $rect
}

function Set-ReviewWindowSize {
    <# 设置宽屏或窄屏窗口并等待布局稳定。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][int]$Height)

    [AgentWorkspaceReviewInput]::SetWindowPos($Handle, [IntPtr](-1), 20, 20, $Width, $Height, 0x0040) | Out-Null
    [AgentWorkspaceReviewInput]::SetForegroundWindow($Handle) | Out-Null
    Start-Sleep -Milliseconds 900
}

function Invoke-WorkspaceRowClick {
    <# 点击左侧真实工作区卡片；卡片从浮动标题栏下的 44px 头部之后开始。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [ValidateRange(0, 19)][int]$Index)

    $rect = Get-WindowRectValue -Handle $Handle
    $x = $rect.Left + 120
    $y = $rect.Top + 104 + ($Index * 52)
    [AgentWorkspaceReviewInput]::SetCursorPos($x, $y) | Out-Null
    [AgentWorkspaceReviewInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceReviewInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 700
}

function Invoke-ReviewShortcut {
    <# 发送 Windows 默认 Ctrl+Shift+G，走产品真实 Review action。 #>
    [AgentWorkspaceReviewInput]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceReviewInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceReviewInput]::keybd_event(0x47, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceReviewInput]::keybd_event(0x47, 0, 2, [UIntPtr]::Zero)
    [AgentWorkspaceReviewInput]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
    [AgentWorkspaceReviewInput]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Seconds 3
}

function Wait-ActiveWorkspace {
    <# 等待鼠标切换通过应用事件循环反映到 IPC 活动索引。 #>
    param([Parameter(Mandatory = $true)][int]$Index)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $current = Invoke-PaneflowRpc -Method 'workspace.current' -Params @{}
        if ([int]$current.index -eq $Index) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "活动工作区未切换到索引 $Index。"
}

function Save-WindowScreenshot {
    <# 只截取真实产品窗口，避免桌面其他内容污染证据。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)

    $rect = Get-WindowRectValue -Handle $Handle
    # 把光标移到无交互的标题栏空白处，避免工作区路径 tooltip 遮挡验收内容。
    [AgentWorkspaceReviewInput]::SetCursorPos($rect.Left + 600, $rect.Top + 18) | Out-Null
    Start-Sleep -Milliseconds 450
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

function Measure-AppShell {
    <# 采样桌面外壳 CPU 与内存；CPU 按逻辑处理器数量归一化。 #>
    param([Parameter(Mandatory = $true)][int]$ProcessId, [Parameter(Mandatory = $true)][int]$Seconds)

    $rows = @()
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $previousCpu = $process.TotalProcessorTime.TotalSeconds
    $previousTime = [DateTimeOffset]::UtcNow
    for ($sample = 1; $sample -le $Seconds; $sample++) {
        Start-Sleep -Seconds 1
        $now = [DateTimeOffset]::UtcNow
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $cpu = (($process.TotalProcessorTime.TotalSeconds - $previousCpu) / [Math]::Max(0.001, ($now - $previousTime).TotalSeconds) / [Environment]::ProcessorCount) * 100
        $previousCpu = $process.TotalProcessorTime.TotalSeconds
        $previousTime = $now
        $rows += [pscustomobject]@{ CpuPercent = $cpu; WorkingSetMiB = $process.WorkingSet64 / 1MB; PrivateMiB = $process.PrivateMemorySize64 / 1MB }
    }
    return [pscustomobject]@{
        CpuAveragePercent = [Math]::Round((($rows | Measure-Object CpuPercent -Average).Average), 4)
        WorkingSetPeakMiB = [Math]::Round((($rows | Measure-Object WorkingSetMiB -Maximum).Maximum), 3)
        PrivatePeakMiB = [Math]::Round((($rows | Measure-Object PrivateMiB -Maximum).Maximum), 3)
    }
}

function Close-PaneflowAndCheck {
    <# 正常关闭窗口并按 PID 与启动时间核对完整实验进程树残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $tracked = @(Get-ProcessTreeIds -RootProcessId $Process.Id)
    $starts = @{}
    foreach ($id in $tracked) {
        $item = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -ne $item) { $starts[$id] = $item.StartTime.ToUniversalTime().Ticks }
    }
    [AgentWorkspaceReviewInput]::SetWindowPos($Process.MainWindowHandle, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
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
Initialize-WindowAutomation

try {
    Initialize-ReviewRepository -Path $repoA -FileName 'ONLY_A.txt'
    Initialize-ReviewRepository -Path $repoB -FileName 'ONLY_B.txt'
    Initialize-IsolatedState
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $process = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady

    Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = 'Review-A'; cwd = $repoA } | Out-Null
    Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = 'Review-B'; cwd = $repoB } | Out-Null
    Invoke-PaneflowRpc -Method 'workspace.close' -Params @{ index = 0 } | Out-Null
    Start-Sleep -Seconds 2

    $workspaces = @((Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}).workspaces | Sort-Object index)
    if ($workspaces.Count -ne 2 -or $workspaces[0].title -ne 'Review-A' -or $workspaces[1].title -ne 'Review-B') {
        throw "工作区顺序异常：$($workspaces | ConvertTo-Json -Compress)"
    }
    $surfaces = @((Invoke-PaneflowRpc -Method 'surface.list' -Params @{}).surfaces | Where-Object { $_.scope -eq 'workspace' } | Sort-Object workspace)
    if ($surfaces.Count -ne 2) { throw "预期两个真实终端，实际为 $($surfaces.Count)。" }

    foreach ($surface in $surfaces) {
        $label = if ([int]$surface.workspace -eq 0) { 'A' } else { 'B' }
        # 使用字符串拼接只替换工作区标签，保留 PowerShell 循环花括号与 `$i` 原文。
        $command = '$i=0; while($i -lt 180){ Write-Output "REVIEW_' + $label + '_TICK_$i"; Start-Sleep -Milliseconds 500; $i++ }; Write-Output "REVIEW_' + $label + '_DONE"'
        Invoke-PaneflowRpc -Method 'surface.send_text' -Params @{ surface_id = [uint64]$surface.surface_id; text = $command; submit = $true; paste = $false } | Out-Null
    }
    Start-Sleep -Seconds 2

    $handle = Get-RealMainWindow -Process $process
    Set-ReviewWindowSize -Handle $handle -Width 1440 -Height 900
    Invoke-WorkspaceRowClick -Handle $handle -Index 0
    Wait-ActiveWorkspace -Index 0
    $powershellBefore = @(Get-PowerShellTreeIds -RootProcessId $process.Id)
    Invoke-ReviewShortcut
    Save-WindowScreenshot -Handle $handle -Path $wideAPath

    Invoke-WorkspaceRowClick -Handle $handle -Index 1
    Wait-ActiveWorkspace -Index 1
    Start-Sleep -Seconds 3
    Save-WindowScreenshot -Handle $handle -Path $wideBPath

    Set-ReviewWindowSize -Handle $handle -Width 1024 -Height 720
    Save-WindowScreenshot -Handle $handle -Path $narrowBPath

    Invoke-WorkspaceRowClick -Handle $handle -Index 0
    Wait-ActiveWorkspace -Index 0
    Start-Sleep -Seconds 3
    Save-WindowScreenshot -Handle $handle -Path $returnAPath

    $surfaceEvidence = @()
    foreach ($surface in $surfaces) {
        $read = Invoke-PaneflowRpc -Method 'surface.read' -Params @{ surface_id = [uint64]$surface.surface_id; lines = 80; fenced = $false }
        $label = if ([int]$surface.workspace -eq 0) { 'A' } else { 'B' }
        $surfaceEvidence += [pscustomobject]@{
            Workspace = $label
            SurfaceId = [uint64]$surface.surface_id
            OutputGeneration = [uint64]$read.output_generation
            BackgroundOutputObserved = ([string]$read.text).Contains("REVIEW_${label}_TICK_")
        }
    }
    $powershellAfter = @(Get-PowerShellTreeIds -RootProcessId $process.Id)
    $resources = Measure-AppShell -ProcessId $process.Id -Seconds $SampleSeconds
    $close = Close-PaneflowAndCheck -Process $process
    $process = $null

    $result = [ordered]@{
        RunId = "真实Review导航-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        Workspaces = @($workspaces | ForEach-Object { [ordered]@{ Index = [int]$_.index; Title = [string]$_.title } })
        NavigationSequence = @(0, 1, 0)
        PowerShellProcessIdsBefore = $powershellBefore
        PowerShellProcessIdsAfter = $powershellAfter
        PowerShellProcessIdsStable = (($powershellBefore -join ',') -eq ($powershellAfter -join ','))
        SurfaceEvidence = $surfaceEvidence
        AllBackgroundOutputObserved = (@($surfaceEvidence | Where-Object { -not $_.BackgroundOutputObserved }).Count -eq 0)
        AppCpuAveragePercent = $resources.CpuAveragePercent
        AppWorkingSetPeakMiB = $resources.WorkingSetPeakMiB
        AppPrivatePeakMiB = $resources.PrivatePeakMiB
        WideWorkspaceAScreenshot = $wideAPath
        WideWorkspaceBScreenshot = $wideBPath
        NarrowWorkspaceBScreenshot = $narrowBPath
        ReturnWorkspaceAScreenshot = $returnAPath
        TrackedProcessIds = $close.Tracked
        RemainingProcessIds = $close.Remaining
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
        Restore-IsolatedState
        if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    }
}
