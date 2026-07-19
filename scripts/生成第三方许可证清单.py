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
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
EXPECTED_PACKAGE_COUNT = 1109


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


def build_inventory(repo_root: Path) -> dict[str, Any]:
    """构建第三方包清单，并校验当前锁定图没有意外缩减或扩张。"""

    metadata = load_cargo_metadata(repo_root)
    workspace_members = set(metadata["workspace_members"])
    packages = [
        normalize_package(package)
        for package in metadata["packages"]
        if package["id"] not in workspace_members
    ]
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

    unresolved = [
        f"{package['name']} {package['version']}"
        for package in packages
        if not package["license"] and not package["license_file"]
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "cargo_lock_sha256": sha256(repo_root / "Cargo.lock"),
        "package_count": len(packages),
        "unresolved_metadata_count": len(unresolved),
        "unresolved_metadata": unresolved,
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
        f"- 缺少上游许可证元数据：{inventory['unresolved_metadata_count']}",
        "",
    ]
    if inventory["unresolved_metadata"]:
        lines.extend(
            [
                "缺少元数据的包会在后续人工澄清表中精确登记；本清单不猜测 SPDX 表达式：",
                "",
                *[f"- `{item}`" for item in inventory["unresolved_metadata"]],
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
        lines.append(
            "| "
            + " | ".join(
                markdown_cell(package[field])
                for field in (
                    "name",
                    "version",
                    "license",
                    "license_file",
                    "source",
                    "repository",
                )
            )
            + " |"
        )
    lines.append("")
    return "\n".join(lines)


def write_inventory(repo_root: Path, inventory: dict[str, Any]) -> tuple[Path, Path]:
    """以固定编码和换行写入 JSON、Markdown 两种发布审查产物。"""

    output_dir = repo_root / "docs" / "许可证"
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "第三方Rust依赖.json"
    markdown_path = output_dir / "第三方Rust依赖清单.md"
    json_text = json.dumps(inventory, ensure_ascii=False, indent=2) + "\n"
    json_path.write_text(json_text, encoding="utf-8", newline="\n")
    markdown_path.write_text(
        render_markdown(inventory), encoding="utf-8", newline="\n"
    )
    return json_path, markdown_path


def main() -> int:
    """生成清单并输出足够精简的校验摘要。"""

    repo_root = Path(__file__).resolve().parent.parent
    inventory = build_inventory(repo_root)
    json_path, markdown_path = write_inventory(repo_root, inventory)
    print(f"已生成第三方 Rust 依赖清单：{inventory['package_count']} 个包")
    print(f"缺少上游许可证元数据：{inventory['unresolved_metadata_count']} 个包")
    print(f"JSON：{json_path}")
    print(f"Markdown：{markdown_path}")
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
