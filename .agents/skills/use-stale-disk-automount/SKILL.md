---
name: use-stale-disk-automount
description: Diagnose and safely remove stale /disk systemd automount entries that block Fluent Bit tail collection on Kuaicdn ant nodes. Use for unavailable /disk/* paths, autofs_wait hangs, or /disk/*/cache-ant/dump_flow discovery failures. Do not use for normal missing disks or fstab-managed mount changes.
---

# Stale /disk automount handling

## Diagnosis

Do not `stat`, `ls`, `find`, or glob through a suspect `/disk/*` path while diagnosing it. A stale systemd automount can block path traversal in kernel `autofs_wait` and hang Fluent Bit's tail thread. Read mount metadata only.

In the `260911-bbiz-metrics` container, discover candidate paths without touching them:

```bash
findmnt -rn -t autofs -o TARGET |
  awk '$1 ~ /^\/disk\// {print $1}' |
  sort > /tmp/disk-autofs.txt

awk '$2 ~ /^\/disk\// {print $2}' /host/etc/fstab |
  sort > /tmp/disk-configured.txt

comm -23 /tmp/disk-autofs.txt /tmp/disk-configured.txt
```

If `/host/etc/fstab` is unavailable, use `/host/proc/1/root/etc/fstab`. If neither host fstab is readable, treat detection as unavailable rather than reporting every autofs path as stale.

The intended metric rule is:

```text
stale paths = /disk/* autofs mount points
              - /disk/* mount points configured in host fstab
              - /disk/* paths that also have an active non-autofs mount
```

The last exclusion is required because systemd can leave an autofs mount under a successfully mounted XFS filesystem. Such a path is usable and must not be reported or removed.

The existing metric implementation is `m_260923_disk_stale_automount` in the `260911-bbiz-metrics` project.

## Confirm before repair

Run repair only on the host, not in the metrics container. For each candidate, require all of these conditions:

```text
the exact path appears as an autofs mount point
the exact path is absent from field 2 of /etc/fstab
the corresponding .mount unit has LoadState=not-found
the path has no active non-autofs filesystem mount
```

Example host checks for `/disk/974abc04`:

```bash
_path=/disk/974abc04
_mount_unit=$(systemd-escape --path --suffix=mount "$_path")

findmnt -rn -t autofs -o TARGET | grep -Fxq "$_path"
! awk -v _p="$_path" '$2 == _p { found = 1 } END { exit found ? 0 : 1 }' /etc/fstab
systemctl show "$_mount_unit" -p LoadState --value
```

Fluent Bit evidence normally includes `flb-in-tail` triggering the automount, systemd reporting `Dependency failed`, and a tail database WAL whose modification time stops advancing.

## Repair

Only after the user explicitly authorizes a production mutation, run from the project root:

```bash
bash .agents/skills/use-stale-disk-automount/scripts/fix_stale_automount.sh /disk/<id>
```

The script is idempotent, supports `--dry-run`, accepts explicit paths only, and refuses to touch a path when any safety condition fails. It stops only the corresponding automount unit and removes the mount point with `rmdir`; it never modifies `/etc/fstab` and never recursively deletes.

If `rmdir` reports that the directory is not empty or busy, stop and investigate the holder. Do not force removal.

## Verify

After repair, verify without traversing the removed path. The autofs lookup should print nothing, the path-existence test should succeed, the metric should no longer emit the path, and Fluent Bit's `dump_flow.db-wal` modification time should advance again:

```bash
findmnt -rn -t autofs -o TARGET | grep -Fx /disk/<id>
test ! -e /disk/<id>
```

In the ant container, a bounded read of `/disk/*/cache-ant/dump_flow` should also complete promptly.
