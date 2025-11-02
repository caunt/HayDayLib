set -euo pipefail
SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$SDK_DIR" ]; then
  echo "ANDROID_SDK_ROOT or ANDROID_HOME must be set" >&2
  exit 1
fi

AAPT_PATH=$(find "$SDK_DIR"/build-tools -maxdepth 2 -type f -name aapt 2>/dev/null | sort -V | tail -n1)
if [ -z "$AAPT_PATH" ]; then
  echo "Unable to locate the aapt tool in the Android SDK" >&2
  exit 1
fi

PACKAGE_SOURCE="app-package.bin"
FINAL_APK="app.apk"
SPLIT_DIR="split-apk"
rm -f "$FINAL_APK"
rm -rf "$SPLIT_DIR"

TEMP_DIR=""
BADGING_OUTPUT=""
cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
  if [ -n "$BADGING_OUTPUT" ] && [ -f "$BADGING_OUTPUT" ]; then rm -f "$BADGING_OUTPUT"; fi
}
trap cleanup EXIT

BADGING_OUTPUT=$(mktemp)
INSTALL_MODE="single"
if "$AAPT_PATH" dump badging "$PACKAGE_SOURCE" >"$BADGING_OUTPUT" 2>/dev/null; then
  PACKAGE_ID=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" "$BADGING_OUTPUT")
  if [ -z "$PACKAGE_ID" ]; then
    echo "Failed to extract package id from APK" >&2
    exit 1
  fi
  mv "$PACKAGE_SOURCE" "$FINAL_APK"
else
  TEMP_DIR=$(mktemp -d)
  unzip -q "$PACKAGE_SOURCE" -d "$TEMP_DIR"

  mkdir -p "$SPLIT_DIR"

  APK_SOURCES=()
  while IFS= read -r -d '' file; do
    APK_SOURCES+=("$file")
  done < <(find "$TEMP_DIR" -type f -name '*.apk' -print0)

  if [ "${#APK_SOURCES[@]}" -eq 0 ]; then
    echo "Failed to locate APK files inside archive" >&2
    exit 1
  fi

  COPIED_APKS=()
  for src in "${APK_SOURCES[@]}"; do
    dest="$SPLIT_DIR/$(basename "$src")"
    cp "$src" "$dest"
    COPIED_APKS+=("$dest")
  done

  BASE_APK=""
  for path in "${COPIED_APKS[@]}"; do
    name=$(basename "$path")
    if [[ "$name" == base.apk ]] || [[ "$name" == base-*.apk ]]; then
      BASE_APK="$path"
      break
    fi
  done
  if [ -z "$BASE_APK" ]; then
    BASE_APK="${COPIED_APKS[0]}"
  fi

  "$AAPT_PATH" dump badging "$BASE_APK" >"$BADGING_OUTPUT"
  PACKAGE_ID=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" "$BADGING_OUTPUT")
  if [ -z "$PACKAGE_ID" ]; then
    echo "Failed to extract package id from APK bundle" >&2
    exit 1
  fi

  ORDERED_APKS=("$BASE_APK")
  for path in "${COPIED_APKS[@]}"; do
    if [ "$path" != "$BASE_APK" ]; then ORDERED_APKS+=("$path"); fi
  done
  printf '%s\n' "${ORDERED_APKS[@]}" >"$SPLIT_DIR/list.txt"

  cp "$BASE_APK" "$FINAL_APK"
  INSTALL_MODE="split"
fi

trap - EXIT
cleanup

echo "Package id: $PACKAGE_ID"
{
  echo "package-id=$PACKAGE_ID"
  echo "install-mode=$INSTALL_MODE"
} >>"$GITHUB_OUTPUT"
