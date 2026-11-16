#!/usr/bin/env bash
# Phone -> sync server -> independent restore on this PC.
#
# 1. Runs integration_test/sync_device_test.dart on the phone: it fills a
#    vault, connects it to the server and backs it up.
# 2. On the PC, restores that backup from the recovery code alone (a
#    "new device") and compares every file's SHA-256 with what the phone had.
#
# Usage: tool/sync_phone_test.sh <device-id> [server-url-as-the-phone-sees-it] [server-url-as-this-pc-sees-it]
#
# With no URLs, the phone reaches the PC's port 8080 through the USB cable
# (adb reverse), which needs no firewall changes.
set -uo pipefail

DEVICE="${1:?device id}"
PHONE_URL="${2:-http://127.0.0.1:8080}"
PC_URL="${3:-http://127.0.0.1:8080}"
ADB="${ADB:-adb}"
INVITE="${SYNC_INVITE:-dev-invite}"
WORK="$(mktemp -d)"
LOG="$WORK/phone.log"

source "$(dirname "$0")/phone_guard.sh"
phone_guard "$ADB" "$DEVICE" "${PKG:-com.videotrimmer.local}" || exit 1

if [ "$PHONE_URL" = "http://127.0.0.1:8080" ]; then
  "$ADB" -s "$DEVICE" reverse tcp:8080 tcp:8080 >/dev/null
fi
"$ADB" -s "$DEVICE" forward --remove-all >/dev/null 2>&1 || true

flutter test integration_test/sync_device_test.dart -d "$DEVICE" \
  --dart-define=SYNC_SERVER="$PHONE_URL" --dart-define=SYNC_INVITE="$INVITE" > "$LOG" 2>&1
grep -E "^\[sync\] (first|second)|All tests passed|Some tests failed|\[E\]" "$LOG" | sed 's/^/phone: /'
if ! grep -q "All tests passed" "$LOG"; then
  grep -E "Expected|Actual|Exception|Error" "$LOG" | head -20
  echo "RESULT: phone-side backup FAILED (log: $LOG)"
  exit 1
fi

ACCOUNT="$(grep -oE '^\[sync\] account=[0-9a-f]+' "$LOG" | cut -d= -f2)"
SECRET="$(grep -oE '^\[sync\] secret=[0-9a-f]+' "$LOG" | cut -d= -f2)"
WORK_W="$(cygpath -m "$WORK" 2>/dev/null || echo "$WORK")"

( cd packages/sync_core
  dart run bin/sync_cli.dart recover --server "$PC_URL" --account "$ACCOUNT" --secret "$SECRET" --state "$WORK_W/newdevice.json" | sed 's/^/pc:    /'
  dart run bin/sync_cli.dart restore --state "$WORK_W/newdevice.json" "$WORK_W/restored" | sed -E 's#restored .*[\\/]restored[\\/]#pc:    restored #' )

FAIL=0
while read -r _ _ rest; do
  HASH="${rest##* }"
  NAME="${rest% *}"
  if [ ! -f "$WORK/restored/$NAME" ]; then echo "MISSING   $NAME"; FAIL=1; continue; fi
  GOT="$(sha256sum "$WORK/restored/$NAME" | cut -d' ' -f1)"
  if [ "$GOT" = "$HASH" ]; then echo "IDENTICAL $NAME"; else echo "DIFFERENT $NAME"; FAIL=1; fi
done < <(grep -E '^\[sync\] sha256 ' "$LOG" | tr -d '\r')

echo "account on server: $ACCOUNT"
rm -rf "$WORK/restored" "$WORK/newdevice.json" "$WORK/newdevice.json.journal"
[ "$FAIL" = 0 ] && echo "RESULT: phone -> server -> restore OK" || { echo "RESULT: restore did NOT match"; exit 1; }
