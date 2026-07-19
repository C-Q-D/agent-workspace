# 在真实 Windows 上解压并运行 AgentWorkspace 便携 ZIP，验证内容、用户数据边界与进程清理。
# 验收使用隔离 USERPROFILE/HOME，不读取或修改开发者现有 AgentWorkspace 会话与设置。
[CmdletBinding()]
param(
    [string]$ZipPath,
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path $RepositoryRoot "target\portable\agent-workspace-0.7.11-windows-x64.zip"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot (
        "target\portable-acceptance\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    )
}
$ZipPath = [IO.Path]::GetFullPath($ZipPath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "便携 ZIP 不存在：$ZipPath"
}
$SidecarPath = "$ZipPath.sha256"
if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
    throw "便携 ZIP 缺少 SHA-256 sidecar：$SidecarPath"
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "便携验收输出目录必须是全新目录：$OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

function Get-DirectoryFingerprint {
    # 记录目录、文件相对路径和文件哈希；不存在也作为稳定状态参与前后比较。
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return "__ABSENT__"
    }
    $RootPath = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    $Records = @(
        Get-ChildItem -LiteralPath $RootPath -Force -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                $Relative = $_.FullName.Substring($RootPath.Length).TrimStart("\").Replace("\", "/")
                if ($_.PSIsContainer) {
                    "D|$Relative"
                }
                else {
                    $Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    "F|$Relative|$($_.Length)|$Hash"
                }
            }
    )
    return $Records -join "`n"
}

$ActualZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ExpectedSidecar = "$ActualZipHash *$([IO.Path]::GetFileName($ZipPath))"
if ([IO.File]::ReadAllText($SidecarPath).Trim() -ne $ExpectedSidecar) {
    throw "便携 ZIP 的 SHA-256 sidecar 与实际文件不一致"
}

$ExtractDirectory = Join-Path $OutputDirectory "extracted"
New-Item -ItemType Directory -Path $ExtractDirectory | Out-Null
$Archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $Entries = @($Archive.Entries)
    if ($Entries.Count -ne 25) {
        throw "便携 ZIP 条目数量不是 25：$($Entries.Count)"
    }
    foreach ($Entry in $Entries) {
        if ($Entry.FullName.Contains("\") -or
            $Entry.FullName.StartsWith("/") -or
            $Entry.FullName.Contains("../") -or
            $Entry.FullName -match "^[A-Za-z]:") {
            throw "便携 ZIP 包含不安全条目：$($Entry.FullName)"
        }
    }
    [IO.Compression.ZipFileExtensions]::ExtractToDirectory($Archive, $ExtractDirectory, $false)
}
finally {
    $Archive.Dispose()
}

$PackageDirectories = @(Get-ChildItem -LiteralPath $ExtractDirectory -Directory)
if ($PackageDirectories.Count -ne 1) {
    throw "解压根目录必须只包含一个版本目录"
}
$PackageRoot = $PackageDirectories[0].FullName
$ExpectedExecutable = Join-Path $PackageRoot "agent-workspace.exe"
$ExpectedHelpers = @(
    "agy.exe", "amp.exe", "claude.exe", "codebuddy.exe", "codex.exe", "copilot.exe",
    "cursor-agent.exe", "droid.exe", "gemini.exe", "grok.exe", "hermes.exe", "kiro-cli.exe",
    "openclaw.exe", "opencode.exe", "paneflow-ai-hook.exe", "pi.exe", "qodercli.exe"
)
$ExpectedLegal = @(
    "LICENSE.txt", "UPSTREAM-NOTICE.md", "THIRD-PARTY-RUST.md",
    "THIRD-PARTY-RUST.json", "THIRD-PARTY-ASSETS.md"
)
foreach ($Path in @(
    $ExpectedExecutable,
    (Join-Path $PackageRoot "License.rtf"),
    (Join-Path $PackageRoot "便携版说明.txt")
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "解压后缺少必需文件：$Path"
    }
}
foreach ($Name in $ExpectedHelpers) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot "bin\$Name") -PathType Leaf)) {
        throw "解压后缺少 helper：$Name"
    }
}
foreach ($Name in $ExpectedLegal) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot "licenses\$Name") -PathType Leaf)) {
        throw "解压后缺少法律材料：$Name"
    }
}

# 对 ZIP 内每个文件和解压文件做真实字节哈希比对，证明解压器没有改写载荷。
$Archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    foreach ($Entry in $Archive.Entries) {
        $ExtractedPath = Join-Path $ExtractDirectory $Entry.FullName.Replace("/", "\")
        if (-not (Test-Path -LiteralPath $ExtractedPath -PathType Leaf)) {
            throw "ZIP 条目没有对应解压文件：$($Entry.FullName)"
        }
        $Stream = $Entry.Open()
        try {
            $Sha = [Security.Cryptography.SHA256]::Create()
            try {
                $EntryHash = [Convert]::ToHexString($Sha.ComputeHash($Stream)).ToLowerInvariant()
            }
            finally {
                $Sha.Dispose()
            }
        }
        finally {
            $Stream.Dispose()
        }
        $ExtractedHash = (Get-FileHash -LiteralPath $ExtractedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($EntryHash -ne $ExtractedHash -or $Entry.Length -ne (Get-Item -LiteralPath $ExtractedPath).Length) {
            throw "解压文件与 ZIP 条目字节不一致：$($Entry.FullName)"
        }
    }
}
finally {
    $Archive.Dispose()
}

$DeveloperDataRoot = Join-Path $env:USERPROFILE ".agent-workspace"
$DeveloperFingerprintBefore = Get-DirectoryFingerprint -Root $DeveloperDataRoot
$IsolatedUser = Join-Path $OutputDirectory "user"
New-Item -ItemType Directory -Path $IsolatedUser | Out-Null
$StdoutPath = Join-Path $OutputDirectory "便携版版本输出.txt"
$StderrPath = Join-Path $OutputDirectory "便携版错误输出.txt"
$PreviousUserProfile = $env:USERPROFILE
$PreviousHome = $env:HOME
try {
    $env:USERPROFILE = $IsolatedUser
    $env:HOME = $IsolatedUser
    $Process = Start-Process `
        -FilePath $ExpectedExecutable `
        -ArgumentList "--version" `
        -WorkingDirectory $PackageRoot `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -Wait `
        -PassThru
}
finally {
    $env:USERPROFILE = $PreviousUserProfile
    $env:HOME = $PreviousHome
}
if ($Process.ExitCode -ne 0) {
    throw "便携主程序版本探针失败，退出码：$($Process.ExitCode)"
}
$VersionOutput = (Get-Content -Raw -LiteralPath $StdoutPath).Trim()
if ($VersionOutput -ne "agent-workspace 0.7.11") {
    throw "便携主程序版本输出异常：$VersionOutput"
}
if (@(Get-Process -Name "agent-workspace" -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "便携版本探针退出后仍有 AgentWorkspace 进程"
}
if (Get-ChildItem -LiteralPath $PackageRoot -Directory -Filter ".agent-workspace" -Recurse -ErrorAction SilentlyContinue) {
    throw "便携运行错误地在解压目录创建了 .agent-workspace"
}
$DeveloperFingerprintAfter = Get-DirectoryFingerprint -Root $DeveloperDataRoot
if ($DeveloperFingerprintAfter -ne $DeveloperFingerprintBefore) {
    throw "便携版本探针修改了开发者现有 .agent-workspace"
}

$Result = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    zip = [ordered]@{
        path = $ZipPath
        length = (Get-Item -LiteralPath $ZipPath).Length
        sha256 = $ActualZipHash
        sidecarVerified = $true
    }
    extraction = [ordered]@{
        root = $PackageRoot
        entryCount = $Entries.Count
        allEntryHashesVerified = $true
        helperCount = $ExpectedHelpers.Count
        legalMaterialCount = $ExpectedLegal.Count
    }
    execution = [ordered]@{
        executable = $ExpectedExecutable
        exitCode = $Process.ExitCode
        version = $VersionOutput
        processResidueCount = 0
    }
    dataBoundary = [ordered]@{
        isolatedUserProfile = $IsolatedUser
        portableDataDirectoryCreated = $false
        developerDataFingerprintPreserved = $true
        expectedUserDataRootName = ".agent-workspace"
    }
}
$ResultPath = Join-Path $OutputDirectory "运行结果.json"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($ResultPath, ($Result | ConvertTo-Json -Depth 7) + "`n", $Utf8NoBom)
Write-Output "Windows 便携包真实解压运行验收通过"
Write-Output "版本：$VersionOutput"
Write-Output "ZIP SHA-256：$ActualZipHash"
Write-Output "证据：$ResultPath"
