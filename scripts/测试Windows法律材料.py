#!/usr/bin/env python3
"""使用真实仓库文件验证 Windows 法律材料、WiX 引用和发布门禁。"""

from __future__ import annotations

import importlib.util
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR_PATH = REPO_ROOT / "scripts" / "生成Windows法律材料.py"
SPEC = importlib.util.spec_from_file_location("windows_legal_materials", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载 Windows 法律材料生成器：{GENERATOR_PATH}")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class WindowsLegalMaterialsTests(unittest.TestCase):
    """验证发布目录内容、GPL RTF、WiX 文件表和工作流入口。"""

    @classmethod
    def setUpClass(cls) -> None:
        """从真实源文件计算期望输出，并要求版本化产物零漂移。"""

        cls.outputs = GENERATOR.expected_outputs(REPO_ROOT)
        GENERATOR.check_outputs(REPO_ROOT, cls.outputs)

    def test_release_materials_are_byte_exact_copies(self) -> None:
        """五份发布材料必须与根许可证及已验收清单逐字节一致。"""

        legal_dir = REPO_ROOT / "packaging" / "windows" / "legal"
        for output_name, source_name in GENERATOR.COPY_INPUTS.items():
            self.assertEqual(
                (legal_dir / output_name).read_bytes(),
                (REPO_ROOT / source_name).read_bytes(),
            )

    def test_wix_license_is_gpl_not_historical_mit(self) -> None:
        """安装向导必须显示 GPL v3，不能继续显示历史 MIT 文本。"""

        content = (REPO_ROOT / "packaging" / "wix" / "License.rtf").read_bytes()
        GENERATOR.validate_license_rtf(content)

    def test_wix_installs_every_legal_material(self) -> None:
        """WiX LegalMaterials 组件必须安装全部五份发布材料。"""

        namespace = {"w": "http://schemas.microsoft.com/wix/2006/wi"}
        root = ET.parse(REPO_ROOT / "packaging" / "wix" / "main.wxs").getroot()
        files = {
            element.attrib["Source"].replace("\\", "/")
            for element in root.findall(".//w:Component[@Id='LegalMaterials']/w:File", namespace)
        }
        expected = {
            f"packaging/windows/legal/{name}" for name in GENERATOR.COPY_INPUTS
        }
        self.assertEqual(files, expected)
        installed_names = {
            element.attrib["Name"]
            for element in root.findall(".//w:Component[@Id='LegalMaterials']/w:File", namespace)
        }
        self.assertEqual(
            installed_names,
            {
                "LICENSE.txt",
                "UPSTREAM-NOTICE.md",
                "THIRD-PARTY-RUST.md",
                "THIRD-PARTY-RUST.json",
                "THIRD-PARTY-ASSETS.md",
            },
        )
        component_refs = {
            element.attrib["Id"]
            for element in root.findall(".//w:Feature/w:ComponentRef", namespace)
        }
        self.assertIn("LegalMaterials", component_refs)

    def test_release_workflow_runs_read_only_gate(self) -> None:
        """Windows 发布构建前必须执行法律材料只读门禁。"""

        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("python scripts/生成Windows法律材料.py --check", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
