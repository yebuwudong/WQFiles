import json
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");$')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:lld|llu|lu|ld|[dio@a-zA-Z])')


def read_table(path: Path) -> dict[str, str]:
    entries = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("/*"):
            continue
        match = ENTRY.match(line)
        if not match:
            raise AssertionError(f"{path.name}:{line_number}: malformed .strings entry")
        key = json.loads(match.group(1))
        value = json.loads(match.group(2))
        if key in entries:
            raise AssertionError(f"{path.name}:{line_number}: duplicate key {key!r}")
        entries[key] = value
    return entries


class LocalizationTests(unittest.TestCase):
    def test_language_tables_have_identical_keys(self):
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        self.assertEqual(set(english), set(chinese))
        self.assertGreater(len(chinese), 600)

    def test_placeholders_are_preserved(self):
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        for key, value in chinese.items():
            self.assertEqual(PLACEHOLDER.findall(key), PLACEHOLDER.findall(value), key)

    def test_critical_ui_terms_are_translated(self):
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        expected = {
            "App Data": "应用数据",
            "App Groups": "应用组",
            "Signing problem: no App Group": "签名问题：缺少应用组",
            "Cancel": "取消",
            "OK": "好",
            "Allow Deleting": "允许删除",
            "Show Item Counts": "显示项目数量",
            "Restore Backup…": "还原备份…",
            "Deleting is turned off": "删除功能已关闭",
        }
        for key, value in expected.items():
            self.assertEqual(chinese.get(key), value)

    def test_unused_restore_keys_are_removed(self):
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        for key in ("Restore.FileBackup", "Restore.AppBackup"):
            self.assertNotIn(key, english)
            self.assertNotIn(key, chinese)

    def test_plural_suffixes_are_not_localized_as_placeholders(self):
        legacy_keys = {
            "This permanently removes %lu complete backup%@ and everything inside them. It cannot be undone.",
            "Delete Library/Caches and tmp for %lu app%@, plus Crash Logs",
            "Delete Library/Caches and tmp for %lu app%@",
            "%lu container enumeration%@ failed",
            "%lu container%@ had limited access",
            "%lu cache tree measurement%@ was limited",
            "%lu container%@ had no identifier or identity",
            "No %@ container%@ found.",
            "%@ selected in %lu item%@",
            "Created %@. %lu symbolic link%@ or special file%@ were left out.",
            "Extracted %lu file%@ into %@. %lu symbolic link%@ in the ZIP were left out.",
        }
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        self.assertFalse(legacy_keys & set(english))
        for path in ROOT.glob("*.m"):
            source = path.read_text(encoding="utf-8")
            self.assertNotRegex(source, r'\?\s*@""\s*:\s*@"(?:s|es)"', str(path))

    def test_bundle_and_build_declare_localizations(self):
        info = plistlib.loads((ROOT / "Info.plist").read_bytes())
        self.assertEqual(set(info["CFBundleLocalizations"]), {"en", "zh-Hans"})
        build = (ROOT / "build.sh").read_text(encoding="utf-8")
        self.assertIn('for lproj in "$ROOT"/*.lproj', build)
        self.assertIn('cp -R "$lproj" "$APP/"', build)


if __name__ == "__main__":
    unittest.main()
