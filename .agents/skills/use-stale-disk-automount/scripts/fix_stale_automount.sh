#!/usr/bin/env bash

set -euo pipefail

_dry_run=false
_paths=()

__usage() {
  cat >&2 <<'EOF'
Usage: fix_stale_automount.sh [--dry-run] /disk/<id> [/disk/<id> ...]

Stops a stale systemd automount and removes its empty mount point.
Every path must be an autofs mount, absent from /etc/fstab, have a
not-found .mount unit, and have no active non-autofs filesystem mount.
EOF
}

__require_commands() {
  for _command in findmnt systemd-escape systemctl rmdir; do
    command -v "$_command" >/dev/null 2>&1 || {
      printf 'required command not found: %s\n' "$_command" >&2
      return 2
    }
  done
}

__has_autofs() {
  _wanted=$1
  findmnt -rn -t autofs -o TARGET | grep -Fxq "$_wanted"
}

__has_non_autofs_mount() {
  _wanted=$1
  findmnt -rn -o TARGET,FSTYPE |
    awk -v _path="$_wanted" '$1 == _path && $2 != "autofs" { found = 1 } END { exit found ? 0 : 1 }'
}

__configured_in_fstab() {
  _wanted=$1
  awk -v _path="$_wanted" '$2 == _path { found = 1 } END { exit found ? 0 : 1 }' /etc/fstab
}

__repair_one() {
  _path=$1
  _automount_unit=$(systemd-escape --path --suffix=automount "$_path")
  _mount_unit=$(systemd-escape --path --suffix=mount "$_path")
  _mount_load_state=$(systemctl show "$_mount_unit" -p LoadState --value 2>/dev/null || true)

  if [[ ! $_path =~ ^/disk/[0-9A-Za-z_-]+$ ]]; then
    printf 'refuse unsafe path: %s\n' "$_path" >&2
    return 2
  fi

  if ! __has_autofs "$_path"; then
    if [[ -e $_path ]]; then
      printf 'path exists but has no autofs, left untouched: %s\n' "$_path"
    else
      printf 'no stale autofs: %s\n' "$_path"
    fi
    return 0
  fi

  if __configured_in_fstab "$_path"; then
    printf 'configured in /etc/fstab, refuse fix: %s\n' "$_path" >&2
    return 2
  fi

  if [[ $_mount_load_state != not-found ]]; then
    printf 'mount unit is not not-found, refuse fix: %s\n' "$_path" >&2
    return 2
  fi

  if __has_non_autofs_mount "$_path"; then
    printf 'active non-autofs mount exists, refuse fix: %s\n' "$_path" >&2
    return 2
  fi

  if [[ $_dry_run == true ]]; then
    printf 'dry-run: would stop %s and rmdir %s\n' "$_automount_unit" "$_path"
    return 0
  fi

  if [[ $(id -u) -ne 0 ]]; then
    printf 'must run as root on the host\n' >&2
    return 2
  fi

  systemctl stop "$_automount_unit"

  if __has_autofs "$_path"; then
    printf 'autofs still exists after stop, refuse rmdir: %s\n' "$_path" >&2
    return 2
  fi

  rmdir -- "$_path"

  if [[ -e $_path ]]; then
    printf 'rmdir succeeded but path still exists: %s\n' "$_path" >&2
    return 2
  fi

  printf 'removed stale automount path: %s\n' "$_path"
}

__main() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)
        _dry_run=true
        shift
        ;;
      -h|--help)
        __usage
        return 0
        ;;
      --*)
        __usage
        return 2
        ;;
      *)
        _paths+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#_paths[@]} -eq 0 ]]; then
    __usage
    return 2
  fi

  __require_commands

  for _path in "${_paths[@]}"; do
    __repair_one "$_path"
  done
}

__main "$@"
