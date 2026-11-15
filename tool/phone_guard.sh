#!/usr/bin/env bash
# Sourced by the phone test scripts.
#
# `flutter test` reinstalls the app and uninstalls it when the run ends,
# which erases the app's private data on the phone. Test runs never leave a
# vault behind, so a vault found there belongs to the phone's owner: refuse
# to run rather than erase it. Nothing outside the app's own private storage
# (photos, downloads, other apps) is ever touched by the tests.
#
# Override, only when that vault is disposable: ALLOW_APP_DATA_RESET=1
phone_guard() {
  local adb="$1" device="$2" pkg="$3"
  if [ "${ALLOW_APP_DATA_RESET:-0}" = "1" ]; then return 0; fi
  if ! "$adb" -s "$device" shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:$pkg"; then
    return 0 # not installed: nothing to lose
  fi
  local listing
  listing="$("$adb" -s "$device" shell run-as "$pkg" ls -a files 2>&1 | tr -d '\r')"
  if printf '%s\n' "$listing" | grep -qiE "not debuggable|unknown package|run-as:"; then
    echo "STOP: the app on this phone is not a debug build, so its data can't be checked."
    echo "Running tests would replace it and erase whatever it holds. Nothing was changed."
    return 1
  fi
  if printf '%s\n' "$listing" | grep -qx "thumbnails.cache"; then
    echo "STOP: the app on this phone holds a vault. Running tests would erase it."
    echo "Nothing was changed. Move that data out first, or set ALLOW_APP_DATA_RESET=1 if it is disposable."
    return 1
  fi
  return 0
}
