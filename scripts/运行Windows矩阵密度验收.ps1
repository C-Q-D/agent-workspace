<#
.SYNOPSIS
运行工作区矩阵密度的真实 Windows Release 验收。

.DESCRIPTION
脚本在隔离 USERPROFILE 中启动真实 GUI 和 16 个 PowerShell/ConPTY 终端，运行中依次
切换 Auto、Comfortable、Compact。它通过生产 IPC 核对 Surface、PowerShell PID 和
终端输出连续性，保存真实窗口截图，并重启验证设置与会话持久化；不使用 mock 数据。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\矩阵密度数据'),

    [switch]$ScreenshotSmokeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = "Release-$Timestamp"
$EvidenceDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $RunId
$FixtureRoot = Join-Path ([IO.Path]::GetPathRoot($RepositoryRoot)) "AWGridDensity-$RunId"
$IsolatedUser = Join-Path $FixtureRoot '隔离用户'
$DataRoot = Join-Path $IsolatedUser '.agent-workspace'
$ConfigPath = Join-Path $DataRoot 'config\settings.json'
$SessionPath = Join-Path $DataRoot 'sessions\workspaces.json'
$PipeName = "agent-workspace-grid-density-$Timestamp"
$PipePath = "\\.\pipe\$PipeName"
$ResultPath = Join-Path $EvidenceDirectory '运行结果.json'

if (Test-Path -LiteralPath $EvidenceDirectory) { throw "证据目录必须全新：$EvidenceDirectory" }
if (Test-Path -LiteralPath $FixtureRoot) { throw "夹具目录必须全新：$FixtureRoot" }
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '开始验收前存在 AgentWorkspace 进程，无法可靠判断进程连续性。'
}
New-Item -ItemType Directory -Force -Path @(
    $EvidenceDirectory,
    $IsolatedUser,
    (Split-Path $ConfigPath -Parent)
) | Out-Null

function Write-DensitySettings {
    <# 写入合法密度设置；未知字段用于验证 watcher 不会破坏未来配置。 #>
    param([Parameter(Mandatory = $true)][ValidateSet('auto', 'comfortable', 'compact')][string]$Density)

    $Json = [ordered]@{
        telemetry = [ordered]@{ enabled = $false }
        workspace_grid_density = $Density
        git_auto_init = $false
        future_setting = [ordered]@{ preserved = $true }
    } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($ConfigPath, $Json + "`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-AgentWorkspaceRpc {
    <# 使用本轮唯一生产命名管道执行一次真实 JSON-RPC。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [object]$Params = @{})

    $Pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $Pipe.Connect(5000)
        $Utf8 = [Text.UTF8Encoding]::new($false)
        $Writer = [IO.StreamWriter]::new($Pipe, $Utf8, 1024, $true)
        $Reader = [IO.StreamReader]::new($Pipe, $Utf8, $false, 1024, $true)
        $Writer.AutoFlush = $true
        $Writer.WriteLine(([ordered]@{
            jsonrpc = '2.0'; method = $Method; params = $Params; id = 1
        } | ConvertTo-Json -Depth 12 -Compress))
        $Line = $Reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($Line)) { throw "$Method 返回空响应。" }
        $Response = $Line | ConvertFrom-Json
        if ($Response.PSObject.Properties.Name -contains 'error') {
            throw "$Method 失败：$($Response.error | ConvertTo-Json -Compress)"
        }
        if ($Response.PSObject.Properties.Name -notcontains 'result') {
            throw "$Method 响应缺少 result。"
        }
        return $Response.result
    }
    finally { $Pipe.Dispose() }
}

function Wait-AppReady {
    <# 有界等待真实主窗口和命名管道就绪。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    for ($Attempt = 0; $Attempt -lt 80; $Attempt++) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { throw "GUI 提前退出，退出码 $($Process.ExitCode)。" }
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero -and
                (Invoke-AgentWorkspaceRpc -Method 'system.ping').pong) { return }
        }
        catch {
            if ($Process.HasExited) { throw }
            # 冷启动期间主窗口或管道未出现属于预期状态。
        }
        Start-Sleep -Milliseconds 250
    }
    throw '真实 AgentWorkspace 在 20 秒内未就绪。'
}

function Start-TestApp {
    <# 启动真实桌面程序，并把日志保存在证据目录。 #>
    param([Parameter(Mandatory = $true)][string]$Phase)

    $Process = Start-Process `
        -FilePath $Binary `
        -WorkingDirectory $RepositoryRoot `
        -WindowStyle Normal `
        -RedirectStandardOutput (Join-Path $EvidenceDirectory "$Phase-标准输出.txt") `
        -RedirectStandardError (Join-Path $EvidenceDirectory "$Phase-错误输出.txt") `
        -PassThru
    Wait-AppReady -Process $Process
    return $Process
}

function Get-SurfaceSnapshot {
    <# 返回按 Surface ID 排序的 16 个真实工作区终端投影。 #>
    $Surfaces = @(
        (Invoke-AgentWorkspaceRpc -Method 'surface.list').surfaces |
            Where-Object { $_.scope -eq 'workspace' } |
            Sort-Object surface_id
    )
    return $Surfaces
}

function Wait-MatrixReady {
    <# 有界等待全部工作区、Surface 和 PowerShell 提示符完成创建。 #>
    for ($Attempt = 0; $Attempt -lt 160; $Attempt++) {
        $Workspaces = @((Invoke-AgentWorkspaceRpc -Method 'workspace.list').workspaces)
        $Surfaces = @(Get-SurfaceSnapshot)
        if ($Workspaces.Count -eq 16 -and $Surfaces.Count -eq 16) {
            $Ready = $true
            foreach ($Surface in $Surfaces) {
                $Read = Invoke-AgentWorkspaceRpc -Method 'surface.read' -Params @{
                    surface_id = [uint64]$Surface.surface_id
                    lines = 80
                    fenced = $false
                }
                $Text = [string]$Read.text
                if ($Text.Contains('cannot access the file') -or $Text.Contains('正由另一进程使用')) {
                    throw "Surface $($Surface.surface_id) 的 Shell 集成脚本出现共享冲突。"
                }
                if (-not ($Text.Contains('PS ') -and $Text.Contains('>'))) {
                    $Ready = $false
                    break
                }
            }
            if ($Ready) {
                return [pscustomobject]@{ Workspaces = $Workspaces; Surfaces = $Surfaces }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw '16 个真实工作区、Surface 和 PowerShell 提示符未在 16 秒内就绪。'
}

function Get-ProcessTree {
    <# 返回根进程与全部实时后代，保存启动时间以避免 PID 复用误判。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)

    $Children = @{}
    foreach ($Item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $ParentId = if ($null -eq $Item.Parent) { 0 } else { [int]$Item.Parent.Id } }
        catch { $ParentId = 0 }
        if (-not $Children.ContainsKey($ParentId)) {
            $Children[$ParentId] = [Collections.Generic.List[int]]::new()
        }
        $Children[$ParentId].Add([int]$Item.Id)
    }
    $Seen = [Collections.Generic.HashSet[int]]::new()
    $Queue = [Collections.Generic.Queue[int]]::new()
    $Queue.Enqueue($RootProcessId)
    while ($Queue.Count -gt 0) {
        $Current = $Queue.Dequeue()
        if (-not $Seen.Add($Current)) { continue }
        if ($Children.ContainsKey($Current)) {
            foreach ($Child in $Children[$Current]) { $Queue.Enqueue($Child) }
        }
    }
    return @($Seen | Sort-Object | ForEach-Object {
        $Live = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($null -ne $Live) {
            [ordered]@{
                id = [int]$Live.Id
                name = [string]$Live.ProcessName
                startedUtcTicks = $Live.StartTime.ToUniversalTime().Ticks
            }
        }
    })
}

function Get-PowerShellPidKey {
    <# 返回稳定排序的真实 PowerShell 后代 PID 文本，供切换前后精确比较。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Ids = @(
        Get-ProcessTree -RootProcessId $Process.Id |
            Where-Object { $_.name -in @('pwsh', 'powershell') } |
            ForEach-Object { [int]$_.id } |
            Sort-Object
    )
    if ($Ids.Count -ne 16) { throw "应有 16 个 PowerShell 后代，实际为 $($Ids.Count)。" }
    return ($Ids -join ',')
}

function Assert-SurfaceIdentity {
    <# 密度切换不得替换任何终端 Surface。 #>
    param([Parameter(Mandatory = $true)][string]$Expected)

    $Actual = (@(Get-SurfaceSnapshot | ForEach-Object { [uint64]$_.surface_id }) -join ',')
    if ($Actual -ne $Expected) { throw "密度切换改变了 Surface ID：$Actual" }
}

function Assert-TerminalMarkers {
    <# 从每个真实 ConPTY 回读已提交标记，证明终端输出在重排后仍可访问。 #>
    param([Parameter(Mandatory = $true)][object[]]$Surfaces)

    foreach ($Surface in $Surfaces) {
        $Index = [int]$Surface.workspace + 1
        $Marker = 'GRID-DENSITY-{0:D2}' -f $Index
        $Read = Invoke-AgentWorkspaceRpc -Method 'surface.read' -Params @{
            surface_id = [uint64]$Surface.surface_id
            lines = 80
            fenced = $false
        }
        if (-not ([string]$Read.text).Contains($Marker)) {
            throw "Surface $($Surface.surface_id) 缺少连续性标记 $Marker。"
        }
    }
}

function Wait-TerminalMarkers {
    <# 有界等待全部命令真实执行，避免用固定休眠掩盖慢启动或丢输入。 #>
    param([Parameter(Mandatory = $true)][object[]]$Surfaces)

    $LastError = $null
    for ($Attempt = 0; $Attempt -lt 200; $Attempt++) {
        try {
            Assert-TerminalMarkers -Surfaces $Surfaces
            return
        }
        catch {
            $LastError = $_
            Start-Sleep -Milliseconds 100
        }
    }
    throw "16 个终端标记未在 20 秒内全部回显：$($LastError.Exception.Message)"
}

function Measure-AppIdle {
    <# 采集两秒桌面进程 CPU、内存、线程和句柄。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Process.Refresh()
    $CpuBefore = $Process.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 2
    $Process.Refresh()
    return [ordered]@{
        cpuMillisecondsOverTwoSeconds = [math]::Round(
            $Process.TotalProcessorTime.TotalMilliseconds - $CpuBefore,
            3
        )
        workingSetMiB = [math]::Round($Process.WorkingSet64 / 1MB, 3)
        privateMemoryMiB = [math]::Round($Process.PrivateMemorySize64 / 1MB, 3)
        threads = $Process.Threads.Count
        handles = $Process.HandleCount
    }
}

function Stop-TestAppGracefully {
    <# 正常关闭窗口，并要求已记录的全部后代归零；强杀不计为通过。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Tracked = @(Get-ProcessTree -RootProcessId $Process.Id)
    if (-not $Process.CloseMainWindow()) { throw '真实 GUI 没有接受正常关闭请求。' }
    if (-not $Process.WaitForExit(15000)) { throw '真实 GUI 正常关闭 15 秒后仍未退出。' }
    if ($Process.ExitCode -ne 0) { throw "真实 GUI 退出码为 $($Process.ExitCode)。" }
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $Remaining = @(foreach ($Entry in $Tracked) {
            $Live = Get-Process -Id $Entry.id -ErrorAction SilentlyContinue
            if ($null -ne $Live -and
                $Live.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) { $Entry }
        })
        if ($Remaining.Count -eq 0) { return $Tracked }
        Start-Sleep -Milliseconds 100
    }
    throw "正常关闭后仍有进程残留：$($Remaining | ConvertTo-Json -Compress)"
}

function Initialize-ScreenshotApi {
    <# 注册固定窗口尺寸与真实桌面截图所需的最小 Win32 API。 #>
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgentWorkspaceGridCapture {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@
}

function Save-DensityScreenshot {
    <# 把真实产品窗口固定为 1400×820 后保存指定密度截图。 #>
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $Process.Refresh()
    $Handle = $Process.MainWindowHandle
    if ($Handle -eq [IntPtr]::Zero) { throw '无法取得真实产品主窗口。' }
    # 仅改变窗口尺寸，不移动、不改变 Z 序、不激活，避免干扰用户正在使用的软件。
    if (-not [AgentWorkspaceGridCapture]::SetWindowPos(
        $Handle, [IntPtr]::Zero, 0, 0, 1400, 820, 0x0016
    )) { throw '无法设置真实产品窗口的验收尺寸。' }
    Start-Sleep -Milliseconds 750
    $Rect = New-Object AgentWorkspaceGridCapture+RECT
    if (-not [AgentWorkspaceGridCapture]::GetWindowRect($Handle, [ref]$Rect)) { throw '无法读取窗口矩形。' }
    $Width = $Rect.Right - $Rect.Left
    $Height = $Rect.Bottom - $Rect.Top
    if ($Width -lt 1300 -or $Height -lt 750) { throw "窗口尺寸异常：${Width}×${Height}" }
    $Bitmap = [Drawing.Bitmap]::new($Width, $Height)
    $Graphics = [Drawing.Graphics]::FromImage($Bitmap)
    try {
        # PrintWindow 直接请求目标窗口离屏绘制，不依赖窗口是否被其他软件遮挡。
        $DeviceContext = $Graphics.GetHdc()
        try {
            if (-not [AgentWorkspaceGridCapture]::PrintWindow($Handle, $DeviceContext, 2)) {
                $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "目标窗口离屏绘制失败，Win32 错误码：$ErrorCode"
            }
        }
        finally { $Graphics.ReleaseHdc($DeviceContext) }
        $Bitmap.Save((Join-Path $EvidenceDirectory "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Graphics.Dispose()
        $Bitmap.Dispose()
    }
}

$PreviousEnvironment = [ordered]@{
    USERPROFILE = $env:USERPROFILE
    HOME = $env:HOME
    PANEFLOW_SOCKET_PATH = $env:PANEFLOW_SOCKET_PATH
    PANEFLOW_IPC_SCRIPTING = $env:PANEFLOW_IPC_SCRIPTING
    PANEFLOW_NO_TELEMETRY = $env:PANEFLOW_NO_TELEMETRY
}
$Process = $null
$FirstTree = @()
$RestoredTree = @()
Initialize-ScreenshotApi

try {
    $env:USERPROFILE = $IsolatedUser
    $env:HOME = $IsolatedUser
    $env:PANEFLOW_SOCKET_PATH = $PipePath
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $env:PANEFLOW_NO_TELEMETRY = '1'

    Write-DensitySettings -Density 'auto'
    $Process = Start-TestApp -Phase '01-密度切换'
    for ($Index = 1; $Index -le 16; $Index++) {
        Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
            name = 'Density-{0:D2}' -f $Index
            cwd = $RepositoryRoot
        } | Out-Null
    }
    $Initial = Wait-MatrixReady
    $SurfaceKey = (@($Initial.Surfaces | ForEach-Object { [uint64]$_.surface_id }) -join ',')
    $PowerShellPidKey = Get-PowerShellPidKey -Process $Process

    foreach ($Surface in $Initial.Surfaces) {
        $Index = [int]$Surface.workspace + 1
        $Marker = 'GRID-DENSITY-{0:D2}' -f $Index
        Invoke-AgentWorkspaceRpc -Method 'surface.send_text' -Params @{
            surface_id = [uint64]$Surface.surface_id
            text = "Write-Output '$Marker'"
            submit = $true
            paste = $false
        } | Out-Null
    }
    Wait-TerminalMarkers -Surfaces $Initial.Surfaces
    Save-DensityScreenshot -Process $Process -Name '01-Auto-16终端'
    if ($ScreenshotSmokeOnly) {
        Stop-TestAppGracefully -Process $Process | Out-Null
        $Process = $null
        $ResolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
        $ExpectedPrefix = Join-Path ([IO.Path]::GetPathRoot($RepositoryRoot)) 'AWGridDensity-Release-'
        if (-not $ResolvedFixture.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝清理不符合固定前缀的目录：$ResolvedFixture"
        }
        Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
        Write-Output "离屏截图试运行完成：$(Join-Path $EvidenceDirectory '01-Auto-16终端.png')"
        return
    }

    $Stages = @()
    foreach ($Density in @('comfortable', 'compact', 'auto')) {
        Write-DensitySettings -Density $Density
        Start-Sleep -Seconds 2
        Assert-SurfaceIdentity -Expected $SurfaceKey
        $CurrentPidKey = Get-PowerShellPidKey -Process $Process
        if ($CurrentPidKey -ne $PowerShellPidKey) { throw "$Density 切换改变了 PowerShell PID。" }
        Assert-TerminalMarkers -Surfaces $Initial.Surfaces
        Save-DensityScreenshot -Process $Process -Name ("02-{0}-16终端" -f $Density)
        $Stages += [ordered]@{
            density = $Density
            surfaceIdsUnchanged = $true
            powershellPidsUnchanged = $true
            terminalOutputContinuous = $true
        }
    }

    # 以 Compact 作为最终持久化值，正常退出并重启验证配置与会话恢复。
    Write-DensitySettings -Density 'compact'
    Start-Sleep -Seconds 2
    $LastConfigWrite = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
    $FirstPerformance = Measure-AppIdle -Process $Process
    if ((Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc -ne $LastConfigWrite) {
        throw '密度设置出现高频或意外回写。'
    }
    $FirstTree = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null
    if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) { throw '没有保存真实工作区会话。' }
    Copy-Item -LiteralPath $SessionPath -Destination (Join-Path $EvidenceDirectory '01-退出会话.json')

    $Process = Start-TestApp -Phase '02-Compact重启恢复'
    $Restored = Wait-MatrixReady
    $RestoredConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if ($RestoredConfig.workspace_grid_density -ne 'compact' -or
        -not $RestoredConfig.future_setting.preserved) {
        throw '重启后密度或未知配置字段不一致。'
    }
    Save-DensityScreenshot -Process $Process -Name '03-Compact-重启恢复'
    $RestoredPerformance = Measure-AppIdle -Process $Process
    $RestoredPowerShellCount = @(
        (Get-ProcessTree -RootProcessId $Process.Id) |
            Where-Object { $_.name -in @('pwsh', 'powershell') }
    ).Count
    if ($RestoredPowerShellCount -ne 16) { throw "重启恢复后 PowerShell 数量为 $RestoredPowerShellCount。" }
    $RestoredTree = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null

    if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw '两次正常退出后仍有 AgentWorkspace 进程。'
    }
    if ($FirstPerformance.cpuMillisecondsOverTwoSeconds -gt 1200 -or
        $RestoredPerformance.cpuMillisecondsOverTwoSeconds -gt 1200) {
        throw '16 终端两秒 CPU 增量超过 1200 ms，疑似新增高频后台工作。'
    }

    $Result = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        executedAt = (Get-Date).ToString('o')
        baseCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
        binary = [ordered]@{
            path = $Binary
            length = (Get-Item -LiteralPath $Binary).Length
            sha256 = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
            version = (& $Binary --version 2>&1 | Out-String).Trim()
        }
        matrix = [ordered]@{
            workspaces = 16
            surfaces = 16
            powershellProcesses = 16
            initialSurfaceIds = @($Initial.Surfaces | ForEach-Object { [uint64]$_.surface_id })
            stages = $Stages
            compactPersistedAcrossRestart = $true
            restoredWorkspaces = $Restored.Workspaces.Count
            restoredSurfaces = $Restored.Surfaces.Count
            restoredPowerShellProcesses = $RestoredPowerShellCount
        }
        performance = [ordered]@{
            beforeRestart = $FirstPerformance
            afterRestart = $RestoredPerformance
        }
        configuration = [ordered]@{
            unknownFieldPreserved = $true
            timestampStableAfterWrite = $true
            finalDensity = 'compact'
        }
        process = [ordered]@{
            firstTracked = $FirstTree
            restoredTracked = $RestoredTree
            gracefulExitBothRuns = $true
            residueCount = 0
        }
        screenshots = @(
            '01-Auto-16终端.png',
            '02-comfortable-16终端.png',
            '02-compact-16终端.png',
            '02-auto-16终端.png',
            '03-Compact-重启恢复.png'
        )
        result = 'passed'
    }
    [IO.File]::WriteAllText(
        $ResultPath,
        ($Result | ConvertTo-Json -Depth 14) + "`n",
        [Text.UTF8Encoding]::new($false)
    )

    $ResolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
    $ExpectedPrefix = Join-Path ([IO.Path]::GetPathRoot($RepositoryRoot)) 'AWGridDensity-Release-'
    if (-not $ResolvedFixture.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理不符合固定前缀的目录：$ResolvedFixture"
    }
    Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
    Write-Output 'Windows 矩阵密度 Release 验收通过'
    Write-Output "证据：$ResultPath"
}
finally {
    foreach ($Name in $PreviousEnvironment.Keys) {
        $Value = $PreviousEnvironment[$Name]
        if ($null -eq $Value) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$Name" $Value }
    }
    if ($null -ne $Process) {
        $Live = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        if ($null -ne $Live) {
            # 失败时只终止本轮应用，证据与夹具保留用于根因分析；强杀不生成通过结果。
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
