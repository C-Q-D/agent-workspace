<#
.SYNOPSIS
运行 AgentWorkspace 第一版真实 Windows CLI 引用格式验收。

.DESCRIPTION
脚本隔离用户状态，在真实 Release 应用中通过鼠标选择 Common、Codex、Claude 和 Shell，
从真实文件树右键预填路径并选择连续代码行。随后读取真实 ConPTY 回显，确认文本完整、
没有自动提交，并重启应用验证每工作区选择持久化。全程不使用 mock 终端或伪造引用。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\CLI引用格式数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实引用-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$fixtureRoot = "F:\AWRef-$timestamp"
$fixtureFile = Join-Path $fixtureRoot '引用样例.rs'
$fixtureDirectory = Join-Path $fixtureRoot '资料目录'
$formatsScreenshot = Join-Path $runDirectory '四种路径格式.png'
$linesScreenshot = Join-Path $runDirectory 'Claude行范围.png'
$restoredScreenshot = Join-Path $runDirectory '重启恢复Claude格式.png'
$rightClickScreenshot = Join-Path $runDirectory '真实右键菜单.png'
$resultPath = Join-Path $runDirectory '运行结果.json'
$firstSessionPath = Join-Path $runDirectory '首次退出会话.json'
$restoredSessionPath = Join-Path $runDirectory '重启退出会话.json'
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
            # 冷启动阶段命名管道尚不存在属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Paneflow IPC 在 30 秒内未就绪。'
}

function Get-WorkspaceList {
    <# 返回按索引排序的工作区，包括引用格式持久化投影。 #>
    return @((Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}).workspaces | Sort-Object index)
}

function Get-WorkspaceSurfaceId {
    <# 返回指定工作区唯一真实终端的 Surface ID。 #>
    param([Parameter(Mandatory = $true)][int]$WorkspaceIndex)

    $surfaces = @((Invoke-PaneflowRpc -Method 'surface.list' -Params @{}).surfaces | Where-Object {
        $_.scope -eq 'workspace' -and [int]$_.workspace -eq $WorkspaceIndex
    })
    if ($surfaces.Count -ne 1) { throw "工作区 $WorkspaceIndex 应有一个真实终端，实际为 $($surfaces.Count)。" }
    return [uint64]$surfaces[0].surface_id
}

function Initialize-IsolatedState {
    <# 暂存用户状态并创建不启用遥测的干净配置。 #>
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
    <# 注册真实鼠标、Shift 选择、主窗口定位和截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceReferenceInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, UIntPtr w, IntPtr l);
}
'@
}

function Get-RealMainWindow {
    <# 恢复并返回至少 800×500 的 GPUI 产品主窗口句柄。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $Process.Refresh()
        $handle = $Process.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) { [AgentWorkspaceReferenceInput]::ShowWindow($handle, 9) | Out-Null }
        $rect = New-Object AgentWorkspaceReferenceInput+RECT
        if ($handle -ne [IntPtr]::Zero -and [AgentWorkspaceReferenceInput]::GetWindowRect($handle, [ref]$rect)) {
            if (($rect.Right - $rect.Left) -ge 800 -and ($rect.Bottom - $rect.Top) -ge 500) {
                [AgentWorkspaceReferenceInput]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
                [AgentWorkspaceReferenceInput]::SetForegroundWindow($handle) | Out-Null
                Start-Sleep -Milliseconds 750
                return $handle
            }
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow 真实主窗口在 15 秒内未达到最小尺寸。'
}

function Get-WindowRectValue {
    <# 返回已验证句柄的当前屏幕坐标。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    $rect = New-Object AgentWorkspaceReferenceInput+RECT
    if (-not [AgentWorkspaceReferenceInput]::GetWindowRect($Handle, [ref]$rect)) { throw '无法读取主窗口坐标。' }
    return $rect
}

function Invoke-MouseClick {
    <# 在真实应用窗口发送一次左键或右键点击。 #>
    param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y, [ValidateSet('Left', 'Right')][string]$Button = 'Left', [switch]$Shift)

    [AgentWorkspaceReferenceInput]::SetCursorPos($X, $Y) | Out-Null
    if ($Shift) { [AgentWorkspaceReferenceInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero) }
    if ($Button -eq 'Right') {
        # GPUI 在 Windows 上把右键注册为 aux-click；直接向真实窗口投递客户区消息，
        # 避免旧 mouse_event 在部分桌面会话中只移动光标却丢失右键消息。
        $point = New-Object AgentWorkspaceReferenceInput+POINT
        $point.X = $X
        $point.Y = $Y
        if (-not [AgentWorkspaceReferenceInput]::ScreenToClient($script:activeHandle, [ref]$point)) {
            throw '无法把右键坐标转换为窗口客户区坐标。'
        }
        $lParam = [IntPtr](($point.Y -shl 16) -bor ($point.X -band 0xFFFF))
        [AgentWorkspaceReferenceInput]::PostMessage($script:activeHandle, 0x0204, [UIntPtr]2, $lParam) | Out-Null
        [AgentWorkspaceReferenceInput]::PostMessage($script:activeHandle, 0x0205, [UIntPtr]0, $lParam) | Out-Null
    }
    else {
        [AgentWorkspaceReferenceInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [AgentWorkspaceReferenceInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
    if ($Shift) { [AgentWorkspaceReferenceInput]::keybd_event(0x10, 0, 0x0002, [UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 350
}

function Get-ReferenceLayoutPoints {
    <# 按第一版固定三栏和 300px 文件栏计算验收点击点。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle)

    $rect = Get-WindowRectValue -Handle $Handle
    $sidebarLeft = $rect.Right - 300
    $selectorInner = 284
    $buttonWidth = ($selectorInner - 9) / 4
    $selectorCenters = @(for ($index = 0; $index -lt 4; $index++) {
        [int]($sidebarLeft + 8 + ($buttonWidth + 3) * $index + $buttonWidth / 2)
    })
    return [pscustomobject]@{
        Handle = $Handle
        WorkspaceX = $rect.Left + 100
        FixtureWorkspaceY = $rect.Top + 165
        SelectorY = $rect.Top + 89
        SelectorX = $selectorCenters
        FileX = $sidebarLeft + 150
        FileY = $rect.Top + 150
        # 文件行的右键点靠近窗口右缘，220px 菜单会向左翻转；菜单条目必须点击翻转后的中心。
        MenuX = $sidebarLeft + 40
        Line1Y = $rect.Top + 116
        ActionY = $rect.Bottom - 20
        Right = $rect.Right
        Bottom = $rect.Bottom
    }
}

function Add-PathReferenceByUi {
    <# 选择一个 CLI 策略，并从真实文件行的右键菜单预填路径。 #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Points, [Parameter(Mandatory = $true)][ValidateRange(0, 3)][int]$FormatIndex)

    Invoke-MouseClick -X $Points.SelectorX[$FormatIndex] -Y $Points.SelectorY
    Invoke-MouseClick -X $Points.FileX -Y $Points.FileY -Button Right
    if (-not $script:rightClickDebugCaptured) {
        Start-Sleep -Milliseconds 500
        Save-WindowScreenshot -Handle $Points.Handle -Path $rightClickScreenshot
        $script:rightClickDebugCaptured = $true
    }
    Invoke-MouseClick -X $Points.MenuX -Y ($Points.FileY + 18)
}

function Add-LineReferenceByUi {
    <# 使用真实右键菜单进入行选择器，再以普通点击和 Shift 点击选择第 2～4 行。 #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Points)

    # Claude 按钮索引为 2；切换发生在当前工作区并立即持久化。
    Invoke-MouseClick -X $Points.SelectorX[2] -Y $Points.SelectorY
    Invoke-MouseClick -X $Points.FileX -Y $Points.FileY -Button Right
    Invoke-MouseClick -X $Points.MenuX -Y ($Points.FileY + 46)
    Invoke-MouseClick -X $Points.FileX -Y ($Points.Line1Y + 24)
    Invoke-MouseClick -X $Points.FileX -Y ($Points.Line1Y + 72) -Shift
    Invoke-MouseClick -X $Points.FileX -Y $Points.ActionY
}

function Save-WindowScreenshot {
    <# 使用已验证的产品主窗口句柄保存截图。 #>
    param([Parameter(Mandatory = $true)][IntPtr]$Handle, [Parameter(Mandatory = $true)][string]$Path)

    $rect = Get-WindowRectValue -Handle $Handle
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

$firstProcess = $null
$restoredProcess = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false
$script:activeHandle = [IntPtr]::Zero
$script:rightClickDebugCaptured = $false
Initialize-WindowAutomation

try {
    Initialize-IsolatedState
    New-Item -ItemType Directory -Force -Path $fixtureRoot, $fixtureDirectory | Out-Null
    @('// 第一行', 'fn target() {', '    println!("reference");', '}', '// 第五行') | Set-Content -LiteralPath $fixtureFile -Encoding utf8

    $firstProcess = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -PassThru
    Wait-PaneflowReady
    $firstHandle = Get-RealMainWindow -Process $firstProcess
    $script:activeHandle = $firstHandle
    # 保留两个工作区的原验收拓扑，但两者都通过显式目录入口创建。
    Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = '基线工作区'; cwd = $repoRoot } | Out-Null
    $create = Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = '引用验收'; cwd = $fixtureRoot }
    if ([int]$create.index -ne 1) { throw "引用工作区索引应为 1，实际为 $($create.index)。" }
    Start-Sleep -Seconds 2

    # 左栏第二张卡片在无放大状态下应直接放大目标并自动打开其文件面板。
    $points = Get-ReferenceLayoutPoints -Handle $firstHandle
    Invoke-MouseClick -X $points.WorkspaceX -Y $points.FixtureWorkspaceY
    Start-Sleep -Seconds 2
    $points = Get-ReferenceLayoutPoints -Handle $firstHandle

    for ($formatIndex = 0; $formatIndex -lt 4; $formatIndex++) {
        Add-PathReferenceByUi -Points $points -FormatIndex $formatIndex
    }
    Start-Sleep -Milliseconds 750
    Save-WindowScreenshot -Handle $firstHandle -Path $formatsScreenshot

    Add-LineReferenceByUi -Points $points
    Start-Sleep -Milliseconds 750
    Save-WindowScreenshot -Handle $firstHandle -Path $linesScreenshot

    $surfaceId = Get-WorkspaceSurfaceId -WorkspaceIndex 1
    $read = Invoke-PaneflowRpc -Method 'surface.read' -Params @{ surface_id = $surfaceId; lines = 200; fenced = $false }
    $rawText = [string]$read.text
    $flatText = $rawText -replace "`r|`n", ''
    $commonToken = 'f:引用样例.rs'
    $claudeToken = '@引用样例.rs'
    $shellToken = "'$fixtureFile'"
    $lineToken = '@引用样例.rs#L2-L4'
    $commonCount = [regex]::Matches($flatText, [regex]::Escape($commonToken)).Count
    $checks = [ordered]@{
        CommonAndCodexBothPresent = $commonCount -ge 2
        ClaudePresent = $flatText.Contains($claudeToken)
        PowerShellPresent = $flatText.Contains($shellToken)
        ClaudeLineRangePresent = $flatText.Contains($lineToken)
    }
    if (@($checks.Values | Where-Object { -not $_ }).Count -ne 0) {
        throw "真实终端未完整回显全部引用：$($checks | ConvertTo-Json -Compress)。"
    }
    $promptPattern = [regex]::Escape("PS $fixtureRoot>")
    $promptCount = [regex]::Matches($flatText, $promptPattern).Count
    if ($promptCount -ne 1) { throw "引用可能被自动提交：工作区提示符应出现 1 次，实际为 $promptCount 次。" }

    $beforeRestart = @(Get-WorkspaceList)
    if ([string]$beforeRestart[0].reference_format -ne 'common' -or [string]$beforeRestart[1].reference_format -ne 'claude') {
        throw "引用格式没有按工作区隔离：$($beforeRestart | ConvertTo-Json -Compress)。"
    }

    $firstClose = Close-PaneflowAndCheck -Process $firstProcess
    $firstProcess = $null
    if ($firstClose.Remaining.Count -ne 0) { throw "首次关闭仍有残留进程：$($firstClose.Remaining -join ',')。" }
    Copy-Item -LiteralPath $actualSessionPath -Destination $firstSessionPath

    $restoredProcess = Start-Process -FilePath $binary -WorkingDirectory $repoRoot -PassThru
    Wait-PaneflowReady
    $restoredHandle = Get-RealMainWindow -Process $restoredProcess
    $script:activeHandle = $restoredHandle
    $afterRestart = @(Get-WorkspaceList)
    if ([string]$afterRestart[0].reference_format -ne 'common' -or [string]$afterRestart[1].reference_format -ne 'claude') {
        throw "重启后引用格式没有恢复：$($afterRestart | ConvertTo-Json -Compress)。"
    }
    $restoredPoints = Get-ReferenceLayoutPoints -Handle $restoredHandle
    Invoke-MouseClick -X $restoredPoints.WorkspaceX -Y $restoredPoints.FixtureWorkspaceY
    Start-Sleep -Seconds 2
    Save-WindowScreenshot -Handle $restoredHandle -Path $restoredScreenshot

    $restoredClose = Close-PaneflowAndCheck -Process $restoredProcess
    $restoredProcess = $null
    if ($restoredClose.Remaining.Count -ne 0) { throw "重启关闭仍有残留进程：$($restoredClose.Remaining -join ',')。" }
    Copy-Item -LiteralPath $actualSessionPath -Destination $restoredSessionPath

    $result = [ordered]@{
        RunId = "真实引用-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        FixtureRoot = $fixtureRoot
        WorkspaceFormatsBeforeRestart = @($beforeRestart | ForEach-Object { $_.reference_format })
        WorkspaceFormatsAfterRestart = @($afterRestart | ForEach-Object { $_.reference_format })
        SurfaceId = $surfaceId
        InsertedTokens = @($commonToken, $commonToken, $claudeToken, $shellToken, $lineToken)
        EchoChecks = $checks
        PromptCount = $promptCount
        Submit = $false
        FirstTrackedProcessIds = $firstClose.Tracked
        FirstRemainingProcessIds = $firstClose.Remaining
        RestoredTrackedProcessIds = $restoredClose.Tracked
        RestoredRemainingProcessIds = $restoredClose.Remaining
        Screenshots = @($rightClickScreenshot, $formatsScreenshot, $linesScreenshot, $restoredScreenshot)
        Passed = $true
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
    [pscustomobject]$result
}
finally {
    foreach ($process in @($firstProcess, $restoredProcess)) {
        if ($null -ne $process -and -not $process.HasExited) {
            try {
                $tree = @(Get-ProcessTreeIds -RootProcessId $process.Id)
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                foreach ($id in @($tree | Sort-Object -Descending)) {
                    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
    }
    Restore-IsolatedState
    if ($fixtureRoot.StartsWith('F:\AWRef-', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fixtureRoot)) {
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
                break
            }
            catch {
                if ($attempt -eq 29) { Write-Warning "验收夹具目录稍后需要人工删除：$fixtureRoot；$($_.Exception.Message)" }
                Start-Sleep -Milliseconds 200
            }
        }
    }
}
