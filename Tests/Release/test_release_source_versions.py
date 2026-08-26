from __future__ import annotations

import json
import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleaseSourceVersionTests(unittest.TestCase):
    def app_version(self) -> str:
        with (ROOT / "LLMPulse/Resources/Info.plist").open("rb") as handle:
            return plistlib.load(handle)["CFBundleShortVersionString"]

    def test_app_and_codex_companion_manifest_share_one_version(self) -> None:
        app_version = self.app_version()

        manifest = ROOT / "Plugin/.codex-plugin/plugin.json"
        document = json.loads(manifest.read_text(encoding="utf-8"))

        self.assertEqual(document["version"], app_version)

    def test_current_release_documents_match_the_app_version(self) -> None:
        app_version = self.app_version()
        artifact = f"LLM-Pulse-{app_version}.dmg"

        release_notes = ROOT / f"docs/release-notes-v{app_version}.md"
        self.assertTrue(release_notes.is_file())
        self.assertEqual(
            release_notes.read_text(encoding="utf-8").splitlines()[0],
            f"# LLM Pulse v{app_version}",
        )

        for readme_name in ("README.md", "README.zh-CN.md"):
            readme = (ROOT / readme_name).read_text(encoding="utf-8")
            self.assertIn(f"LLM Pulse {app_version}", readme)
            self.assertIn(f"`{artifact}`", readme)
            self.assertIn(f"`{artifact}.sha256`", readme)

        releasing = (ROOT / "docs/RELEASING.md").read_text(encoding="utf-8")
        self.assertIn(f'export VERSION="{app_version}"', releasing)
        self.assertIn(f"dist/{artifact}", releasing)
        self.assertIn(f"dist/{artifact}.sha256", releasing)


if __name__ == "__main__":
    unittest.main()
