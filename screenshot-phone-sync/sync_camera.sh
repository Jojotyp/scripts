#!/usr/bin/env bash
set -euo pipefail

# Pull last N camera media files from an Android phone via adb.
# Default N=1.
# Destination: ~/Pictures/phone/<phone_name>_<adb_serial>/camera/
#
# usage examples:
# ~/Programming/scripts/screenshot-phone-sync/sync_camera.sh
# ~/Programming/scripts/screenshot-phone-sync/sync_camera.sh --n 50
# ~/Programming/scripts/screenshot-phone-sync/sync_camera.sh --serial <ADB_ID>

N=1
SERIAL=""

usage() {
  cat <<USAGE
Pull the last N camera image and video files from an Android phone via adb.

Looks in common Android camera folders:
  /sdcard/DCIM/Camera
  /sdcard/DCIM/100ANDRO
  /sdcard/Pictures/Camera

Includes images and videos:
  jpg, jpeg, png, webp, heic, heif, dng, mp4, mov, mkv, webm, 3gp

Saves to:
  ~/Pictures/phone/<phone_name>_<adb_serial>/camera/

Usage:
  $(basename "$0") [--n N] [--serial SERIAL]

Examples:
  $(basename "$0")
  $(basename "$0") --n 25
  $(basename "$0") --serial R58N123ABCD --n 50
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --n|-n)
      N="${2:-}"
      shift 2
      ;;
    --serial|-s)
      SERIAL="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: adb not found. Install Android platform-tools and ensure adb is in PATH." >&2
  exit 1
fi

adb_base=(adb)
if [ -n "${SERIAL}" ]; then
  adb_base=(adb -s "${SERIAL}")
fi

# Determine device serial if not given
if [ -z "${SERIAL}" ]; then
  mapfile -t devices < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  if [ "${#devices[@]}" -eq 0 ]; then
    echo "No adb devices found. Check USB debugging and authorization prompt on the phone." >&2
    exit 1
  elif [ "${#devices[@]}" -gt 1 ]; then
    echo "Multiple devices connected. Please specify one with --serial:" >&2
    printf '  %s\n' "${devices[@]}" >&2
    exit 1
  fi
  SERIAL="${devices[0]}"
  adb_base=(adb -s "${SERIAL}")
fi

# Get a friendly phone name
# (Sanitize for filesystem)
manufacturer="$("${adb_base[@]}" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')"
model="$("${adb_base[@]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
if [ -z "${model}" ]; then
  model="AndroidPhone"
fi
phone_name="${manufacturer}_${model}"
# Keep only safe filename characters. Put '-' at the end to avoid locale-dependent
# range parsing errors on Linux (e.g. "reverse collating sequence order").
phone_name="$(printf '%s' "${phone_name}" | tr ' /' '__' | tr -cd '[:alnum:]_.-')"

dest_base="${HOME}/Pictures/phone"
dest="${dest_base}/${phone_name}_${SERIAL}/camera"
mkdir -p "${dest}"

# Candidate camera directories (device/vendor dependent)
candidates=(
  "/sdcard/DCIM/Camera"
  "/sdcard/DCIM/100ANDRO"
  "/sdcard/Pictures/Camera"
)

remote_dir=""
for d in "${candidates[@]}"; do
  if "${adb_base[@]}" shell "test -d \"$d\" && ls -1 \"$d\" >/dev/null 2>&1"; then
    remote_dir="$d"
    break
  fi
done

if [ -z "${remote_dir}" ]; then
  echo "Could not find a camera directory on the device. Tried:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  exit 1
fi

# Get last N files by mtime (newest first).
files="$("${adb_base[@]}" shell "ls -1t \"$remote_dir\" 2>/dev/null | sed 's/\r$//' | grep -Ei '\\.(jpe?g|png|webp|heic|heif|dng|mp4|mov|mkv|webm|3gp)$' || true")"

if [ -z "${files}" ]; then
  echo "No camera media files found in: ${remote_dir}"
  exit 0
fi

tmp_list="$(mktemp)"
printf '%s\n' "${files}" | head -n "${N}" > "${tmp_list}"

count="$(wc -l < "${tmp_list}" | tr -d ' ')"
echo "Device:  ${phone_name} (${SERIAL})"
echo "Remote:  ${remote_dir}"
echo "Local:   ${dest}"
echo "Pulling: ${count} camera media file(s) (requested N=${N})"

while IFS= read -r f; do
  [ -n "${f}" ] || continue
  "${adb_base[@]}" pull -a "${remote_dir}/${f}" "${dest}/" >/dev/null
done < "${tmp_list}"

rm -f "${tmp_list}"

echo "Done."
