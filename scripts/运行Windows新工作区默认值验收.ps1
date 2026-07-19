<#
.SYNOPSIS
运行新工作区默认引用格式与 Git 自动初始化的真实 Windows Release 验收。

.DESCRIPTION
脚本使用隔离 USERPROFILE、唯一命名管道、真实 AgentWorkspace GUI、PowerShell/ConPTY、
生产 JSON-RPC 与真实 CLI。它不会读取开发者现有会话，也不使用 mock 终端或伪造 Git。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\新工作区默认值数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunId = "Release-$Timestamp"
$EvidenceDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $RunId
$VolumeRoot = [IO.Path]::GetPathRoot($RepositoryRoot)
$FixtureRoot = Join-Path $VolumeRoot "AWWorkspaceDefaults-$RunId"
$IsolatedUser = Join-Path $FixtureRoot '隔离用户'
$DataRoot = Join-Path $IsolatedUser '.agent-workspace'
$ConfigPath = Join-Path $DataRoot 'config\settings.json'
$SessionPath = Join-Path $DataRoot 'sessions\workspaces.json'
$PipeName = "agent-workspace-defaults-$Timestamp"
$PipePath = "\\.\pipe\$PipeName"
$ResultPath = Join-Path $EvidenceDirectory '运行结果.json'

$Roots = [ordered]@{
    RpcNoGit = Join-Path $FixtureRoot '01-RPC非Git'
    UpNoGit = Join-Path $FixtureRoot '02-UP非Git'
    CliNoGit = Join-Path $FixtureRoot '03-CLI非Git'
    ExistingGit = Join-Path $FixtureRoot '04-已有Git'
    CodexGit = Join-Path $FixtureRoot '05-Codex自动Git'
    PowerShellGit = Join-Path $FixtureRoot '06-PowerShell自动Git'
    CommonGit = Join-Path $FixtureRoot '07-Common自动Git'
}

if (Test-Path -LiteralPath $EvidenceDirectory) { throw "证据目录必须全新：$EvidenceDirectory" }
if (Test-Path -LiteralPath $FixtureRoot) { throw "夹具目录必须全新：$FixtureRoot" }
if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
    throw '开始验收前存在 AgentWorkspace 进程，无法可靠判断进程残留。'
}

New-Item -ItemType Directory -Force -Path @(
    $EvidenceDirectory,
    $IsolatedUser,
    (Split-Path $ConfigPath -Parent)
) | Out-Null
foreach ($Root in $Roots.Values) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $Root '项目文件.txt'),
        "真实工作区默认值验收：$([IO.Path]::GetFileName($Root))`n",
        [Text.UTF8Encoding]::new($false)
    )
}
& git -C $Roots.ExistingGit init --quiet
if ($LASTEXITCODE -ne 0) { throw '无法创建真实已有 Git 仓库夹具。' }

function Write-IsolatedSettings {
    <# 写入一份合法设置；保留未知字段用来验证读写不会丢失未来配置。 #>
    param(
        [Parameter(Mandatory = $true)][string]$ReferenceFormat,
        [Parameter(Mandatory = $true)][bool]$GitAutoInit
    )

    $Settings = [ordered]@{
        telemetry = [ordered]@{ enabled = $false }
        default_reference_format = $ReferenceFormat
        git_auto_init = $GitAutoInit
        future_setting = [ordered]@{ preserved = $true }
    }
    $Json = ($Settings | ConvertTo-Json -Depth 6) + "`n"
    [IO.File]::WriteAllText($ConfigPath, $Json, [Text.UTF8Encoding]::new($false))
}

function Invoke-AgentWorkspaceRpc {
    <# 每次建立一个生产命名管道连接并执行真实 JSON-RPC。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params = @{}
    )

    $Pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $Pipe.Connect(5000)
        $Utf8 = [Text.UTF8Encoding]::new($false)
        $Writer = [IO.StreamWriter]::new($Pipe, $Utf8, 1024, $true)
        $Reader = [IO.StreamReader]::new($Pipe, $Utf8, $false, 1024, $true)
        $Writer.AutoFlush = $true
        $Writer.WriteLine(([ordered]@{
            jsonrpc = '2.0'
            method = $Method
            params = $Params
            id = 1
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
    finally {
        $Pipe.Dispose()
    }
}

function Wait-AgentWorkspaceReady {
    <# 有界等待真实 GUI 完成 IPC 和主窗口初始化。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    for ($Attempt = 0; $Attempt -lt 80; $Attempt++) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) { throw "GUI 提前退出，退出码 $($Process.ExitCode)。" }
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero -and
                (Invoke-AgentWorkspaceRpc -Method 'system.ping').pong) {
                return
            }
        }
        catch {
            if ($Process.HasExited) { throw }
            # 冷启动期间主窗口或命名管道尚未出现属于预期状态。
        }
        Start-Sleep -Milliseconds 250
    }
    throw '真实 AgentWorkspace 在 20 秒内未就绪。'
}

function Start-TestApp {
    <# 启动真实桌面应用，并把本阶段标准输出与错误写入证据目录。 #>
    param([Parameter(Mandatory = $true)][string]$Phase)

    $Process = Start-Process `
        -FilePath $Binary `
        -WorkingDirectory $RepositoryRoot `
        -WindowStyle Normal `
        -RedirectStandardOutput (Join-Path $EvidenceDirectory "$Phase-标准输出.txt") `
        -RedirectStandardError (Join-Path $EvidenceDirectory "$Phase-错误输出.txt") `
        -PassThru
    Wait-AgentWorkspaceReady -Process $Process
    return $Process
}

function Get-Workspaces {
    <# 返回按索引排序的生产工作区投影。 #>
    return @((Invoke-AgentWorkspaceRpc -Method 'workspace.list').workspaces | Sort-Object index)
}

function Wait-WorkspaceCount {
    <# 有界等待异步 PTY 创建完成并达到预期工作区数量。 #>
    param([Parameter(Mandatory = $true)][int]$Expected)

    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $List = @(Get-Workspaces)
        if ($List.Count -eq $Expected) { return $List }
        Start-Sleep -Milliseconds 100
    }
    throw "工作区数量未达到 $Expected。"
}

function Wait-GitDirectory {
    <# 有界等待共享 Git lifecycle 为允许初始化的目录创建真实仓库。 #>
    param([Parameter(Mandatory = $true)][string]$Root)

    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        if (Test-Path -LiteralPath (Join-Path $Root '.git')) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "10 秒内没有初始化真实 Git 仓库：$Root"
}

function Assert-WorkspaceFormat {
    <# 按标题验证工作区持久化引用格式。 #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Workspaces,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $Match = @($Workspaces | Where-Object { $_.title -eq $Title })
    if ($Match.Count -ne 1) { throw "工作区标题 $Title 应唯一，实际 $($Match.Count)。" }
    if ([string]$Match[0].reference_format -ne $Expected) {
        throw "$Title 引用格式应为 $Expected，实际为 $($Match[0].reference_format)。"
    }
}

function Get-ProcessTree {
    <# 记录根进程及实时后代，并保存启动时间避免 PID 复用误判。 #>
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

function Measure-AppIdle {
    <# 采集两秒桌面进程 CPU 增量、工作集、线程与句柄数。 #>
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
    <# 正常关闭真实窗口，并要求已记录进程树完全退出；强杀不计为通过。 #>
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    $Tracked = @(Get-ProcessTree -RootProcessId $Process.Id)
    if (-not $Process.CloseMainWindow()) { throw '真实 GUI 没有接受正常关闭请求。' }
    if (-not $Process.WaitForExit(15000)) { throw '真实 GUI 正常关闭 15 秒后仍未退出。' }
    if ($Process.ExitCode -ne 0) { throw "真实 GUI 正常关闭退出码为 $($Process.ExitCode)。" }
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $Remaining = @(foreach ($Entry in $Tracked) {
            $Live = Get-Process -Id $Entry.id -ErrorAction SilentlyContinue
            if ($null -ne $Live -and
                $Live.StartTime.ToUniversalTime().Ticks -eq $Entry.startedUtcTicks) {
                $Entry
            }
        })
        if ($Remaining.Count -eq 0) { return $Tracked }
        Start-Sleep -Milliseconds 100
    }
    throw "正常关闭后仍有进程残留：$($Remaining | ConvertTo-Json -Compress)"
}

$PreviousEnvironment = [ordered]@{
    USERPROFILE = $env:USERPROFILE
    HOME = $env:HOME
    PANEFLOW_SOCKET_PATH = $env:PANEFLOW_SOCKET_PATH
    PANEFLOW_IPC_SCRIPTING = $env:PANEFLOW_IPC_SCRIPTING
    PANEFLOW_NO_TELEMETRY = $env:PANEFLOW_NO_TELEMETRY
}
$Process = $null
$Phase1List = @()
$Phase2Restored = @()
$Phase2Final = @()
$Phase1Tree = @()
$Phase2Tree = @()

try {
    $env:USERPROFILE = $IsolatedUser
    $env:HOME = $IsolatedUser
    $env:PANEFLOW_SOCKET_PATH = $PipePath
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $env:PANEFLOW_NO_TELEMETRY = '1'

    # 第一阶段：关闭自动初始化，并让三个生产创建入口消费 Claude 默认值。
    Write-IsolatedSettings -ReferenceFormat 'claude' -GitAutoInit $false
    $Process = Start-TestApp -Phase '01-Claude禁用Git'
    $ConfigTimestampBeforeCreate = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
    Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'RPC-Claude'
        cwd = $Roots.RpcNoGit
    } | Out-Null
    Invoke-AgentWorkspaceRpc -Method 'workspace.up' -Params @{
        name = 'UP-Claude'
        layout = 'even_h'
        panes = @(@{ cwd = $Roots.UpNoGit; focus = $true })
    } | Out-Null
    $CliOutput = @(& $Binary new --name 'CLI-Claude' --cwd $Roots.CliNoGit 2>&1 | ForEach-Object { "$_" })
    $CliExitCode = $LASTEXITCODE
    if ($CliExitCode -ne 0) { throw "真实 CLI new 失败：$($CliOutput -join ' ')" }
    Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'Existing-Claude'
        cwd = $Roots.ExistingGit
    } | Out-Null
    $Phase1List = @(Wait-WorkspaceCount -Expected 4)
    Start-Sleep -Seconds 4

    foreach ($Title in @('RPC-Claude', 'UP-Claude', 'CLI-Claude', 'Existing-Claude')) {
        Assert-WorkspaceFormat -Workspaces $Phase1List -Title $Title -Expected 'claude'
    }
    foreach ($Root in @($Roots.RpcNoGit, $Roots.UpNoGit, $Roots.CliNoGit)) {
        if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
            throw "关闭自动初始化后仍产生 .git：$Root"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Roots.ExistingGit '.git'))) {
        throw '关闭自动初始化错误影响了已有 Git 仓库。'
    }
    if ((Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc -ne $ConfigTimestampBeforeCreate) {
        throw '创建工作区期间应用意外改写了设置文件。'
    }
    $Phase1Performance = Measure-AppIdle -Process $Process
    $Phase1Tree = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null
    if (-not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) {
        throw '第一阶段正常退出后没有保存真实会话。'
    }
    Copy-Item -LiteralPath $SessionPath -Destination (Join-Path $EvidenceDirectory '01-Claude禁用Git-会话.json')

    # 第二阶段：把全局默认改为 Codex 并重新开启 Git；恢复值必须仍为 Claude。
    Write-IsolatedSettings -ReferenceFormat 'codex' -GitAutoInit $true
    $Process = Start-TestApp -Phase '02-恢复并启用Git'
    $Phase2Restored = @(Wait-WorkspaceCount -Expected 4)
    foreach ($Title in @('RPC-Claude', 'UP-Claude', 'CLI-Claude', 'Existing-Claude')) {
        Assert-WorkspaceFormat -Workspaces $Phase2Restored -Title $Title -Expected 'claude'
    }

    Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'RPC-Codex'
        cwd = $Roots.CodexGit
    } | Out-Null
    Wait-GitDirectory -Root $Roots.CodexGit
    $AfterCodex = @(Wait-WorkspaceCount -Expected 5)
    Assert-WorkspaceFormat -Workspaces $AfterCodex -Title 'RPC-Codex' -Expected 'codex'

    # 配置 watcher 必须让后续新工作区消费新默认，同时不得覆盖恢复工作区。
    Write-IsolatedSettings -ReferenceFormat 'powershell' -GitAutoInit $true
    Start-Sleep -Seconds 2
    Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'RPC-PowerShell'
        cwd = $Roots.PowerShellGit
    } | Out-Null
    Wait-GitDirectory -Root $Roots.PowerShellGit
    $AfterPowerShell = @(Wait-WorkspaceCount -Expected 6)
    Assert-WorkspaceFormat -Workspaces $AfterPowerShell -Title 'RPC-PowerShell' -Expected 'powershell'

    Write-IsolatedSettings -ReferenceFormat 'common' -GitAutoInit $true
    Start-Sleep -Seconds 2
    $LastConfigWrite = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
    Invoke-AgentWorkspaceRpc -Method 'workspace.create' -Params @{
        name = 'RPC-Common'
        cwd = $Roots.CommonGit
    } | Out-Null
    Wait-GitDirectory -Root $Roots.CommonGit
    $Phase2Final = @(Wait-WorkspaceCount -Expected 7)
    Assert-WorkspaceFormat -Workspaces $Phase2Final -Title 'RPC-Common' -Expected 'common'
    foreach ($Title in @('RPC-Claude', 'UP-Claude', 'CLI-Claude', 'Existing-Claude')) {
        Assert-WorkspaceFormat -Workspaces $Phase2Final -Title $Title -Expected 'claude'
    }
    Start-Sleep -Seconds 2
    if ((Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc -ne $LastConfigWrite) {
        throw '配置 watcher 或工作区创建出现高频/意外回写。'
    }
    $FinalConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if (-not $FinalConfig.future_setting.preserved) { throw '未知配置字段未被保留。' }

    $Phase2Performance = Measure-AppIdle -Process $Process
    $Phase2Tree = @(Stop-TestAppGracefully -Process $Process)
    $Process = $null
    Copy-Item -LiteralPath $SessionPath -Destination (Join-Path $EvidenceDirectory '02-最终会话.json')
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $EvidenceDirectory '02-最终设置.json')

    if (@(Get-Process -Name 'agent-workspace' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw '两阶段正常退出后仍存在 AgentWorkspace 进程。'
    }
    if ($Phase1Performance.cpuMillisecondsOverTwoSeconds -gt 1000 -or
        $Phase2Performance.cpuMillisecondsOverTwoSeconds -gt 1000) {
        throw '两秒空闲窗口内桌面进程 CPU 超过 1000 ms，疑似出现高频后台工作。'
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
        isolation = [ordered]@{
            userProfile = $IsolatedUser
            dataRoot = $DataRoot
            pipe = $PipePath
        }
        phase1 = [ordered]@{
            defaultReferenceFormat = 'claude'
            gitAutoInit = $false
            cliExitCode = $CliExitCode
            cliOutput = $CliOutput
            workspaces = $Phase1List
            nonGitRootsPreserved = $true
            existingGitPreserved = $true
            configTimestampUnchanged = $true
            performance = $Phase1Performance
            trackedProcesses = $Phase1Tree
        }
        phase2 = [ordered]@{
            restoredWorkspaceFormats = @($Phase2Restored | ForEach-Object { $_.reference_format })
            restoredValuesNotOverwritten = $true
            newFormats = [ordered]@{
                codex = 'codex'
                powershell = 'powershell'
                common = 'common'
            }
            autoInitializedRoots = @($Roots.CodexGit, $Roots.PowerShellGit, $Roots.CommonGit)
            unknownFieldPreserved = $true
            configTimestampStableAfterWrite = $true
            workspaces = $Phase2Final
            performance = $Phase2Performance
            trackedProcesses = $Phase2Tree
        }
        process = [ordered]@{
            gracefulExitBothRuns = $true
            residueCount = 0
        }
        result = 'passed'
    }
    [IO.File]::WriteAllText(
        $ResultPath,
        ($Result | ConvertTo-Json -Depth 14) + "`n",
        [Text.UTF8Encoding]::new($false)
    )

    # 成功时才删除仓库外夹具；完整会话、配置和机器结果已复制到证据目录。
    $ResolvedFixture = [IO.Path]::GetFullPath($FixtureRoot)
    $ExpectedPrefix = Join-Path $VolumeRoot 'AWWorkspaceDefaults-Release-'
    if (-not $ResolvedFixture.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理不符合固定前缀的目录：$ResolvedFixture"
    }
    Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force

    Write-Output 'Windows 新工作区默认值 Release 验收通过'
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
            # 失败时只清理本轮真实应用，现场目录保留用于根因分析；强杀不生成通过结果。
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
