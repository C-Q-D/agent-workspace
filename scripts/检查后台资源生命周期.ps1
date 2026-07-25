# 只读核对 A013 后台资源生命周期报告依赖的关键源码锚点。
# 本脚本覆盖事件 watcher、定时轮询、channel、异步任务、子进程、进程守护和缓存；
# 它不把“源码中出现 sleep”直接判定为产品轮询，具体语义由报告按所有者和触发条件分类。
[CmdletBinding()]
param(
    # 可选 JSON 输出路径；未提供时只把结果写到标准输出。
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

# 每项都带资源类型与倍增维度，避免后续只统计数量而遗漏生命周期。
$Contracts = @(
    [ordered]@{
        id = "app-global-tickers"
        kind = "定时任务"
        multiplier = "每个应用实例"
        path = "src-app/src/app/bootstrap.rs"
        markers = @("app.process_automation_tick(cx);", "from_millis(50)", "from_millis(200)", "from_secs(30)", "schedule_active_port_rescans")
    },
    [ordered]@{
        id = "config-watcher"
        kind = "事件Watcher+线程"
        multiplier = "每个应用实例"
        path = "crates/paneflow-config/src/watcher.rs"
        markers = @("RecommendedWatcher::new(", "RecursiveMode::NonRecursive", "rx.recv_timeout(remaining)", "thread::spawn(move ||")
    },
    [ordered]@{
        id = "theme-watcher"
        kind = "事件Watcher+失败回退"
        multiplier = "每个应用实例"
        path = "src-app/src/theme/watcher.rs"
        markers = @("static WATCHER_ACTIVE: AtomicBool", "RecommendedWatcher::new(", "THEME_CHECK_INTERVAL", "rx.recv_timeout(remaining)")
    },
    [ordered]@{
        id = "terminal-events"
        kind = "PTY线程+异步Channel"
        multiplier = "每个终端"
        path = "src-app/src/terminal/view.rs"
        markers = @("let events_rx = terminal.events_rx.take()", "let Some(first_event) = events_rx.next().await", "batch.len() >= 100")
    },
    [ordered]@{
        id = "terminal-shutdown"
        kind = "子进程生命周期"
        multiplier = "每个终端"
        path = "src-app/src/terminal/pty_session.rs"
        markers = @("let _io_thread = event_loop.spawn();", "impl Drop for TerminalState", "self.notifier.0.shutdown();", "MAX_PENDING_INPUT_BYTES")
    },
    [ordered]@{
        id = "files-watcher"
        kind = "聚焦时事件Watcher"
        multiplier = "最多一个聚焦文件上下文"
        path = "src-app/src/app/files_sidebar/watch.rs"
        markers = @("build_files_watcher(", "notify::RecursiveMode::NonRecursive", "app.files_sidebar_open", "app.files_tree.root == root")
    },
    [ordered]@{
        id = "diff-watcher"
        kind = "Review时事件Watcher"
        multiplier = "当前Review实体"
        path = "src-app/src/diff/view/watcher.rs"
        markers = @("pub(super) fn start_watchers(", "while let Some(result) = rx.next().await", "pub fn suspend(", "self._watchers.clear();")
    },
    [ordered]@{
        id = "session-discovery"
        kind = "按需后台扫描"
        multiplier = "打开会话栏时按启用适配器"
        path = "src-app/src/app/sessions_sidebar.rs"
        markers = @("sessions_scan_generation", "smol::unblock(move ||", "read_sessions_for_cwd_with_omitted")
    },
    [ordered]@{
        id = "update-check"
        kind = "一次性网络线程"
        multiplier = "每次应用启动"
        path = "src-app/src/update/checker.rs"
        markers = @("const UPDATE_HTTP_TIMEOUT", "pub fn spawn_check(", "std::thread::spawn(move ||", "timeout_global(Some(UPDATE_HTTP_TIMEOUT))")
    },
    [ordered]@{
        id = "telemetry"
        kind = "条件定时网络任务"
        multiplier = "每个活动Telemetry句柄"
        path = "crates/paneflow-telemetry/src/client.rs"
        markers = @("pub(crate) const QUEUE_MAX", "pub fn is_active(&self)", "pub fn poll_flush(&self)", "pub fn deactivate(&self)")
    },
    [ordered]@{
        id = "ipc-server"
        kind = "服务器线程+有界队列"
        multiplier = "每个应用实例，连接按上限"
        path = "src-app/src/ipc.rs"
        markers = @("const MAX_REQUEST_CONNECTIONS", "const MAX_SUBSCRIPTION_CONNECTIONS", "mpsc::sync_channel(IPC_REQUEST_QUEUE_CAPACITY)", "IPC_DRAIN_MAX_PER_TICK")
    },
    [ordered]@{
        id = "windows-process-guard"
        kind = "Job Object"
        multiplier = "每个应用实例"
        path = "src-app/src/terminal/process_guard.rs"
        markers = @("limit_kill_on_job_close()", "job.assign_current_process()?", "std::mem::forget(job)")
    },
    [ordered]@{
        id = "bounded-caches"
        kind = "内存缓存"
        multiplier = "进程级与Review级"
        path = "src-app/src/agent_sessions.rs"
        markers = @("pub const MAX_CACHE_ENTRIES: usize = 10", "SIDEBAR_SESSION_RETAINED_PER_SOURCE", "DIFF_ATTRIBUTION_MATCH_CAP")
    },
    [ordered]@{
        id = "bounded-diff-cache"
        kind = "Review实体缓存"
        multiplier = "每个应用实例"
        path = "src-app/src/app/diff_view_actions.rs"
        markers = @("const DIFF_VIEW_CACHE_CAP: usize = 6", "v.suspend(cx)", "evict_diff_cache_if_needed")
    }
)

$Results = foreach ($Contract in $Contracts) {
    $FullPath = Join-Path $RepositoryRoot $Contract.path
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        throw "后台资源契约文件不存在：$($Contract.path)"
    }

    $Lines = Get-Content -LiteralPath $FullPath
    $Evidence = foreach ($Marker in $Contract.markers) {
        $MatchIndex = -1
        for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
            if ($Lines[$Index].IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) {
                $MatchIndex = $Index
                break
            }
        }
        if ($MatchIndex -lt 0) {
            throw "后台资源源码锚点缺失：$($Contract.path) -> $Marker"
        }
        [ordered]@{
            marker = $Marker
            line = $MatchIndex + 1
        }
    }

    [ordered]@{
        id = $Contract.id
        kind = $Contract.kind
        multiplier = $Contract.multiplier
        path = $Contract.path
        evidence = @($Evidence)
    }
}

$Report = [ordered]@{
    schemaVersion = 1
    repositoryRoot = $RepositoryRoot
    contractCount = $Results.Count
    result = "passed"
    contracts = @($Results)
}
$Json = $Report | ConvertTo-Json -Depth 8

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $ResolvedOutput = [IO.Path]::GetFullPath($OutputPath, $RepositoryRoot)
    $Parent = Split-Path -Parent $ResolvedOutput
    if (-not [string]::IsNullOrWhiteSpace($Parent)) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }
    [IO.File]::WriteAllText($ResolvedOutput, "$Json`n", [Text.UTF8Encoding]::new($false))
}

Write-Output $Json
Write-Output "A013 后台资源生命周期检查通过：$($Results.Count) 组资源契约"
