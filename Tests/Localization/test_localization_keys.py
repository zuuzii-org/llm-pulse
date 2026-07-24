"""Guards the source-to-catalog contract for `PulseL10n`.

`PulseL10n.text(_:language:_:)` uses the Simplified Chinese string itself as the
lookup key and falls back to that key when a table has no entry. Simplified
Chinese is therefore correct by construction, but a key missing from
`en.lproj` renders raw Chinese inside the English interface with no other
symptom. These tests make that failure mode a build failure instead.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = ROOT / "LLMPulse"
EN_TABLE = ROOT / "LLMPulse/Resources/en.lproj/Localizable.strings"
ZH_TABLE = ROOT / "LLMPulse/Resources/zh-Hans.lproj/Localizable.strings"

ENTRY_PATTERN = re.compile(
    r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;',
    re.MULTILINE,
)

STRING_LITERAL_PATTERN = re.compile(r'"((?:[^"\\]|\\.)*)"')

# A literal reaches the catalog only if it carries an ideograph. Strings made
# solely of CJK punctuation are separators (for example "，"), not copy.
IDEOGRAPH_PATTERN = re.compile(r"[一-鿿]")

# SwiftUI turns an interpolated literal into a `LocalizedStringKey` whose
# placeholders are `%@`, so `Text("仅看 \(name)")` looks up "仅看 %@".
INTERPOLATION_PATTERN = re.compile(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)")

# Mirrors the subset of IEEE printf that `String(format:)` accepts. The capture
# is the conversion character, which is what must agree between a key and its
# translation; flags, width, precision, and length modifiers may differ.
FORMAT_SPECIFIER_PATTERN = re.compile(
    r"%(?:\d+\$)?[-+ #0]*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|L|z|j|t|q)?"
    r"([@dDuUxXoOfeEgGcCsSpaAiF%])"
)

CALL_PREFIX = "PulseL10n.text("


def _swift_sources() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def _skip_swift_string_literal(text: str, index: int) -> int:
    """Returns the index just past the string literal starting at `index`."""
    index += 1
    while index < len(text) and text[index] != '"':
        index += 2 if text[index] == "\\" else 1
    return index + 1


def _top_level_argument_count(body: str) -> int:
    """Commas separating arguments, ignoring nested calls and literals.

    A variadic argument is routinely another call that carries commas of its
    own, so depth must be tracked rather than counted flat.
    """
    count = 0
    depth = 0
    index = 0
    while index < len(body):
        character = body[index]
        if character == '"':
            index = _skip_swift_string_literal(body, index)
            continue
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == "," and depth == 0:
            count += 1
        index += 1
    return count


def _call_sites() -> list[tuple[str, int, Path]]:
    """Every `PulseL10n.text` call with a literal key.

    Returns `(key, argument_count, source_file)`. Calls whose key is not a
    literal are skipped: they cannot be checked statically, and the codebase
    currently has none.
    """
    sites: list[tuple[str, int, Path]] = []
    for source in _swift_sources():
        text = source.read_text(encoding="utf-8")
        cursor = 0
        while True:
            start = text.find(CALL_PREFIX, cursor)
            if start < 0:
                break
            index = start + len(CALL_PREFIX)
            body_start = index
            depth = 1
            while index < len(text) and depth > 0:
                character = text[index]
                if character == '"':
                    index = _skip_swift_string_literal(text, index)
                    continue
                if character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                index += 1
            body = text[body_start : index - 1]
            match = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*,\s*language:', body)
            if match:
                trailing = body[match.end() :]
                sites.append(
                    (match.group(1), _top_level_argument_count(trailing), source)
                )
            cursor = index
    return sites


def _entries(table: Path) -> list[tuple[str, str]]:
    return ENTRY_PATTERN.findall(table.read_text(encoding="utf-8"))


def _swiftui_literals() -> list[tuple[str, Path]]:
    """Copy that SwiftUI localizes on its own, rather than through PulseL10n.

    `Text`, `Label`, `Button`, `Toggle`, `Section`, `.help`, and the
    accessibility modifiers all take `LocalizedStringKey`, so a bare literal is
    looked up in the main bundle. That path is invisible to the PulseL10n scan
    but breaks the English interface exactly the same way.
    """
    literals: list[tuple[str, Path]] = []
    for source in _swift_sources():
        text = source.read_text(encoding="utf-8")
        masked = re.sub(
            r'(PulseL10n\.text\(\s*)"((?:[^"\\]|\\.)*)"',
            lambda match: f'{match.group(1)}""',
            text,
        )
        for match in STRING_LITERAL_PATTERN.finditer(masked):
            literal = match.group(1)
            if not IDEOGRAPH_PATTERN.search(literal):
                continue
            literals.append((INTERPOLATION_PATTERN.sub("%@", literal), source))
    return literals


def _conversions(value: str) -> list[str]:
    """Conversion characters in `value`, ignoring the `%%` literal escape."""
    return [
        conversion
        for conversion in FORMAT_SPECIFIER_PATTERN.findall(value)
        if conversion != "%"
    ]


class LocalizationKeyTests(unittest.TestCase):
    def test_every_literal_key_has_an_english_translation(self) -> None:
        translated = {key for key, _ in _entries(EN_TABLE)}
        missing = sorted(
            {
                (key, source.relative_to(ROOT).as_posix())
                for key, _, source in _call_sites()
                if key not in translated
            }
        )

        self.assertEqual(
            missing,
            [],
            "These keys fall back to raw Simplified Chinese in the English "
            f"interface. Add them to {EN_TABLE.relative_to(ROOT)}.",
        )

    def test_every_swiftui_literal_has_an_english_translation(self) -> None:
        translated = {key for key, _ in _entries(EN_TABLE)}
        missing = sorted(
            {
                (key, source.relative_to(ROOT).as_posix())
                for key, source in _swiftui_literals()
                if key not in translated
            }
        )

        self.assertEqual(
            missing,
            [],
            "SwiftUI resolves these against the main bundle and falls back to "
            f"the key. Add them to {EN_TABLE.relative_to(ROOT)}.",
        )

    def test_translation_tables_declare_each_key_once(self) -> None:
        for table in (EN_TABLE, ZH_TABLE):
            with self.subTest(table=table.relative_to(ROOT).as_posix()):
                keys = [key for key, _ in _entries(table)]
                duplicates = sorted({key for key in keys if keys.count(key) > 1})
                self.assertEqual(duplicates, [], "Later entries silently win.")

    def test_simplified_chinese_overrides_stay_within_the_english_catalog(
        self,
    ) -> None:
        english = {key for key, _ in _entries(EN_TABLE)}
        chinese = {key for key, _ in _entries(ZH_TABLE)}

        self.assertEqual(
            sorted(chinese - english),
            [],
            "A key worth overriding in Simplified Chinese is a key the English "
            "table must also carry.",
        )

    def test_formatted_keys_agree_with_their_translations(self) -> None:
        """Only keys passed arguments are formatted, so only they must agree.

        `PulseL10n.text` returns the raw table value when no arguments are
        supplied, which is why UI copy may contain a bare `%` (for example
        "60%") as long as it is never formatted.
        """
        formatted_keys = {key for key, count, _ in _call_sites() if count > 0}
        mismatches: list[str] = []

        for table in (EN_TABLE, ZH_TABLE):
            for key, value in _entries(table):
                if key not in formatted_keys:
                    continue
                expected = _conversions(key)
                actual = _conversions(value)
                if expected != actual:
                    mismatches.append(
                        f"{table.relative_to(ROOT).as_posix()}: {key!r} "
                        f"declares {expected} but its translation uses {actual}"
                    )

        self.assertEqual(
            mismatches,
            [],
            "String(format:) reads arguments positionally; a mismatch prints "
            "garbage or traps.",
        )

    def test_call_sites_supply_the_arguments_their_key_declares(self) -> None:
        mismatches: list[str] = []
        for key, count, source in _call_sites():
            declared = len(_conversions(key))
            if declared != count:
                mismatches.append(
                    f"{source.relative_to(ROOT).as_posix()}: {key!r} declares "
                    f"{declared} argument(s) but the call passes {count}"
                )

        self.assertEqual(sorted(set(mismatches)), [])


if __name__ == "__main__":
    unittest.main()
