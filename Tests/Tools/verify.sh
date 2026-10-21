#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/TestResults"
RESULTS="$(mktemp -d "$ROOT/TestResults/simulation.XXXXXX")"
APP_OUTPUT="$ROOT/dist/tests/simulation"
./scripts/app.py test 2>&1 | tee "$RESULTS/swift-test.log"
./scripts/app.py build --configuration release --arch native --sign ad-hoc --output "$APP_OUTPUT" 2>&1 | tee "$RESULTS/build.log"
APP="$APP_OUTPUT/SimpleCodexBar.app"
bash Tests/Tools/verify_native.sh --app "$APP" --output "$RESULTS/native-simulation" --case simulation
bash Tests/Tools/verify_native.sh --app "$APP" --output "$RESULTS/native-standard" --case simulation --appearance standard
"$APP/Contents/MacOS/SimpleCodexBar" --demo --screenshot "$RESULTS/popover-demo.png"
test -s "$RESULTS/popover-demo.png"
printf 'Verification artifacts: %s\n' "$RESULTS"
