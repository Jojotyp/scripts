#!/usr/bin/bash
set -euo pipefail

# to actually rsync run:
# /home/fabi/Programming/scripts/backup/backup_to_mount.sh --no-dry-run --delete

# backup_to_mount.sh
# Default location (where the script lives) for include/exclude lists:
#   include_dirs.txt    (one directory path per line)
#   include_files.txt   (one file path per line)
#   exclude_dirs.txt    (patterns or paths, passed to rsync --exclude-from)
#   exclude_files.txt   (patterns or paths, passed to rsync --exclude-from)
#
# Usage:
#   backup_to_mount.sh [OPTIONS] [DIR...]
#   backup_to_mount.sh --list dirs.txt
#
# If no DIR... and no --list provided, the script will read include_* files from the script folder.
#
# Note:
# - Paths in include_* files may be absolute or use ~ for home. Relative paths are interpreted relative to the current working directory.
# - Exclude files contain rsync exclude patterns/paths, one per line.
# - Default behaviour is a dry-run. Use --no-dry-run to actually copy.

# -------- configuration / defaults --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INCLUDE_DIRS="${SCRIPT_DIR}/include_dirs.txt"
DEFAULT_INCLUDE_FILES="${SCRIPT_DIR}/include_files.txt"
DEFAULT_EXCLUDE_DIRS="${SCRIPT_DIR}/exclude_dirs.txt"
DEFAULT_EXCLUDE_FILES="${SCRIPT_DIR}/exclude_files.txt"

MOUNTPOINT="/mnt/backup_drive"
DRY_RUN=1
DELETE_FLAG=""
EXCLUDE_FILES_LIST=()
SRC_LIST=()
LOGFILE=""

print_help() {
  sed -n '1,200p' <<'USAGE'
backup_to_mount.sh — backup a list of files/dirs to a mounted backup drive

Options:
  -m, --mount DIR      Mountpoint (default: /mnt/backup_drive)
  -l, --list FILE      File with one source directory per line
  -e, --exclude FILE   Add an extra exclude-file (can be used multiple times)
  -n, --dry-run        (default) show what would be done
  --no-dry-run         actually perform the sync
  --delete             pass --delete to rsync (mirror)
  --log FILE           append rsync output to FILE
  -h, --help           show this help
If no sources were provided and --list was not used, the script will try to read:
  ${DEFAULT_INCLUDE_DIRS} and ${DEFAULT_INCLUDE_FILES}
as the source list, and it will use ${DEFAULT_EXCLUDE_DIRS} and ${DEFAULT_EXCLUDE_FILES}
as default exclude-files when present.
USAGE
}

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mount) MOUNTPOINT="$2"; shift 2 ;;
    -l|--list) srcfile="$2"; shift 2
               if [[ ! -f "$srcfile" ]]; then echo "List file not found: $srcfile" >&2; exit 2; fi
               while IFS= read -r line || [ -n "$line" ]; do
                 # strip leading/trailing whitespace
                 line="${line#"${line%%[![:space:]]*}"}"
                 line="${line%"${line##*[![:space:]]}"}"
                 [[ -z "$line" ]] && continue
                 [[ "${line:0:1}" = "#" ]] && continue
                 SRC_LIST+=("$line")
               done < "$srcfile"
               ;;
    -e|--exclude) EXCL="$2"; shift 2
                  if [[ ! -f "$EXCL" ]]; then echo "Exclude file not found: $EXCL" >&2; exit 2; fi
                  EXCLUDE_FILES_LIST+=("$EXCL")
                  ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --no-dry-run) DRY_RUN=0; shift ;;
    --delete) DELETE_FLAG="--delete"; shift ;;
    --log) LOGFILE="$2"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; print_help; exit 2 ;;
    *) SRC_LIST+=("$1"); shift ;;
  esac
done

# ---------- helper ----------
_expand_path() {
  # expand ~ and return as-is otherwise (no realpath to avoid failure on non-existent)
  local p="$1"
  if [[ "$p" == ~* ]]; then
    printf '%s' "${p/#\~/$HOME}"
  else
    printf '%s' "$p"
  fi
}

_add_from_file_to_src() {
  local f="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    # normalize whitespace and skip comments/empty
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" = "#" ]] && continue
    # expand ~
    line="$(_expand_path "$line")"
    SRC_LIST+=("$line")
  done < "$f"
}

# ---------- if no explicit sources provided, use include_* defaults ----------
if [ ${#SRC_LIST[@]} -eq 0 ]; then
  # read include_dirs and include_files if present
  if [[ -f "$DEFAULT_INCLUDE_DIRS" ]]; then
    _add_from_file_to_src "$DEFAULT_INCLUDE_DIRS"
  fi
  if [[ -f "$DEFAULT_INCLUDE_FILES" ]]; then
    _add_from_file_to_src "$DEFAULT_INCLUDE_FILES"
  fi

  if [ ${#SRC_LIST[@]} -eq 0 ]; then
    echo "No source directories/files provided and no include_* defaults found. Use arguments or --list." >&2
    exit 2
  fi
fi

# ---------- default exclude files (use them unless user provided others) ----------
if [ ${#EXCLUDE_FILES_LIST[@]} -eq 0 ]; then
  [[ -f "$DEFAULT_EXCLUDE_DIRS" ]] && EXCLUDE_FILES_LIST+=("$DEFAULT_EXCLUDE_DIRS")
  [[ -f "$DEFAULT_EXCLUDE_FILES" ]] && EXCLUDE_FILES_LIST+=("$DEFAULT_EXCLUDE_FILES")
fi

# ---------- sanity checks ----------
command -v rsync >/dev/null 2>&1 || { echo "rsync not found. Install it and retry." >&2; exit 3; }

if [ ! -d "$MOUNTPOINT" ]; then
  echo "Mountpoint does not exist: $MOUNTPOINT" >&2
  echo "Create it or mount your backup drive there." >&2
  exit 4
fi

# ---------- build rsync options ----------
RSYNC_OPTS=( -a -h --progress --partial --inplace )
# Note: -a preserves many attributes which CIFS may map; change if needed
for exf in "${EXCLUDE_FILES_LIST[@]}"; do
  RSYNC_OPTS+=( "--exclude-from=$exf" )
done
if [[ -n "$DELETE_FLAG" ]]; then
  RSYNC_OPTS+=( "$DELETE_FLAG" )
fi

# ---------- run function ----------
run_rsync() {
  local src="$1"
  if [[ -z "$src" ]]; then
    echo "Empty source, skipping." >&2
    return 1
  fi

  # expand ~, leave relative as-is (relative => relative to current working dir)
  src="$(_expand_path "$src")"

  if [ ! -e "$src" ]; then
    echo "Source not found, skipping: $src" >&2
    return 1
  fi

  # create destination path under mountpoint
  # we preserve the absolute path structure: /home/fabi/... -> /mnt/backup_drive/home/fabi/...
  # if source is relative, place it under mountpoint/$(pwd)/<relative>
  local dest
  if [[ "$src" = /* ]]; then
    dest="${MOUNTPOINT}${src}"
  else
    # relative path: prefix working dir
    dest="${MOUNTPOINT}/$(pwd)/${src}"
  fi

  mkdir -p "$dest" || { echo "Cannot create destination: $dest" >&2; return 2; }

  echo
  echo "=== Sync ==="
  echo "SRC:  $src"
  echo "DEST: $dest"
  echo "RSYNC OPTS: ${RSYNC_OPTS[*]}"
  echo

  # build full rsync command: put options (including --dry-run if requested) BEFORE src/dest
  local rsync_cmd=(rsync "${RSYNC_OPTS[@]}")

  if [ "$DRY_RUN" -eq 1 ]; then
    rsync_cmd+=(--dry-run)
  fi

  # add source and destination as last arguments
  rsync_cmd+=(-- "$src"/ "$dest"/)

  # execute and capture exit codes correctly (handle tee with PIPESTATUS)
  if [ -n "$LOGFILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "DRY-RUN (no changes):"
    fi
    "${rsync_cmd[@]}" 2>&1 | tee -a "$LOGFILE"
    return ${PIPESTATUS[0]}
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "DRY-RUN (no changes):"
    fi
    "${rsync_cmd[@]}"
    return $?
  fi
}

# ---------- summary then run ----------
echo "Mountpoint: $MOUNTPOINT"
echo "Sources to sync:"
for s in "${SRC_LIST[@]}"; do echo "  $s"; done
if [ ${#EXCLUDE_FILES_LIST[@]} -gt 0 ]; then
  echo "Exclude files used:"
  for f in "${EXCLUDE_FILES_LIST[@]}"; do echo "  $f"; done
fi
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "NOTE: Dry-run enabled. Use --no-dry-run to perform real sync."
fi

EXITCODE=0
for s in "${SRC_LIST[@]}"; do
  run_rsync "$s" || EXITCODE=$?
done

exit $EXITCODE
