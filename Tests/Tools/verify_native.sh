#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: ./Tests/Tools/verify_native.sh --app ABSOLUTE.app --output ABSOLUTE_DIRECTORY [options]

Run one isolated fixture from a prebuilt Simple Codex Bar bundle.
The output must be new or empty, with an existing writable parent.
Its canonical path must not overlap .build/native-verification in either direction.
No app build, normal user mode, or existing-app stop is performed.

  --case appearance|simulation|localization|shortcuts  Default: appearance
  --appearance native|standard              Default: native
  --timeout-seconds N                       Decimal in (0, 86400]; default: 300
  --help                                    Show help without running a fixture

Every case uses --demo. Evidence is saved as manifest.json, stdout.log,
stderr.log and the case's own JSON/PNG files. A passed manifest requires
normal exit, a new report with passed=true, completed fixture cleanup,
and unchanged observed source and app fingerprints.
HELP
}

fail() {
    printf 'verify_native: %s\n' "$1" >&2
    exit 2
}

APP=""
OUTPUT=""
CASE_NAME=appearance
APPEARANCE=native
TIMEOUT_SECONDS=300
HELP=0
SEEN_OPTIONS=" "
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            [[ "$HELP" == 0 ]] || fail "Duplicate option: --help"
            HELP=1
            shift
            ;;
        --app|--output|--case|--appearance|--timeout-seconds)
            [[ "$SEEN_OPTIONS" != *" $1 "* ]] || fail "Duplicate option: $1"
            SEEN_OPTIONS+="$1 "
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
            case "$1" in
                --app) APP="$2" ;;
                --output) OUTPUT="$2" ;;
                --case) CASE_NAME="$2" ;;
                --appearance) APPEARANCE="$2" ;;
                --timeout-seconds) TIMEOUT_SECONDS="$2" ;;
            esac
            shift 2
            ;;
        *) fail "Unknown option: $1. Only fixed fixture options are accepted." ;;
    esac
done

case "$CASE_NAME" in
    appearance) FIXTURE_FLAG=--verify-panel-appearance; REPORT_NAME=appearance-checks.json ;;
    simulation) FIXTURE_FLAG=--verify-simulation; REPORT_NAME=simulation-flow.json ;;
    shortcuts) FIXTURE_FLAG=--verify-shortcuts; REPORT_NAME=keyboard-checks.json ;;
    localization) FIXTURE_FLAG=--verify-localization; REPORT_NAME=localization-flow.json ;;
    *) fail "Unknown case: $CASE_NAME" ;;
esac
case "$APPEARANCE" in
    native|standard) ;;
    *) fail "Unknown appearance: $APPEARANCE" ;;
esac
python3 - "$TIMEOUT_SECONDS" <<'PY'
import math
import re
import sys

value = sys.argv[1]
if not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)", value):
    print("verify_native: --timeout-seconds must be a positive decimal in (0, 86400].", file=sys.stderr)
    sys.exit(2)
number = float(value)
if not math.isfinite(number) or not 0 < number <= 86400:
    print("verify_native: --timeout-seconds must be in (0, 86400].", file=sys.stderr)
    sys.exit(2)
PY
if [[ "$HELP" == 1 ]]; then
    usage
    exit 0
fi
[[ -n "$APP" && -n "$OUTPUT" ]] || fail "Both --app and --output are required."
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
python3 - "$ROOT" "$APP" "$OUTPUT" <<'PY'
import os
from pathlib import Path
import plistlib
import sys

try:
    repo, app_input, output_input = map(Path, sys.argv[1:])
    if not app_input.is_absolute() or not output_input.is_absolute():
        raise ValueError("--app and --output must be absolute paths")
    app = app_input.resolve(strict=True)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("--app must be an existing .app directory")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict):
        raise ValueError("app metadata must be a dictionary")
    if info.get("CFBundlePackageType") != "APPL" or info.get("CFBundleIdentifier") != "app.mayfiles.SimpleCodexBar":
        raise ValueError("app must be a Simple Codex Bar bundle (app.mayfiles.SimpleCodexBar)")
    if info.get("CFBundleExecutable") != "SimpleCodexBar":
        raise ValueError("unexpected app executable")
    binary = (app / "Contents/MacOS/SimpleCodexBar").resolve(strict=True)
    if not binary.is_relative_to(app / "Contents/MacOS") or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("app executable must be a contained executable file")
    output = output_input.resolve()
    metadata = repo / ".git"
    if output == app or output.is_relative_to(app) or output == metadata or output.is_relative_to(metadata):
        raise ValueError("output must be outside the app and Git metadata")
    cache = (repo / ".build/native-verification").resolve()
    if output == cache or output.is_relative_to(cache) or cache.is_relative_to(output):
        raise ValueError("output must not overlap the native verification compiler cache")
    if output.exists():
        if not output.is_dir() or any(output.iterdir()) or not os.access(output, os.W_OK):
            raise ValueError("output must be an empty writable directory")
    elif not output.parent.is_dir() or not os.access(output.parent, os.W_OK):
        raise ValueError("new output requires an existing writable parent directory")
except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
    print(f"verify_native: {error}", file=sys.stderr)
    sys.exit(2)
PY

EVIDENCE_SOURCE="$ROOT/scripts/lib/VerificationEvidence.swift"
EVIDENCE_CACHE="$ROOT/.build/native-verification"
EVIDENCE_TOOL="$EVIDENCE_CACHE/VerificationEvidence"
[[ -f "$EVIDENCE_SOURCE" ]] || fail "Missing shared evidence tool source: $EVIDENCE_SOURCE"
mkdir -p "$EVIDENCE_CACHE"
swiftc -module-cache-path "$EVIDENCE_CACHE/ModuleCache" "$EVIDENCE_SOURCE" -o "$EVIDENCE_TOOL"
FIXTURE_ARGUMENTS=(--demo)
if [[ "$APPEARANCE" == standard ]]; then
    FIXTURE_ARGUMENTS+=(--standard-appearance)
fi
FIXTURE_ARGUMENTS+=("$FIXTURE_FLAG" "$OUTPUT")
EVIDENCE_ARGUMENTS=(--project simple-codex-bar --repo "$ROOT" --app "$APP" --output "$OUTPUT"
    --expected-bundle-id app.mayfiles.SimpleCodexBar --report "$OUTPUT/$REPORT_NAME"
    --success-field passed --cleanup-field fixtureDirectory --timeout-seconds "$TIMEOUT_SECONDS")
if [[ "$CASE_NAME" == localization ]]; then
    EVIDENCE_ARGUMENTS+=(--localization-cleanup true)
fi
exec "$EVIDENCE_TOOL" "${EVIDENCE_ARGUMENTS[@]}" \
    -- "$APP/Contents/MacOS/SimpleCodexBar" "${FIXTURE_ARGUMENTS[@]}"
