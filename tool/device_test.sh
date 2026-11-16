#!/usr/bin/env bash
# Runs an integration test on a connected device/emulator,
# granting the cover app's storage permissions as soon as
# `flutter test` installs the app (so no system dialog interrupts the run).
#
# Usage:  tool/device_test.sh integration_test/app_flow_test.dart [device-id] [extra flutter args]
# e.g.    tool/device_test.sh integration_test/app_flow_test.dart <id> --dart-define=SYNC_SERVER=http://127.0.0.1:8080
set -euo pipefail

TEST="${1:?test file}"
DEVICE="${2:-emulator-5554}"
PKG="${PKG:-com.videotrimmer.local}"
ADB="${ADB:-adb}"

source "$(dirname "$0")/phone_guard.sh"
phone_guard "$ADB" "$DEVICE" "$PKG" || exit 1

(
  for _ in $(seq 1 600); do
    if "$ADB" -s "$DEVICE" shell pm list packages 2>/dev/null | grep -q "$PKG"; then
      for p in READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_AUDIO RECORD_AUDIO CAMERA; do
        "$ADB" -s "$DEVICE" shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1 || true
      done
      "$ADB" -s "$DEVICE" shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
      exit 0
    fi
    sleep 0.3
  done
) &
GRANTER=$!

flutter test "$TEST" -d "$DEVICE" --dart-define=SECURE_WINDOW=false "${@:3}"
STATUS=$?
kill "$GRANTER" 2>/dev/null || true
exit $STATUS
