#!/bin/bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly PROJECT_FILE="$REPO_ROOT/LLMPulse.xcodeproj"
readonly PROJECT_SPEC="$REPO_ROOT/project.yml"
readonly INFO_PLIST="$REPO_ROOT/LLMPulse/Resources/Info.plist"
readonly PLUGIN_MANIFEST="$REPO_ROOT/Plugin/.codex-plugin/plugin.json"
readonly BUILT_APP_NAME="LLM Pulse.app"
readonly DISTRIBUTED_APP_NAME="LLM Pulse.app"
readonly APP_EXECUTABLE="LLM Pulse"
readonly SCHEME="LLMPulse"
readonly VOLUME_NAME="LLM Pulse"
readonly SPARKLE_FEED_URL="https://github.com/zuuzii-org/llm-pulse/releases/latest/download/appcast.xml"
readonly RELEASE_DOWNLOAD_ROOT="https://github.com/zuuzii-org/llm-pulse/releases/download"
readonly PROJECT_URL="https://github.com/zuuzii-org/llm-pulse"
readonly DEFAULT_SPARKLE_PRIVATE_KEY_FILE="$HOME/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key"
readonly SPARKLE_BRIDGE_VERSION="1.4.0"
readonly SPARKLE_BRIDGE_BUILD="6"
readonly SPARKLE_BRIDGE_DMG_NAME="LLM-Pulse-1.4.0.dmg"
readonly SPARKLE_BRIDGE_APPCAST_URL="$RELEASE_DOWNLOAD_ROOT/v$SPARKLE_BRIDGE_VERSION/appcast.xml"
readonly SPARKLE_BRIDGE_DMG_URL="$RELEASE_DOWNLOAD_ROOT/v$SPARKLE_BRIDGE_VERSION/$SPARKLE_BRIDGE_DMG_NAME"
readonly SPARKLE_BRIDGE_APPCAST_SHA256="d324b4ff25932bfd5c400cd643e4807eab92ddddd246aa1e6d5318b7d32ec888"
readonly SPARKLE_BRIDGE_DMG_SHA256="f08274014f9a486b33abae034e8cf8f76171dfb6282b7d264347b2b4269fc4b3"

STAGE="all"
VERSION=""
OUTPUT_DIR=""
BACKGROUND_PATH="${BACKGROUND_PATH:-}"
VOLUME_ICON_PATH="${VOLUME_ICON_PATH:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-LLMPulseNotary}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
DRY_RUN="${DRY_RUN:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
SKIP_FINDER_LAYOUT="${SKIP_FINDER_LAYOUT:-0}"
NOTARY_POLL_INTERVAL="${NOTARY_POLL_INTERVAL:-15}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-1800}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-zuuzii}"
SPARKLE_KEY_SOURCE="${SPARKLE_KEY_SOURCE:-file}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"

DERIVED_DATA=""
WORK_DIR=""
APP_PATH=""
APP_ZIP_PATH=""
DMG_PATH=""
CHECKSUM_PATH=""
APPCAST_PATH=""
RELEASE_NOTES_PATH=""
SPARKLE_BIN_DIR=""
SPARKLE_GENERATE_KEYS=""
SPARKLE_GENERATE_APPCAST=""
SPARKLE_KEY_TOOL=""
SPARKLE_APPCAST_MERGE_TOOL=""
SPARKLE_BRIDGE_APPCAST_PATH=""
SPARKLE_BRIDGE_DMG_PATH=""
MOUNT_DIR=""
MOUNTED=0
RESOLVED_SIGNING_IDENTITY=""
SOURCE_BUILD=""
CURRENT_GIT_HEAD=""
MANIFEST_PATH=""
MANIFEST_PLANNED=0

usage() {
  cat <<'EOF'
Build, sign, notarize, package, and verify LLM Pulse for macOS.

Usage:
  scripts/release.sh [options]

Options:
  --stage NAME              all (default), build, notarize-app, package,
                            notarize-dmg, verify, appcast, or checksum
  --version VERSION         Expected CFBundleShortVersionString
  --output-dir PATH         Artifact directory (default: dist)
  --background PATH         640x420 PNG with an adjacent 1280x840 @2x PNG
  --volume-icon PATH        Optional .icns file for the mounted DMG volume
  --notary-profile NAME     notarytool Keychain profile (default: LLMPulseNotary)
  --team-id ID              Restrict automatic certificate selection to a Team ID
  --signing-identity VALUE  Certificate SHA-1 or keychain identity name
  --skip-finder-layout      Skip Finder window/icon layout (for headless rehearsal)
  --allow-dirty             Permit a dirty or unborn Git worktree in DRY_RUN only
  --dry-run                 Print mutating commands without executing them
  -h, --help                Show this help

Environment equivalents:
  DRY_RUN, ALLOW_DIRTY, BACKGROUND_PATH, VOLUME_ICON_PATH, NOTARY_PROFILE,
  SIGNING_IDENTITY, TEAM_ID, SKIP_FINDER_LAYOUT, NOTARY_POLL_INTERVAL,
  NOTARY_TIMEOUT, SPARKLE_ACCOUNT, SPARKLE_KEY_SOURCE,
  SPARKLE_PRIVATE_KEY_FILE

No Apple ID or password argument is accepted. Notarization always uses the
named Keychain profile so credentials cannot appear in shell history or logs.
EOF
}

log() {
  printf '[release] %s\n' "$*"
}

warn() {
  printf '[release] warning: %s\n' "$*" >&2
}

die() {
  printf '[release] error: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

print_command() {
  printf '[release] +'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  if ! is_true "$DRY_RUN"; then
    "$@"
  fi
}

capture() {
  local output_file="$1"
  shift
  print_command "$@"
  printf '[release]   > %q\n' "$output_file"
  if ! is_true "$DRY_RUN"; then
    "$@" >"$output_file"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
  if ! is_true "$DRY_RUN"; then
    [[ -f "$1" ]] || die "required file not found: $1"
  fi
}

require_directory() {
  if ! is_true "$DRY_RUN"; then
    [[ -d "$1" ]] || die "required directory not found: $1"
  fi
}

absolute_from_repo() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
  esac
}

safe_remove_release_path() {
  local path="$1"
  case "$path" in
    "$REPO_ROOT/.build/"*) run /bin/rm -rf "$path" ;;
    *) die "refusing to recursively remove a path outside .build: $path" ;;
  esac
}

cleanup() {
  local exit_code=$?
  if [[ "$MOUNTED" -eq 1 ]] && [[ -n "$MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    MOUNTED=0
  fi
  detach_stray_release_volume
  exit "$exit_code"
}

# Detaching by mount point misses a volume that ended up somewhere else.
#
# A release aborted during the Finder layout left the disk image attached at
# `/Volumes/<volume name>` while the detach above was aimed at the requested
# mount point, so the next run inherited a mounted stale image. The device is
# read back from `hdiutil info`, which reports where the image actually is.
# Reads `hdiutil info` on stdin and prints the device holding the release
# volume, or nothing.
#
# hdiutil separates device, UUID, and mount point with tabs. Splitting on
# whitespace instead truncates any volume name containing a space — which
# this one does — and silently finds nothing.
release_volume_device() {
  /usr/bin/awk -F'\t' -v volume="/Volumes/$VOLUME_NAME" \
    '$NF == volume { print $1; exit }'
}

detach_stray_release_volume() {
  [[ -n "$VOLUME_NAME" ]] || return 0
  local device
  # Only images hdiutil itself reports as attached, never a directory that
  # merely exists at that path.
  device="$(/usr/bin/hdiutil info 2>/dev/null | release_volume_device)" || return 0
  [[ -n "$device" ]] || return 0
  /usr/bin/hdiutil detach "$device" -force >/dev/null 2>&1 || true
}

trap cleanup EXIT

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)
        [[ $# -ge 2 ]] || die "--stage requires a value"
        STAGE="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir requires a value"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --background)
        [[ $# -ge 2 ]] || die "--background requires a value"
        BACKGROUND_PATH="$2"
        shift 2
        ;;
      --volume-icon)
        [[ $# -ge 2 ]] || die "--volume-icon requires a value"
        VOLUME_ICON_PATH="$2"
        shift 2
        ;;
      --notary-profile)
        [[ $# -ge 2 ]] || die "--notary-profile requires a value"
        NOTARY_PROFILE="$2"
        shift 2
        ;;
      --team-id)
        [[ $# -ge 2 ]] || die "--team-id requires a value"
        TEAM_ID="$2"
        shift 2
        ;;
      --signing-identity)
        [[ $# -ge 2 ]] || die "--signing-identity requires a value"
        SIGNING_IDENTITY="$2"
        shift 2
        ;;
      --skip-finder-layout)
        SKIP_FINDER_LAYOUT=1
        shift
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

# Sparkle only offers an update when the feed advertises a build higher than
# the installed one. A build number that has already shipped therefore fails
# silently: the release signs, notarizes, and publishes cleanly, and no user is
# ever offered it. Nothing downstream can detect that, so it has to be caught
# before anything is built.
#
# Released builds are read from the tags themselves rather than a changelog, so
# the check cannot drift from what was actually shipped, and needs no network.
highest_released_build() {
  local highest=0 tag build plist_path

  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    # Re-running a release for the version being prepared is legitimate.
    [[ "$tag" == "v$VERSION" ]] && continue
    # The bundle directory has been renamed once already, so the plist is
    # located within each tag rather than assumed.
    while IFS= read -r plist_path; do
      [[ -n "$plist_path" ]] || continue
      build="$(git -C "$REPO_ROOT" show "$tag:$plist_path" 2>/dev/null \
        | /usr/bin/plutil -extract CFBundleVersion raw -o - - 2>/dev/null)" || continue
      [[ "$build" =~ ^[0-9]+$ ]] || continue
      if (( build > highest )); then
        highest="$build"
      fi
    done < <(git -C "$REPO_ROOT" ls-tree -r --name-only "$tag" 2>/dev/null \
      | /usr/bin/grep -E '(^|/)Resources/Info\.plist$' || true)
  done < <(git -C "$REPO_ROOT" tag --list 'v*')

  printf '%s' "$highest"
}

validate_build_number_is_new() {
  local highest
  highest="$(highest_released_build)"

  if (( highest == 0 )); then
    warn "no released build number found in git tags; skipping monotonicity check"
    return 0
  fi

  (( SOURCE_BUILD > highest )) || die \
    "CFBundleVersion $SOURCE_BUILD is not greater than the highest released build $highest. \
Sparkle would publish this release and never offer it to anyone. \
Raise CFBundleVersion in $INFO_PLIST."

  log "CFBundleVersion $SOURCE_BUILD is ahead of the highest released build $highest"
}

initialize_paths() {
  local source_version
  source_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
  SOURCE_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
  if [[ -z "$VERSION" ]]; then
    VERSION="$source_version"
  fi
  [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]] || die "invalid version: $VERSION"
  [[ "$source_version" == "$VERSION" ]] || \
    die "requested version $VERSION does not match Info.plist version $source_version"
  [[ "$SOURCE_BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion must be an integer"
  (( SOURCE_BUILD > SPARKLE_BRIDGE_BUILD )) || \
    die "CFBundleVersion must be greater than bridge build $SPARKLE_BRIDGE_BUILD"
  validate_build_number_is_new

  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/dist"
  else
    OUTPUT_DIR="$(absolute_from_repo "$OUTPUT_DIR")"
  fi

  if [[ -z "$BACKGROUND_PATH" ]] && \
     [[ -f "$REPO_ROOT/Assets/Release/dmg-background.png" ]]; then
    BACKGROUND_PATH="$REPO_ROOT/Assets/Release/dmg-background.png"
  elif [[ -n "$BACKGROUND_PATH" ]]; then
    BACKGROUND_PATH="$(absolute_from_repo "$BACKGROUND_PATH")"
  fi

  if [[ -n "$VOLUME_ICON_PATH" ]]; then
    VOLUME_ICON_PATH="$(absolute_from_repo "$VOLUME_ICON_PATH")"
  elif [[ -f "$REPO_ROOT/Assets/Brand/LLMPulse.icns" ]]; then
    VOLUME_ICON_PATH="$REPO_ROOT/Assets/Brand/LLMPulse.icns"
  fi

  if [[ "$SPARKLE_KEY_SOURCE" == "file" ]]; then
    if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
      SPARKLE_PRIVATE_KEY_FILE="$(absolute_from_repo "$SPARKLE_PRIVATE_KEY_FILE")"
    else
      SPARKLE_PRIVATE_KEY_FILE="$DEFAULT_SPARKLE_PRIVATE_KEY_FILE"
    fi
  fi

  DERIVED_DATA="$REPO_ROOT/.build/release/DerivedData"
  WORK_DIR="$REPO_ROOT/.build/release/work-v$VERSION"
  APP_PATH="$DERIVED_DATA/Build/Products/Release/$BUILT_APP_NAME"
  APP_ZIP_PATH="$WORK_DIR/LLM-Pulse-$VERSION-notarization.zip"
  DMG_PATH="$OUTPUT_DIR/LLM-Pulse-$VERSION.dmg"
  CHECKSUM_PATH="$DMG_PATH.sha256"
  APPCAST_PATH="$OUTPUT_DIR/appcast.xml"
  RELEASE_NOTES_PATH="$REPO_ROOT/docs/release-notes-v$VERSION.md"
  SPARKLE_BIN_DIR="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
  SPARKLE_GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
  SPARKLE_GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
  SPARKLE_KEY_TOOL="$REPO_ROOT/scripts/sparkle_key_tool.swift"
  SPARKLE_APPCAST_MERGE_TOOL="$REPO_ROOT/scripts/merge_sparkle_bridge_appcast.py"
  SPARKLE_BRIDGE_APPCAST_PATH="$WORK_DIR/sparkle-bridge/appcast.xml"
  SPARKLE_BRIDGE_DMG_PATH="$WORK_DIR/sparkle-bridge/$SPARKLE_BRIDGE_DMG_NAME"
  MOUNT_DIR="$WORK_DIR/mount"
  MANIFEST_PATH="$WORK_DIR/release-manifest.plist"
}

validate_options() {
  case "$STAGE" in
    all|build|notarize-app|app-notarize|package|notarize-dmg|dmg-notarize|verify|appcast|checksum) ;;
    *) die "unsupported stage: $STAGE" ;;
  esac
  [[ "$NOTARY_POLL_INTERVAL" =~ ^[0-9]+$ ]] || die "NOTARY_POLL_INTERVAL must be an integer"
  [[ "$NOTARY_TIMEOUT" =~ ^[0-9]+$ ]] || die "NOTARY_TIMEOUT must be an integer"
  (( NOTARY_POLL_INTERVAL >= 1 && NOTARY_POLL_INTERVAL <= 60 )) || \
    die "NOTARY_POLL_INTERVAL must be between 1 and 60 seconds"
  (( NOTARY_TIMEOUT >= NOTARY_POLL_INTERVAL )) || \
    die "NOTARY_TIMEOUT must be at least NOTARY_POLL_INTERVAL"
  [[ -n "$NOTARY_PROFILE" ]] || die "notary profile cannot be empty"
  case "$SPARKLE_KEY_SOURCE" in
    file|keychain) ;;
    *) die "SPARKLE_KEY_SOURCE must be file or keychain" ;;
  esac
  if [[ "$SPARKLE_KEY_SOURCE" == "keychain" ]]; then
    [[ -n "$SPARKLE_ACCOUNT" ]] || die "Sparkle keychain account cannot be empty"
  fi
  if [[ -n "$TEAM_ID" ]]; then
    [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "TEAM_ID must be a 10-character Apple Team ID"
  fi
  if is_true "$ALLOW_DIRTY" && ! is_true "$DRY_RUN"; then
    die "--allow-dirty is restricted to DRY_RUN; formal artifacts require a clean commit"
  fi
  if [[ -n "$BACKGROUND_PATH" ]]; then
    [[ -f "$BACKGROUND_PATH" ]] || die "DMG background not found: $BACKGROUND_PATH"
  fi
  if [[ -n "$VOLUME_ICON_PATH" ]]; then
    [[ -f "$VOLUME_ICON_PATH" ]] || die "DMG volume icon not found: $VOLUME_ICON_PATH"
    [[ "$VOLUME_ICON_PATH" == *.icns ]] || die "DMG volume icon must be an .icns file"
  fi
  if [[ "$SPARKLE_KEY_SOURCE" == "file" ]]; then
    [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]] || die "Sparkle private-key file cannot be empty"
    case "$SPARKLE_PRIVATE_KEY_FILE" in
      "$REPO_ROOT"|"$REPO_ROOT/"*|/tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
        die "Sparkle private key must remain outside the repository and temporary directories"
        ;;
      "$HOME/Library/CloudStorage"|"$HOME/Library/CloudStorage/"*|\
      "$HOME/Library/Mobile Documents"|"$HOME/Library/Mobile Documents/"*)
        die "Sparkle private key must not be stored in a cloud-synchronized directory"
        ;;
    esac
    # The path policy above is pure validation and always runs. Only the
    # existence check is skipped for a dry run, so a rehearsal can exercise
    # every other preflight on a machine that holds no signing secrets —
    # which is the only way CI can reach this code at all.
    if is_true "$DRY_RUN"; then
      log "[dry-run] skip private-key existence check for $SPARKLE_PRIVATE_KEY_FILE"
    else
      [[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]] || \
        die "Sparkle private-key file not found: $SPARKLE_PRIVATE_KEY_FILE"
    fi
  elif [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    die "SPARKLE_PRIVATE_KEY_FILE cannot be set when SPARKLE_KEY_SOURCE=keychain"
  fi
}

validate_dmg_background_assets() {
  local background_2x width height width_2x height_2x format format_2x
  [[ -n "$BACKGROUND_PATH" ]] || return 0

  background_2x="${BACKGROUND_PATH%.*}@2x.${BACKGROUND_PATH##*.}"
  if is_true "$DRY_RUN" && [[ ! -f "$BACKGROUND_PATH" || ! -f "$background_2x" ]]; then
    log "[dry-run] require a 640x420 PNG and adjacent 1280x840 @2x PNG for the DMG background"
    return
  fi

  require_file "$BACKGROUND_PATH"
  require_file "$background_2x"
  format="$(/usr/bin/sips -g format "$BACKGROUND_PATH" | /usr/bin/awk '/format:/{print $2}')"
  width="$(/usr/bin/sips -g pixelWidth "$BACKGROUND_PATH" | /usr/bin/awk '/pixelWidth:/{print $2}')"
  height="$(/usr/bin/sips -g pixelHeight "$BACKGROUND_PATH" | /usr/bin/awk '/pixelHeight:/{print $2}')"
  format_2x="$(/usr/bin/sips -g format "$background_2x" | /usr/bin/awk '/format:/{print $2}')"
  width_2x="$(/usr/bin/sips -g pixelWidth "$background_2x" | /usr/bin/awk '/pixelWidth:/{print $2}')"
  height_2x="$(/usr/bin/sips -g pixelHeight "$background_2x" | /usr/bin/awk '/pixelHeight:/{print $2}')"

  [[ "$format" == "png" && "$width" == "640" && "$height" == "420" ]] || \
    die "DMG background must be a 640x420 PNG: $BACKGROUND_PATH"
  [[ "$format_2x" == "png" && "$width_2x" == "1280" && "$height_2x" == "840" ]] || \
    die "DMG Retina background must be a 1280x840 PNG: $background_2x"
  log "validated 640x420 + 1280x840 Retina DMG backgrounds"
}

validate_source_sparkle_configuration() {
  local feed_url public_key verify_before_extraction decoded_bytes
  feed_url="$(/usr/bin/plutil -extract SUFeedURL raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  verify_before_extraction="$(/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw -o - \
    "$INFO_PLIST" 2>/dev/null || true)"

  [[ "$feed_url" == "$SPARKLE_FEED_URL" ]] || \
    die "unexpected Sparkle feed URL: $feed_url"
  [[ -n "$public_key" ]] || die "SUPublicEDKey is missing"
  decoded_bytes="$(printf '%s' "$public_key" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
  [[ "$decoded_bytes" == "32" ]] || die "SUPublicEDKey must decode to 32 bytes"
  [[ "$verify_before_extraction" == "true" || "$verify_before_extraction" == "1" ]] || \
    die "SUVerifyUpdateBeforeExtraction must be enabled"

  if /usr/bin/plutil -extract SUEnableSystemProfiling raw -o - "$INFO_PLIST" \
      >/dev/null 2>&1; then
    [[ "$(/usr/bin/plutil -extract SUEnableSystemProfiling raw -o - "$INFO_PLIST")" != "true" ]] || \
      die "Sparkle system profiling must remain disabled"
  fi
  log "validated Sparkle feed, EdDSA public key, and privacy settings"
}

validate_release_source_versions() {
  local plugin_version
  [[ -f "$RELEASE_NOTES_PATH" ]] || \
    die "release notes are required before signing or notarization: $RELEASE_NOTES_PATH"
  [[ -f "$PLUGIN_MANIFEST" ]] || die "Codex plugin manifest is missing: $PLUGIN_MANIFEST"
  plugin_version="$(/usr/bin/plutil -extract version raw -o - "$PLUGIN_MANIFEST" 2>/dev/null || true)"
  [[ "$plugin_version" == "$VERSION" ]] || \
    die "Codex plugin version $plugin_version does not match app version $VERSION"
  log "validated release notes and Codex companion plugin version"
}

validate_file_backed_sparkle_key() {
  local expected_public_key actual_public_key
  if [[ "$SPARKLE_KEY_SOURCE" != "file" ]]; then
    return 0
  fi

  if is_true "$DRY_RUN"; then
    log "[dry-run] verify private-key ownership, mode, format, and SUPublicEDKey match"
    return
  fi

  [[ -x "$SPARKLE_KEY_TOOL" ]] || die "Sparkle key tool is missing or not executable"
  expected_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
  if ! actual_public_key="$("$SPARKLE_KEY_TOOL" public-key "$SPARKLE_PRIVATE_KEY_FILE")"; then
    die "Sparkle private-key file failed ownership, permission, or format validation"
  fi
  [[ "$actual_public_key" == "$expected_public_key" ]] || \
    die "Sparkle private-key file does not match SUPublicEDKey"
  log "validated file-backed Sparkle signing key"
}

stage_requires_notarization() {
  case "$STAGE" in
    all|notarize-app|app-notarize|notarize-dmg|dmg-notarize) return 0 ;;
    *) return 1 ;;
  esac
}

validate_notary_profile() {
  stage_requires_notarization || return 0

  if is_true "$DRY_RUN"; then
    log "[dry-run] verify notarytool Keychain profile $NOTARY_PROFILE"
    return
  fi

  if ! /usr/bin/xcrun notarytool history \
      --keychain-profile "$NOTARY_PROFILE" \
      --no-progress \
      --output-format json >/dev/null 2>&1; then
    die "notarytool Keychain profile is unavailable or invalid: $NOTARY_PROFILE"
  fi
  log "validated notarytool Keychain profile"
}

require_clean_worktree() {
  local status
  if is_true "$ALLOW_DIRTY"; then
    warn "dirty-worktree protection is disabled"
    return
  fi
  /usr/bin/git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || \
    die "release builds require a committed HEAD; use --allow-dirty only for rehearsal"
  status="$(/usr/bin/git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] || \
    die "Git worktree is not clean; commit changes before producing release artifacts"
}

resolve_git_head() {
  CURRENT_GIT_HEAD="$(/usr/bin/git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -z "$CURRENT_GIT_HEAD" ]]; then
    if is_true "$DRY_RUN" && is_true "$ALLOW_DIRTY"; then
      CURRENT_GIT_HEAD="UNBORN"
      warn "release manifest rehearsal is using an unborn Git HEAD"
      return
    fi
    die "release provenance requires a committed Git HEAD"
  fi
}

write_release_manifest() {
  local temporary_manifest="$MANIFEST_PATH.tmp"
  log "recording release provenance for Git HEAD $CURRENT_GIT_HEAD"
  run /bin/mkdir -p "$WORK_DIR"
  run /bin/rm -f "$temporary_manifest"
  run /usr/bin/plutil -create xml1 "$temporary_manifest"
  run /usr/bin/plutil -insert schemaVersion -integer 1 "$temporary_manifest"
  run /usr/bin/plutil -insert gitHead -string "$CURRENT_GIT_HEAD" "$temporary_manifest"
  run /usr/bin/plutil -insert version -string "$VERSION" "$temporary_manifest"
  run /usr/bin/plutil -insert build -string "$SOURCE_BUILD" "$temporary_manifest"
  run /usr/bin/plutil -insert outputDirectory -string "$OUTPUT_DIR" "$temporary_manifest"
  run /bin/mv "$temporary_manifest" "$MANIFEST_PATH"
  MANIFEST_PLANNED=1
}

validate_release_manifest() {
  local manifest_head manifest_version manifest_build manifest_output manifest_schema

  if is_true "$DRY_RUN" && [[ "$MANIFEST_PLANNED" -eq 1 ]]; then
    log "[dry-run] validate manifest HEAD=$CURRENT_GIT_HEAD version=$VERSION build=$SOURCE_BUILD output=$OUTPUT_DIR"
    return
  fi
  if [[ ! -f "$MANIFEST_PATH" ]]; then
    if is_true "$DRY_RUN"; then
      log "[dry-run] require $MANIFEST_PATH and validate HEAD, version, build, and output directory"
      return
    fi
    die "release manifest not found: $MANIFEST_PATH; run --stage build from the current commit"
  fi

  manifest_schema="$(/usr/bin/plutil -extract schemaVersion raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
  manifest_head="$(/usr/bin/plutil -extract gitHead raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
  manifest_version="$(/usr/bin/plutil -extract version raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
  manifest_build="$(/usr/bin/plutil -extract build raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
  manifest_output="$(/usr/bin/plutil -extract outputDirectory raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"

  [[ "$manifest_schema" == "1" ]] || \
    die "unsupported or corrupt release manifest: $MANIFEST_PATH"
  [[ "$manifest_head" == "$CURRENT_GIT_HEAD" ]] || \
    die "release manifest HEAD $manifest_head does not match current HEAD $CURRENT_GIT_HEAD; rebuild"
  [[ "$manifest_version" == "$VERSION" ]] || \
    die "release manifest version $manifest_version does not match $VERSION; rebuild"
  [[ "$manifest_build" == "$SOURCE_BUILD" ]] || \
    die "release manifest build $manifest_build does not match $SOURCE_BUILD; rebuild"
  [[ "$manifest_output" == "$OUTPUT_DIR" ]] || \
    die "release manifest output $manifest_output does not match $OUTPUT_DIR; rebuild"
  log "validated release provenance for Git HEAD $CURRENT_GIT_HEAD"
}

resolve_signing_identity() {
  local identities matches count
  if [[ -n "$RESOLVED_SIGNING_IDENTITY" ]]; then
    return
  fi
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    RESOLVED_SIGNING_IDENTITY="$SIGNING_IDENTITY"
    log "using the explicitly configured Developer ID identity"
    return
  fi

  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  matches="$(printf '%s\n' "$identities" | /usr/bin/sed -n \
    '/"Developer ID Application:/s/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-F][0-9A-F]*\).*/\1/p')"
  if [[ -n "$TEAM_ID" ]]; then
    matches="$(printf '%s\n' "$identities" | /usr/bin/grep '"Developer ID Application:' | \
      /usr/bin/grep "(${TEAM_ID})" | /usr/bin/sed -n \
      's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-F][0-9A-F]*\).*/\1/p' || true)"
  fi
  count="$(printf '%s\n' "$matches" | /usr/bin/sed '/^[[:space:]]*$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "$count" == "1" ]] || \
    die "expected exactly one Developer ID Application identity; set TEAM_ID or SIGNING_IDENTITY"
  RESOLVED_SIGNING_IDENTITY="$(printf '%s\n' "$matches" | /usr/bin/sed -n '1p')"
  log "resolved one Developer ID Application identity from the keychain"
}

verify_universal_code() {
  local bundle="$1"
  local found=0
  local code_file
  require_directory "$bundle"
  if is_true "$DRY_RUN"; then
    log "[dry-run] verify every Mach-O in $bundle contains arm64 and x86_64"
    return
  fi
  while IFS= read -r -d '' code_file; do
    if /usr/bin/file -b "$code_file" | /usr/bin/grep -q 'Mach-O'; then
      found=1
      /usr/bin/lipo "$code_file" -verify_arch arm64 x86_64 >/dev/null || \
        die "non-universal Mach-O found: $code_file"
    fi
  done < <(/usr/bin/find "$bundle" -type f -print0)
  [[ "$found" -eq 1 ]] || die "no Mach-O executable found in $bundle"
  log "verified all Mach-O files contain arm64 and x86_64"
}

verify_app_signature() {
  local app="$1"
  local signature_info
  require_directory "$app"
  run /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
  if is_true "$DRY_RUN"; then
    return
  fi
  signature_info="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)"
  [[ "$signature_info" == *"Authority=Developer ID Application:"* ]] || \
    die "app is not signed with a Developer ID Application certificate"
  [[ "$signature_info" == *"runtime"* ]] || die "app signature is missing hardened runtime"
  [[ "$signature_info" == *"Timestamp="* ]] || die "app signature is missing a secure timestamp"
  if [[ -n "$TEAM_ID" ]]; then
    [[ "$signature_info" == *"TeamIdentifier=$TEAM_ID"* ]] || \
      die "app signature does not match TEAM_ID"
  fi
}

verify_app_metadata() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
  local bundle_id bundle_name display_name executable_name short_version build_version ui_element minimum_system
  local source_build feed_url public_key verify_before_extraction linked_framework
  require_file "$plist"
  require_file "$app/Contents/Resources/AppIcon.icns"
  require_directory "$sparkle_framework"
  if is_true "$DRY_RUN"; then
    log "[dry-run] verify app metadata, Sparkle framework, feed, EdDSA key, and privacy settings"
    return
  fi

  bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")"
  bundle_name="$(/usr/bin/plutil -extract CFBundleName raw -o - "$plist")"
  display_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$plist")"
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist")"
  short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")"
  build_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$plist")"
  ui_element="$(/usr/bin/plutil -extract LSUIElement raw -o - "$plist")"
  minimum_system="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$plist")"
  source_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
  feed_url="$(/usr/bin/plutil -extract SUFeedURL raw -o - "$plist")"
  public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$plist")"
  verify_before_extraction="$(/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$plist")"

  [[ "$bundle_id" == "com.zuuzii.LLMPulse" ]] || die "unexpected bundle ID: $bundle_id"
  [[ "$bundle_name" == "LLM Pulse" ]] || die "unexpected bundle name: $bundle_name"
  [[ "$display_name" == "LLM Pulse" ]] || die "unexpected display name: $display_name"
  [[ "$executable_name" == "$APP_EXECUTABLE" ]] || die "unexpected executable name: $executable_name"
  [[ "$short_version" == "$VERSION" ]] || die "unexpected app version: $short_version"
  [[ "$build_version" == "$source_build" ]] || die "unexpected app build: $build_version"
  [[ "$ui_element" == "true" || "$ui_element" == "1" ]] || die "LSUIElement is not enabled"
  /usr/bin/awk -v version="$minimum_system" 'BEGIN {
    gsub(/^[[:space:]]+/, "", version)
    gsub(/[[:space:]]+$/, "", version)
    exit !(version == "14" || version == "14.0" || version == "14.0.0")
  }' || die "minimum macOS version must be exactly 14.0: $minimum_system"
  [[ "$feed_url" == "$SPARKLE_FEED_URL" ]] || die "unexpected bundled Sparkle feed: $feed_url"
  [[ "$public_key" == "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")" ]] || \
    die "bundled Sparkle public key differs from source"
  [[ "$verify_before_extraction" == "true" || "$verify_before_extraction" == "1" ]] || \
    die "bundled Sparkle archive verification is disabled"
  if /usr/bin/plutil -extract SUEnableSystemProfiling raw -o - "$plist" >/dev/null 2>&1; then
    [[ "$(/usr/bin/plutil -extract SUEnableSystemProfiling raw -o - "$plist")" != "true" ]] || \
      die "bundled Sparkle system profiling must remain disabled"
  fi
  linked_framework="$(/usr/bin/otool -L "$app/Contents/MacOS/$APP_EXECUTABLE")"
  [[ "$linked_framework" == *"@rpath/Sparkle.framework/"* ]] || \
    die "main executable is not linked to the embedded Sparkle framework"
  [[ -z "$(/usr/bin/find "$sparkle_framework" -name '*.xpc' -print -quit)" ]] || \
    die "non-sandboxed release must not ship Sparkle XPC services"
  log "verified app metadata, icon resources, and Sparkle update configuration"
}

prepare_sparkle_for_non_sandbox() {
  local app="$1"
  local sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
  local xpc_path
  require_directory "$sparkle_framework"

  if is_true "$DRY_RUN"; then
    log "[dry-run] remove Sparkle XPC services for the non-sandboxed host app"
    return
  fi

  while IFS= read -r -d '' xpc_path; do
    case "$xpc_path" in
      "$sparkle_framework"/Versions/*/XPCServices)
        run /bin/rm -rf "$xpc_path"
        ;;
      *)
        die "refusing to remove unexpected Sparkle XPC path: $xpc_path"
        ;;
    esac
  done < <(/usr/bin/find "$sparkle_framework/Versions" -mindepth 2 -maxdepth 2 \
    -type d -name XPCServices -print0)
  if [[ -L "$sparkle_framework/XPCServices" ]]; then
    run /bin/rm -f "$sparkle_framework/XPCServices"
  fi
  [[ -z "$(/usr/bin/find "$sparkle_framework" -name '*.xpc' -print -quit)" ]] || \
    die "Sparkle XPC services remain after non-sandbox preparation"
  log "prepared Sparkle for the non-sandboxed release host"
}

verify_dmg_signature() {
  local dmg="$1"
  local signature_info
  require_file "$dmg"
  run /usr/bin/codesign --verify --strict --verbose=2 "$dmg"
  if is_true "$DRY_RUN"; then
    return
  fi
  signature_info="$(/usr/bin/codesign -d --verbose=4 "$dmg" 2>&1)"
  [[ "$signature_info" == *"Authority=Developer ID Application:"* ]] || \
    die "DMG is not signed with a Developer ID Application certificate"
  [[ "$signature_info" == *"Timestamp="* ]] || die "DMG signature is missing a secure timestamp"
}

sign_embedded_code() {
  local app="$1"
  local code_file bundle

  if is_true "$DRY_RUN"; then
    log "[dry-run] sign embedded Mach-O files and code bundles from deepest to shallowest"
    return
  fi

  while IFS= read -r -d '' code_file; do
    [[ "$code_file" == "$app/Contents/MacOS/$APP_EXECUTABLE" ]] && continue
    if /usr/bin/file -b "$code_file" | /usr/bin/grep -q 'Mach-O'; then
      run /usr/bin/codesign --force --options runtime --timestamp \
        --generate-entitlement-der --sign "$RESOLVED_SIGNING_IDENTITY" "$code_file"
    fi
  done < <(/usr/bin/find "$app/Contents" -type f -print0)

  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    run /usr/bin/codesign --force --options runtime --timestamp \
      --generate-entitlement-der --sign "$RESOLVED_SIGNING_IDENTITY" "$bundle"
  done < <(/usr/bin/find "$app/Contents" -type d \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \
    -print | /usr/bin/awk '{ print length($0) "\t" $0 }' | \
    /usr/bin/sort -rn | /usr/bin/cut -f2-)
}

build_and_sign_app() {
  local built_version
  log "building macOS $VERSION Release for arm64 + x86_64"
  require_clean_worktree
  resolve_signing_identity
  safe_remove_release_path "$DERIVED_DATA"
  safe_remove_release_path "$WORK_DIR"
  run /bin/mkdir -p "$OUTPUT_DIR"
  run /bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH" "$APPCAST_PATH"

  run "$(command -v xcodegen)" generate --spec "$PROJECT_SPEC"
  require_clean_worktree
  run /usr/bin/xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

  require_directory "$APP_PATH"
  if ! is_true "$DRY_RUN"; then
    built_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
      "$APP_PATH/Contents/Info.plist")"
    [[ "$built_version" == "$VERSION" ]] || \
      die "built app version $built_version does not match $VERSION"
  fi
  prepare_sparkle_for_non_sandbox "$APP_PATH"
  verify_universal_code "$APP_PATH"
  verify_app_metadata "$APP_PATH"
  sign_embedded_code "$APP_PATH"
  run /usr/bin/codesign --force --options runtime --timestamp \
    --generate-entitlement-der --sign "$RESOLVED_SIGNING_IDENTITY" "$APP_PATH"
  verify_app_signature "$APP_PATH"
  write_release_manifest
  validate_release_manifest
  log "signed app ready: $APP_PATH"
}

json_field() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

fetch_notary_log() {
  local submission_id="$1"
  local label="$2"
  local log_path="$WORK_DIR/notary-$label-log.json"
  if ! /usr/bin/xcrun notarytool log "$submission_id" \
    --keychain-profile "$NOTARY_PROFILE" --output-format json >"$log_path"; then
    warn "could not fetch notarization diagnostics"
  else
    warn "notarization diagnostics saved to $log_path"
  fi
}

notarize_artifact() {
  local artifact="$1"
  local label="$2"
  local submit_path="$WORK_DIR/notary-$label-submit.json"
  local info_path="$WORK_DIR/notary-$label-info.json"
  local submission_id status previous_status=""
  local started_at now

  require_file "$artifact"
  run /bin/mkdir -p "$WORK_DIR"
  if is_true "$DRY_RUN"; then
    log "[dry-run] submit $artifact with notary profile $NOTARY_PROFILE (no wait)"
    log "[dry-run] poll notarytool info every ${NOTARY_POLL_INTERVAL}s for up to ${NOTARY_TIMEOUT}s"
    return
  fi

  capture "$submit_path" /usr/bin/xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --no-wait --no-progress --output-format json
  submission_id="$(json_field "$submit_path" id)"
  [[ -n "$submission_id" ]] || die "notarytool did not return a submission ID; see $submit_path"
  log "$label notarization submitted"

  started_at="$(/bin/date +%s)"
  while :; do
    capture "$info_path" /usr/bin/xcrun notarytool info "$submission_id" \
      --keychain-profile "$NOTARY_PROFILE" --no-progress --output-format json
    status="$(json_field "$info_path" status)"
    [[ -n "$status" ]] || die "notarytool returned no status; see $info_path"
    if [[ "$status" != "$previous_status" ]]; then
      log "$label notarization status: $status"
      previous_status="$status"
    fi
    case "$status" in
      Accepted)
        return
        ;;
      Invalid|Rejected)
        fetch_notary_log "$submission_id" "$label"
        die "$label notarization was rejected"
        ;;
      'In Progress'|Submitted|Uploaded)
        ;;
      *)
        fetch_notary_log "$submission_id" "$label"
        die "unknown $label notarization status: $status"
        ;;
    esac
    now="$(/bin/date +%s)"
    (( now - started_at < NOTARY_TIMEOUT )) || \
      die "$label notarization timed out; submission ID: $submission_id"
    /bin/sleep "$NOTARY_POLL_INTERVAL"
  done
}

notarize_and_staple_app() {
  log "notarizing the signed app"
  require_clean_worktree
  validate_release_manifest
  verify_universal_code "$APP_PATH"
  verify_app_signature "$APP_PATH"
  run /bin/mkdir -p "$WORK_DIR"
  run /bin/rm -f "$APP_ZIP_PATH"
  run /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP_PATH"
  notarize_artifact "$APP_ZIP_PATH" app
  run /usr/bin/xcrun stapler staple -v "$APP_PATH"
  run /usr/bin/xcrun stapler validate -v "$APP_PATH"
  verify_app_signature "$APP_PATH"
  run /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
  log "notarized app is stapled and accepted by Gatekeeper"
}

apply_finder_layout() {
  local background_name="$1"
  if is_true "$SKIP_FINDER_LAYOUT"; then
    warn "Finder DMG layout was explicitly skipped"
    return
  fi
  if is_true "$DRY_RUN"; then
    log "[dry-run] apply 640x420 Finder layout with app, drag arrow, and Applications icons"
    return
  fi

  # Finder needs a moment to make the freshly mounted volume's window
  # scriptable, and how long is not predictable — a fixed delay fails as
  # -10006 ("can't set ... of container window") often enough to lose a whole
  # build plus two notarization round trips. The window is polled instead, and
  # the whole thing retried, because the failure is transient.
  local attempt
  for attempt in 1 2 3; do
    if apply_finder_layout_once "$background_name"; then
      return
    fi
    warn "Finder DMG layout attempt $attempt did not complete; retrying"
    /usr/bin/osascript -e 'tell application "Finder" to close every window' \
      >/dev/null 2>&1 || true
    /bin/sleep 2
  done
  die "Finder DMG layout failed after 3 attempts; \
set SKIP_FINDER_LAYOUT=1 to ship a DMG without the custom icon arrangement"
}

apply_finder_layout_once() {
  local background_name="$1"
  /usr/bin/osascript - "$MOUNT_DIR" "$DISTRIBUTED_APP_NAME" "$background_name" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  set applicationName to item 2 of argv
  set backgroundName to item 3 of argv
  set mountedFolder to POSIX file mountPath as alias

  tell application "Finder"
    open mountedFolder
    -- Wait for the window to become scriptable rather than assuming it is.
    set readyAttempts to 0
    repeat until readyAttempts is 30
      try
        if exists (container window of mountedFolder) then
          set current view of (container window of mountedFolder) to icon view
          exit repeat
        end if
      end try
      set readyAttempts to readyAttempts + 1
      delay 0.5
    end repeat
    -- Resolve the exact custom mount path. Finder does not consistently
    -- expose `disk <volume name>` for volumes mounted outside /Volumes.
    set dmgWindow to container window of mountedFolder
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set pathbar visible of dmgWindow to false
    -- Finder bounds include the title bar; 448px yields a 420px content area.
    set bounds of dmgWindow to {200, 120, 840, 568}

    set viewOptions to icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 14
    if backgroundName is not "" then
      set background picture of viewOptions to file (mountPath & "/.background/" & backgroundName) as POSIX file
    else
      set background color of viewOptions to {10537, 11051, 12336}
    end if

    set position of item applicationName of mountedFolder to {160, 205}
    set position of item "Applications" of mountedFolder to {480, 205}
    update mountedFolder without registering applications
    delay 2
    close dmgWindow
  end tell
end run
APPLESCRIPT
}

calculate_dmg_size_mb() {
  local app_kb size_mb
  if is_true "$DRY_RUN"; then
    printf '200\n'
    return
  fi
  app_kb="$(/usr/bin/du -sk "$APP_PATH" | /usr/bin/awk '{print $1}')"
  size_mb=$(( app_kb / 1024 + 64 ))
  (( size_mb >= 128 )) || size_mb=128
  printf '%s\n' "$size_mb"
}

create_and_sign_dmg() {
  local rw_dmg="$WORK_DIR/LLM-Pulse-$VERSION-rw.dmg"
  local unsigned_dmg="$WORK_DIR/LLM-Pulse-$VERSION-unsigned.dmg"
  local background_name=""
  local background_2x=""
  local effective_volume_icon="$VOLUME_ICON_PATH"
  local dmg_size_mb setfile_path

  log "creating signed DMG"
  require_clean_worktree
  validate_release_manifest
  verify_app_signature "$APP_PATH"
  run /usr/bin/xcrun stapler validate -v "$APP_PATH"
  resolve_signing_identity
  safe_remove_release_path "$MOUNT_DIR"
  run /bin/mkdir -p "$MOUNT_DIR" "$OUTPUT_DIR"
  run /bin/rm -f "$rw_dmg" "$unsigned_dmg" "$DMG_PATH" "$CHECKSUM_PATH"

  dmg_size_mb="$(calculate_dmg_size_mb)"
  run /usr/bin/hdiutil create -quiet -size "${dmg_size_mb}m" \
    -fs HFS+ -type UDIF -volname "$VOLUME_NAME" "$rw_dmg"
  run /usr/bin/hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNT_DIR"
  if ! is_true "$DRY_RUN"; then
    MOUNTED=1
  fi

  run /usr/bin/ditto --rsrc --extattr "$APP_PATH" "$MOUNT_DIR/$DISTRIBUTED_APP_NAME"
  run /bin/ln -s /Applications "$MOUNT_DIR/Applications"

  if [[ -n "$BACKGROUND_PATH" ]]; then
    run /bin/mkdir -p "$MOUNT_DIR/.background"
    background_2x="${BACKGROUND_PATH%.*}@2x.${BACKGROUND_PATH##*.}"
    if [[ -f "$background_2x" ]]; then
      background_name="dmg-background.tiff"
      run /usr/bin/tiffutil -cathidpicheck "$BACKGROUND_PATH" "$background_2x" \
        -out "$MOUNT_DIR/.background/$background_name"
    else
      background_name="$(basename "$BACKGROUND_PATH")"
      run /bin/cp "$BACKGROUND_PATH" "$MOUNT_DIR/.background/$background_name"
    fi
  fi

  apply_finder_layout "$background_name"

  # Finder can clear the custom-volume-icon file and bit while persisting its
  # window layout. Install the icon only after Finder has finished writing the
  # volume metadata so both survive detach and image conversion.
  if [[ -z "$effective_volume_icon" ]]; then
    effective_volume_icon="$APP_PATH/Contents/Resources/AppIcon.icns"
  fi
  require_file "$effective_volume_icon"
  if [[ -n "$effective_volume_icon" ]]; then
    run /bin/cp "$effective_volume_icon" "$MOUNT_DIR/.VolumeIcon.icns"
    setfile_path="$(/usr/bin/xcrun --find SetFile 2>/dev/null || true)"
    [[ -n "$setfile_path" ]] || die "SetFile is required when --volume-icon is used"
    run "$setfile_path" -a C "$MOUNT_DIR"
  fi

  run /bin/sync
  run /usr/bin/hdiutil detach "$MOUNT_DIR"
  if ! is_true "$DRY_RUN"; then
    MOUNTED=0
  fi
  run /usr/bin/hdiutil convert "$rw_dmg" -quiet -format UDZO \
    -imagekey zlib-level=9 -o "$unsigned_dmg"
  run /bin/mv "$unsigned_dmg" "$DMG_PATH"
  run /usr/bin/codesign --force --timestamp \
    --sign "$RESOLVED_SIGNING_IDENTITY" "$DMG_PATH"
  verify_dmg_signature "$DMG_PATH"
  run /usr/bin/hdiutil verify "$DMG_PATH"
  log "signed DMG ready: $DMG_PATH"
}

notarize_and_staple_dmg() {
  log "notarizing the signed DMG"
  require_clean_worktree
  validate_release_manifest
  verify_dmg_signature "$DMG_PATH"
  run /usr/bin/hdiutil verify "$DMG_PATH"
  notarize_artifact "$DMG_PATH" dmg
  run /usr/bin/xcrun stapler staple -v "$DMG_PATH"
  run /usr/bin/xcrun stapler validate -v "$DMG_PATH"
  verify_dmg_signature "$DMG_PATH"
  run /usr/bin/hdiutil verify "$DMG_PATH"
  run /usr/sbin/spctl --assess --type open --context context:primary-signature \
    --verbose=4 "$DMG_PATH"
  log "notarized DMG is stapled and accepted by Gatekeeper"
}

resolve_sparkle_tools_and_key() {
  local expected_public_key keychain_public_key
  expected_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
  if is_true "$DRY_RUN"; then
    log "[dry-run] require Sparkle generate_appcast from resolved 2.9.4"
    if [[ "$SPARKLE_KEY_SOURCE" == "file" ]]; then
      log "[dry-run] use the validated file-backed Sparkle signing key"
    else
      log "[dry-run] verify Keychain account $SPARKLE_ACCOUNT matches SUPublicEDKey"
    fi
    return
  fi

  [[ -x "$SPARKLE_GENERATE_APPCAST" ]] || \
    die "Sparkle generate_appcast not found: $SPARKLE_GENERATE_APPCAST"

  if [[ "$SPARKLE_KEY_SOURCE" == "file" ]]; then
    validate_file_backed_sparkle_key
    log "verified Sparkle tools and file-backed signing key"
    return
  fi

  [[ -x "$SPARKLE_GENERATE_KEYS" ]] || die "Sparkle generate_keys not found: $SPARKLE_GENERATE_KEYS"
  keychain_public_key="$("$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
  [[ "$keychain_public_key" == "$expected_public_key" ]] || \
    die "Sparkle Keychain account does not match SUPublicEDKey"
  log "verified Sparkle tools and Keychain signing identity"
}

download_and_verify_sparkle_bridge_release() {
  local bridge_dir actual_appcast_hash actual_dmg_hash item_count
  local build short_version minimum_update url signature declared_length actual_length
  local expected_public_key
  bridge_dir="$(dirname "$SPARKLE_BRIDGE_APPCAST_PATH")"

  log "fetching the pinned Sparkle bridge release"
  safe_remove_release_path "$bridge_dir"
  run /bin/mkdir -p "$bridge_dir"
  run /usr/bin/curl --fail --location --retry 3 --silent --show-error \
    --output "$SPARKLE_BRIDGE_APPCAST_PATH" "$SPARKLE_BRIDGE_APPCAST_URL"
  run /usr/bin/curl --fail --location --retry 3 --silent --show-error \
    --output "$SPARKLE_BRIDGE_DMG_PATH" "$SPARKLE_BRIDGE_DMG_URL"
  if is_true "$DRY_RUN"; then
    log "[dry-run] verify pinned bridge hashes, metadata, notarization, and EdDSA signature"
    return
  fi

  actual_appcast_hash="$(/usr/bin/shasum -a 256 "$SPARKLE_BRIDGE_APPCAST_PATH" | /usr/bin/awk '{print $1}')"
  actual_dmg_hash="$(/usr/bin/shasum -a 256 "$SPARKLE_BRIDGE_DMG_PATH" | /usr/bin/awk '{print $1}')"
  [[ "$actual_appcast_hash" == "$SPARKLE_BRIDGE_APPCAST_SHA256" ]] || \
    die "pinned bridge appcast hash mismatch"
  [[ "$actual_dmg_hash" == "$SPARKLE_BRIDGE_DMG_SHA256" ]] || \
    die "pinned bridge DMG hash mismatch"

  /usr/bin/xmllint --noout "$SPARKLE_BRIDGE_APPCAST_PATH" || \
    die "pinned bridge appcast is not valid XML"
  item_count="$(/usr/bin/xmllint --xpath 'count(/rss/channel/item)' \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  build="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item/*[local-name()='version'])[1])" \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  short_version="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item/*[local-name()='shortVersionString'])[1])" \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  minimum_update="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item/*[local-name()='minimumUpdateVersion'])[1])" \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  url="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item/enclosure)[1]/@url)" \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  signature="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item/enclosure)[1]/@*[local-name()='edSignature'])" \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  declared_length="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item/enclosure)[1]/@length)" \
    "$SPARKLE_BRIDGE_APPCAST_PATH")"
  actual_length="$(/usr/bin/stat -f %z "$SPARKLE_BRIDGE_DMG_PATH")"

  [[ "$item_count" == "1" ]] || die "pinned bridge appcast must contain one item"
  [[ "$build" == "$SPARKLE_BRIDGE_BUILD" ]] || die "unexpected bridge build: $build"
  [[ "$short_version" == "$SPARKLE_BRIDGE_VERSION" ]] || \
    die "unexpected bridge version: $short_version"
  [[ -z "$minimum_update" ]] || die "bridge item must not have minimumUpdateVersion"
  [[ "$url" == "$SPARKLE_BRIDGE_DMG_URL" ]] || die "unexpected bridge URL: $url"
  [[ "$declared_length" == "$actual_length" ]] || \
    die "bridge enclosure length does not match the pinned DMG"
  [[ -n "$signature" ]] || die "bridge enclosure has no EdDSA signature"
  expected_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
  "$SPARKLE_KEY_TOOL" verify \
    "$expected_public_key" "$SPARKLE_BRIDGE_DMG_PATH" "$signature" >/dev/null || \
    die "bridge DMG failed EdDSA verification against SUPublicEDKey"
  verify_dmg_signature "$SPARKLE_BRIDGE_DMG_PATH"
  run /usr/bin/xcrun stapler validate -v "$SPARKLE_BRIDGE_DMG_PATH"
  log "verified pinned Sparkle bridge build $SPARKLE_BRIDGE_BUILD"
}

verify_appcast() {
  local appcast="$1"
  local channel_title item_count version short_version minimum_update
  local minimum_system hardware_requirements
  local update_url signature declared_length actual_length expected_public_key
  local bridge_version bridge_short_version bridge_minimum_update bridge_url
  local bridge_signature bridge_declared_length bridge_actual_length
  require_file "$appcast"
  require_file "$DMG_PATH"
  require_file "$SPARKLE_BRIDGE_DMG_PATH"
  if is_true "$DRY_RUN"; then
    log "[dry-run] verify two-hop appcast selection, URLs, lengths, minimum macOS, and EdDSA signatures"
    return
  fi

  /usr/bin/xmllint --noout "$appcast" || die "generated appcast is not valid XML"
  channel_title="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/title)[1])" "$appcast")"
  item_count="$(/usr/bin/xmllint --xpath 'count(/rss/channel/item)' "$appcast")"
  version="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='version'])[1])" "$appcast")"
  short_version="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='shortVersionString'])[1])" "$appcast")"
  minimum_update="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[1]/*[local-name()='minimumUpdateVersion'])[1])" \
    "$appcast")"
  minimum_system="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='minimumSystemVersion'])[1])" "$appcast")"
  hardware_requirements="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='hardwareRequirements'])[1])" "$appcast")"
  update_url="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='enclosure'])[1]/@url)" "$appcast")"
  signature="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='enclosure'])[1]/@*[local-name()='edSignature'])" "$appcast")"
  declared_length="$(/usr/bin/xmllint --xpath \
    "string((//*[local-name()='enclosure'])[1]/@length)" "$appcast")"
  actual_length="$(/usr/bin/stat -f %z "$DMG_PATH")"
  bridge_version="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[2]/*[local-name()='version'])[1])" "$appcast")"
  bridge_short_version="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[2]/*[local-name()='shortVersionString'])[1])" \
    "$appcast")"
  bridge_minimum_update="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[2]/*[local-name()='minimumUpdateVersion'])[1])" \
    "$appcast")"
  bridge_url="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[2]/enclosure)[1]/@url)" "$appcast")"
  bridge_signature="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[2]/enclosure)[1]/@*[local-name()='edSignature'])" \
    "$appcast")"
  bridge_declared_length="$(/usr/bin/xmllint --xpath \
    "string((/rss/channel/item[2]/enclosure)[1]/@length)" "$appcast")"
  bridge_actual_length="$(/usr/bin/stat -f %z "$SPARKLE_BRIDGE_DMG_PATH")"

  [[ "$channel_title" == "LLM Pulse" ]] || \
    die "appcast title is $channel_title, expected LLM Pulse"
  [[ "$item_count" == "2" ]] || die "appcast must contain current and bridge items"
  [[ "$version" == "$SOURCE_BUILD" ]] || die "appcast build is $version, expected $SOURCE_BUILD"
  [[ "$short_version" == "$VERSION" ]] || \
    die "appcast version is $short_version, expected $VERSION"
  [[ "$minimum_update" == "$SPARKLE_BRIDGE_BUILD" ]] || \
    die "current appcast item must require host build $SPARKLE_BRIDGE_BUILD"
  /usr/bin/awk -v version="$minimum_system" 'BEGIN {
    gsub(/^[[:space:]]+/, "", version)
    gsub(/[[:space:]]+$/, "", version)
    exit !(version == "14" || version == "14.0" || version == "14.0.0")
  }' || die "appcast minimum macOS must be 14.0: $minimum_system"
  if [[ -n "$hardware_requirements" ]]; then
    [[ "$hardware_requirements" == *"arm64"* && "$hardware_requirements" == *"x86_64"* ]] || \
      die "appcast unexpectedly restricts hardware: $hardware_requirements"
  fi
  [[ "$update_url" == "$RELEASE_DOWNLOAD_ROOT/v$VERSION/$(basename "$DMG_PATH")" ]] || \
    die "unexpected appcast enclosure URL: $update_url"
  [[ "$declared_length" == "$actual_length" ]] || \
    die "appcast length $declared_length does not match DMG length $actual_length"
  [[ -n "$signature" ]] || die "appcast enclosure has no EdDSA signature"
  expected_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
  "$SPARKLE_KEY_TOOL" verify "$expected_public_key" "$DMG_PATH" "$signature" >/dev/null || \
    die "Sparkle EdDSA signature verification failed against SUPublicEDKey"
  [[ "$bridge_version" == "$SPARKLE_BRIDGE_BUILD" ]] || \
    die "second appcast item is not bridge build $SPARKLE_BRIDGE_BUILD"
  [[ "$bridge_short_version" == "$SPARKLE_BRIDGE_VERSION" ]] || \
    die "unexpected bridge short version: $bridge_short_version"
  [[ -z "$bridge_minimum_update" ]] || \
    die "bridge item must remain available to pre-bridge hosts"
  [[ "$bridge_url" == "$SPARKLE_BRIDGE_DMG_URL" ]] || \
    die "unexpected bridge enclosure URL: $bridge_url"
  [[ "$bridge_declared_length" == "$bridge_actual_length" ]] || \
    die "bridge appcast length does not match the pinned DMG"
  [[ -n "$bridge_signature" ]] || die "bridge appcast enclosure has no EdDSA signature"
  "$SPARKLE_KEY_TOOL" verify \
    "$expected_public_key" "$SPARKLE_BRIDGE_DMG_PATH" "$bridge_signature" >/dev/null || \
    die "Sparkle bridge signature verification failed against SUPublicEDKey"
  log "verified two-hop Sparkle appcast and both EdDSA update signatures"
}

generate_and_verify_appcast() {
  local source_dir="$WORK_DIR/appcast-source"
  local source_dmg
  source_dmg="$source_dir/$(basename "$DMG_PATH")"
  local source_notes="$source_dir/LLM-Pulse-$VERSION.md"
  local generated_current_appcast="$source_dir/current-appcast.xml"
  local generated_appcast="$source_dir/appcast.xml"

  log "generating Sparkle appcast from the final notarized DMG"
  require_clean_worktree
  validate_release_manifest
  require_file "$DMG_PATH"
  require_file "$RELEASE_NOTES_PATH"
  run /usr/bin/xcrun stapler validate -v "$DMG_PATH"
  verify_dmg_signature "$DMG_PATH"
  resolve_sparkle_tools_and_key
  safe_remove_release_path "$source_dir"
  run /bin/mkdir -p "$source_dir" "$OUTPUT_DIR"
  run /bin/rm -f "$APPCAST_PATH"
  run /bin/cp "$DMG_PATH" "$source_dmg"
  run /bin/cp "$RELEASE_NOTES_PATH" "$source_notes"
  if [[ "$SPARKLE_KEY_SOURCE" == "file" ]]; then
    run "$SPARKLE_GENERATE_APPCAST" \
      --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
      --download-url-prefix "$RELEASE_DOWNLOAD_ROOT/v$VERSION/" \
      --embed-release-notes \
      --link "$PROJECT_URL" \
      --versions "$SOURCE_BUILD" \
      --minimum-update-version "$SPARKLE_BRIDGE_BUILD" \
      --maximum-versions 1 \
      --maximum-deltas 0 \
      -o "$generated_current_appcast" \
      "$source_dir"
  else
    run "$SPARKLE_GENERATE_APPCAST" \
      --account "$SPARKLE_ACCOUNT" \
      --download-url-prefix "$RELEASE_DOWNLOAD_ROOT/v$VERSION/" \
      --embed-release-notes \
      --link "$PROJECT_URL" \
      --versions "$SOURCE_BUILD" \
      --minimum-update-version "$SPARKLE_BRIDGE_BUILD" \
      --maximum-versions 1 \
      --maximum-deltas 0 \
      -o "$generated_current_appcast" \
      "$source_dir"
  fi
  download_and_verify_sparkle_bridge_release
  run /usr/bin/python3 "$SPARKLE_APPCAST_MERGE_TOOL" \
    --current "$generated_current_appcast" \
    --bridge "$SPARKLE_BRIDGE_APPCAST_PATH" \
    --output "$generated_appcast" \
    --current-build "$SOURCE_BUILD" \
    --bridge-build "$SPARKLE_BRIDGE_BUILD" \
    --minimum-update-build "$SPARKLE_BRIDGE_BUILD" \
    --channel-title "LLM Pulse"
  run /bin/cp "$generated_appcast" "$APPCAST_PATH"
  verify_appcast "$APPCAST_PATH"
  log "Sparkle appcast ready: $APPCAST_PATH"
}

verify_final_release() {
  local mounted_app="$MOUNT_DIR/$DISTRIBUTED_APP_NAME"
  local app_count app_entry getfileinfo_path volume_attributes
  log "performing final offline verification"
  require_clean_worktree
  validate_release_manifest
  require_file "$DMG_PATH"
  run /usr/bin/xcrun stapler validate -v "$DMG_PATH"
  verify_dmg_signature "$DMG_PATH"
  run /usr/bin/hdiutil verify "$DMG_PATH"
  run /usr/sbin/spctl --assess --type open --context context:primary-signature \
    --verbose=4 "$DMG_PATH"

  safe_remove_release_path "$MOUNT_DIR"
  run /bin/mkdir -p "$MOUNT_DIR"
  run /usr/bin/hdiutil attach "$DMG_PATH" -readonly -noverify -noautoopen \
    -mountpoint "$MOUNT_DIR"
  if ! is_true "$DRY_RUN"; then
    MOUNTED=1
  fi
  verify_universal_code "$mounted_app"
  verify_app_metadata "$mounted_app"
  verify_app_signature "$mounted_app"
  run /usr/bin/xcrun stapler validate -v "$mounted_app"
  run /usr/sbin/spctl --assess --type execute --verbose=4 "$mounted_app"
  if ! is_true "$DRY_RUN"; then
    app_count=0
    for app_entry in "$MOUNT_DIR"/*.app; do
      [[ -e "$app_entry" ]] || continue
      app_count=$((app_count + 1))
    done
    [[ "$app_count" -eq 1 ]] || die "DMG must contain exactly one application bundle"
    [[ -L "$MOUNT_DIR/Applications" ]] || die "DMG Applications item is not a symlink"
    [[ "$(/usr/bin/readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] || \
      die "DMG Applications symlink has the wrong target"
    [[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]] || die "DMG volume icon is missing"
    if [[ -n "$BACKGROUND_PATH" ]] && [[ -f "${BACKGROUND_PATH%.*}@2x.${BACKGROUND_PATH##*.}" ]]; then
      [[ -f "$MOUNT_DIR/.background/dmg-background.tiff" ]] || \
        die "DMG HiDPI background TIFF is missing"
    fi
    getfileinfo_path="$(/usr/bin/xcrun --find GetFileInfo 2>/dev/null || true)"
    [[ -n "$getfileinfo_path" ]] || die "GetFileInfo is required for final DMG validation"
    volume_attributes="$("$getfileinfo_path" -a "$MOUNT_DIR")"
    [[ "$volume_attributes" == *C* ]] || die "DMG custom volume icon bit is not set"
  else
    log "[dry-run] verify Applications symlink, HiDPI background, and custom volume icon bit"
  fi
  run /usr/bin/hdiutil detach "$MOUNT_DIR"
  if ! is_true "$DRY_RUN"; then
    MOUNTED=0
  fi
  log "final DMG and contained app passed all verification checks"
}

write_checksum() {
  local dmg_basename checksum_basename
  validate_release_manifest
  require_file "$DMG_PATH"
  dmg_basename="$(basename "$DMG_PATH")"
  checksum_basename="$(basename "$CHECKSUM_PATH")"
  if is_true "$DRY_RUN"; then
    log "[dry-run] (cd $OUTPUT_DIR && shasum -a 256 $dmg_basename > $checksum_basename)"
    return
  fi
  (
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "$dmg_basename" >"$checksum_basename"
  )
  log "SHA-256 written: $CHECKSUM_PATH"
}

preflight() {
  require_file "$PROJECT_SPEC"
  require_file "$INFO_PLIST"
  require_file "$SPARKLE_APPCAST_MERGE_TOOL"
  require_command git
  require_command plutil
  require_command codesign
  require_command security
  require_command xcrun
  require_command xcodebuild
  require_command xcodegen
  require_command ditto
  require_command file
  require_command find
  require_command lipo
  require_command otool
  require_command hdiutil
  require_command tiffutil
  require_command sips
  require_command spctl
  require_command shasum
  require_command xmllint
  require_command base64
  require_command curl
  require_command python3
  if ! is_true "$SKIP_FINDER_LAYOUT"; then
    require_command osascript
  fi
  validate_dmg_background_assets
  validate_source_sparkle_configuration
  validate_release_source_versions
  validate_file_backed_sparkle_key
  require_clean_worktree
  resolve_git_head
  validate_notary_profile
}

run_stage() {
  case "$STAGE" in
    all)
      build_and_sign_app
      notarize_and_staple_app
      create_and_sign_dmg
      notarize_and_staple_dmg
      verify_final_release
      write_checksum
      generate_and_verify_appcast
      ;;
    build)
      build_and_sign_app
      ;;
    notarize-app|app-notarize)
      notarize_and_staple_app
      ;;
    package)
      create_and_sign_dmg
      ;;
    notarize-dmg|dmg-notarize)
      notarize_and_staple_dmg
      ;;
    verify)
      verify_final_release
      write_checksum
      generate_and_verify_appcast
      ;;
    appcast)
      generate_and_verify_appcast
      ;;
    checksum)
      require_clean_worktree
      write_checksum
      ;;
  esac
}

main() {
  parse_arguments "$@"
  cd "$REPO_ROOT"
  initialize_paths
  validate_options
  preflight
  log "stage=$STAGE version=$VERSION output=$OUTPUT_DIR"
  if is_true "$DRY_RUN"; then
    warn "DRY_RUN is enabled; no mutating command will execute"
  fi
  run_stage
  log "release stage completed successfully"
}

# Only run when executed. Sourcing exposes the individual functions so release
# logic can be tested without building, signing, or publishing anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
