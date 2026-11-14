#!/usr/bin/env bash
# Runs an integration test on a connected device/emulator with the motion
# module switched off, granting the cover app's storage permissions as soon as
# `flutter test` installs the app (so no system dialog interrupts the run).
#
# Usage:  tool/device_test.sh integration_test/app_flow_test.dart [device-id]
set -euo pipefail

TEST="${1:?test file}"
DEVICE="${2:-emulator-5554}"
PKG="com.example.gesture_unlock"
ADB="${ADB:-adb}"

(
  for _ in $(seq 1 600); do
    if "$ADB" -s "$DEVICE" shell pm list packages 2>/dev/null | grep -q "$PKG"; then
      for p in READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_AUDIO; do
        "$ADB" -s "$DEVICE" shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1 || true
      done
      "$ADB" -s "$DEVICE" shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
      exit 0
    fi
    sleep 0.3
  done
) &
GRANTER=$!

flutter test "$TEST" -d "$DEVICE" --dart-define=GESTURES=false --dart-define=SECURE_WINDOW=false
STATUS=$?
kill "$GRANTER" 2>/dev/null || true
exit $STATUS
