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
    exit 1
  fi
  adb install-multiple "${APK_FILES[@]}"
else
  if [ ! -f "app.apk" ]; then
    echo "app.apk not found for installation" >&2
    exit 1
  fi
  adb install app.apk
fi

if ! adb shell pm list packages | grep -Fxq "package:$PACKAGE_ID"; then
  echo "Package $PACKAGE_ID was not found in installed packages" >&2
  exit 1
fi
