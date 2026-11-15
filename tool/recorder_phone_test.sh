#!/usr/bin/env bash
# Runs integration_test/recorder_device_test.dart and plays the user's part:
# when the test prints "[rec] press …", volume-down is pressed three times;
# for "screen-off" the screen is turned off first; "[rec] wake" wakes it.
#
# Screen-off presses must be *hardware* key events. `input keyevent` injects
# keys, and Android delivers injected keys to the (dark) screen instead of
# media sessions, so:
#   * on an emulator, the script gets root and writes to the keyboard device
#     (exactly what a real button does);
#   * on a physical phone, the screen-off phase is skipped unless HUMAN=1,
#     in which case it asks you to press the real button.
# The phone may need unlocking afterwards.
#
# Usage: [HUMAN=1] tool/recorder_phone_test.sh <device-id>
set -uo pipefail

DEVICE="${1:?device id}"
ADB="${ADB:-adb}"
PKG="com.example.gesture_unlock"
LOG="$(mktemp)"

source "$(dirname "$0")/phone_guard.sh"
phone_guard "$ADB" "$DEVICE" "$PKG" || exit 1

EMULATOR=0
KEYDEV=""
case "$DEVICE" in
  emulator-*)
    EMULATOR=1
    "$ADB" -s "$DEVICE" root >/dev/null 2>&1
    sleep 2
    "$ADB" -s "$DEVICE" wait-for-device
    KEYDEV="$("$ADB" -s "$DEVICE" shell getevent -pl 2>/dev/null | tr -d '\r' |
      awk '/^add device/{d=$4} /KEY_VOLUMEDOWN/{print d; exit}')"
    ;;
esac
SCREEN_OFF=true
if [ "$EMULATOR" = 0 ] && [ "${HUMAN:-0}" != 1 ]; then SCREEN_OFF=false; fi

"$ADB" -s "$DEVICE" forward --remove-all >/dev/null 2>&1 || true
ADB="$ADB" bash "$(dirname "$0")/device_test.sh" integration_test/recorder_device_test.dart "$DEVICE" \
  --dart-define=SCREEN_OFF_PHASE=$SCREEN_OFF > "$LOG" 2>&1 &
TEST=$!

press() {
  if [ -n "$KEYDEV" ]; then
    local one="sendevent $KEYDEV 1 114 1; sendevent $KEYDEV 0 0 0; sendevent $KEYDEV 1 114 0; sendevent $KEYDEV 0 0 0"
    "$ADB" -s "$DEVICE" shell "$one; sleep 0.15; $one; sleep 0.15; $one"
  else
    "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_VOLUME_DOWN KEYCODE_VOLUME_DOWN KEYCODE_VOLUME_DOWN
  fi
}

screen_off_press() {
  if [ -n "$KEYDEV" ]; then
    press
  else
    echo ">>> Screen is off: press VOLUME-DOWN three times quickly on the phone now <<<"
  fi
}

handled=0
while kill -0 "$TEST" 2>/dev/null; do
  mapfile -t asks < <(grep -E '^\[rec\] (press|wake)' "$LOG")
  while [ "$handled" -lt "${#asks[@]}" ]; do
    ask="${asks[$handled]}"
    case "$ask" in
      *"screen-off (start)"*)
        "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_SLEEP
        sleep 2
        screen_off_press ;;
      *"screen-off (stop)"*) screen_off_press ;;
      *wake*)
        "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP
        # Only dismisses a lock screen that has no PIN (the emulator's).
        "$ADB" -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1 || true ;;
      *) press ;;
    esac
    echo "script: answered \"$ask\""
    handled=$((handled + 1))
  done
  sleep 0.3
done
wait "$TEST"
STATUS=$?
"$ADB" -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
if [ "$EMULATOR" = 1 ]; then "$ADB" -s "$DEVICE" unroot >/dev/null 2>&1 || true; fi
grep -E "^\[rec\]|All tests passed|Some tests failed|Timed out|Expected|Actual|EXCEPTION|STOP" "$LOG" | cut -c1-300
echo "log: $LOG"
exit $STATUS
