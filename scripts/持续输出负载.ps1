<#
.SYNOPSIS
为终端矩阵性能验收产生有界、可识别的真实 PowerShell 输出。

.DESCRIPTION
脚本按固定间隔输出带窗口名称和序号的行，结束时写出唯一完成标记。它不访问
网络、不修改仓库，只作为 ConPTY/VTE/隐藏重绘链路的真实子进程负载。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WindowName,

    [ValidateRange(1, 7200)]
    [int]$DurationSeconds = 30,

    [ValidateRange(20, 60000)]
    [int]$IntervalMilliseconds = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$startedAt = [DateTimeOffset]::UtcNow
$sequence = 0
while (([DateTimeOffset]::UtcNow - $startedAt).TotalSeconds -lt $DurationSeconds) {
    $sequence++
    '{0}-{1:D8}-{2}' -f $WindowName, $sequence, [DateTimeOffset]::UtcNow.ToString('O')
    Start-Sleep -Milliseconds $IntervalMilliseconds
}

'AGENTWORKSPACE_DONE {0} {1}' -f $WindowName, $sequence
