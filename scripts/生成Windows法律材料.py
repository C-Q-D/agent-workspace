#!/usr/bin/env python3
"""确定性生成并检查 Windows 发布与 WiX 使用的法律材料。

发布目录只镜像仓库内已经验收的单一事实源，不重新解释许可证。WiX 的
``License.rtf`` 由根 GPL 文本生成，避免安装向导继续显示历史遗留的 MIT 文本。
``--check`` 只读比较全部字节，适合在本地和发布工作流中阻断材料漂移。
"""

from __future__ import annotations

import sys
from pathlib import Path


# 输出名称同时是 WiX 安装后的文件名；LICENSE 保留开源生态惯例，其余文档使用中文。
COPY_INPUTS = {
    "LICENSE.txt": "LICENSE",
    "上游归属与修改说明.md": "上游归属与修改说明.md",
    "第三方Rust依赖清单.md": "docs/许可证/第三方Rust依赖清单.md",
    "第三方Rust依赖.json": "docs/许可证/第三方Rust依赖.json",
    "第三方资产清单.md": "docs/许可证/第三方资产清单.md",
}


def rtf_escape(text: str) -> str:
    """把 Unicode 文本转换为 WiX v3 可读取的 ASCII RTF 内容。"""

    output: list[str] = []
    for character in text:
        if character == "\n":
            output.append("\\par\n")
        elif character == "\r":
            continue
        elif character in "\\{}":
            output.append("\\" + character)
        elif 32 <= ord(character) <= 126:
            output.append(character)
        else:
            # RTF \u 使用带符号 16 位数；按 UTF-16 单元展开可正确处理非 BMP 字符。
            for offset in range(0, len(character.encode("utf-16-le")), 2):
                unit = int.from_bytes(
                    character.encode("utf-16-le")[offset : offset + 2], "little"
                )
                signed = unit if unit < 32768 else unit - 65536
                output.append(f"\\u{signed}?")
    return "".join(output)


def render_license_rtf(license_text: str) -> bytes:
    """将根 GPL 文本包装成安装向导可滚动显示的最小 RTF 文档。"""

    header = (
        r"{\rtf1\ansi\deff0\nouicompat"
        r"{\fonttbl{\f0\fnil\fcharset0 Segoe UI;}{\f1\fmodern\fcharset0 Consolas;}}"
        "\n"
        r"\viewkind4\uc1\pard\f1\fs18 "
    )
    return (header + rtf_escape(license_text) + "}\n").encode("ascii")


def expected_outputs(repo_root: Path) -> dict[Path, bytes]:
    """读取真实源文件并返回所有 Windows 法律材料的期望字节。"""

    legal_dir = repo_root / "packaging" / "windows" / "legal"
    outputs: dict[Path, bytes] = {}
    for output_name, source_name in COPY_INPUTS.items():
        source = repo_root / source_name
        if not source.is_file():
            raise FileNotFoundError(f"Windows 法律材料缺少源文件：{source}")
        outputs[legal_dir / output_name] = source.read_bytes()

    license_text = (repo_root / "LICENSE").read_text(encoding="utf-8")
    outputs[repo_root / "packaging" / "wix" / "License.rtf"] = render_license_rtf(
        license_text
    )
    return outputs


def validate_license_rtf(content: bytes) -> None:
    """阻止历史 MIT 文本或损坏的 GPL 标题重新进入安装向导。"""

    text = content.decode("ascii")
    if "GNU GENERAL PUBLIC LICENSE" not in text or "Version 3, 29 June 2007" not in text:
        raise ValueError("WiX License.rtf 没有包含完整 GPL v3 标题")
    if "Permission is hereby granted, free of charge" in text:
        raise ValueError("WiX License.rtf 仍包含历史 MIT 许可证文本")


def write_outputs(outputs: dict[Path, bytes]) -> None:
    """创建目标目录并写入确定性字节，不保留时间戳等易漂移元数据。"""

    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


def check_outputs(repo_root: Path, outputs: dict[Path, bytes]) -> None:
    """只读检查全部版本化产物与单一事实源完全一致。"""

    mismatches = [
        path.relative_to(repo_root).as_posix()
        for path, expected in outputs.items()
        if not path.is_file() or path.read_bytes() != expected
    ]
    if mismatches:
        raise ValueError(
            "Windows 法律材料已漂移，请重新生成并审查：" + "，".join(mismatches)
        )


def main() -> int:
    """生成或只读检查 Windows 法律材料。"""

    arguments = sys.argv[1:]
    if arguments not in ([], ["--check"]):
        raise ValueError("仅支持无参数生成，或使用 --check 执行只读门禁")

    repo_root = Path(__file__).resolve().parent.parent
    outputs = expected_outputs(repo_root)
    validate_license_rtf(outputs[repo_root / "packaging" / "wix" / "License.rtf"])
    if arguments == ["--check"]:
        check_outputs(repo_root, outputs)
        print(f"Windows 法律材料只读检查通过：{len(outputs)} 个文件")
        return 0

    write_outputs(outputs)
    check_outputs(repo_root, outputs)
    print(f"已生成 Windows 法律材料：{len(outputs)} 个文件")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, OSError, UnicodeError, ValueError) as error:
        print(f"生成 Windows 法律材料失败：{error}", file=sys.stderr)
        raise SystemExit(1) from error
