#!/usr/bin/env python3
"""验证第三方许可证清单的真实输入与关键失败门禁。

测试直接读取当前 Cargo.lock、Cargo metadata、Zed 固定 checkout、字体和版本化
清单；失败场景只在内存中改变从真实输入复制出的集合，不写入项目文件。
"""

from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATOR_PATH = REPO_ROOT / "scripts" / "生成第三方许可证清单.py"
SPEC = importlib.util.spec_from_file_location("third_party_license_inventory", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载许可证生成器：{GENERATOR_PATH}")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class LicenseInventoryTests(unittest.TestCase):
    """覆盖真实清单、未知依赖、来源漂移和资产遗漏四类门禁。"""

    @classmethod
    def setUpClass(cls) -> None:
        """只读取一次真实 Cargo 图，避免每个用例重复启动 Cargo。"""

        cls.inventory = GENERATOR.build_inventory(REPO_ROOT)
        cls.assets = GENERATOR.load_asset_inventory(REPO_ROOT)

    def test_real_locked_inventory_is_complete(self) -> None:
        """真实锁定图必须包含 1109 个第三方包且没有未澄清项。"""

        self.assertEqual(self.inventory["package_count"], 1109)
        self.assertEqual(self.inventory["clarified_metadata_count"], 3)
        self.assertEqual(self.inventory["unresolved_metadata_count"], 0)
        GENERATOR.check_inventory(REPO_ROOT, self.inventory, self.assets)

    def test_unknown_missing_package_is_rejected(self) -> None:
        """真实澄清集合中新增未知包时必须失败。"""

        keys = set(GENERATOR.LICENSE_CLARIFICATIONS)
        keys.add(("new_unknown_package", "1.0.0", "registry+https://example.invalid"))
        with self.assertRaisesRegex(ValueError, "新增未澄清项"):
            GENERATOR.validate_clarification_keys(keys)

    def test_clarified_source_revision_drift_is_rejected(self) -> None:
        """已澄清包的 Git revision 改变后不能继续沿用旧许可证结论。"""

        keys = set(GENERATOR.LICENSE_CLARIFICATIONS)
        original = next(key for key in keys if key[0] == "language_core")
        keys.remove(original)
        keys.add((original[0], original[1], str(original[2]).replace("3aaba57", "deadbee")))
        with self.assertRaisesRegex(ValueError, "新增未澄清项"):
            GENERATOR.validate_clarification_keys(keys)

    def test_unregistered_real_font_is_rejected(self) -> None:
        """从真实资产登记中移除一个家族后，剩余真实字体必须触发遗漏失败。"""

        assets = copy.deepcopy(self.assets)
        assets["assets"] = [
            asset for asset in assets["assets"] if asset["id"] != "font-lilex"
        ]
        with self.assertRaisesRegex(ValueError, "未登记的第三方字体"):
            GENERATOR.validate_asset_inventory(REPO_ROOT, assets)


if __name__ == "__main__":
    unittest.main(verbosity=2)
