#!/usr/bin/env python3
"""从 AgentWorkspace 透明主图确定性生成 Windows 图标资产。

该脚本只负责 Windows 使用的 PNG 与 ICO，不修改 macOS/Linux 图标。
输入主图必须是 1024×1024 RGBA PNG；任何不符合约定的输入都会直接失败，
避免发布流程静默生成裁切、变形或缺少透明通道的应用图标。
"""

from __future__ import annotations

import hashlib
import shutil
import sys
from pathlib import Path

from PIL import Image


# Windows Shell 会按显示比例请求不同尺寸；补齐常用 DPI 档位可避免运行时缩放发糊。
PNG_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256, 512)
# ICO 保留 256 以下的完整尺寸层级，兼容 Explorer、任务栏和旧控制面板。
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def sha256(path: Path) -> str:
    """返回文件 SHA-256，用于验证 WiX 镜像与主 ICO 完全一致。"""

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_master(image: Image.Image, master_path: Path) -> None:
    """校验主图尺寸、颜色模式和透明安全边距，不接受隐式降级。"""

    if image.size != (1024, 1024):
        raise ValueError(f"主图必须为 1024×1024，当前为 {image.size}: {master_path}")
    if image.mode != "RGBA":
        raise ValueError(f"主图必须为 RGBA，当前为 {image.mode}: {master_path}")

    alpha = image.getchannel("A")
    alpha_min, alpha_max = alpha.getextrema()
    if (alpha_min, alpha_max) != (0, 255):
        raise ValueError("主图必须同时包含完全透明与完全不透明像素")

    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError("主图没有任何可见像素")
    left, top, right, bottom = bbox
    minimum_margin = 64
    margins = (left, top, 1024 - right, 1024 - bottom)
    if min(margins) < minimum_margin:
        raise ValueError(f"主图安全边距不足 {minimum_margin}px，当前边距为 {margins}")


def save_pngs(image: Image.Image, icons_dir: Path) -> None:
    """使用高质量重采样生成各尺寸 PNG，并保留透明通道。"""

    for size in PNG_SIZES:
        resized = image.resize((size, size), Image.Resampling.LANCZOS)
        output = icons_dir / f"agent-workspace-{size}.png"
        resized.save(output, format="PNG", optimize=True)

    # 128px 是 GPUI 运行时和不带尺寸资源路径的稳定折中。
    shutil.copyfile(
        icons_dir / "agent-workspace-128.png",
        icons_dir / "agent-workspace.png",
    )


def save_ico(image: Image.Image, ico_path: Path) -> None:
    """生成包含全部 Windows 常用尺寸的单个 ICO 容器。"""

    image.save(
        ico_path,
        format="ICO",
        sizes=[(size, size) for size in ICO_SIZES],
        bitmap_format="bmp",
    )


def validate_outputs(ico_path: Path, wix_ico_path: Path) -> None:
    """验证 ICO 尺寸层级与 WiX 镜像一致性。"""

    with Image.open(ico_path) as icon:
        sizes = sorted(icon.ico.sizes())
    expected = sorted((size, size) for size in ICO_SIZES)
    if sizes != expected:
        raise ValueError(f"ICO 尺寸层级不完整：期望 {expected}，实际 {sizes}")
    if sha256(ico_path) != sha256(wix_ico_path):
        raise ValueError("WiX ICO 与主 ICO 字节不一致")


def main() -> int:
    """解析仓库路径、生成全部 Windows 图标并执行输出校验。"""

    repo_root = Path(__file__).resolve().parent.parent
    master_path = repo_root / "assets/icons/master/agent-workspace-icon-1024.png"
    icons_dir = repo_root / "assets/icons"
    ico_path = repo_root / "assets/AgentWorkspace.ico"
    wix_ico_path = repo_root / "packaging/wix/agent-workspace.ico"
    runtime_icon_path = repo_root / "src-app/assets/icons/agent-workspace.png"

    if not master_path.is_file():
        raise FileNotFoundError(f"缺少 AgentWorkspace 图标主图：{master_path}")

    icons_dir.mkdir(parents=True, exist_ok=True)
    ico_path.parent.mkdir(parents=True, exist_ok=True)
    wix_ico_path.parent.mkdir(parents=True, exist_ok=True)
    runtime_icon_path.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(master_path) as source:
        image = source.convert("RGBA")
    validate_master(image, master_path)
    save_pngs(image, icons_dir)
    save_ico(image, ico_path)
    shutil.copyfile(ico_path, wix_ico_path)
    shutil.copyfile(icons_dir / "agent-workspace-128.png", runtime_icon_path)
    validate_outputs(ico_path, wix_ico_path)

    print(f"已生成 AgentWorkspace Windows 图标：{ico_path}")
    print(f"ICO 尺寸：{', '.join(str(size) for size in ICO_SIZES)}")
    print(f"SHA-256：{sha256(ico_path)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, ValueError, OSError) as error:
        print(f"生成 Windows 图标失败：{error}", file=sys.stderr)
        raise SystemExit(1) from error
