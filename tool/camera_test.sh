#!/usr/bin/env bash
# Runs integration_test/camera_device_test.dart and saves a screenshot each
# time the test prints "[cam] shot <name>" (to check the preview is upright
# and the right way round). Screenshots go to $SHOTS (default: a temp dir).
#
# Usage: tool/camera_test.sh <device-id>
set -uo pipefail

DEVICE="${1:?device id}"
ADB="${ADB:-adb}"
PKG="com.example.gesture_unlock"
LOG="$(mktemp)"
SHOTS="${SHOTS:-$(mktemp -d)}"

source "$(dirname "$0")/phone_guard.sh"
phone_guard "$ADB" "$DEVICE" "$PKG" || exit 1

ADB="$ADB" bash "$(dirname "$0")/device_test.sh" integration_test/camera_device_test.dart "$DEVICE" > "$LOG" 2>&1 &
TEST=$!

handled=0
while kill -0 "$TEST" 2>/dev/null; do
  mapfile -t asks < <(grep -E '^\[cam\] shot' "$LOG")
  while [ "$handled" -lt "${#asks[@]}" ]; do
    name="${asks[$handled]##*shot }"
    "$ADB" -s "$DEVICE" exec-out screencap -p > "$SHOTS/$name.png"
    echo "script: saved $SHOTS/$name.png"
    handled=$((handled + 1))
  done
  sleep 0.3
done
wait "$TEST"
STATUS=$?
grep -E "^\[cam\]|All tests passed|Some tests failed|Timed out|Expected|Actual|EXCEPTION|STOP|Error" "$LOG" | cut -c1-400
echo "log: $LOG"
echo "shots: $SHOTS"
exit $STATUS
