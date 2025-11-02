#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ID="${PACKAGE_ID:?PACKAGE_ID environment variable is required}"
INSTALL_MODE="${INSTALL_MODE:-single}"

if [ "$INSTALL_MODE" = "split" ]; then
  if [ ! -f "split-apk/list.txt" ]; then
    echo "Expected split-apk/list.txt to exist for split installation" >&2
    exit 1
  fi
  mapfile -t APK_FILES < split-apk/list.txt
  if [ "${#APK_FILES[@]}" -eq 0 ]; then
    echo "No APK files listed for split installation" >&2
    exit 2
  fi
  adb install-multiple "${APK_FILES[@]}"
else
  if [ ! -f "app.apk" ]; then
    echo "app.apk not found for installation" >&2
    exit 3
  fi
adb install app.apk
fi

if ! adb shell pm list packages | grep -Fxq "package:$PACKAGE_ID"; then
  echo "Package $PACKAGE_ID was not found in installed packages" >&2
  exit 4
fi

echo "Enabling root adb access"
adb root >/dev/null
adb wait-for-device
adb shell setenforce 0 >/dev/null 2>&1 || true

echo "Launching $PACKAGE_ID"
if ! adb shell monkey -p "$PACKAGE_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
  echo "Failed to launch $PACKAGE_ID via monkey" >&2
  exit 5
fi

sleep 30

PID=$(adb shell pidof "$PACKAGE_ID" | tr -d '\r')
if [ -z "$PID" ]; then
  echo "Unable to determine PID for $PACKAGE_ID" >&2
  exit 6
fi

echo "Captured process id: $PID"

mkdir -p artifacts
MAPS_PATH="artifacts/${PACKAGE_ID}_maps.txt"
adb shell cat "/proc/$PID/maps" | tr -d '\r' >"$MAPS_PATH"

LIB_LINE=$(grep -m1 'libg.so' "$MAPS_PATH" || true)
if [ -z "$LIB_LINE" ]; then
  echo "Could not locate libg mapping in process maps" >&2
  exit 7
fi

RANGE=$(echo "$LIB_LINE" | awk '{print $1}')
START_HEX=${RANGE%-*}
END_HEX=${RANGE#*-}
START_DEC=$((16#$START_HEX))
END_DEC=$((16#$END_HEX))
SIZE=$((END_DEC - START_DEC))
if [ "$SIZE" -le 0 ]; then
  echo "Computed invalid mapping size for libg: $SIZE" >&2
  exit 8
fi

PAGE_SIZE=4096
SKIP=$((START_DEC / PAGE_SIZE))
COUNT=$(((SIZE + PAGE_SIZE - 1) / PAGE_SIZE))
REMOTE_DUMP="/data/local/tmp/libg-${PID}.mem"

echo "Dumping libg region (start=0x$START_HEX size=$SIZE bytes)"
adb shell "dd if=/proc/$PID/mem of=$REMOTE_DUMP bs=$PAGE_SIZE skip=$SKIP count=$COUNT" >/dev/null

LOCAL_DUMP="artifacts/libg.mem"
adb pull "$REMOTE_DUMP" "$LOCAL_DUMP" >/dev/null
adb shell rm -f "$REMOTE_DUMP"

echo "libg memory dump saved to $LOCAL_DUMP"
