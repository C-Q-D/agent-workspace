<#
.SYNOPSIS
验收 Release GUI 与 AI hook 之间的真实 Windows 命名管道传输。

.DESCRIPTION
脚本隔离用户会话，启动真实 Paneflow GUI，通过真实 IPC 创建工作区，再启动
paneflow-ai-hook 子进程发送 Prompt 与 Stop 事件。随后用 fleet.list 读取服务端状态，
证明 one-way frame 已到达主应用。全程不使用模拟服务端、模拟 hook 或模拟目录。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BinaryPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$HookPath,

    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary = (Resolve-Path -LiteralPath $BinaryPath).Path
$hookBinary = (Resolve-Path -LiteralPath $HookPath).Path
$debugBuild = (Split-Path $binary -Parent) -match '[\\/]debug$'
$pipeName = if ($debugBuild) { 'paneflow-dev' } else { 'paneflow' }
$appSubdirectory = if ($debugBuild) { 'paneflow-dev' } else { 'paneflow' }
$sessionFileName = if ($debugBuild) { 'session-dev.json' } else { 'session.json' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$fixtureRoot = "F:\AWIpcHook-$timestamp"
$actualConfigPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) "$appSubdirectory\paneflow.json"
$actualSessionPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "$appSubdirectory\$sessionFileName"
$configBackupPath = Join-Path $fixtureRoot '用户配置.json'
$sessionBackupPath = Join-Path $fixtureRoot '用户会话.json'

function Invoke-PaneflowRpc {
    <# 通过真实命名管道发送一条请求响应 frame。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][object]$Params
    )

    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(5000)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer.AutoFlush = $true
        $request = [ordered]@{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 }
        $writer.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress))
        $response = $reader.ReadLine() | ConvertFrom-Json
        if ($response.PSObject.Properties.Name -contains 'error') {
            throw ($response.error | ConvertTo-Json -Compress)
        }
        return $response.result
    }
    finally {
        $pipe.Dispose()
    }
}

function Wait-PaneflowReady {
    <# 有界等待真实 GUI 的命名管道开始响应。 #>
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            if ((Invoke-PaneflowRpc -Method 'system.ping' -Params @{}).pong) { return }
        }
        catch { }
        Start-Sleep -Milliseconds 250
    }
    throw 'Paneflow IPC 在 15 秒内未就绪。'
}

function Invoke-RealHook {
    <# 启动真实 hook 子进程并写入事件 JSON；返回退出码、耗时和 stderr。 #>
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][uint64]$WorkspaceId,
        [Parameter(Mandatory = $true)][uint32]$AgentPid
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:hookBinary
    $startInfo.ArgumentList.Add($Event)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PANEFLOW_SOCKET_PATH'] = "\\.\pipe\$script:pipeName"
    $startInfo.Environment['PANEFLOW_WORKSPACE_ID'] = $WorkspaceId.ToString()
    $startInfo.Environment['PANEFLOW_AI_TOOL'] = 'codex'
    $startInfo.Environment['PANEFLOW_AI_PID'] = $AgentPid.ToString()

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write($Payload)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(5000)) {
        $process.Kill($true)
        throw "$Event hook 在 5 秒内未退出。"
    }
    $watch.Stop()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        StandardError = $process.StandardError.ReadToEnd()
    }
}

function Get-ProcessTreeIds {
    <# 返回根进程和全部后代 PID，用于关闭 GUI 后检查零残留。 #>
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
    return @($seen)
}

New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$server = $null
$trackedProcessIds = @()
$statePrepared = $false
$hadConfig = $false
$hadSession = $false

try {
    if (Get-Process paneflow -ErrorAction SilentlyContinue) {
        throw '验收前仍存在 Paneflow 进程。'
    }
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

    $creation = Invoke-PaneflowRpc -Method 'workspace.create' -Params @{ name = 'Hook传输验收'; cwd = $fixtureRoot }
    if ($creation.index -ne 0) { throw "隔离会话的首个工作区索引应为 0，实际为 $($creation.index)。" }

    # 隔离进程中 NEXT_WORKSPACE_ID 从 1 开始，首个工作区稳定 ID 必为 1。
    $workspaceId = [uint64]1
    $agentPid = [uint32]$PID
    $prompt = Invoke-RealHook -Event 'UserPromptSubmit' -Payload '{"prompt":"验证真实 Windows IPC"}' -WorkspaceId $workspaceId -AgentPid $agentPid
    if ($prompt.ExitCode -ne 0) { throw "Prompt hook 退出码应为 0，实际为 $($prompt.ExitCode)。" }

    $matchedAgent = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $fleet = Invoke-PaneflowRpc -Method 'fleet.list' -Params @{}
        $matchedAgent = @($fleet.agents | Where-Object {
            $_.hooked -eq $true -and $_.tool -eq 'codex' -and $_.state -eq 'thinking' -and $_.pid -eq $agentPid
        }) | Select-Object -First 1
        if ($null -ne $matchedAgent) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $matchedAgent) { throw '真实 Prompt hook 已退出，但 fleet.list 未观察到 thinking 状态。' }

    $stop = Invoke-RealHook -Event 'Stop' -Payload '{}' -WorkspaceId $workspaceId -AgentPid $agentPid
    if ($stop.ExitCode -ne 0) { throw "Stop hook 退出码应为 0，实际为 $($stop.ExitCode)。" }

    $result = [pscustomobject]@{
        BuildProfile = if ($debugBuild) { 'Debug' } else { 'Release' }
        ServerProcessId = $server.Id
        WorkspaceIndex = $creation.index
        WorkspaceId = $workspaceId
        AgentPid = $agentPid
        PromptHookExitCode = $prompt.ExitCode
        PromptHookMilliseconds = $prompt.ElapsedMilliseconds
        StopHookExitCode = $stop.ExitCode
        StopHookMilliseconds = $stop.ElapsedMilliseconds
        ObservedTool = $matchedAgent.tool
        ObservedState = $matchedAgent.state
        ObservedHooked = $matchedAgent.hooked
        GitRepository = Test-Path -LiteralPath (Join-Path $fixtureRoot '.git') -PathType Container
    }
    $result | Format-List | Out-Host
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $evidenceParent = Split-Path $EvidencePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($evidenceParent)) {
            New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
        }
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    }
}
finally {
    if ($null -ne $server) {
        $trackedProcessIds = @(Get-ProcessTreeIds -RootProcessId $server.Id)
        if ($null -ne (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) {
            $server.CloseMainWindow() | Out-Null
            if (-not $server.WaitForExit(10000)) { Stop-Process -Id $server.Id -Force }
        }
        foreach ($id in $trackedProcessIds) {
            $remaining = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($null -ne $remaining) { Stop-Process -Id $id -Force }
        }
    }
    if ($statePrepared) {
        if (Test-Path -LiteralPath $actualSessionPath -PathType Leaf) {
            Remove-Item -LiteralPath $actualSessionPath -Force
        }
        if ($hadSession -and (Test-Path -LiteralPath $sessionBackupPath -PathType Leaf)) {
            Move-Item -LiteralPath $sessionBackupPath -Destination $actualSessionPath -Force
        }
        if ($hadConfig -and (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $configBackupPath -Destination $actualConfigPath -Force
        }
        elseif (Test-Path -LiteralPath $actualConfigPath -PathType Leaf) {
            Remove-Item -LiteralPath $actualConfigPath -Force
        }
    }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolvedFixture.StartsWith('F:\AWIpcHook-', [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝清理意外目录：$resolvedFixture"
        }
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
                break
            }
            catch {
                if ($attempt -eq 29) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
}
