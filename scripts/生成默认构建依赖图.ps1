# 从 Cargo 元数据、Windows 目标依赖树、桌面构建脚本和发行清单生成 A011 依赖事实。
# 脚本只读仓库并调用 Cargo 的只读分析命令；不会构建、安装、修改配置或写入用户数据。
[CmdletBinding()]
param(
    # v1 的正式构建目标；允许 CI 显式覆盖以复核其他 Windows 架构。
    [string]$Target = "x86_64-pc-windows-msvc",
    # 可选 JSON 输出路径；未提供时只输出到标准输出。
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Invoke-CargoText {
    # 统一执行 Cargo 并保留 stderr；非零退出时立即失败，禁止把残缺依赖图写成通过。
    param([string[]]$Arguments)

    $Output = & cargo @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Cargo 分析命令失败：cargo $($Arguments -join ' ')`n$($Output -join "`n")"
    }
    return $Output -join "`n"
}

function Test-FileMarker {
    # 以 Ordinal 文本匹配验证构建/运行时锚点，避免正则和区域设置产生误判。
    param([string]$RelativePath, [string]$Marker)

    $FullPath = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
        throw "依赖证据文件不存在：$RelativePath"
    }
    $Text = [IO.File]::ReadAllText($FullPath)
    if ($Text.IndexOf($Marker, [StringComparison]::Ordinal) -lt 0) {
        throw "依赖证据锚点缺失：$RelativePath -> $Marker"
    }
    return $true
}

$MetadataText = Invoke-CargoText -Arguments @(
    "metadata", "--format-version", "1", "--no-deps", "--locked"
)
$Metadata = $MetadataText | ConvertFrom-Json
$AppPackage = $Metadata.packages | Where-Object name -eq "paneflow-app"
if ($null -eq $AppPackage) {
    throw "Cargo metadata 中缺少 paneflow-app"
}

$TreeText = Invoke-CargoText -Arguments @(
    "tree", "-p", "paneflow-app", "--target", $Target, "--depth", "1",
    "-e", "normal,build", "--prefix", "none", "--locked"
)

$DirectInternal = @(
    $AppPackage.dependencies |
        Where-Object { $_.name -like "paneflow-*" -and ($null -eq $_.kind -or $_.kind -eq "normal") } |
        ForEach-Object name |
        Sort-Object -Unique
)
$ExpectedDirect = @(
    "paneflow-acp",
    "paneflow-config",
    "paneflow-ipc-client",
    "paneflow-mcp-install",
    "paneflow-process",
    "paneflow-telemetry"
)
$DirectDiff = Compare-Object -ReferenceObject $ExpectedDirect -DifferenceObject $DirectInternal
if ($null -ne $DirectDiff) {
    throw "paneflow-app 默认内部直接依赖发生变化：$($DirectDiff | Out-String)"
}

$TrackedPackages = @(
    "paneflow-ai-hook",
    "paneflow-mcp",
    "paneflow-mcp-install",
    "paneflow-shim",
    "paneflow-ipc-client",
    "paneflow-telemetry",
    "paneflow-process"
)
$EmbeddedNames = @("paneflow-shim", "paneflow-ai-hook", "paneflow-mcp")
$Tracked = foreach ($Name in $TrackedPackages) {
    $Package = $Metadata.packages | Where-Object name -eq $Name
    if ($null -eq $Package) {
        throw "Cargo workspace 缺少受审查包：$Name"
    }
    $Linked = $TreeText -match "(?m)^$([regex]::Escape($Name)) v"
    $Embedded = $Name -in $EmbeddedNames
    if ($Embedded) {
        Test-FileMarker -RelativePath "src-app/build.rs" -Marker ".arg(`"$Name`")" | Out-Null
    }
    [ordered]@{
        name = $Name
        targetKinds = @($Package.targets | ForEach-Object { $_.kind } | ForEach-Object { $_ })
        linkedToDesktop = $Linked
        builtAndEmbeddedByDesktopBuildScript = $Embedded
    }
}

# WiX 是 Windows 安装载荷的最终声明，不能只根据 release workflow 的复制循环推断。
[xml]$Wix = Get-Content -LiteralPath (Join-Path $RepositoryRoot "packaging/wix/main.wxs") -Raw
$Namespace = New-Object Xml.XmlNamespaceManager($Wix.NameTable)
$Namespace.AddNamespace("w", "http://schemas.microsoft.com/wix/2006/wi")
$PackagedHelpers = @(
    $Wix.SelectNodes("//w:Component[@Id='HelperBinaries']/w:File", $Namespace) |
        ForEach-Object { $_.Name } |
        Sort-Object
)
if ($PackagedHelpers.Count -ne 17) {
    throw "Windows MSI helper 数量应为 17，实际为 $($PackagedHelpers.Count)"
}

$EvidenceContracts = @(
    [ordered]@{
        id = "desktop-build-script"
        passed = Test-FileMarker "src-app/Cargo.toml" 'name = "agent-workspace"'
    },
    [ordered]@{
        id = "embedded-binaries"
        passed = Test-FileMarker "src-app/build.rs" "stage_ai_hook_binaries"
    },
    [ordered]@{
        id = "runtime-extraction"
        passed = Test-FileMarker "src-app/src/ai_hooks/extract.rs" "ensure_binaries_extracted"
    },
    [ordered]@{
        id = "ipc-server"
        passed = Test-FileMarker "src-app/src/main.rs" "mod ipc;"
    },
    [ordered]@{
        id = "telemetry-runtime"
        passed = Test-FileMarker "src-app/src/app/bootstrap.rs" "spawn_telemetry_flusher"
    },
    [ordered]@{
        id = "updater-runtime"
        passed = Test-FileMarker "src-app/src/main.rs" "mod update;"
    },
    [ordered]@{
        id = "windows-release-helper-preparation"
        passed = Test-FileMarker ".github/workflows/release.yml" '$packagedHelperDir'
    },
    [ordered]@{
        id = "windows-portable-helper-list"
        passed = Test-FileMarker "scripts/生成Windows便携包.ps1" '$HelperNames'
    }
)

$FeatureNames = @($AppPackage.features.PSObject.Properties.Name | Sort-Object)
$Report = [ordered]@{
    schemaVersion = 1
    target = $Target
    desktopPackage = $AppPackage.name
    desktopBinary = @($AppPackage.targets | Where-Object { "bin" -in $_.kind } | ForEach-Object name)
    desktopBuildScript = @(
        $AppPackage.targets | Where-Object { "custom-build" -in $_.kind } | ForEach-Object src_path
    )
    declaredFeatures = $FeatureNames
    defaultFeatureDeclared = "default" -in $FeatureNames
    directInternalDependencies = $DirectInternal
    trackedPackages = @($Tracked)
    embeddedBinaries = $EmbeddedNames
    packagedWindowsHelpers = $PackagedHelpers
    evidenceContracts = $EvidenceContracts
    result = "passed"
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
Write-Output "A011 默认构建依赖图生成通过：$($Tracked.Count) 个重点包，$($PackagedHelpers.Count) 个 Windows helper"
