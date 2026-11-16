# Keeping a btrfs data drive fast

This covers how to tell when disk I/O is the bottleneck, what causes it on a machine built the way this repository builds one (btrfs subvolumes under `/data`, SSD, zram swap), and how to fix each cause without losing work.

## Diagnose first

- `uptime` and `vmstat 1 3`: load far above the core count with a high `wa` column means processes are waiting on storage, not CPU.
- `cat /proc/pressure/io /proc/pressure/memory`: `full avg10` above a few percent is a stall you will feel. Memory pressure with a full swap is the other common cause.
- `ps -eo pid,stat,comm,wchan:24 | awk '$2 ~ /D/'`: processes in uninterruptible sleep and their wait channel. `folio_wait_bit*` and `wait_on_buffer` point at storage reads and writeback. `handle_reserve_ticket` on btrfs means it is short of metadata space or flushing reservations.
- `findmnt -t btrfs -o TARGET,OPTIONS`: confirm the options actually in effect, not just what fstab says.
- Measure btrfs space with `btrfs filesystem df <mount>` (per-type totals and usage). Use `btrfs filesystem du -s <path>` for real usage. Plain `du` overstates usage on btrfs when files share extents or are compressed, so a deletion can free less than `du` predicted.

## Keep btrfs below about 85 to 90 percent full

Btrfs slows down sharply as the data or metadata type fills. Clear space before the drive is nearly full, and watch metadata as well as data: a metadata type near its total causes the `handle_reserve_ticket` stalls above.

## Turn off per-delete discard

Recent kernels turn on `discard=async` for SSD btrfs by default, even when fstab does not mention it. Each deletion then sends trims to the drive, so cleaning up stalls everything else. Use `nodiscard` on every btrfs entry in fstab, not just one: the first mount of a filesystem decides, and the option applies to the whole filesystem.

```
UUID=<fs-uuid>  /data/workspace  btrfs  subvol=@workspace,compress=zstd:3,noatime,nodiscard  0 0
```

Apply it live with `mount -o remount,nodiscard <mountpoint>` for each mount, then confirm with `findmnt`. Keep a trim schedule with `fstrim.timer` (enabled by default on most distributions) so freed space is still returned to the drive, just in batches.

## Compressed RAM swap

Use `systemd-zram-generator` for a compressed swap device in RAM, with a disk swap file behind it as fallback.

`/etc/systemd/zram-generator.conf`:

```
[zram0]
zram-size = 16G
compression-algorithm = zstd
swap-priority = 100
```

- The package ships a default `/usr/lib/systemd/zram-generator.conf` that creates a 4 GB device. Your `/etc` file overrides it, but only when the device is created.
- A device that already exists keeps its size. To resize: `swapoff /dev/zram0` (it moves its pages back into RAM, so do it while RAM is free), then `zramctl --reset /dev/zram0`, then `systemctl restart systemd-zram-setup@zram0`.
- Setting a large `disksize` can fail with `Cannot allocate memory` when RAM is nearly full, even though it succeeds moments later. Retry when memory is freer, or set the size from a shell once RAM is available and `mkswap`/`swapon` it manually.
- Check with `zramctl` and `cat /proc/swaps`. The disk swap file stays in place at lower priority. Pages already in it stay there until used.

## Run deduplication only when idle, in small pieces

`duperemove` on btrfs replaces identical blocks with shared extents. Run it through a hashfile so the work is saved between runs.

- The hashfile is a SQLite database. Hashes are committed as files are processed, so an interrupted run keeps its progress, and the next run skips files that have not changed.
- Never run two duperemove processes against the same hashfile at once. The man page warns that this can corrupt it. A timer that fires while a manual run is still going is enough to cause it. Guard the unit or the script with a lock (`flock`).
- A systemd `TimeoutStartSec` covers the whole of `ExecStart`, not just the pre-start steps. If the timeout is shorter than the run, systemd kills it. Either set the timeout above the longest run, or split the work into runs that each finish within the budget.
- Gate each run: skip it on battery (`/sys/class/power_supply/AC*/online`) and skip it while the 1-minute load is above a threshold. Let the skipped run exit successfully so the timer just tries again later.
- Set the unit to lowest priority (`Nice=19`, `IOSchedulingClass=idle`, low `CPUWeight` and `IOWeight`), cap memory (`MemoryHigh` below `MemoryMax`), and cap I/O bandwidth (`IOReadBandwidthMax`, `IOWriteBandwidthMax`) per device.
- Long scans cover a large tree slowly. Split the work so every run finishes:
  - Pick the top-level subdirectory that was attempted least recently, and record each attempt with a timestamp, so every subdirectory gets its turn.
  - Build the file list for that subdirectory once (`find <dir> -xdev -type f`), and keep a position file.
  - Each run takes the next fixed-size batch of files and passes it to duperemove. Unchanged files that were already hashed are skipped, so a batch that repeats costs little.
  - Keep the per-run budget with `timeout`. A run that hits its budget keeps its hashes, and the position does not advance, so the next run retries that batch.

## Cleaning up without losing work

Measure first, then delete, and never delete a directory that may be the only copy of someone's work.

- Journal: `journalctl --disk-usage`, then `journalctl --vacuum-size=500M`. The vacuum only removes archived journal files, so check the usage again afterwards.
- apt: `apt-get clean` removes the downloaded package cache.
- snap: remove disabled revisions with `snap list --all`, then `snap remove <name> --revision=<rev>`.
- Docker: `docker builder prune -f` removes unused build cache only. Leave stopped containers alone if they hold state you want. Remove images only after checking they are not used.
- Package caches (`npm`, `pip`, `uv`, `cargo`, `rustup`) regenerate on demand, so they are the safest space to reclaim. Virtualenvs do not regenerate on their own, so check before removing one.
- Build output (`target/` directories) regenerates when the project is built again, but check that no build is using it first.
- Before any `rm -rf`, check that no process has files open or a working directory in the target: `lsof +D <dir>`, and `readlink /proc/*/cwd`.
- A folder with no `.git` directory and no documentation may still be the only copy of something. Ask before removing it.

## Keep builds from starving the rest of the machine

Run heavy builds with low I/O and CPU priority while you work: `ionice -c3 -p <pid>` and `renice -n 15 -p <pid>` on the running build processes. Cap parallel jobs (`CARGO_BUILD_JOBS`, `make -j`) so several linkers do not run at once. Linkers can use several gigabytes each, and that alone can push a small machine into swap.
