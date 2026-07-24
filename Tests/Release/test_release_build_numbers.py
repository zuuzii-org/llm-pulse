"""Guards the build-number monotonicity check in `scripts/release.sh`.

Sparkle only offers an update whose advertised build is higher than the one
installed. Publishing a build number that already shipped therefore fails
completely silently — the release signs, notarizes, and uploads, and nobody is
ever offered it. Nothing downstream can observe that, so the check that
prevents it is worth testing directly.

`release.sh` guards its own `main`, so sourcing it yields the functions without
running a release.
"""

from __future__ import annotations

import plistlib
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPT = ROOT / "scripts/release.sh"


def _run_guard(source_build: int, version: str) -> subprocess.CompletedProcess[str]:
    # Sourcing resets the script's own mutable state, and `REPO_ROOT` is
    # readonly and self-derived, so the inputs are assigned afterwards.
    script = f"""
    set -Eeuo pipefail
    source {str(RELEASE_SCRIPT)!r}
    VERSION={version!r}
    SOURCE_BUILD={source_build}
    validate_build_number_is_new
    """
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        cwd=ROOT,
        check=False,
    )


class ReleaseBuildNumberTests(unittest.TestCase):
    def test_sourcing_the_release_script_does_not_start_a_release(self) -> None:
        result = subprocess.run(
            ["bash", "-c", f'source {str(RELEASE_SCRIPT)!r}; echo sourced'],
            capture_output=True,
            text=True,
            cwd=ROOT,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sourced", result.stdout)

    def test_a_build_number_above_every_release_is_accepted(self) -> None:
        result = _run_guard(source_build=9_999, version="99.0.0")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_build_number_that_already_shipped_is_rejected(self) -> None:
        # Build 7 shipped as v2.0.0, so a later version reusing it must fail.
        result = _run_guard(source_build=7, version="99.0.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not greater than the highest released build", result.stderr)

    def test_the_version_being_prepared_does_not_block_itself(self) -> None:
        """Re-running a release for the current version has to stay possible."""
        with (ROOT / "LLMPulse/Resources/Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)

        result = _run_guard(
            source_build=int(plist["CFBundleVersion"]),
            version=plist["CFBundleShortVersionString"],
        )

        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
