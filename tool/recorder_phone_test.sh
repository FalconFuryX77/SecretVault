#!/usr/bin/env bash
# Runs integration_test/recorder_device_test.dart and plays the user's part:
# when the test prints "[rec] press …", the volume keys are pressed (down ×3
# unless it says "up4" or "mixed"); for "screen-off" the screen is turned off
# first; "[rec] wake" wakes it; "[rec] assist …" sends the assist intent (or,
# on an emulator, makes the app the assistant app and presses the assistant
# key, putting the previous assistant back afterwards).
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
PKG="${PKG:-com.videotrimmer.local}"
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
ASSIST_ROLE="android.app.role.ASSISTANT"
PREV_ASSIST=""
ASSIST_SET=0
ADB="$ADB" bash "$(dirname "$0")/device_test.sh" integration_test/recorder_device_test.dart "$DEVICE" \
  --dart-define=SCREEN_OFF_PHASE=$SCREEN_OFF --dart-define=ASSIST_KEY_PHASE=$([ "$EMULATOR" = 1 ] && echo true || echo false) \
  > "$LOG" 2>&1 &
TEST=$!

# press 114 114 114: Linux key codes, 114 volume-down, 115 volume-up.
press() {
  local codes=("$@")
  [ ${#codes[@]} -eq 0 ] && codes=(114 114 114)
  if [ -n "$KEYDEV" ]; then
    local cmd="" c
    for c in "${codes[@]}"; do
      cmd="$cmd sendevent $KEYDEV 1 $c 1; sendevent $KEYDEV 0 0 0; sendevent $KEYDEV 1 $c 0; sendevent $KEYDEV 0 0 0; sleep 0.15;"
    done
    "$ADB" -s "$DEVICE" shell "$cmd"
  else
    local names="" c
    for c in "${codes[@]}"; do
      if [ "$c" = 115 ]; then names="$names KEYCODE_VOLUME_UP"; else names="$names KEYCODE_VOLUME_DOWN"; fi
    done
    "$ADB" -s "$DEVICE" shell input keyevent $names
  fi
}

ASSIST_ACTIVITY="$PKG/.AssistTriggerActivity"
assist_intent() {
  "$ADB" -s "$DEVICE" shell am start -W -a android.intent.action.ASSIST -n "$ASSIST_ACTIVITY" "$@" >/dev/null
}

# Emulator only: make this app the assistant, then press the assistant key.
assist_key() {
  if [ "$ASSIST_SET" = 0 ]; then
    PREV_ASSIST="$("$ADB" -s "$DEVICE" shell cmd role get-role-holders "$ASSIST_ROLE" | tr -d '\r')"
    "$ADB" -s "$DEVICE" shell cmd role add-role-holder "$ASSIST_ROLE" "$PKG"
    ASSIST_SET=1
    sleep 1
  fi
  "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_ASSIST
}

restore_assist() {
  [ "$ASSIST_SET" = 1 ] || return 0
  "$ADB" -s "$DEVICE" shell cmd role remove-role-holder "$ASSIST_ROLE" "$PKG" >/dev/null 2>&1 || true
  if [ -n "$PREV_ASSIST" ]; then
    "$ADB" -s "$DEVICE" shell cmd role add-role-holder "$ASSIST_ROLE" "$PREV_ASSIST" >/dev/null 2>&1 || true
  fi
  ASSIST_SET=0
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
  mapfile -t asks < <(grep -E '^\[rec\] (press|wake|assist)' "$LOG")
  while [ "$handled" -lt "${#asks[@]}" ]; do
    ask="${asks[$handled]}"
    case "$ask" in
      *"screen-off (start)"*)
        "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_SLEEP
        sleep 2
        screen_off_press ;;
      *"screen-off (stop)"*) screen_off_press ;;
      *"press mixed"*) press 115 115 114 115 115 ;;
      *"press up4"*) press 115 115 115 115 ;;
      *"assist-forged"*) assist_intent --es android.intent.extra.REFERRER_NAME android-app://com.android.systemui ;;
      *"assist-key"*) assist_key ;;
      *"assist-done"*) restore_assist ;;
      *"assist ("*) assist_intent ;;
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
restore_assist
"$ADB" -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
if [ "$EMULATOR" = 1 ]; then "$ADB" -s "$DEVICE" unroot >/dev/null 2>&1 || true; fi
grep -E "^\[rec\]|All tests passed|Some tests failed|Timed out|Expected|Actual|EXCEPTION|STOP" "$LOG" | cut -c1-300
echo "log: $LOG"
exit $STATUS
