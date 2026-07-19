# 从已构建的真实 Windows x64 Release 载荷生成字节可重复的 AgentWorkspace 便携 ZIP。
# 脚本只使用 PowerShell 与 .NET 标准库，不调用 Cargo、WiX 或安装器；所有输入都显式列入清单。
[CmdletBinding()]
param(
    [string]$Version = "0.7.11",
    [string]$ExecutablePath,
    [string]$HelpersDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($Version -notmatch "^\d+\.\d+\.\d+$") {
    throw "便携包版本必须是三段数字版本：$Version"
}
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path $RepositoryRoot "target\x86_64-pc-windows-msvc\release\agent-workspace.exe"
}
if ([string]::IsNullOrWhiteSpace($HelpersDirectory)) {
    $HelpersDirectory = Join-Path $RepositoryRoot "target\x86_64-pc-windows-msvc\release\paneflow-helpers"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot "target\portable"
}

$ExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
$HelpersDirectory = [IO.Path]::GetFullPath($HelpersDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$PackageRoot = "AgentWorkspace-$Version-windows-x64"

function New-PayloadItem {
    # 统一构造输入文件与 ZIP 相对路径，拒绝反斜杠和越界条目，防止生成平台相关目录。
    param([string]$Source, [string]$RelativePath)
    $FullSource = [IO.Path]::GetFullPath($Source)
    if (-not (Test-Path -LiteralPath $FullSource -PathType Leaf)) {
        throw "便携包输入不存在：$FullSource"
    }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.Contains("\") -or
        $RelativePath.StartsWith("/") -or
        $RelativePath.Contains("../")) {
        throw "便携包条目不是安全的相对路径：$RelativePath"
    }
    return [pscustomobject]@{
        Source = $FullSource
        Entry = "$PackageRoot/$RelativePath"
    }
}

# helper 名单与 WiX HelperBinaries 组件保持一致；显式名单让新增或遗漏必须经过审查。
$HelperNames = @(
    "agy.exe",
    "amp.exe",
    "claude.exe",
    "codebuddy.exe",
    "codex.exe",
    "copilot.exe",
    "cursor-agent.exe",
    "droid.exe",
    "gemini.exe",
    "grok.exe",
    "hermes.exe",
    "kiro-cli.exe",
    "openclaw.exe",
    "opencode.exe",
    "paneflow-ai-hook.exe",
    "pi.exe",
    "qodercli.exe"
)
$Payload = @(
    New-PayloadItem -Source $ExecutablePath -RelativePath "agent-workspace.exe"
    New-PayloadItem -Source (Join-Path $RepositoryRoot "packaging\windows\便携版说明.txt") -RelativePath "便携版说明.txt"
    New-PayloadItem -Source (Join-Path $RepositoryRoot "packaging\wix\License.rtf") -RelativePath "License.rtf"
)
foreach ($Name in $HelperNames) {
    $Payload += New-PayloadItem -Source (Join-Path $HelpersDirectory $Name) -RelativePath "bin/$Name"
}
$LegalMappings = @(
    @{ Source = "LICENSE.txt"; Entry = "LICENSE.txt" },
    @{ Source = "上游归属与修改说明.md"; Entry = "UPSTREAM-NOTICE.md" },
    @{ Source = "第三方Rust依赖清单.md"; Entry = "THIRD-PARTY-RUST.md" },
    @{ Source = "第三方Rust依赖.json"; Entry = "THIRD-PARTY-RUST.json" },
    @{ Source = "第三方资产清单.md"; Entry = "THIRD-PARTY-ASSETS.md" }
)
foreach ($Mapping in $LegalMappings) {
    $Payload += New-PayloadItem `
        -Source (Join-Path $RepositoryRoot "packaging\windows\legal\$($Mapping.Source)") `
        -RelativePath "licenses/$($Mapping.Entry)"
}

$DuplicateEntries = @($Payload | Group-Object Entry | Where-Object Count -gt 1)
if ($DuplicateEntries.Count -ne 0) {
    throw "便携包清单包含重复条目：$($DuplicateEntries.Name -join ', ')"
}
# 条目顺序完全由上面的显式数组和循环决定，不调用受系统区域设置影响的文化排序。
$Payload = @($Payload)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$ZipName = "agent-workspace-$Version-windows-x64.zip"
$ZipPath = Join-Path $OutputDirectory $ZipName
$TemporaryZip = "$ZipPath.tmp"
foreach ($Path in @($TemporaryZip, $ZipPath)) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

$FixedTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$FileStream = [IO.File]::Open($TemporaryZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$Archive = $null
try {
    $Archive = [IO.Compression.ZipArchive]::new(
        $FileStream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false,
        [Text.UTF8Encoding]::new($false)
    )
    foreach ($Item in $Payload) {
        $Entry = $Archive.CreateEntry($Item.Entry, [IO.Compression.CompressionLevel]::Optimal)
        $Entry.LastWriteTime = $FixedTimestamp
        $Entry.ExternalAttributes = 0
        $Input = [IO.File]::OpenRead($Item.Source)
        $Output = $null
        try {
            $Output = $Entry.Open()
            $Input.CopyTo($Output)
        }
        finally {
            if ($null -ne $Output) { $Output.Dispose() }
            $Input.Dispose()
        }
    }
}
finally {
    if ($null -ne $Archive) { $Archive.Dispose() }
    $FileStream.Dispose()
}
Move-Item -LiteralPath $TemporaryZip -Destination $ZipPath

# 回读最终 ZIP，确保条目集合与清单完全一致，而不是只相信写入循环没有遗漏。
$ReadArchive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $ActualEntries = @($ReadArchive.Entries | ForEach-Object FullName)
}
finally {
    $ReadArchive.Dispose()
}
$ExpectedEntries = @($Payload | ForEach-Object Entry)
if ($ActualEntries.Count -ne $ExpectedEntries.Count -or
    (Compare-Object -ReferenceObject $ExpectedEntries -DifferenceObject $ActualEntries).Count -ne 0) {
    throw "最终 ZIP 条目与便携载荷清单不一致"
}

$ZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$SidecarPath = "$ZipPath.sha256"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($SidecarPath, "$ZipHash *$ZipName`n", $Utf8NoBom)
$Result = [ordered]@{
    schemaVersion = 1
    version = $Version
    packageRoot = $PackageRoot
    zip = [ordered]@{
        path = $ZipPath
        length = (Get-Item -LiteralPath $ZipPath).Length
        sha256 = $ZipHash
        sidecar = $SidecarPath
    }
    entries = @(
        $Payload | ForEach-Object {
            [ordered]@{
                path = $_.Entry
                length = (Get-Item -LiteralPath $_.Source).Length
                sha256 = (Get-FileHash -LiteralPath $_.Source -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
}
$ResultPath = Join-Path $OutputDirectory "便携包结果.json"
[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 6) + "`n", $Utf8NoBom)
Write-Output "Windows 便携包生成通过"
Write-Output "ZIP：$ZipPath"
Write-Output "SHA-256：$ZipHash"
Write-Output "条目：$($Payload.Count)"
