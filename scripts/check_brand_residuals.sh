#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly LEGACY_ROOT='g''pt'
readonly LEGACY_PRODUCT='p''ulse'
readonly LEGACY_PATTERN="${LEGACY_ROOT}([ _-]?${LEGACY_PRODUCT})"
readonly LEGACY_COMPATIBILITY_FILE='./LLMPulse/Services/LegacyCompatibility.swift'
readonly LEGACY_DISPLAY='G''PT P''ulse'
readonly LEGACY_COMPACT='G''PTP''ulse'

command -v rg >/dev/null 2>&1 || {
  echo "brand residual check requires ripgrep (rg)" >&2
  exit 2
}

cd "$REPO_ROOT"

content_results="$(mktemp "${TMPDIR:-/tmp}/llm-pulse-brand-content.XXXXXX")"
path_results="$(mktemp "${TMPDIR:-/tmp}/llm-pulse-brand-paths.XXXXXX")"
trap 'rm -f "$content_results" "$path_results"' EXIT

content_status=0
rg \
  --hidden \
  --no-ignore \
  --line-number \
  --ignore-case \
  --color never \
  --glob '!.git/**' \
  --glob '!.build/**' \
  --glob '!build/**' \
  --glob '!dist/**' \
  --glob '!docs/release-notes-v0.1.0.md' \
  --glob '!docs/release-notes-v1.0.0.md' \
  --glob '!docs/release-notes-v1.1.0.md' \
  --glob '!docs/release-notes-v1.2.0.md' \
  --glob '!docs/release-notes-v1.3.0.md' \
  --glob '!LLMPulse/Services/LegacyCompatibility.swift' \
  "$LEGACY_PATTERN" \
  . >"$content_results" || content_status=$?

if [[ "$content_status" -gt 1 ]]; then
  echo "brand residual content scan failed with rg status $content_status" >&2
  exit "$content_status"
fi

path_status=0
find . \
  \( -path './.git' -o -path './.build' -o -path './build' -o -path './dist' \) -prune -o \
  -type f \
  ! -path './docs/release-notes-v0.1.0.md' \
  ! -path './docs/release-notes-v1.0.0.md' \
  ! -path './docs/release-notes-v1.1.0.md' \
  ! -path './docs/release-notes-v1.2.0.md' \
  ! -path './docs/release-notes-v1.3.0.md' \
  ! -path "$LEGACY_COMPATIBILITY_FILE" \
  -print \
  | LC_ALL=C rg --ignore-case --color never "$LEGACY_PATTERN" \
    >"$path_results" || path_status=$?

if [[ "$path_status" -gt 1 ]]; then
  echo "brand residual path scan failed with rg status $path_status" >&2
  exit "$path_status"
fi

if [[ -s "$content_results" || -s "$path_results" ]]; then
  echo "brand residual check failed" >&2
  if [[ -s "$content_results" ]]; then
    echo >&2
    echo "Disallowed content:" >&2
    cat "$content_results" >&2
  fi
  if [[ -s "$path_results" ]]; then
    echo >&2
    echo "Disallowed paths:" >&2
    cat "$path_results" >&2
  fi
  echo >&2
  echo "Move required upgrade literals into a centralized LegacyCompatibility file." >&2
  exit 1
fi

legacy_occurrence_count="$(
  rg --only-matching --ignore-case "$LEGACY_PATTERN" \
    "$LEGACY_COMPATIBILITY_FILE" | /usr/bin/wc -l | /usr/bin/tr -d ' '
)"
[[ "$legacy_occurrence_count" == "4" ]] || {
  echo "central compatibility file must contain exactly four legacy identity literals" >&2
  exit 1
}

for required_literal in \
  "static let displayName = \"$LEGACY_DISPLAY\"" \
  "static let applicationBundleFilename = \"$LEGACY_DISPLAY.app\"" \
  "static let bundleIdentifier = \"com.zuuzii.$LEGACY_COMPACT\"" \
  "static let applicationSupportDirectoryName = \"$LEGACY_DISPLAY\""
do
  [[ "$(rg --fixed-strings --count "$required_literal" "$LEGACY_COMPATIBILITY_FILE")" == "1" ]] || {
    echo "central compatibility file has an unexpected legacy identity definition" >&2
    exit 1
  }
done

echo "brand residual check passed"
