# 对真实 Windows Release 载荷执行便携 ZIP 的重复构建、内容一致性与失败门禁测试。
# 负向场景只复制并修改真实输入，不使用虚构 EXE 或 helper，以保持载荷行为和文件规模真实。
[CmdletBinding()]
param(
    [string]$Version = "0.7.11",
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$GeneratorPath = Join-Path $RepositoryRoot "scripts\生成Windows便携包.ps1"
$PowerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"
if (-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) {
    $PowerShellPath = (Get-Process -Id $PID).Path
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot (
        "target\portable-test\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    )
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Invoke-Generator {
    # 每次生成都放在独立 PowerShell 进程中，避免程序集或环境状态影响重复构建结论。
    param(
        [string]$Destination,
        [string]$GeneratorVersion = $Version,
        [string]$ExecutablePath,
        [string]$HelpersDirectory,
        [switch]$ExpectFailure,
        [string]$Label
    )
    $Arguments = @(
        "-NoProfile",
        "-File", $GeneratorPath,
        "-Version", $GeneratorVersion,
        "-OutputDirectory", $Destination
    )
    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
        $Arguments += @("-ExecutablePath", $ExecutablePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($HelpersDirectory)) {
        $Arguments += @("-HelpersDirectory", $HelpersDirectory)
    }
    $Stdout = Join-Path $OutputDirectory "$Label-stdout.txt"
    $Stderr = Join-Path $OutputDirectory "$Label-stderr.txt"
    $Process = Start-Process `
        -FilePath $PowerShellPath `
        -ArgumentList $Arguments `
        -RedirectStandardOutput $Stdout `
        -RedirectStandardError $Stderr `
        -Wait `
        -PassThru
    if ($ExpectFailure) {
        if ($Process.ExitCode -eq 0) {
            throw "负向门禁错误地返回成功：$Label"
        }
        return $null
    }
    if ($Process.ExitCode -ne 0) {
        $ErrorText = if (Test-Path -LiteralPath $Stderr) { Get-Content -Raw -LiteralPath $Stderr } else { "" }
        throw "便携包生成失败：$Label，退出码 $($Process.ExitCode)`n$ErrorText"
    }
    $ResultPath = Join-Path $Destination "便携包结果.json"
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "生成器没有输出机器结果：$Label"
    }
    return Get-Content -Raw -LiteralPath $ResultPath | ConvertFrom-Json
}

function Assert-ZipMatchesResult {
    # 回读每个 ZIP 条目的路径、顺序、DOS 时间、长度和内容哈希，阻止绝对路径与越界条目。
    param($Result, [string]$Label)
    if ($Result.entries.Count -ne 25) {
        throw "$Label 条目数量不是 25：$($Result.entries.Count)"
    }
    $ActualZipHash = (Get-FileHash -LiteralPath $Result.zip.path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualZipHash -ne $Result.zip.sha256) {
        throw "$Label ZIP 哈希与机器结果不一致"
    }
    $ExpectedSidecar = "$ActualZipHash *$([IO.Path]::GetFileName($Result.zip.path))"
    if ([IO.File]::ReadAllText($Result.zip.sidecar).Trim() -ne $ExpectedSidecar) {
        throw "$Label SHA-256 sidecar 内容不一致"
    }

    $Archive = [IO.Compression.ZipFile]::OpenRead($Result.zip.path)
    try {
        $Entries = @($Archive.Entries)
        if ($Entries.Count -ne $Result.entries.Count) {
            throw "$Label ZIP 实际条目数量与机器结果不一致"
        }
        $FixedDate = [datetime]::new(1980, 1, 1, 0, 0, 0, [DateTimeKind]::Unspecified)
        for ($Index = 0; $Index -lt $Entries.Count; $Index++) {
            $Entry = $Entries[$Index]
            $Expected = $Result.entries[$Index]
            if ($Entry.FullName -ne $Expected.path) {
                throw "$Label 条目顺序或路径漂移：$($Entry.FullName)"
            }
            if ($Entry.FullName.Contains("\") -or
                $Entry.FullName.StartsWith("/") -or
                $Entry.FullName.Contains("../") -or
                $Entry.FullName -match "^[A-Za-z]:") {
                throw "$Label 包含不安全条目：$($Entry.FullName)"
            }
            if ($Entry.LastWriteTime.DateTime -ne $FixedDate) {
                throw "$Label 条目时间戳未固定：$($Entry.FullName)"
            }
            if ($Entry.Length -ne $Expected.length) {
                throw "$Label 条目长度漂移：$($Entry.FullName)"
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
            if ($EntryHash -ne $Expected.sha256) {
                throw "$Label 条目内容漂移：$($Entry.FullName)"
            }
        }
    }
    finally {
        $Archive.Dispose()
    }
}

$FirstDirectory = Join-Path $OutputDirectory "first"
$SecondDirectory = Join-Path $OutputDirectory "second"
$First = Invoke-Generator -Destination $FirstDirectory -Label "第一次生成"
$Second = Invoke-Generator -Destination $SecondDirectory -Label "第二次生成"
Assert-ZipMatchesResult -Result $First -Label "第一次生成"
Assert-ZipMatchesResult -Result $Second -Label "第二次生成"
if ($First.zip.sha256 -ne $Second.zip.sha256) {
    throw "相同真实输入连续生成的 ZIP 哈希不一致"
}
$FirstBytes = [IO.File]::ReadAllBytes($First.zip.path)
$SecondBytes = [IO.File]::ReadAllBytes($Second.zip.path)
if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($FirstBytes, $SecondBytes)) {
    throw "相同真实输入连续生成的 ZIP 字节不一致"
}

# 非法版本与缺失 helper 必须由生成器自身拒绝，而不是生成残缺包后再补救。
Invoke-Generator `
    -Destination (Join-Path $OutputDirectory "invalid-version") `
    -GeneratorVersion "0.7" `
    -ExpectFailure `
    -Label "非法版本"
$MissingHelpers = Join-Path $OutputDirectory "missing-helpers"
New-Item -ItemType Directory -Force -Path $MissingHelpers | Out-Null
Invoke-Generator `
    -Destination (Join-Path $OutputDirectory "missing-output") `
    -HelpersDirectory $MissingHelpers `
    -ExpectFailure `
    -Label "缺失helper"

# 从真实 Release EXE 复制一份并追加单字节；若重复构建门禁仍给出同一哈希，则说明输入漂移未被识别。
$RealExecutable = Join-Path $RepositoryRoot "target\x86_64-pc-windows-msvc\release\agent-workspace.exe"
$DriftExecutable = Join-Path $OutputDirectory "agent-workspace-drift.exe"
Copy-Item -LiteralPath $RealExecutable -Destination $DriftExecutable
$DriftStream = [IO.File]::Open($DriftExecutable, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $DriftStream.WriteByte(0)
}
finally {
    $DriftStream.Dispose()
}
$Drift = Invoke-Generator `
    -Destination (Join-Path $OutputDirectory "drift") `
    -ExecutablePath $DriftExecutable `
    -Label "输入漂移"
Assert-ZipMatchesResult -Result $Drift -Label "输入漂移"
if ($Drift.zip.sha256 -eq $First.zip.sha256) {
    throw "真实 EXE 输入变化后 ZIP 哈希没有变化"
}

$TestResult = [ordered]@{
    schemaVersion = 1
    executedAt = (Get-Date).ToString("o")
    outputDirectory = $OutputDirectory
    zipSha256 = [string]$First.zip.sha256
    zipLength = [long]$First.zip.length
    entryCount = [int]$First.entries.Count
    identicalBuilds = $true
    fixedEntryMetadata = $true
    safeRelativeEntries = $true
    illegalVersionRejected = $true
    missingHelperRejected = $true
    realInputDriftDetected = $true
}
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$TestResultPath = Join-Path $OutputDirectory "测试结果.json"
[IO.File]::WriteAllText($TestResultPath, ($TestResult | ConvertTo-Json -Depth 5) + "`n", $Utf8NoBom)
Write-Output "Windows 便携包确定性与失败门禁通过"
Write-Output "ZIP SHA-256：$($First.zip.sha256)"
Write-Output "条目：$($First.entries.Count)"
Write-Output "证据：$TestResultPath"
