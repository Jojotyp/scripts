#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# backup_to_mount.sh
# Mirror selected dirs/files into /mnt/backup_drive using rsync.
#
# - Relative excludes (node_modules/, *.log) work everywhere.
# - Absolute excludes (/home/fabi/...) are converted per-source.
# - Includes override excludes (filter rules: first match wins).
# - Can delete excluded items from destination (--delete-excluded).
# - Dry-run supported.
# ------------------------------------------------------------

DEST_ROOT="/mnt/backup_drive"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

INCLUDE_DIRS_FILE="${SCRIPT_DIR}/include_dirs.txt"
INCLUDE_FILES_FILE="${SCRIPT_DIR}/include_files.txt"

EXCLUDE_DIRS_FILE="${SCRIPT_DIR}/exclude_dirs.txt"
EXCLUDE_FILES_FILE="${SCRIPT_DIR}/exclude_files.txt"

DRY_RUN=0
DO_DELETE=1
VERBOSE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -n, --dry-run       Show what would happen
  --no-delete         Do not delete anything in destination
  -v, --verbose       Verbose output
  -h, --help          Show this help

Destination mountpoint:
  ${DEST_ROOT}

List files (in script directory):
  include_dirs.txt, include_files.txt
  exclude_dirs.txt, exclude_files.txt

Notes:
- Lines starting with '/' in exclude files are treated as ABSOLUTE paths.
- Other exclude lines are treated as RELATIVE rsync patterns.
- Includes override excludes (first-match-wins).
EOF
}

log() {
  if [[ "${VERBOSE}" -eq 1 ]]; then
    printf -- '%s\n' "$*" >&2
  fi
}

die() {
  printf --'ERROR: %s\n' "$*" >&2
  exit 1
}

is_mountpoint() {
  mountpoint -q -- "$1"
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

# Collect includes/excludes into arrays
mapfile -d '' -t INCLUDE_DIRS < <(read_list_file "$INCLUDE_DIRS_FILE")
mapfile -d '' -t INCLUDE_FILES < <(read_list_file "$INCLUDE_FILES_FILE")
mapfile -d '' -t EXCL_DIRS_RAW < <(read_list_file "$EXCLUDE_DIRS_FILE")
mapfile -d '' -t EXCL_FILES_RAW < <(read_list_file "$EXCLUDE_FILES_FILE")

# Split excludes into absolute vs relative (by leading '/')
EXCL_ABS=()
EXCL_REL=()

for e in "${EXCL_DIRS_RAW[@]}" "${EXCL_FILES_RAW[@]}"; do
  if [[ "$e" == /* ]]; then
    EXCL_ABS+=("$e")
  else
    EXCL_REL+=("$e")
  fi
done

# Helper: add include rules for all parents of an anchored path.
# Example path: /foo/bar/baz.txt
# Adds:
#   + /foo/
#   + /foo/bar/
# So that included deep paths survive if some parent would be excluded.
add_parent_includes() {
  local anchored="$1"    # must start with /
  local out_file="$2"

  local p="$anchored"
  # Remove trailing file/dir segment step by step
  while [[ "$p" == */* ]]; do
    p="${p%/*}"
    [[ -z "$p" ]] && break
    [[ "$p" == "/" ]] && break
    printf -- '+ %s/\n' "$p" >> "$out_file"
  done
}

# For a given source root, generate a temporary rsync filter file:
# - includes first (anchored) => override
# - absolute excludes under this source -> converted to anchored
# - relative exclude patterns appended
make_filter_file_for_src() {
  local src_root="$1"  # absolute path of the directory being synced
  local tmp
  tmp="$(mktemp)"

  # 1) Include overrides (only those that are inside this src_root)
  # We include both include_dirs and include_files that sit under src_root.
  local src_norm="${src_root%/}"

  # include dirs
  for inc in "${INCLUDE_DIRS[@]}"; do
    inc="$(expand_path "$inc")"
    [[ "$inc" == /* ]] || continue
    local inc_norm="${inc%/}"
    if [[ "$inc_norm" == "$src_norm" || "$inc_norm" == "$src_norm/"* ]]; then
      local rel="${inc_norm#"$src_norm"}"
      rel="${rel#/}"  # remove leading slash if any
      # If include is exactly the root, nothing special needed.
      if [[ -n "$rel" ]]; then
        # Anchor include at root of this transfer:
        printf -- '+ /%s/\n' "$rel" >> "$tmp"
        add_parent_includes "/$rel" "$tmp"
        # Include all contents of included dir:
        printf -- '+ /%s/***\n' "$rel" >> "$tmp"
      fi
    fi
  done

  # include files
  for inc in "${INCLUDE_FILES[@]}"; do
    inc="$(expand_path "$inc")"
    [[ "$inc" == /* ]] || continue
    local inc_norm="$inc"
    if [[ "$inc_norm" == "$src_norm/"* ]]; then
      local rel="${inc_norm#"$src_norm"/}"
      if [[ -n "$rel" ]]; then
        printf -- '+ /%s\n' "$rel" >> "$tmp"
        add_parent_includes "/$rel" "$tmp"
      fi
    fi
  done

  # 2) Absolute excludes: only those under src_root; convert to anchored excludes
  for ex in "${EXCL_ABS[@]}"; do
    local ex_norm="${ex%/}"
    # exclude is exactly the src root: skip (not meaningful)
    if [[ "$ex_norm" == "$src_norm" ]]; then
      continue
    fi
    if [[ "$ex_norm" == "$src_norm/"* ]]; then
      local rel="${ex_norm#"$src_norm"/}"
      # rsync anchored excludes start with '/'
      if [[ "$ex" == */ ]]; then
        printf -- '- /%s/\n' "$rel" >> "$tmp"
        printf -- '- /%s/***\n' "$rel" >> "$tmp"
      else
        printf -- '- /%s\n' "$rel" >> "$tmp"
      fi
    fi
  done

  # 3) Relative excludes (patterns): apply anywhere
  for ex in "${EXCL_REL[@]}"; do
    # If user wrote "node_modules" we treat as dir name match; both are valid in rsync,
    # but "node_modules/" is safer for dirs. We'll not rewrite; we respect user's pattern.
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

run_rsync_dir() {
  local src="$1"
  src="$(expand_path "$src")"
  [[ "$src" == /* ]] || die "include_dirs entry is not absolute: $src"
  [[ -d "$src" ]] || die "Source dir does not exist: $src"

  local dest
  dest="$(dest_for_abs_path "$src")"

  mkdir -p -- "$dest"

  local filter_file
  filter_file="$(make_filter_file_for_src "$src")"

  local rsync_opts=(-a -h --partial --inplace)
  [[ "$VERBOSE" -eq 1 ]] && rsync_opts+=(--info=progress2)

  if [[ "$DO_DELETE" -eq 1 ]]; then
    # --delete removes items that disappear from source
    # --delete-excluded removes items excluded by filter rules from destination too
    rsync_opts+=(--delete --delete-excluded)
  fi

  [[ "$DRY_RUN" -eq 1 ]] && rsync_opts+=(--dry-run)

  # Use --filter=. so we can express + /path and - pattern rules with first-match-wins
  local cmd=(rsync "${rsync_opts[@]}" --filter="merge $filter_file" -- "${src%/}/" "${dest%/}/")

  log "== DIR  : $src  ->  $dest"
  log "== FILTER: $filter_file"
  "${cmd[@]}"

  rm -f -- "$filter_file"
}

run_rsync_file() {
  local src="$1"
  src="$(expand_path "$src")"
  [[ "$src" == /* ]] || die "include_files entry is not absolute: $src"
  [[ -f "$src" ]] || die "Source file does not exist: $src"

  local src_dir
  src_dir="$(dirname -- "$src")"

  local dest_dir
  dest_dir="$(dest_for_abs_path "$src_dir")"
  mkdir -p -- "$dest_dir"

  # Filter for src_dir, but ensure this file is included even if excluded
  local filter_file
  filter_file="$(make_filter_file_for_src "$src_dir")"

  local rsync_opts=(-a -h --partial --inplace)
  [[ "$VERBOSE" -eq 1 ]] && rsync_opts+=(--info=progress2)

  if [[ "$DO_DELETE" -eq 1 ]]; then
    # For a single file sync, --delete is mostly irrelevant,
    # but --delete-excluded could remove other excluded items in that dest_dir.
    rsync_opts+=(--delete --delete-excluded)
  fi

  [[ "$DRY_RUN" -eq 1 ]] && rsync_opts+=(--dry-run)

  local cmd=(rsync "${rsync_opts[@]}" --filter="merge $filter_file" -- "$src" "${dest_dir%/}/")

  log "== FILE : $src  ->  $dest_dir"
  log "== FILTER: $filter_file"
  "${cmd[@]}"

  rm -f -- "$filter_file"
}

# -------------------- args --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    --no-delete) DO_DELETE=0; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

# -------------------- checks --------------------
[[ -d "$DEST_ROOT" ]] || die "Destination directory does not exist: $DEST_ROOT"
is_mountpoint "$DEST_ROOT" || die "$DEST_ROOT is not a mountpoint (refusing to run)"

# -------------------- run --------------------
# 1) Sync included directories
for d in "${INCLUDE_DIRS[@]}"; do
  run_rsync_dir "$d"
done

# 2) Sync included files
for f in "${INCLUDE_FILES[@]}"; do
  run_rsync_file "$f"
done

echo "Backup completed."
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: no changes were made)"
