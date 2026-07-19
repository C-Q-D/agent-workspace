#!/usr/bin/env python3
"""从锁定的 Cargo 依赖图确定性生成第三方 Rust 许可证清单。

脚本只读取 ``Cargo.lock`` 和 ``cargo metadata --locked`` 的真实结果，不访问
crates.io API，也不根据包名猜测许可证。工作区自身包会按 Cargo 返回的
``workspace_members`` 精确排除，剩余依赖按稳定键排序后同时写入 JSON 和中文
Markdown，便于机器门禁和开源用户复核。
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from fnmatch import fnmatch
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
EXPECTED_PACKAGE_COUNT = 1109

# 这三个固定 Zed crate 的 Cargo.toml 没有 license 字段，但各自目录包含明确的许可证指针。
# 以包名、版本和完整 Git 来源三元组绑定，可避免上游 revision 变化后继续套用旧结论。
ZED_SOURCE = (
    "git+https://github.com/arthjean/zed?"
    "rev=3aaba57b95c22f4d21bbbf9f4b10b513173209db#"
    "3aaba57b95c22f4d21bbbf9f4b10b513173209db"
)
LICENSE_CLARIFICATIONS = {
    ("gpui_shared_string", "0.1.0", ZED_SOURCE): {
        "license": "Apache-2.0",
        "evidence": "crates/gpui_shared_string/LICENSE-APACHE → ../../LICENSE-APACHE",
        "source_license_file": "LICENSE-APACHE",
        "source_license_target": "../../LICENSE-APACHE",
        "note": "固定 Zed 源码目录提供 crate 级 Apache 许可证指针。",
    },
    ("gpui_util", "0.1.0", ZED_SOURCE): {
        "license": "Apache-2.0",
        "evidence": "crates/gpui_util/LICENSE-APACHE → ../../LICENSE-APACHE",
        "source_license_file": "LICENSE-APACHE",
        "source_license_target": "../../LICENSE-APACHE",
        "note": "固定 Zed 源码目录提供 crate 级 Apache 许可证指针。",
    },
    ("language_core", "0.1.0", ZED_SOURCE): {
        "license": "GPL-3.0-or-later",
        "evidence": "crates/language_core/LICENSE-GPL → ../../LICENSE-GPL",
        "source_license_file": "LICENSE-GPL",
        "source_license_target": "../../LICENSE-GPL",
        "note": "固定 Zed 源码目录提供 crate 级 GPL 许可证指针；Zed 官方许可说明标注 GPL-3.0-or-later。",
    },
}


def sha256(path: Path) -> str:
    """返回文件 SHA-256，作为依赖清单对应锁文件的稳定指纹。"""

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_cargo_metadata(repo_root: Path) -> dict[str, Any]:
    """读取锁定依赖图；Cargo 失败或输出无效 JSON 时直接终止生成。"""

    completed = subprocess.run(
        ["cargo", "metadata", "--locked", "--format-version", "1"],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    metadata = json.loads(completed.stdout)
    if not isinstance(metadata.get("packages"), list):
        raise ValueError("Cargo metadata 缺少 packages 数组")
    if not isinstance(metadata.get("workspace_members"), list):
        raise ValueError("Cargo metadata 缺少 workspace_members 数组")
    return metadata


def normalize_package(package: dict[str, Any]) -> dict[str, str | None]:
    """保留发布审查需要的稳定字段，不写入本机 Cargo 缓存绝对路径。"""

    return {
        "name": package["name"],
        "version": package["version"],
        "source": package.get("source"),
        "repository": package.get("repository"),
        "license": package.get("license"),
        "license_file": package.get("license_file"),
    }


def validate_clarification_evidence(
    package: dict[str, Any], clarification: dict[str, str]
) -> None:
    """验证固定 Cargo checkout 内的 crate 级许可证指针确实存在且目标一致。"""

    crate_root = Path(package["manifest_path"]).parent
    license_path = crate_root / clarification["source_license_file"]
    if not license_path.is_file():
        raise ValueError(f"澄清证据文件不存在：{license_path}")

    # Git 在 Windows 上会把仓库内的相对符号链接检出为文本；本项目只承诺 Windows，
    # 因此直接校验指针内容可以同时阻止文件名或目标在固定 revision 中漂移。
    target = license_path.read_text(encoding="utf-8").strip().replace("\\", "/")
    if target != clarification["source_license_target"]:
        raise ValueError(
            f"澄清证据目标发生变化：{license_path}，"
            f"期望 {clarification['source_license_target']}，实际 {target}"
        )


def validate_clarification_keys(
    missing_keys: set[tuple[str, str, str | None]],
) -> None:
    """要求实际缺失元数据集合与固定人工澄清集合完全一致。"""

    clarification_keys = set(LICENSE_CLARIFICATIONS)
    if missing_keys != clarification_keys:
        unknown = sorted(missing_keys - clarification_keys)
        stale = sorted(clarification_keys - missing_keys)
        raise ValueError(
            "许可证元数据澄清集合发生漂移："
            f"新增未澄清项 {unknown}；失效澄清项 {stale}"
        )


def build_inventory(repo_root: Path) -> dict[str, Any]:
    """构建第三方包清单，并校验当前锁定图没有意外缩减或扩张。"""

    metadata = load_cargo_metadata(repo_root)
    workspace_members = set(metadata["workspace_members"])
    third_party_packages = [
        package
        for package in metadata["packages"]
        if package["id"] not in workspace_members
    ]
    packages = [normalize_package(package) for package in third_party_packages]
    packages.sort(
        key=lambda package: (
            package["name"] or "",
            package["version"] or "",
            package["source"] or "",
        )
    )

    if len(packages) != EXPECTED_PACKAGE_COUNT:
        raise ValueError(
            "第三方 Rust 包数量发生变化："
            f"期望 {EXPECTED_PACKAGE_COUNT}，实际 {len(packages)}；"
            "请先审查 Cargo.lock 变更并更新许可证基线"
        )

    missing_metadata = [
        package
        for package in packages
        if not package["license"] and not package["license_file"]
    ]
    missing_keys = {
        (package["name"], package["version"], package["source"])
        for package in missing_metadata
    }
    validate_clarification_keys(missing_keys)

    for package in missing_metadata:
        key = (package["name"], package["version"], package["source"])
        clarification = LICENSE_CLARIFICATIONS[key]
        raw_package = next(
            candidate
            for candidate in third_party_packages
            if (
                candidate["name"],
                candidate["version"],
                candidate["source"],
            )
            == key
        )
        validate_clarification_evidence(raw_package, clarification)
        package["clarification"] = clarification

    return {
        "schema_version": SCHEMA_VERSION,
        "cargo_lock_sha256": sha256(repo_root / "Cargo.lock"),
        "package_count": len(packages),
        "upstream_missing_metadata_count": len(missing_metadata),
        "clarified_metadata_count": len(missing_metadata),
        "unresolved_metadata_count": 0,
        "packages": packages,
    }


def markdown_cell(value: str | None) -> str:
    """转义 Markdown 表格中的分隔符，并统一表示缺失元数据。"""

    if not value:
        return "—"
    return value.replace("|", "\\|").replace("\n", " ")


def render_markdown(inventory: dict[str, Any]) -> str:
    """把机器清单渲染为面向开源用户的中文可读表格。"""

    lines = [
        "# 第三方 Rust 依赖许可证清单",
        "",
        "> 本文件由 `scripts/生成第三方许可证清单.py` 从锁定依赖图确定性生成，请勿手工修改。",
        "",
        f"- Cargo.lock SHA-256：`{inventory['cargo_lock_sha256']}`",
        f"- 第三方包数量：{inventory['package_count']}",
        f"- 上游缺少许可证元数据：{inventory['upstream_missing_metadata_count']}",
        f"- 已精确人工澄清：{inventory['clarified_metadata_count']}",
        f"- 尚未澄清：{inventory['unresolved_metadata_count']}",
        "",
    ]
    clarified_packages = [
        package for package in inventory["packages"] if package.get("clarification")
    ]
    if clarified_packages:
        lines.extend(
            [
                "以下包的 Cargo 元数据缺少许可证字段，已按固定源码 revision 中的 crate 级许可证文件澄清：",
                "",
                *[
                    f"- `{package['name']} {package['version']}`："
                    f"`{package['clarification']['license']}`；"
                    f"{package['clarification']['evidence']}"
                    for package in clarified_packages
                ],
                "",
            ]
        )

    lines.extend(
        [
            "| 包 | 版本 | 许可证 | 许可证文件 | 来源 | 仓库 |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
    )
    for package in inventory["packages"]:
        clarification = package.get("clarification")
        license_value = package["license"]
        license_file_value = package["license_file"]
        if clarification:
            license_value = f"{clarification['license']}（人工澄清）"
            license_file_value = clarification["evidence"]
        lines.append(
            "| "
            + " | ".join(
                (
                    markdown_cell(package["name"]),
                    markdown_cell(package["version"]),
                    markdown_cell(license_value),
                    markdown_cell(license_file_value),
                    markdown_cell(package["source"]),
                    markdown_cell(package["repository"]),
                )
            )
            + " |"
        )
    lines.append("")
    return "\n".join(lines)


def validate_asset_inventory(repo_root: Path, assets: dict[str, Any]) -> dict[str, Any]:
    """验证第三方字体登记，确保字体文件不存在遗漏或重复归属。"""

    if assets.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("第三方资产清单 schema_version 不受支持")

    font_root = repo_root / "src-app" / "assets" / "fonts"
    actual_fonts = {
        path.relative_to(repo_root).as_posix() for path in font_root.glob("*.ttf")
    }
    matched_fonts: dict[str, str] = {}
    for asset in assets.get("assets", []):
        license_path = repo_root / asset["license_file"]
        if not license_path.is_file():
            raise ValueError(f"第三方资产缺少许可证文件：{asset['license_file']}")
        matches = {
            path for path in actual_fonts if any(fnmatch(path, pattern) for pattern in asset["files"])
        }
        if not matches:
            raise ValueError(f"第三方资产模式没有匹配文件：{asset['id']}")
        for path in matches:
            if path in matched_fonts:
                raise ValueError(
                    f"字体文件重复登记：{path} 同时属于 {matched_fonts[path]} 和 {asset['id']}"
                )
            matched_fonts[path] = asset["id"]

    missing_fonts = sorted(actual_fonts - set(matched_fonts))
    if missing_fonts:
        raise ValueError(f"存在未登记的第三方字体：{missing_fonts}")
    assets["font_file_count"] = len(actual_fonts)
    return assets


def load_asset_inventory(repo_root: Path) -> dict[str, Any]:
    """从版本化 JSON 读取资产登记，再执行真实文件完整性验证。"""

    asset_path = repo_root / "docs" / "许可证" / "第三方资产.json"
    assets = json.loads(asset_path.read_text(encoding="utf-8"))
    return validate_asset_inventory(repo_root, assets)


def render_asset_markdown(assets: dict[str, Any]) -> str:
    """把字体资产登记渲染为中文清单，并保留完整许可证文件路径。"""

    lines = [
        "# 第三方资产许可证清单",
        "",
        "> 本文件由 `scripts/生成第三方许可证清单.py` 校验并生成，请勿手工修改。",
        "",
        f"- 已登记字体文件：{assets['font_file_count']}",
        f"- 字体家族：{len(assets['assets'])}",
        "",
        "| 资产 | 许可证 | 许可证文件 | 来源 | 文件模式 |",
        "| --- | --- | --- | --- | --- |",
    ]
    for asset in assets["assets"]:
        lines.append(
            "| "
            + " | ".join(
                (
                    markdown_cell(asset["name"]),
                    markdown_cell(asset["license"]),
                    markdown_cell(asset["license_file"]),
                    markdown_cell(asset["source"]),
                    markdown_cell("、".join(asset["files"])),
                )
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "## 视觉资产边界",
            "",
            "- AgentWorkspace 主图标由本项目生成，不属于第三方资产；生成源和过程保存在 `assets/icons/master/` 与 `scripts/生成Windows图标资产.py`。",
            "- 其余从 Paneflow 基线继承的界面图标与示例图片随上游源码和根 `LICENSE` 保留；Agent、编辑器和服务名称及标志的商标权仍归各自权利人，清单不主张商标授权。",
            "",
        ]
    )
    return "\n".join(lines)


def write_inventory(
    repo_root: Path, inventory: dict[str, Any], assets: dict[str, Any]
) -> tuple[Path, Path, Path]:
    """以固定编码和换行写入 Rust JSON、Rust Markdown 与资产 Markdown。"""

    output_dir = repo_root / "docs" / "许可证"
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "第三方Rust依赖.json"
    markdown_path = output_dir / "第三方Rust依赖清单.md"
    asset_markdown_path = output_dir / "第三方资产清单.md"
    json_text = json.dumps(inventory, ensure_ascii=False, indent=2) + "\n"
    json_path.write_text(json_text, encoding="utf-8", newline="\n")
    markdown_path.write_text(
        render_markdown(inventory), encoding="utf-8", newline="\n"
    )
    asset_markdown_path.write_text(
        render_asset_markdown(assets), encoding="utf-8", newline="\n"
    )
    return json_path, markdown_path, asset_markdown_path


def check_inventory(repo_root: Path, inventory: dict[str, Any], assets: dict[str, Any]) -> None:
    """只读比较版本化产物；任何锁文件、生成逻辑或人工编辑漂移都会失败。"""

    output_dir = repo_root / "docs" / "许可证"
    expected_outputs = {
        output_dir / "第三方Rust依赖.json": json.dumps(
            inventory, ensure_ascii=False, indent=2
        )
        + "\n",
        output_dir / "第三方Rust依赖清单.md": render_markdown(inventory),
        output_dir / "第三方资产清单.md": render_asset_markdown(assets),
    }
    mismatches = []
    for path, expected in expected_outputs.items():
        if not path.is_file() or path.read_text(encoding="utf-8") != expected:
            mismatches.append(path.relative_to(repo_root).as_posix())
    if mismatches:
        raise ValueError(
            "许可证生成产物已漂移，请审查依赖或资产变化后重新生成："
            + "，".join(mismatches)
        )


def main() -> int:
    """生成或只读检查清单，并输出足够精简的校验摘要。"""

    repo_root = Path(__file__).resolve().parent.parent
    arguments = sys.argv[1:]
    if arguments not in ([], ["--check"]):
        raise ValueError("仅支持无参数生成，或使用 --check 执行只读门禁")
    inventory = build_inventory(repo_root)
    assets = load_asset_inventory(repo_root)
    if arguments == ["--check"]:
        check_inventory(repo_root, inventory, assets)
        print("第三方许可证清单只读检查通过")
        print(f"第三方 Rust 包：{inventory['package_count']} 个")
        print(f"第三方字体：{assets['font_file_count']} 个文件")
        return 0

    json_path, markdown_path, asset_markdown_path = write_inventory(repo_root, inventory, assets)
    print(f"已生成第三方 Rust 依赖清单：{inventory['package_count']} 个包")
    print(
        "上游缺少但已精确澄清许可证元数据："
        f"{inventory['clarified_metadata_count']} 个包"
    )
    print(f"已登记第三方字体：{assets['font_file_count']} 个文件")
    print(f"JSON：{json_path}")
    print(f"Markdown：{markdown_path}")
    print(f"资产清单：{asset_markdown_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        FileNotFoundError,
        KeyError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"生成第三方许可证清单失败：{error}", file=sys.stderr)
        raise SystemExit(1) from error
