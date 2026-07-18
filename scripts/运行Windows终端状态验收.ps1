<#
.SYNOPSIS
运行 AgentWorkspace 第一版真实 Windows 终端生命周期验收。

.DESCRIPTION
脚本隔离用户状态，通过真实 Release 应用和 PowerShell/ConPTY 依次观测启动中、
运行中、正常退出、异常退出和启动失败。启动失败使用一个真实存在但不可执行的文本
文件作为 default_shell，让 Windows CreateProcess 返回真实错误；不使用 mock 终端。
finally 始终恢复用户原有配置和会话，验收期间不要启动其他 Paneflow 实例。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\终端状态数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实状态-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$screenshotPath = Join-Path $runDirectory '四种稳定状态.png'
$resultPath = Join-Path $runDirectory '运行结果.json'
$invalidShellPath = Join-Path $runDirectory '不可执行终端程序.txt'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'paneflow\paneflow.json'
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'paneflow\session.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory | Out-Null

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
            # 冷启动阶段管道尚不存在属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Paneflow IPC 在 30 秒内未就绪。'
}

function Get-WorkspaceList {
    <# 返回按索引排序的工作区和同源终端状态。 #>
    $response = Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}
    return @($response.workspaces | Sort-Object index)
}

function Get-WorkspaceSurfaces {
    <# 返回按工作区索引排序的真实终端实体。 #>
    $response = Invoke-PaneflowRpc -Method 'surface.list' -Params @{}
    return @($response.surfaces | Where-Object { $_.scope -eq 'workspace' } | Sort-Object workspace)
}

function Wait-WorkspaceStatus {
    <# 等待事件驱动状态达到期望值；轮询仅存在于验收器，不进入产品。 #>
    param([Parameter(Mandatory = $true)][int]$Index, [Parameter(Mandatory = $true)][string]$Expected)

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $workspace = @(Get-WorkspaceList | Where-Object { [int]$_.index -eq $Index })
        if ($workspace.Count -eq 1 -and [string]$workspace[0].terminal_status -eq $Expected) {
            return $workspace[0]
        }
        Start-Sleep -Milliseconds 100
    }
    $actual = @(Get-WorkspaceList | Where-Object { [int]$_.index -eq $Index })
    throw "工作区 $Index 在 10 秒内未达到 $Expected，实际为 $($actual.terminal_status)。"
}

function Set-ExperimentConfig {
    <# 写入本轮实验配置；使用 ConvertTo-Json 保证 Windows 路径正确转义。 #>
    param([string]$DefaultShell)

    $config = [ordered]@{ telemetry = [ordered]@{ enabled = $false } }
    if (-not [string]::IsNullOrWhiteSpace($DefaultShell)) { $config['default_shell'] = $DefaultShell }
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $actualConfigPath -Encoding utf8
}

function Initialize-IsolatedState {
    <# 暂存用户状态并创建干净实验配置。 #>
    if (Get-Process paneflow -ErrorAction SilentlyContinue) { throw '开始验收前仍存在 Paneflow 进程。' }
    $script:hadConfig = Test-Path -LiteralPath $actualConfigPath -PathType Leaf
    $script:hadSession = Test-Path -LiteralPath $actualSessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $actualConfigPath -Parent), (Split-Path $actualSessionPath -Parent) | Out-Null
    if ($script:hadConfig) { Copy-Item -LiteralPath $actualConfigPath -Destination $configBackupPath }
    if ($script:hadSession) { Move-Item -LiteralPath $actualSessionPath -Destination $sessionBackupPath }
    Set-ExperimentConfig
    $script:statePrepared = $true
}

function Restore-IsolatedState {
    <# 删除实验状态并原样恢复用户配置和会话。 #>
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
    Remove-Item -LiteralPath $stateDirectory -Recurse -Force
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

function Initialize-WindowAutomation {
    <# 注册主窗口截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceStatusWindow {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
'@
}

function Get-RealMainWindow {
    <# 恢复并返回至少 800×500 的 GPUI 产品主窗口句柄。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $Process.Refresh()
        $handle = $Process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) { [AgentWorkspaceStatusWindow]::ShowWindow($handle, 9) | Out-Null }
        $rect = New-Object AgentWorkspaceStatusWindow+RECT
        if ($handle -ne [IntPtr]::Zero -and [AgentWorkspaceStatusWindow]::GetWindowRect($handle, [ref]$rect)) {
            if (($rect.Right - $rect.Left) -ge 800 -and ($rect.Bottom - $rect.Top) -ge 500) {
                [AgentWorkspaceStatusWindow]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
                [AgentWorkspaceStatusWindow]::SetForegroundWindow($handle) | Out-Null
                Start-Sleep -Milliseconds 750
                return $handle
            }
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow 真实主窗口在 15 秒内未达到最小尺寸。'
}

function Save-WindowScreenshot {
    <# 使用已验证的产品主窗口句柄保存截图。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)

    $rect = New-Object AgentWorkspaceStatusWindow+RECT
    if (-not [AgentWorkspaceStatusWindow]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取主窗口坐标。' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 800 -or $height -lt 500) { throw "拒绝保存非主窗口截图：${width}×${height}。" }
    $bitmap = [Drawing.Bitmap]::new($width, $height)
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

function Close-PaneflowAndCheck {
    <# 正常关闭窗口并核对完整实验进程树没有残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $tracked = @(Get-ProcessTreeIds -RootProcessId $Process.Id)
    $starts = @{}
    foreach ($id in $tracked) {
        $item = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -ne $item) { $starts[$id] = $item.StartTime.ToUniversalTime().Ticks }
    }
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
    Initialize-IsolatedState
    Set-Content -LiteralPath $invalidShellPath -Encoding utf8 -Value '这是真实存在但不能由 Windows CreateProcess 执行的文本文件。'
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $process = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady
    Get-RealMainWindow -Process $process | Out-Null

    $statusTrace = [Collections.Generic.List[object]]::new()
    # 快速创建真实 PTY，记录后台创建窗口；随后删去临时工作区，只保留验收四项。
    for ($index = 1; $index -lt 15; $index++) {
        $created = Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = 'state-{0:D2}' -f ($index + 1); cwd = $repoRoot }
        $snapshot = @(Get-WorkspaceList)
        $statusTrace.Add([pscustomobject]@{
            TimestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
            WorkspaceCount = $snapshot.Count
            CreateResponseStatus = [string]$created.terminal_status
            Statuses = @($snapshot | ForEach-Object { [string]$_.terminal_status })
        })
    }
    for ($index = 0; $index -lt 15; $index++) { Wait-WorkspaceStatus -Index $index -Expected 'running' | Out-Null }
    for ($index = 14; $index -ge 3; $index--) {
        Invoke-PaneflowRpc -Method 'workspace.close' -Params @{ index = $index } | Out-Null
    }
    $settled = @(Get-WorkspaceList)
    if ($settled.Count -ne 3) { throw "清理后应保留 3 个工作区，实际为 $($settled.Count)。" }

    $surfacesBeforeExit = @(Get-WorkspaceSurfaces)
    Invoke-PaneflowRpc -Method 'surface.send_text' -Params @{ surface_id = [uint64]$surfacesBeforeExit[1].surface_id; text = 'exit 0'; submit = $true; paste = $false } | Out-Null
    Invoke-PaneflowRpc -Method 'surface.send_text' -Params @{ surface_id = [uint64]$surfacesBeforeExit[2].surface_id; text = 'exit 7'; submit = $true; paste = $false } | Out-Null
    Wait-WorkspaceStatus -Index 1 -Expected 'normal_exited' | Out-Null
    Wait-WorkspaceStatus -Index 2 -Expected 'abnormal_exited' | Out-Null

    # 真实文本文件通过配置校验，但 Windows CreateProcess 会以 BAD_EXE_FORMAT 拒绝它。
    Set-ExperimentConfig -DefaultShell $invalidShellPath
    Start-Sleep -Seconds 1
    $failureCreated = Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = 'launch-failed'; cwd = $repoRoot }
    $failureStartSnapshot = @(Get-WorkspaceList)
    $statusTrace.Add([pscustomobject]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
        WorkspaceCount = $failureStartSnapshot.Count
        CreateResponseStatus = [string]$failureCreated.terminal_status
        Statuses = @($failureStartSnapshot | ForEach-Object { [string]$_.terminal_status })
    })
    Wait-WorkspaceStatus -Index 3 -Expected 'launch_failed' | Out-Null

    $finalWorkspaces = @(Get-WorkspaceList)
    $finalSurfaces = @(Get-WorkspaceSurfaces)
    $expectedStatuses = @('running', 'normal_exited', 'abnormal_exited', 'launch_failed')
    $actualStatuses = @($finalWorkspaces | ForEach-Object { [string]$_.terminal_status })
    if (($actualStatuses -join ',') -ne ($expectedStatuses -join ',')) {
        throw "最终状态不一致：$($actualStatuses -join ',')。"
    }
    if ($finalSurfaces.Count -ne 4) { throw "退出终端应保留，预期 4 个 surface，实际为 $($finalSurfaces.Count)。" }
    $stableExitIds = @($surfacesBeforeExit[0..2] | ForEach-Object { [uint64]$_.surface_id })
    $finalFirstIds = @($finalSurfaces[0..2] | ForEach-Object { [uint64]$_.surface_id })
    if (($stableExitIds -join ',') -ne ($finalFirstIds -join ',')) { throw '退出后终端实体被自动重建。' }
    $startingObserved = @(
        $statusTrace | Where-Object {
            $_.CreateResponseStatus -eq 'starting' -or $_.Statuses -contains 'starting'
        }
    ).Count -gt 0
    if (-not $startingObserved) { throw '快速真实创建期间没有捕获到 starting 状态。' }

    $handle = Get-RealMainWindow -Process $process
    Save-WindowScreenshot -Handle $handle -Path $screenshotPath
    $close = Close-PaneflowAndCheck -Process $process
    $process = $null
    if ($close.Remaining.Count -ne 0) { throw '正常关闭后仍有残留进程。' }

    $result = [ordered]@{
        RunId = "真实状态-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        StartingObserved = $startingObserved
        StatusTrace = $statusTrace
        FinalWorkspaces = $finalWorkspaces
        FinalSurfaceIds = @($finalSurfaces | ForEach-Object { [uint64]$_.surface_id })
        ExitedSurfaceIdsPreserved = $true
        TrackedProcessIds = $close.Tracked
        RemainingProcessIds = $close.Remaining
        Screenshot = $screenshotPath
        Passed = $true
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
    }
}
