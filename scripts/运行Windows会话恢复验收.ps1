<#
.SYNOPSIS
运行 AgentWorkspace 第一版真实会话、终端矩阵页码与 PTY 重建验收。

.DESCRIPTION
脚本隔离当前用户的 Paneflow 配置和会话，启动真实 Release 应用并创建 20 个
PowerShell 工作区，通过真实鼠标点击切换到矩阵第二页，再正常关闭应用。随后检查
session.json 的顺序、活动项和页码，重启应用并核对工作区恢复以及 PowerShell PID
全部替换。finally 始终恢复用户原有状态；验收期间不要同时启动其他 Paneflow 实例。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateRange(2, 20)]
    [int]$WorkspaceCount = 20,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\会话恢复数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $outputRoot "真实重启-$timestamp"
$firstPagePath = Join-Path $runDirectory '首次启动第一页.png'
$secondPagePath = Join-Path $runDirectory '首次启动第二页.png'
$restoredPagePath = Join-Path $runDirectory '重启恢复第二页.png'
$savedSessionPath = Join-Path $runDirectory '首次退出会话.json'
$restoredSessionPath = Join-Path $runDirectory '重启退出会话.json'
$resultPath = Join-Path $runDirectory '运行结果.json'
$stateDirectory = Join-Path $runDirectory '状态备份'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'paneflow\paneflow.json'
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'paneflow\session.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory | Out-Null

function Invoke-PaneflowRpc {
    <# 通过一次一连接协议调用真实 Paneflow JSON-RPC。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][object]$Params
    )

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'paneflow', [IO.Pipes.PipeDirection]::InOut)
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
            throw "Paneflow IPC 对 $Method 返回空响应。"
        }
        $response = $line | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw "Paneflow IPC $Method 失败：$($response.error | ConvertTo-Json -Compress)"
        }
        if ($response.PSObject.Properties.Name -notcontains 'result') {
            throw "Paneflow IPC $Method 响应缺少 result。"
        }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-PaneflowReady {
    <# 有界等待 GUI 实例完成命名管道和工作区恢复。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $pong = Invoke-PaneflowRpc -Method 'system.ping' -Params @{}
            if ($pong.pong) { return }
        }
        catch {
            # 冷启动阶段管道尚不存在属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Paneflow IPC 在 30 秒内未就绪。'
}

function Initialize-IsolatedState {
    <# 暂存真实用户状态，保证验收从单个空白工作区开始。 #>
    if (Get-Process paneflow -ErrorAction SilentlyContinue) {
        throw '开始验收前仍存在 Paneflow 进程。'
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
    <# 删除实验状态并原样恢复用户文件。 #>
    if (-not $script:statePrepared) { return }
    if (Test-Path -LiteralPath $actualSessionPath -PathType Leaf) {
        Remove-Item -LiteralPath $actualSessionPath -Force
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
    Remove-Item -LiteralPath $stateDirectory -Recurse -Force
}

function Get-ProcessTreeIds {
    <# 使用实时父子关系返回根进程及全部后代 PID。 #>
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

function Get-PowerShellTreeRecords {
    <# 返回应用进程树内 PowerShell PID 和启动时刻，用于证明重启后 PTY 已重建。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    return @(
        Get-ProcessTreeIds -RootProcessId $RootProcessId |
            ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } |
            Where-Object { $null -ne $_ -and $_.ProcessName -in @('pwsh', 'powershell') } |
            Sort-Object Id |
            ForEach-Object {
                [pscustomobject]@{
                    Pid = [int]$_.Id
                    StartTimeUtc = $_.StartTime.ToUniversalTime().ToString('O')
                }
            }
    )
}

function Initialize-WindowAutomation {
    <# 注册窗口截图和真实鼠标点击所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceSessionInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
'@
}

function Prepare-Window {
    <# 等待真实 GPUI 主窗口完成首帧，再按产品默认尺寸置于前台。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $handle = [IntPtr]::Zero
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $Process.Refresh()
        $candidate = $Process.MainWindowHandle
        $rect = New-Object AgentWorkspaceSessionInput+RECT
        if ($candidate -ne [IntPtr]::Zero) {
            # 恢复启动时 Windows 可能先暴露压缩后的 160×28 句柄；先请求恢复，再检查尺寸。
            [AgentWorkspaceSessionInput]::ShowWindow($candidate, 9) | Out-Null
        }
        if ($candidate -ne [IntPtr]::Zero -and [AgentWorkspaceSessionInput]::GetWindowRect($candidate, [ref]$rect)) {
            if (($rect.Right - $rect.Left) -ge 800 -and ($rect.Bottom - $rect.Top) -ge 500) {
                $handle = $candidate
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($handle -eq [IntPtr]::Zero) { throw 'Paneflow 真实主窗口在 15 秒内未达到最小尺寸。' }
    [AgentWorkspaceSessionInput]::ShowWindow($handle, 9) | Out-Null
    # 仅切换置顶关系，不移动或缩放产品默认的 1200×800 窗口。
    [AgentWorkspaceSessionInput]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
    [AgentWorkspaceSessionInput]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 750
    return $handle
}

function Save-WindowScreenshot {
    <# 保存当前真实应用窗口，不截取桌面其他区域。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)

    $rect = New-Object AgentWorkspaceSessionInput+RECT
    if (-not [AgentWorkspaceSessionInput]::GetWindowRect($Handle, [ref]$rect)) {
        throw '无法读取 Paneflow 主窗口坐标。'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 800 -or $height -lt 500) {
        throw "拒绝保存非主窗口截图：${width}×${height}。"
    }
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

function Select-NextGridPage {
    <# 点击矩阵底部分页器的 Next 按钮，走用户真实交互入口。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $handle = Prepare-Window -Process $Process
    $rect = New-Object AgentWorkspaceSessionInput+RECT
    if (-not [AgentWorkspaceSessionInput]::GetWindowRect($handle, [ref]$rect)) {
        throw '无法读取 Paneflow 主窗口坐标。'
    }
    $windowWidth = $rect.Right - $rect.Left
    # CLI 左栏固定约 248px；分页器位于剩余主区域中心，Next 中心在页码右侧约 55px。
    $x = $rect.Left + 248 + [Math]::Floor(($windowWidth - 248) / 2) + 55
    # Win32 窗口矩形包含约 8px 阴影和底部缩放命中区，按钮视觉中心在 Bottom-29px。
    $y = $rect.Bottom - 29
    [AgentWorkspaceSessionInput]::SetCursorPos($x, $y) | Out-Null
    [AgentWorkspaceSessionInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [AgentWorkspaceSessionInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Seconds 2
}

function Close-PaneflowAndCheck {
    <# 正常关闭窗口，并核对本轮完整进程树没有残留。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $tracked = @(Get-ProcessTreeIds -RootProcessId $Process.Id)
    $starts = @{}
    foreach ($id in $tracked) {
        $item = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -ne $item) { $starts[$id] = $item.StartTime.ToUniversalTime().Ticks }
    }
    [AgentWorkspaceSessionInput]::SetWindowPos($Process.MainWindowHandle, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
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

function Get-WorkspaceSurfaces {
    <# 返回按工作区索引排序的真实根终端元数据。 #>
    $list = Invoke-PaneflowRpc -Method 'surface.list' -Params @{}
    return @($list.surfaces | Where-Object { $_.scope -eq 'workspace' } | Sort-Object workspace)
}

function Get-WorkspaceList {
    <# 返回左侧工作区模型；其 title 才是持久化工作区名称。 #>
    $list = Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}
    return @($list.workspaces | Sort-Object index)
}

function Assert-SessionSnapshot {
    <# 校验会话快照的核心恢复契约，并返回解析结果。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ExpectedTitles,
        [Parameter(Mandatory = $true)][int]$ExpectedPage
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "会话文件不存在：$Path" }
    $session = Get-Content -Raw -Encoding utf8 -LiteralPath $Path | ConvertFrom-Json
    $titles = @($session.workspaces | ForEach-Object { [string]$_.title })
    $cwdMismatch = @($session.workspaces | Where-Object { [IO.Path]::GetFullPath([string]$_.cwd) -ne $repoRoot })
    if ([int]$session.version -ne 1) { throw "会话版本应为 1，实际为 $($session.version)。" }
    if ($session.workspaces.Count -ne $WorkspaceCount) { throw "会话工作区数量应为 $WorkspaceCount，实际为 $($session.workspaces.Count)。" }
    if (($titles -join "`n") -ne ($ExpectedTitles -join "`n")) { throw '会话工作区标题或顺序不一致。' }
    if ($cwdMismatch.Count -ne 0) { throw "存在 $($cwdMismatch.Count) 个工作目录未恢复到绑定目录。" }
    if ([int]$session.active_workspace -ne ($WorkspaceCount - 1)) { throw "活动工作区应为最后一项，实际为 $($session.active_workspace)。" }
    if ([int]$session.workspace_grid_page -ne $ExpectedPage) { throw "矩阵页码应为 $ExpectedPage，实际为 $($session.workspace_grid_page)。" }
    return $session
}

$firstProcess = $null
$secondProcess = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false
Initialize-WindowAutomation

try {
    Initialize-IsolatedState
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'

    $firstProcess = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady
    Prepare-Window -Process $firstProcess | Out-Null
    # 空白首启不再隐式创建终端；恢复基线中的每个工作区都显式绑定仓库目录。
    for ($index = 0; $index -lt $WorkspaceCount; $index++) {
        Invoke-PaneflowRpc -Method 'workspace.create' -Params @{
            name = 'restore-{0:D2}' -f ($index + 1)
            cwd = $repoRoot
        } | Out-Null
    }
    Start-Sleep -Seconds 5
    $beforeSurfaces = @(Get-WorkspaceSurfaces)
    if ($beforeSurfaces.Count -ne $WorkspaceCount) {
        throw "首次启动应有 $WorkspaceCount 个工作区终端，实际为 $($beforeSurfaces.Count)。"
    }
    # surface.title 是 PowerShell 自己的终端标题，不是左侧工作区标题；
    # 顺序基准使用本轮通过生产入口实际创建的确定名称。
    $expectedTitles = @(1..$WorkspaceCount | ForEach-Object { 'restore-{0:D2}' -f $_ })
    $firstWindowHandle = Prepare-Window -Process $firstProcess
    Save-WindowScreenshot -Handle $firstWindowHandle -Path $firstPagePath
    Select-NextGridPage -Process $firstProcess
    $firstWindowHandle = Prepare-Window -Process $firstProcess
    Save-WindowScreenshot -Handle $firstWindowHandle -Path $secondPagePath

    # 选择最后一个工作区，使活动项和第二页状态同时进入正常退出快照。
    Invoke-PaneflowRpc -Method 'surface.focus' -Params @{ surface_id = [uint64]$beforeSurfaces[-1].surface_id } | Out-Null
    Start-Sleep -Seconds 2
    $firstPowerShell = @(Get-PowerShellTreeRecords -RootProcessId $firstProcess.Id)
    if ($firstPowerShell.Count -ne $WorkspaceCount) {
        throw "首次启动应有 $WorkspaceCount 个 PowerShell 子进程，实际为 $($firstPowerShell.Count)。"
    }
    $firstClose = Close-PaneflowAndCheck -Process $firstProcess
    $firstProcess = $null
    if ($firstClose.Remaining.Count -ne 0) { throw '首次正常退出后仍有残留进程。' }
    Copy-Item -LiteralPath $actualSessionPath -Destination $savedSessionPath -Force
    $savedSession = Assert-SessionSnapshot -Path $savedSessionPath -ExpectedTitles $expectedTitles -ExpectedPage 1

    $secondProcess = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -WindowStyle Normal -PassThru
    Wait-PaneflowReady
    Prepare-Window -Process $secondProcess | Out-Null
    Start-Sleep -Seconds 5
    $afterSurfaces = @(Get-WorkspaceSurfaces)
    if ($afterSurfaces.Count -ne $WorkspaceCount) {
        throw "重启后应恢复 $WorkspaceCount 个工作区终端，实际为 $($afterSurfaces.Count)。"
    }
    $restoredWorkspaces = @(Get-WorkspaceList)
    $afterTitles = @($restoredWorkspaces | ForEach-Object { [string]$_.title })
    if (($afterTitles -join "`n") -ne ($expectedTitles -join "`n")) { throw '重启后的工作区标题或顺序不一致。' }
    $afterPowerShell = @(Get-PowerShellTreeRecords -RootProcessId $secondProcess.Id)
    if ($afterPowerShell.Count -ne $WorkspaceCount) {
        throw "重启后应有 $WorkspaceCount 个 PowerShell 子进程，实际为 $($afterPowerShell.Count)。"
    }
    $oldPidSet = [Collections.Generic.HashSet[int]]::new([int[]]@($firstPowerShell | ForEach-Object { $_.Pid }))
    $reusedPids = @($afterPowerShell | Where-Object { $oldPidSet.Contains([int]$_.Pid) })
    if ($reusedPids.Count -ne 0) { throw '重启后的 PowerShell PID 与首次启动发生重用，证据不足。' }
    $secondWindowHandle = Prepare-Window -Process $secondProcess
    Save-WindowScreenshot -Handle $secondWindowHandle -Path $restoredPagePath
    $secondClose = Close-PaneflowAndCheck -Process $secondProcess
    $secondProcess = $null
    if ($secondClose.Remaining.Count -ne 0) { throw '第二次正常退出后仍有残留进程。' }
    Copy-Item -LiteralPath $actualSessionPath -Destination $restoredSessionPath -Force
    $restoredSession = Assert-SessionSnapshot -Path $restoredSessionPath -ExpectedTitles $expectedTitles -ExpectedPage 1

    $result = [ordered]@{
        RunId = "真实重启-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        WorkspaceCount = $WorkspaceCount
        ExpectedTitles = $expectedTitles
        SavedActiveWorkspace = [int]$savedSession.active_workspace
        SavedWorkspaceGridPage = [int]$savedSession.workspace_grid_page
        RestoredActiveWorkspace = [int]$restoredSession.active_workspace
        RestoredWorkspaceGridPage = [int]$restoredSession.workspace_grid_page
        FirstPowerShellProcesses = $firstPowerShell
        RestoredPowerShellProcesses = $afterPowerShell
        PowerShellPidsFullyReplaced = $true
        FirstRemainingProcessIds = $firstClose.Remaining
        RestoredRemainingProcessIds = $secondClose.Remaining
        FirstPageScreenshot = $firstPagePath
        SecondPageScreenshot = $secondPagePath
        RestoredPageScreenshot = $restoredPagePath
        Passed = $true
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
    [pscustomobject]$result
}
finally {
    try {
        if ($null -ne $firstProcess -and $null -ne (Get-Process -Id $firstProcess.Id -ErrorAction SilentlyContinue)) {
            Close-PaneflowAndCheck -Process $firstProcess | Out-Null
        }
        if ($null -ne $secondProcess -and $null -ne (Get-Process -Id $secondProcess.Id -ErrorAction SilentlyContinue)) {
            Close-PaneflowAndCheck -Process $secondProcess | Out-Null
        }
    }
    finally {
        Restore-IsolatedState
    }
}
