#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# backup_to_mount.sh
# Mirror configured source roots into /mnt/backup_drive using rsync.
#
# - Relative excludes (node_modules/, *.log) work everywhere.
# - Absolute excludes (/home/fabi/...) are converted per-source.
# - Can delete excluded items from destination (--delete-excluded).
# - Skips symlinks by default for filesystems that do not support them.
# - Dry-run supported.
# ------------------------------------------------------------

DEST_ROOT="/mnt/backup_drive"

SOURCE_DIRS=(
  "/etc"
  "/opt"
  "/var"
  "/home/fabi"
)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

EXCLUDE_DIRS_FILE="${SCRIPT_DIR}/exclude_dirs.txt"
EXCLUDE_FILES_FILE="${SCRIPT_DIR}/exclude_files.txt"

DRY_RUN=0
DO_DELETE=1
VERBOSE=0
SYMLINK_MODE="skip"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -n, --dry-run       Show what would happen
  --no-delete         Do not delete anything in destination
  --symlinks          Preserve symlinks (requires destination filesystem support)
  --copy-links        Copy symlink targets as regular files/directories
  -v, --verbose       Verbose output
  -h, --help          Show this help

Destination mountpoint:
  ${DEST_ROOT}

List files (in script directory):
  exclude_dirs.txt, exclude_files.txt

Notes:
- Lines starting with '/' in exclude files are treated as ABSOLUTE paths.
- Other exclude lines are treated as RELATIVE rsync patterns.
- Default symlink handling is --no-links, which skips symlinks instead of
  failing on filesystems such as exFAT/FAT/NTFS mounts that cannot store them.
EOF
}

log() {
  if [[ "${VERBOSE}" -eq 1 ]]; then
    printf -- '%s\n' "$*" >&2
  fi
}

die() {
  printf -- 'ERROR: %s\n' "$*" >&2
  exit 1
}

is_mountpoint() {
  mountpoint -q -- "$1"
}

requires_root() {
  local src
  for src in "${SOURCE_DIRS[@]}"; do
    case "$src" in
      /etc|/etc/*|/opt|/opt/*|/var|/var/*)
        return 0
        ;;
    esac
  done
  return 1
}

expand_path() {
  local p="$1"
  if [[ "$p" == "~"* ]]; then
    # shellcheck disable=SC2086
    eval "printf '%s' $p"
  else
    printf -- '%s' "$p"
  fi
}

# Read file into array, ignoring blanks/comments, expanding ~
# Outputs NUL-separated entries to stdout.
read_list_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    line="$(expand_path "$line")"
    printf -- '%s\0' "$line"
  done < "$file"
}

# Collect excludes into arrays
mapfile -d '' -t EXCL_DIRS_RAW < <(read_list_file "$EXCLUDE_DIRS_FILE")
mapfile -d '' -t EXCL_FILES_RAW < <(read_list_file "$EXCLUDE_FILES_FILE")

# Split excludes into absolute vs relative (by leading '/')
EXCL_DIRS_ABS=()
EXCL_DIRS_REL=()
EXCL_FILES_ABS=()
EXCL_FILES_REL=()

for e in "${EXCL_DIRS_RAW[@]}"; do
  if [[ "$e" == /* ]]; then
    EXCL_DIRS_ABS+=("$e")
  else
    EXCL_DIRS_REL+=("$e")
  fi
done

for e in "${EXCL_FILES_RAW[@]}"; do
  if [[ "$e" == /* ]]; then
    EXCL_FILES_ABS+=("$e")
  else
    EXCL_FILES_REL+=("$e")
  fi
done

# For a given source root, generate a temporary rsync filter file:
# - absolute excludes under this source -> converted to anchored
# - relative exclude patterns appended
make_filter_file_for_src() {
  local src_root="$1"  # absolute path of the directory being synced
  local tmp
  tmp="$(mktemp)"

  local src_norm="${src_root%/}"

  # Absolute excludes: only those under src_root; convert to anchored excludes
  for ex in "${EXCL_DIRS_ABS[@]}"; do
    local ex_norm="${ex%/}"
    # Do not try to sync a source root that is itself excluded.
    [[ "$ex_norm" == "$src_norm" ]] && die "Source root is excluded: $src_root"
    if [[ "$ex_norm" == "$src_norm/"* ]]; then
      local rel="${ex_norm#"$src_norm"/}"
      printf -- '- /%s/\n' "$rel" >> "$tmp"
      printf -- '- /%s/***\n' "$rel" >> "$tmp"
    fi
  done

  for ex in "${EXCL_FILES_ABS[@]}"; do
    local ex_norm="${ex%/}"
    [[ "$ex_norm" == "$src_norm" ]] && die "Source root is excluded: $src_root"
    if [[ "$ex_norm" == "$src_norm/"* ]]; then
      local rel="${ex_norm#"$src_norm"/}"
      printf -- '- /%s\n' "$rel" >> "$tmp"
    fi
  done

  # Relative excludes (patterns): apply anywhere.
  for ex in "${EXCL_DIRS_REL[@]}"; do
    # If user wrote "node_modules" we treat as dir name match; both are valid in rsync,
    # but "node_modules/" is safer for dirs. We'll not rewrite; we respect user's pattern.
    printf -- '- %s\n' "$ex" >> "$tmp"
  done

  for ex in "${EXCL_FILES_REL[@]}"; do
    printf -- '- %s\n' "$ex" >> "$tmp"
  done

  printf -- '%s' "$tmp"
}

# Compute destination path that mirrors absolute source path under DEST_ROOT.
# Example: /home/fabi/Programming -> /mnt/backup_drive/home/fabi/Programming
dest_for_abs_path() {
  local abs="$1"
  abs="${abs%/}"
  printf -- '%s/%s' "$DEST_ROOT" "${abs#/}"
}

add_symlink_opts() {
  local -n opts_ref="$1"
  case "$SYMLINK_MODE" in
    skip) opts_ref+=(--no-links) ;;
    preserve) ;;
    copy) opts_ref+=(--copy-links) ;;
    *) die "Unknown symlink mode: $SYMLINK_MODE" ;;
  esac
}

run_rsync_dir() {
  local src="$1"
  src="$(expand_path "$src")"
  [[ "$src" == /* ]] || die "Source dir is not absolute: $src"
  [[ -d "$src" ]] || die "Source dir does not exist: $src"

  local dest
  dest="$(dest_for_abs_path "$src")"

  mkdir -p -- "$dest"

  local filter_file
  filter_file="$(make_filter_file_for_src "$src")"

  local rsync_opts=(-a -h --partial --inplace)
  add_symlink_opts rsync_opts
  [[ "$VERBOSE" -eq 1 ]] && rsync_opts+=(--info=progress2)

  if [[ "$DO_DELETE" -eq 1 ]]; then
    # --delete removes items that disappear from source
    # --delete-excluded removes items excluded by filter rules from destination too
    rsync_opts+=(--delete --delete-excluded)
  fi

  [[ "$DRY_RUN" -eq 1 ]] && rsync_opts+=(--dry-run)

  # Use a generated filter so absolute excludes are anchored per source root.
  local cmd=(rsync "${rsync_opts[@]}" --filter="merge $filter_file" -- "${src%/}/" "${dest%/}/")

  log "== DIR  : $src  ->  $dest"
  log "== FILTER: $filter_file"
  if "${cmd[@]}"; then
    rm -f -- "$filter_file"
  else
    local status=$?
    rm -f -- "$filter_file"
    return "$status"
  fi
}

# -------------------- args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    --no-delete) DO_DELETE=0; shift ;;
    --symlinks) SYMLINK_MODE="preserve"; shift ;;
    --copy-links) SYMLINK_MODE="copy"; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

# -------------------- checks --------------------
[[ -d "$DEST_ROOT" ]] || die "Destination directory does not exist: $DEST_ROOT"
is_mountpoint "$DEST_ROOT" || die "$DEST_ROOT is not a mountpoint (refusing to run)"
if requires_root && [[ "$EUID" -ne 0 ]]; then
  die "Run with sudo/root because SOURCE_DIRS includes /etc, /opt, or /var"
fi

# -------------------- run --------------------
# Sync source roots. Exclude files decide what is skipped.
failed=0
for d in "${SOURCE_DIRS[@]}"; do
  if ! run_rsync_dir "$d"; then
    printf -- 'ERROR: rsync failed for directory: %s\n' "$d" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  die "Backup finished with errors"
fi

echo "Backup completed."
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: no changes were made)"
