#!/usr/bin/env bash
set -euo pipefail

# Pull last N recent media files from an Android phone via adb.
# Default N=1.
# Destination: ~/Pictures/phone/<phone_name>_<adb_serial>/recent/
#
# usage examples:
# ~/Programming/scripts/screenshot-phone-sync/sync_recent.sh
# ~/Programming/scripts/screenshot-phone-sync/sync_recent.sh --n 50
# ~/Programming/scripts/screenshot-phone-sync/sync_recent.sh --serial <ADB_ID> --n 30

N=1
SERIAL=""
WHATSAPP_ONLY=0

usage() {
  cat <<USAGE
Pull the last N recent media files from selected Android media folders via adb.

Checks recent entries in:
  /sdcard/DCIM
  /sdcard/Pictures
  /sdcard/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images

WhatsApp image candidates are selected by filename date to avoid slow full-folder mtime sorting.

Includes images and videos:
  jpg, jpeg, png, webp, heic, heif, dng, mp4, mov, mkv, webm, 3gp

Saves to:
  ~/Pictures/phone/<phone_name>_<adb_serial>/recent/

Usage:
  $(basename "$0") [--n N] [--serial SERIAL] [--whatsapp]

Examples:
  $(basename "$0")
  $(basename "$0") --n 25
  $(basename "$0") --serial R58N123ABCD --n 50
  $(basename "$0") --whatsapp --n 10
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
    --whatsapp|-w)
      WHATSAPP_ONLY=1
      shift
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

if ! [[ "${N}" =~ ^[0-9]+$ ]] || [ "${N}" -lt 1 ]; then
  echo "Error: --n must be a positive integer." >&2
  exit 1
fi

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
dest="${dest_base}/${phone_name}_${SERIAL}/recent"
mkdir -p "${dest}"

remote_command="$(cat <<REMOTE
N="${N}"
WHATSAPP_ONLY="${WHATSAPP_ONLY}"
is_media() {
  case "\$1" in
    *.[Jj][Pp][Gg]|*.[Jj][Pp][Ee][Gg]|*.[Pp][Nn][Gg]|*.[Ww][Ee][Bb][Pp]|*.[Hh][Ee][Ii][Cc]|*.[Hh][Ee][Ii][Ff]|*.[Dd][Nn][Gg]|*.[Mm][Pp]4|*.[Mm][Oo][Vv]|*.[Mm][Kk][Vv]|*.[Ww][Ee][Bb][Mm]|*.[3][Gg][Pp])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_album_candidates() {
  dir="\$1"
  [ -d "\$dir" ] || return
  echo "Checking folder: \$dir" >&2
  ls -1t "\$dir" 2>/dev/null |
    while IFS= read -r name; do
      path="\$dir/\$name"
      [ -f "\$path" ] || continue
      is_media "\$path" || continue
      printf "%s\n" "\$path"
    done |
    head -n "\$N"
}

list_whatsapp_candidates() {
  dir="/sdcard/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"
  [ -d "\$dir" ] || return
  echo "Checking WhatsApp folder: \$dir" >&2
  find "\$dir" -maxdepth 1 -type f 2>/dev/null |
    grep -E '/IMG-[0-9]{8}-WA[0-9]+\.[^.]+$' |
    grep -Ei '\.(jpe?g|png|webp|heic|heif|dng)$' |
    sort -r |
    head -n "\$N"
}

{
  if [ "\$WHATSAPP_ONLY" = "1" ]; then
    list_whatsapp_candidates
  else
    for root in /sdcard/DCIM /sdcard/Pictures; do
      [ -d "\$root" ] || continue
      echo "Checking root: \$root" >&2
      list_album_candidates "\$root"
      find "\$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        grep -v '/\.[^/]*$' |
        while IFS= read -r dir; do
          list_album_candidates "\$dir"
        done
    done

    list_whatsapp_candidates
  fi
} |
  while IFS= read -r f; do
    m="\$(stat -c %Y "\$f" 2>/dev/null || echo 0)"
    printf "%s\t%s\n" "\$m" "\$f"
  done |
  sort -rn |
  cut -f2- |
  awk '!seen[\$0]++'
REMOTE
)"

echo "Device:  ${phone_name} (${SERIAL})"
if [ "${WHATSAPP_ONLY}" -eq 1 ]; then
  echo "Remote:  WhatsApp Images"
else
  echo "Remote:  /sdcard/DCIM, /sdcard/Pictures, WhatsApp Images"
fi
echo "Local:   ${dest}"
echo "Listing recent media..."

if ! files="$("${adb_base[@]}" shell "${remote_command}" | sed 's/\r$//')"; then
  echo "Error: could not list recent media files from the device." >&2
  exit 1
fi

if [ -z "${files}" ]; then
  if [ "${WHATSAPP_ONLY}" -eq 1 ]; then
    echo "No WhatsApp images found."
  else
    echo "No recent media files found under /sdcard/DCIM, /sdcard/Pictures, or WhatsApp Images."
  fi
  exit 0
fi

tmp_list="$(mktemp)"
used_names="$(mktemp)"
trap 'rm -f "${tmp_list}" "${used_names}"' EXIT
: > "${tmp_list}"
selected=0
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  printf '%s\n' "${f}" >> "${tmp_list}"
  selected=$((selected + 1))
  [ "${selected}" -ge "${N}" ] && break
done <<< "${files}"

unique_dest_path() {
  local dir="$1"
  local filename="$2"
  local stem="$filename"
  local ext=""
  local candidate
  local candidate_name
  local i

  if [[ "${filename}" == *.* && "${filename}" != .* ]]; then
    ext=".${filename##*.}"
    stem="${filename%.*}"
  fi

  candidate_name="${filename}"
  candidate="${dir}/${candidate_name}"
  if ! grep -Fxq "${candidate_name}" "${used_names}"; then
    printf '%s\n' "${candidate_name}" >> "${used_names}"
    printf '%s\n' "${candidate}"
    return
  fi

  i=1
  while true; do
    candidate_name="${stem}_${i}${ext}"
    candidate="${dir}/${candidate_name}"
    if ! grep -Fxq "${candidate_name}" "${used_names}"; then
      printf '%s\n' "${candidate_name}" >> "${used_names}"
      printf '%s\n' "${candidate}"
      return
    fi
    i=$((i + 1))
  done
}

count="$(wc -l < "${tmp_list}" | tr -d ' ')"
echo "Pulling: ${count} recent media file(s) (requested N=${N})"

while IFS= read -r remote_file; do
  [ -n "${remote_file}" ] || continue

  filename="${remote_file##*/}"
  local_file="$(unique_dest_path "${dest}" "${filename}")"
  echo "Pulling: ${remote_file}"
  "${adb_base[@]}" pull -a "${remote_file}" "${local_file}" >/dev/null
done < "${tmp_list}"

echo "Done."
