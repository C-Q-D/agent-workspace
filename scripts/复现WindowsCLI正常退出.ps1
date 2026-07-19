<#
.SYNOPSIS
复现并判定 Paneflow Windows CLI 成功请求后的异常退出。

.DESCRIPTION
脚本隔离真实用户状态，启动真实桌面服务端，再用同一二进制执行指定 CLI 场景。
服务端状态正确但客户端退出码不符合命令约定时，脚本输出精确症状并以 1 退出；
修复后同一脚本应转绿。该反馈环不使用模拟服务端、模拟终端或模拟目录。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [ValidateSet('new', 'ls', 'status-missing')]
    [string]$ClientScenario = 'new',

    [ValidateSet('NonGit', 'ExistingGit')]
    [string]$WorkspaceKind = 'NonGit',

    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$debugBuild = (Split-Path $binary -Parent) -match '[\\/]debug$'
$pipeName = if ($debugBuild) { 'paneflow-dev' } else { 'paneflow' }
$appSubdirectory = if ($debugBuild) { 'paneflow-dev' } else { 'paneflow' }
$sessionFileName = if ($debugBuild) { 'session-dev.json' } else { 'session.json' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$fixtureRoot = "F:\AWCliExit-$timestamp"
$stdoutPath = Join-Path $fixtureRoot 'stdout.txt'
$stderrPath = Join-Path $fixtureRoot 'stderr.txt'
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) "$appSubdirectory\paneflow.json"
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "$appSubdirectory\$sessionFileName"
$configBackupPath = Join-Path $fixtureRoot '用户配置.json'
$sessionBackupPath = Join-Path $fixtureRoot '用户会话.json'

function Invoke-PaneflowRpc {
    <# 通过真实命名管道检查服务端是否实际完成工作区创建。 #>
    param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][object]$Params)
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine(([ordered]@{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Depth 8 -Compress))
        $response = $reader.ReadLine() | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') { throw ($response.error | ConvertTo-Json -Compress) }
        return $response.result
    }
    finally { $pipe.Dispose() }
}

function Wait-PaneflowReady {
    <# 有界等待真实桌面服务端管道。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try { if ((Invoke-PaneflowRpc -Method 'system.ping' -Params @{}).pong) { return } } catch { }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow IPC 在 15 秒内未就绪。'
}

function Get-ProcessTreeIds {
    <# 返回根进程和全部后代 PID，用于最终零残留检查。 #>
    param([Parameter(Mandatory = $true)][int]$RootProcessId)
    $children = @{}
    foreach ($item in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $parentId = if ($null -eq $item.Parent) { 0 } else { [int]$item.Parent.Id } } catch { $parentId = 0 }
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
    return @($seen)
}

New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
if ($WorkspaceKind -eq 'ExistingGit') {
    & git -C $fixtureRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw '无法建立已有 Git 仓库验收目录。' }
}
$server = $null
$statePrepared = $false
$hadConfig = $false
$hadSession = $false

try {
    if (Get-Process paneflow -ErrorAction SilentlyContinue) { throw '复现前仍存在 Paneflow 进程。' }
    $hadConfig = Test-Path -LiteralPath $actualConfigPath -PathType Leaf
    $hadSession = Test-Path -LiteralPath $actualSessionPath -PathType Leaf
    New-Item -ItemType Directory -Force -Path (Split-Path $actualConfigPath -Parent), (Split-Path $actualSessionPath -Parent) | Out-Null
    if ($hadConfig) { Copy-Item -LiteralPath $actualConfigPath -Destination $configBackupPath }
    if ($hadSession) { Move-Item -LiteralPath $actualSessionPath -Destination $sessionBackupPath }
    Set-Content -LiteralPath $actualConfigPath -Encoding utf8 -Value '{"telemetry":{"enabled":false}}'
    $statePrepared = $true

    $env:PANEFLOW_NO_TELEMETRY = '1'
    $env:PANEFLOW_IPC_SCRIPTING = '1'
    $server = Start-Process -FilePath $binary -WorkingDirectory $fixtureRoot -WindowStyle Hidden -PassThru
    Wait-PaneflowReady

    $clientArguments = switch ($ClientScenario) {
        'new' { @('new', '--name', 'CLI退出复现', '--cwd', $fixtureRoot) }
        'ls' { @('ls') }
        'status-missing' { @('status', '不存在的终端') }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $client = Start-Process -FilePath $binary -ArgumentList $clientArguments -WorkingDirectory $fixtureRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru
    $watch.Stop()
    $workspaces = @((Invoke-PaneflowRpc -Method 'workspace.list' -Params @{}).workspaces)
    # Process.ExitCode 使用有符号 Int32；先扩展到 Int64 再按位保留 Windows NTSTATUS 位型。
    $unsignedExit = [uint32]([int64]$client.ExitCode -band 0xFFFFFFFFL)
    $exitHex = '0x{0:X8}' -f $unsignedExit
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    # 工作区创建先返回 starting，Git 准备随后在后台完成；验收应有界等待真实仓库，
    # 不能把“响应返回的同一瞬间尚未落盘”误判为初始化失败。
    if ($ClientScenario -eq 'new') {
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            if (Test-Path -LiteralPath (Join-Path $fixtureRoot '.git') -PathType Container) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    $gitRepository = Test-Path -LiteralPath (Join-Path $fixtureRoot '.git') -PathType Container

    $result = [pscustomobject]@{
        WorkspaceKind = $WorkspaceKind
        ClientExitCode = $client.ExitCode
        ClientExitHex = $exitHex
        ServerWorkspaceCount = $workspaces.Count
        GitRepository = $gitRepository
        ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        Stdout = $stdout
        Stderr = $stderr
    }
    $result | Format-List | Out-Host
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        # 验收证据直接由脚本内的结构化结果产生，避免终端格式化文本丢失字段。
        $evidenceParent = Split-Path $EvidencePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($evidenceParent)) {
            New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
        }
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    }

    $expectedWorkspaceCount = if ($ClientScenario -eq 'new') { 1 } else { 0 }
    $expectedClientExitCode = if ($ClientScenario -eq 'status-missing') { 3 } else { 0 }
    if ($workspaces.Count -ne $expectedWorkspaceCount) { throw "服务端工作区数量应为 $expectedWorkspaceCount，实际为 $($workspaces.Count)。" }
    if ($ClientScenario -eq 'new' -and -not $gitRepository) { throw '创建后的工作区没有可用 Git 仓库。' }
    if ($client.ExitCode -ne $expectedClientExitCode) {
        throw "服务端状态符合 $ClientScenario 场景预期，但 CLI 应退出 $expectedClientExitCode，实际为 $exitHex。"
    }
    if ($expectedClientExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($stdout)) {
        throw 'CLI 已正常退出但没有输出成功结果。'
    }
    if ($expectedClientExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($stderr)) {
        throw 'CLI 已按错误码退出但没有输出错误信息。'
    }
}
finally {
    if ($null -ne $server -and $null -ne (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) {
        $tracked = @(Get-ProcessTreeIds -RootProcessId $server.Id)
        $server.CloseMainWindow() | Out-Null
        if (-not $server.WaitForExit(10000)) { Stop-Process -Id $server.Id -Force }
        foreach ($id in $tracked) {
            $remaining = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($null -ne $remaining) { Stop-Process -Id $id -Force }
        }
    }
    if ($statePrepared) {
        if (Test-Path -LiteralPath $actualSessionPath -PathType Leaf) { Remove-Item -LiteralPath $actualSessionPath -Force }
        if ($hadSession -and (Test-Path -LiteralPath $sessionBackupPath -PathType Leaf)) { Move-Item -LiteralPath $sessionBackupPath -Destination $actualSessionPath -Force }
        if ($hadConfig -and (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) { Copy-Item -LiteralPath $configBackupPath -Destination $actualConfigPath -Force }
        elseif (Test-Path -LiteralPath $actualConfigPath -PathType Leaf) { Remove-Item -LiteralPath $actualConfigPath -Force }
    }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        # Windows 崩溃退出后的重定向句柄可能短暂延迟释放；有界重试只清理本轮固定目录。
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
                break
            }
            catch {
                if ($attempt -eq 29) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
}
