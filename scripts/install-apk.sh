#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ID="${PACKAGE_ID:?PACKAGE_ID environment variable is required}"
INSTALL_MODE="${INSTALL_MODE:-single}"

ARTIFACTS_DIR="artifacts"
SCREENSHOT_DIR="$ARTIFACTS_DIR/screenshots"
LIBG_DIR="$ARTIFACTS_DIR/libg"
LOGS_DIR="$ARTIFACTS_DIR/logs"

mkdir -p "$SCREENSHOT_DIR" "$LIBG_DIR" "$LOGS_DIR"

RUN_LOG="$LOGS_DIR/run.log"
exec > >(tee -a "$RUN_LOG") 2>&1

step_index=0

sanitize_filename() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_.'
}

capture_screenshot() {
  local description="$1"
  local index
  index=$(printf '%02d' "$step_index")
  local sanitized
  sanitized=$(sanitize_filename "$description")
  local destination="$SCREENSHOT_DIR/step-${index}-${sanitized:-screenshot}.png"

  if ! adb exec-out screencap -p >"$destination" 2>/dev/null; then
    echo "Warning: Failed to capture screenshot for step '$description'" >&2
    rm -f "$destination"
  else
    echo "Captured screenshot: $destination"
  fi

  step_index=$((step_index + 1))
}


capture_logs() {
  local ts prefix
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  prefix="$LOGS_DIR/step-$(printf '%02d' "$step_index")-$ts"

  echo "Collecting failure logs to prefix: $prefix"

  { uname -a || true; echo; adb devices -l || true; } >"${prefix}-host.txt" 2>&1 || true
  adb logcat -v threadtime -d >"${prefix}-logcat.txt" 2>/dev/null || true
  adb logcat -b crash -v threadtime -d >"${prefix}-crash.txt" 2>/dev/null || true
  adb shell getprop >"${prefix}-getprop.txt" 2>/dev/null || true
  adb shell dumpsys package "$PACKAGE_ID" >"${prefix}-dumpsys-package.txt" 2>/dev/null || true

  if [ -n "${PID:-}" ]; then
    adb shell cat "/proc/$PID/maps" >"${prefix}-proc-maps.txt" 2>/dev/null || true
  fi

  # Tombstones list can be useful; content may require perms.
  adb shell ls -l /data/tombstones >"${prefix}-tombstones-ls.txt" 2>/dev/null || true
}

capture_failure_state() {
  capture_screenshot "error-state"
  capture_logs
}

trap capture_failure_state ERR

capture_screenshot "initial"

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
  capture_screenshot "post-split-install"
else
  if [ ! -f "app.apk" ]; then
    echo "app.apk not found for installation" >&2
    exit 3
  fi
  adb install app.apk
  capture_screenshot "post-single-install"
fi

if ! adb shell pm list packages | grep -Fxq "package:$PACKAGE_ID"; then
  echo "Package $PACKAGE_ID was not found in installed packages" >&2
  exit 4
fi
capture_screenshot "post-package-verification"

echo "Enabling root adb access"
adb root >/dev/null
adb wait-for-device
adb shell setenforce 0 >/dev/null 2>&1 || true
capture_screenshot "post-root"

echo "Launching $PACKAGE_ID"
if ! adb shell monkey -p "$PACKAGE_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
  echo "Failed to launch $PACKAGE_ID via monkey" >&2
  exit 5
fi
capture_screenshot "post-launch"

sleep 10
capture_screenshot "post-wait"

PID=$(adb shell pidof "$PACKAGE_ID" | tr -d '\r')
if [ -z "$PID" ]; then
  echo "Unable to determine PID for $PACKAGE_ID" >&2
  exit 6
fi

echo "Captured process id: $PID"
capture_screenshot "post-pid-capture"

MAPS_PATH="$LIBG_DIR/${PACKAGE_ID}_maps.txt"
adb shell cat "/proc/$PID/maps" | tr -d '\r' >"$MAPS_PATH"
capture_screenshot "post-maps"

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
capture_screenshot "post-mapping-calculation"

PAGE_SIZE=4096
SKIP=$((START_DEC / PAGE_SIZE))
COUNT=$(((SIZE + PAGE_SIZE - 1) / PAGE_SIZE))
REMOTE_DUMP="/data/local/tmp/libg-${PID}.mem"

echo "Dumping libg region (start=0x$START_HEX size=$SIZE bytes)"
adb shell "dd if=/proc/$PID/mem of=$REMOTE_DUMP bs=$PAGE_SIZE skip=$SKIP count=$COUNT" >/dev/null
capture_screenshot "post-remote-dump"

LOCAL_DUMP="$LIBG_DIR/libg.mem"
adb pull "$REMOTE_DUMP" "$LOCAL_DUMP" >/dev/null
adb shell rm -f "$REMOTE_DUMP"
capture_screenshot "post-local-dump"

echo "libg memory dump saved to $LOCAL_DUMP"
