"""Guards the stale-mount cleanup in `scripts/release.sh`.

A release that aborts during the Finder layout leaves its disk image attached.
The next run then inherits a mounted stale image, and the failure it produces
points at Finder rather than at the leftover mount.

The parsing is what makes this fragile: `hdiutil info` is tab-separated and the
volume name contains a space, so splitting on whitespace finds nothing and the
cleanup silently does nothing at all.
"""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPT = ROOT / "scripts/release.sh"

# Real `hdiutil info` output shape: device, UUID, mount point, tab-separated.
ATTACHED = (
    "/dev/disk10\tGUID_partition_scheme\t\n"
    "/dev/disk10s1\t48465300-0000-11AA-AA11-00306543ECAC\t/Volumes/LLM Pulse\n"
)
UNRELATED = (
    "/dev/disk4s1\t48465300-0000-11AA-AA11-00306543ECAC\t/Volumes/Some Other Disk\n"
)


def _device_for(hdiutil_output: str) -> str:
    result = subprocess.run(
        ["bash", "-c", f'source {str(RELEASE_SCRIPT)!r}; release_volume_device'],
        input=hdiutil_output,
        capture_output=True,
        text=True,
        cwd=ROOT,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


class ReleaseVolumeCleanupTests(unittest.TestCase):
    def test_finds_the_device_behind_a_volume_name_containing_a_space(self) -> None:
        self.assertEqual(_device_for(ATTACHED), "/dev/disk10s1")

    def test_ignores_volumes_that_are_not_this_release(self) -> None:
        self.assertEqual(_device_for(UNRELATED), "")

    def test_reports_nothing_when_no_image_is_attached(self) -> None:
        self.assertEqual(_device_for(""), "")

    def test_takes_the_first_match_only(self) -> None:
        self.assertEqual(_device_for(ATTACHED + ATTACHED), "/dev/disk10s1")


if __name__ == "__main__":
    unittest.main()
