<#
.SYNOPSIS
运行 AgentWorkspace 工作区恢复生命周期的真实 Windows 验收。

.DESCRIPTION
脚本隔离用户配置和会话，写入一份包含已有 Git、非 Git 与失效目录的真实会话，
再使用 Release 桌面程序、命名管道、PowerShell/ConPTY 和本机 Git 执行两次启动。
验证失效条目被单独跳过、稳定根目录不漂移、非 Git 目录自动初始化、活动窗口正确
映射、第二次重启保持一致，以及两轮关闭后完整进程树零残留。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\docs\验收\工作区恢复生命周期数据')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "真实恢复-$timestamp"
$stateDirectory = Join-Path $runDirectory '状态备份'
$fixtureRoot = "F:\AWRestoreLifecycle-$timestamp"
$existingGitRoot = Join-Path $fixtureRoot '已有Git'
$nonGitRoot = Join-Path $fixtureRoot '非Git'
$missingRoot = Join-Path $fixtureRoot '已失效'
$launchRoot = Join-Path $fixtureRoot '启动目录'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'paneflow\paneflow.json'
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'paneflow\session.json'
$configBackupPath = Join-Path $stateDirectory '用户配置.json'
$sessionBackupPath = Join-Path $stateDirectory '用户会话.json'
$inputSessionPath = Join-Path $runDirectory '混合恢复输入会话.json'
$firstListPath = Join-Path $runDirectory '首次恢复工作区.json'
$savedSessionPath = Join-Path $runDirectory '首次退出会话.json'
$secondListPath = Join-Path $runDirectory '重启恢复工作区.json'
$resultPath = Join-Path $runDirectory '运行结果.json'

New-Item -ItemType Directory -Force -Path $runDirectory, $stateDirectory, $existingGitRoot, $nonGitRoot, $launchRoot | Out-Null
Set-Content -LiteralPath (Join-Path $existingGitRoot 'existing.txt') -Encoding utf8 -Value '已有 Git 真实内容'
Set-Content -LiteralPath (Join-Path $nonGitRoot 'generated.txt') -Encoding utf8 -Value '待初始化真实内容'
& git -C $existingGitRoot init --quiet
if ($LASTEXITCODE -ne 0) { throw '无法初始化已有 Git 验收仓库。' }
& git -C $existingGitRoot remote add origin 'https://example.invalid/agent-workspace.git'
if ($LASTEXITCODE -ne 0) { throw '无法写入已有 Git 验收仓库远端。' }

function Invoke-PaneflowRpc {
    <# 使用生产命名管道协议执行一次真实 JSON-RPC 调用。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [object]$Params = @{})

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'paneflow', [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine(([ordered]@{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Depth 12 -Compress))
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { throw "$Method 返回空响应。" }
        $response = $line | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw "$Method 失败：$($response.error | ConvertTo-Json -Compress)"
        }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-PaneflowReady {
    <# 有界等待真实桌面实例完成命名管道初始化。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ((Invoke-PaneflowRpc -Method 'system.ping').pong) { return }
        }
        catch {
            # 冷启动时命名管道尚未创建属于预期状态。
        }
        Start-Sleep -Milliseconds 500
    }
    throw '应用在 30 秒内未就绪。'
}

function Get-ProcessTreeIds {
    <# 根据实时父子关系返回根进程及其全部后代 PID。 #>
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
        if ($children.ContainsKey($current)) {
            foreach ($child in $children[$current]) { $queue.Enqueue($child) }
        }
    }
    return @($seen | Sort-Object)
}

function Stop-TestApp {
    <# 正常关闭窗口并验证本轮真实进程树全部退出。 #>
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
    if ($remaining.Count -ne 0) { throw "应用关闭后仍有残留 PID：$($remaining -join ', ')" }
    return $tracked
}

function Initialize-IsolatedState {
    <# 暂存用户真实状态并写入本轮独立配置。 #>
    if (Get-Process paneflow -ErrorAction SilentlyContinue) { throw '开始验收前仍存在 paneflow 进程。' }
    $script:hadConfig = Test-Path -LiteralPath $actualConfigPath -PathType Leaf
    $script:hadSession = Test-Path -LiteralPath $actualSessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $actualConfigPath -Parent), (Split-Path $actualSessionPath -Parent) | Out-Null
    if ($script:hadConfig) { Copy-Item -LiteralPath $actualConfigPath -Destination $configBackupPath }
    if ($script:hadSession) { Move-Item -LiteralPath $actualSessionPath -Destination $sessionBackupPath }
    '{"telemetry":{"enabled":false}}' | Set-Content -LiteralPath $actualConfigPath -Encoding utf8
    $script:statePrepared = $true
}

function Restore-IsolatedState {
    <# 删除实验状态并原样恢复用户配置与会话。 #>
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

function Write-MixedSession {
    <# 写入三个真实路径条目，其中一个在启动前故意保持失效。 #>
    $workspaces = @(
        [ordered]@{ title = '已有 Git'; cwd = $existingGitRoot; layout = $null; reference_format = 'common' },
        [ordered]@{ title = '失效目录'; cwd = $missingRoot; layout = $null; reference_format = 'common' },
        [ordered]@{ title = '非 Git'; cwd = $nonGitRoot; layout = $null; reference_format = 'common' }
    )
    $session = [ordered]@{
        version = 1
        active_workspace = 2
        workspace_grid_page = 0
        workspaces = $workspaces
        active_project = 0
        mode = 'cli'
        diff_scope = 'project'
    }
    $json = $session | ConvertTo-Json -Depth 12
    $json | Set-Content -LiteralPath $actualSessionPath -Encoding utf8
    $json | Set-Content -LiteralPath $inputSessionPath -Encoding utf8
}

function Start-And-AssertRestore {
    <# 启动真实应用并等待恢复条目、PTY 和 Git 生命周期全部稳定。 #>
    $process = Start-Process -FilePath $binary -WorkingDirectory $launchRoot -WindowStyle Hidden -PassThru
    Wait-PaneflowReady
    $workspaces = @()
    $surfaces = @()
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $workspaces = @((Invoke-PaneflowRpc -Method 'workspace.list').workspaces | Sort-Object index)
        $surfaces = @((Invoke-PaneflowRpc -Method 'surface.list').surfaces | Where-Object { $_.scope -eq 'workspace' })
        if ($workspaces.Count -eq 2 -and $surfaces.Count -eq 2 -and (Test-Path -LiteralPath (Join-Path $nonGitRoot '.git'))) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($workspaces.Count -ne 2) { throw "应恢复两个有效工作区，实际为 $($workspaces.Count)。" }
    if ($surfaces.Count -ne 2) { throw "应恢复两个真实终端，实际为 $($surfaces.Count)。" }
    if (($workspaces.title -join '|') -ne '已有 Git|非 Git') { throw "恢复标题或顺序错误：$($workspaces.title -join '|')" }
    if ([IO.Path]::GetFullPath([string]$workspaces[0].cwd) -ne [IO.Path]::GetFullPath($existingGitRoot)) { throw '已有 Git 根目录发生漂移。' }
    if ([IO.Path]::GetFullPath([string]$workspaces[1].cwd) -ne [IO.Path]::GetFullPath($nonGitRoot)) { throw '非 Git 根目录发生漂移。' }
    if (-not [bool]$workspaces[1].active) { throw '过滤失效条目后活动工作区没有映射到原非 Git 条目。' }
    if (-not (Test-Path -LiteralPath (Join-Path $nonGitRoot '.git') -PathType Container)) { throw '恢复的非 Git 根目录没有自动初始化。' }
    if (Test-Path -LiteralPath (Join-Path $launchRoot '.git')) { throw '进程启动目录被错误初始化为 Git 仓库。' }
    if (Test-Path -LiteralPath $missingRoot) { throw '失效目录被应用意外创建。' }
    return [pscustomobject]@{ Process = $process; Workspaces = $workspaces; Surfaces = $surfaces }
}

$firstProcess = $null
$secondProcess = $null
$script:statePrepared = $false
$script:hadConfig = $false
$script:hadSession = $false

try {
    Initialize-IsolatedState
    Write-MixedSession
    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'

    $first = Start-And-AssertRestore
    $firstProcess = $first.Process
    $first.Workspaces | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $firstListPath -Encoding utf8
    $firstTracked = Stop-TestApp -Process $firstProcess
    $firstProcess = $null
    Copy-Item -LiteralPath $actualSessionPath -Destination $savedSessionPath -Force
    $saved = Get-Content -LiteralPath $savedSessionPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (@($saved.workspaces).Count -ne 2) { throw '首次退出会话仍包含失效工作区。' }

    $second = Start-And-AssertRestore
    $secondProcess = $second.Process
    $second.Workspaces | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $secondListPath -Encoding utf8
    $secondTracked = Stop-TestApp -Process $secondProcess
    $secondProcess = $null

    $origin = (& git -C $existingGitRoot remote get-url origin).Trim()
    $nonGitRemotes = @(& git -C $nonGitRoot remote)
    if ($origin -ne 'https://example.invalid/agent-workspace.git') { throw '已有仓库远端配置被改写。' }
    if ($nonGitRemotes.Count -ne 0) { throw '自动初始化的本地仓库不应拥有远端。' }

    $result = [ordered]@{
        RunId = "真实恢复-$timestamp"
        Commit = (git -C $repoRoot rev-parse HEAD).Trim()
        BinaryPath = $binary
        BinarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        InputWorkspaceCount = 3
        RestoredWorkspaceCount = 2
        RestoredTitles = @($second.Workspaces.title)
        ActiveTitle = [string](@($second.Workspaces | Where-Object active)[0].title)
        ExistingGitRoot = $existingGitRoot
        NonGitRoot = $nonGitRoot
        MissingRoot = $missingRoot
        NonGitInitialized = $true
        ExistingRemotePreserved = $origin
        LaunchRootUntouched = -not (Test-Path -LiteralPath (Join-Path $launchRoot '.git'))
        FirstTrackedProcessIds = $firstTracked
        SecondTrackedProcessIds = $secondTracked
        RemainingProcessIds = @()
        Passed = $true
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
    [pscustomobject]$result
}
finally {
    try {
        if ($null -ne $firstProcess -and $null -ne (Get-Process -Id $firstProcess.Id -ErrorAction SilentlyContinue)) { Stop-Process -Id $firstProcess.Id -Force }
        if ($null -ne $secondProcess -and $null -ne (Get-Process -Id $secondProcess.Id -ErrorAction SilentlyContinue)) { Stop-Process -Id $secondProcess.Id -Force }
    }
    finally {
        Restore-IsolatedState
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    }
}
