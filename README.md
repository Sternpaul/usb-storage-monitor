# USB Storage Overnight Monitor

Comprehensive monitoring toolkit for diagnosing intermittent USB storage failures on a multi-bay USB enclosure connected to a Linux server.

**Repository**: Clone and run on your server — no dependencies to install manually.

## Problem Being Investigated

The USB enclosure becomes unstable overnight — drives disconnect, filesystems go read-only, Docker containers crash. All evidence points to a failure in the USB storage subsystem (bridge firmware, power delivery, or backplane instability), **not** individual drive failure.

## Quick Start (3 commands)

```bash
git clone https://github.com/Sternpaul/usb-storage-monitor.git
cd usb-storage-monitor
chmod +x setup.sh usb_storage_monitor.sh
sudo ./setup.sh              # installs everything, detects drives
```

Then start monitoring:

```bash
# In a screen/tmux session (recommended):
screen -S usb-monitor
sudo ./usb_storage_monitor.sh --duration 14
# Ctrl+A, D to detach

# Or in the background:
sudo nohup ./usb_storage_monitor.sh --duration 14 > /dev/null 2>&1 &
```

## Dependencies

**All installed automatically by `setup.sh`** — you don't need to install anything manually.

The setup script runs:
```bash
apt-get install smartmontools hdparm sysstat usbutils udev util-linux lm-sensors
```

This provides: `smartctl`, `hdparm`, `iostat`, `lsusb`, `udevadm`, `sensors`

Already present on most Linux distributions: `journalctl`, `blkid`, `findmnt`, `fuser`, `lsof`, `dd`, `timeout`

**Optional** (auto-detected, not required):
- `docker` — if installed, Docker container health is monitored
- `lm-sensors` — if installed, system CPU/chipset thermals are tracked

## What This Monitors (16 parallel monitors)

| # | Monitor | Interval | Purpose |
|---|---------|----------|---------|
| 1 | **Kernel log watcher** | Real-time | USB resets, xHCI errors, SCSI timeouts, I/O errors, hung tasks, ext4 journal aborts |
| 2 | **udev events** | Real-time | USB device add/remove events (catches disconnect/reconnect the instant it happens) |
| 3 | **I/O statistics** | 30s | Per-drive iostat — await, throughput, queue depth |
| 4 | **I/O latency probes** | 60s | Direct 4K read from each drive — catches wake-from-standby delays |
| 5 | **SMART health** | 15 min | Temperature, reallocated sectors, pending sectors, CRC errors (with delta tracking). Reduced from 5 min to avoid perturbing the bridge with ATA commands |
| 6 | **Power state** | 15 min | hdparm -C on each drive (noting JMicron/USB bridge misreports standby) |
| 7 | **USB topology** | 5 min | lsusb snapshots with diff — detects device disappearing or **speed downgrade (5Gbps→0.48Gbps)** |
| 8 | **Mount status** | 60s | Detects read-only remounts |
| 9 | **Docker health** | 2 min | Container status, **restart counts via `docker inspect`** (catches container restarts) |
| 10 | **System resources** | 60s | CPU, memory, load, thermals |
| 11 | **Periodic dmesg dumps** | 10 min | Full kernel ring buffer snapshots — prevents message loss from buffer overflow |
| 12 | **Process I/O tracking** | 60s | Identifies which process (backup task? cron? fstrim?) is accessing enclosure drives |
| 13 | **SCSI error counters** | 5 min | sysfs ioerr_cnt/iodone_cnt — catches errors at the SCSI transport layer |
| 14 | **⚡ PSI I/O pressure** | **10s** | **`/proc/pressure/io` — the single best early-warning signal.** Spikes to 90%+ *before* the USB bridge disconnects. Tells us processes are piling up waiting for I/O |
| 15 | **D-state process tracking** | 30s | Processes in uninterruptible sleep (D state) — catches the *buildup* before total collapse |
| 16 | **ext4 error counters** | 5 min | `/sys/fs/ext4/*/errors_count` — distinguishes filesystem corruption from USB failure |

### Emergency Snapshots

When a **CRITICAL** or **ERROR** event is detected (USB disconnect, I/O error, journal abort, etc.), the script immediately captures a full emergency snapshot with **30-second timeouts** (so it won't hang if the USB subsystem is dead):

- Last 500 lines of dmesg (reads from kernel memory, not disk — always works)
- Verbose lsusb output
- Block device and filesystem state
- Full SMART dump for all drives
- SCSI error counters from sysfs
- **Which processes have the enclosure drives open** (fuser + lsof)
- iostat + raw /proc/diskstats
- Docker container state
- System state including **blocked processes in D state**

### Startup Baseline Captures

- **xHCI host controller**: `lspci -vv` + `usb-devices` (rules out host-side issues)
- **ext4 error counters**: `/sys/fs/ext4/*/errors_count` baseline
- **PSI pressure**: `/proc/pressure/io` baseline
- **Docker restart counts**: `docker inspect` RestartCount/StartedAt/FinishedAt
- **/proc/locks**: file lock state
- SCSI error counters, raw /proc/diskstats, journald persistence check

## Expected Log Sizes (14-hour run)

Total disk usage: **~15–30 MB** for a quiet night, **~30–60 MB** with failures.

| Directory | Estimated Size | Notes |
|-----------|---------------|-------|
| `baseline/` | ~1–2 MB | One-time captures (SMART dumps, lsusb, lspci, dmesg, PSI, ext4, /proc/locks, etc.) |
| `dmesg/` | ~5–15 MB | ~84 full dmesg dumps (~60–180KB each). **Biggest contributor** but essential — kernel ring buffer is only 256KB |
| `smart/` | ~1–2 MB | SMART polling now every 15 min (reduced from 5 min to avoid perturbing the bridge) |
| `io/` | ~3–5 MB | iostat + latency probes + diskstats + process I/O |
| `continuous/` | ~1–3 MB | Kernel errors, udev, USB topology, mounts, SCSI/USB counters, **PSI, D-state, ext4 errors** |
| `system/` | ~0.5–1 MB | System resources + thermals |
| `docker/` | ~0.5 MB | Container status + **restart count tracking** |
| `events/` | ~0.2 MB per snapshot | Emergency snapshots (~200KB each). Only created on errors |
| `summary/` | ~5 KB | Auto-generated report |

**Minimum free space recommended: 100 MB** (generous margin).

## Before Running: Important Steps

### 1. Ensure drives won't sleep (critical for the experiment!)

```bash
# Disable standby on ALL enclosure drives
# Replace sdX with your actual device letters (setup.sh will show them)
sudo hdparm -S 0 /dev/sdX
sudo hdparm -S 0 /dev/sdY
# ... and so on for each drive
```

### 2. Make journald persistent (recommended)

The setup script checks this automatically, but if it warns you:

```bash
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald
```

This ensures kernel logs survive if the machine reboots during a crash.

## Command-Line Options

```
Usage: sudo ./usb_storage_monitor.sh [--duration HOURS] [--output DIR]

  --duration HOURS   How long to monitor (default: 12)
  --output DIR       Base output directory (default: /var/log/usb-monitor)
```

## Morning: How to Review Results

```bash
# Find the latest run
ls -lt /var/log/usb-monitor/

# Read the auto-generated summary
cat /var/log/usb-monitor/run_*/summary/REPORT.md

# Quick check: any critical events?
cat /var/log/usb-monitor/run_*/events/critical_events.log

# Quick check: any anomalies?
cat /var/log/usb-monitor/run_*/events/anomalies.log

# Check temperatures over the night
cat /var/log/usb-monitor/run_*/smart/temperatures.csv

# Check for wake-up delays
grep "SLOW_READ\|READ_FAILED" /var/log/usb-monitor/run_*/io/latency_probes.log

# What was accessing the drives before failure?
cat /var/log/usb-monitor/run_*/io/process_io.log

# SCSI-level errors
cat /var/log/usb-monitor/run_*/continuous/scsi_error_counters.log

# Check CRC errors (USB/SATA link quality)
grep "CRC" /var/log/usb-monitor/run_*/events/critical_events.log
```

## Output Directory Structure

```
/var/log/usb-monitor/run_YYYYMMDD_HHMMSS/
├── master.log                              # Unified chronological log
├── baseline/                               # Captured at start
│   ├── system_info.log                     # OS, kernel, CPU, memory
│   ├── usb_topology.log                    # lsusb + JMicron/USB bridge details
│   ├── usb_power_mgmt.log                 # Autosuspend settings
│   ├── block_devices.log                   # lsblk, blkid, findmnt
│   ├── enclosure_drives.log               # Discovered drives + model/serial
│   ├── smart_sdX_full.log                  # Full SMART dump per drive
│   ├── hdparm_baseline.log                # Power state + identify info
│   ├── xhci_host_controller.log           # lspci -vv + usb-devices
│   ├── scsi_error_counters_baseline.log   # SCSI transport error baselines
│   ├── ext4_error_counters_baseline.log   # ext4 errors_count baselines
│   ├── proc_locks_baseline.log            # /proc/locks snapshot
│   ├── psi_baseline.log                   # PSI pressure baselines
│   ├── diskstats_baseline.log             # Raw /proc/diskstats
│   ├── journald_check.log                 # Journal persistence status
│   ├── docker_baseline.log                # Docker state (if available)
│   ├── dmesg_baseline.log                 # Kernel ring buffer snapshot
│   ├── iostat_baseline.log                # I/O stats snapshot
│   └── sensors_baseline.log               # Thermal data (if available)
├── continuous/                             # Ongoing monitoring
│   ├── kernel_usb_errors.log              # Filtered error messages
│   ├── kernel_all_relevant.log            # All storage-related kernel msgs
│   ├── udev_events.log                    # USB/block device events
│   ├── usb_topology_snapshots.log         # Periodic lsusb + diff detection
│   ├── usb_error_counters.log             # sysfs USB error stats
│   ├── scsi_error_counters.log            # SCSI ioerr/iodone/iorequest
│   ├── psi_io.log                         # ⚡ PSI I/O pressure (10s intervals)
│   ├── dstate_processes.log               # D-state process buildup tracking
│   ├── ext4_error_counters.log            # ext4 errors_count changes
│   └── mount_status.log                   # Filesystem mount state
├── dmesg/                                  # Periodic kernel ring buffer dumps
│   ├── dmesg_dump_0001.log                # Every 10 minutes
│   ├── dmesg_dump_0002.log
│   ├── ...
│   └── dmesg_dump_NNNN_FINAL.log          # Final dump at shutdown
├── smart/                                  # Drive health tracking
│   ├── smart_periodic.log                 # Periodic SMART attribute dumps
│   ├── temperatures.csv                   # CSV: timestamp, temp per drive
│   ├── power_states.log                   # hdparm -C results over time
│   └── smart_error_deltas.log             # Changes in error counters
├── io/                                     # I/O performance data
│   ├── iostat_continuous.log              # Periodic iostat snapshots
│   ├── latency_probes.log                 # Direct-read latency per drive
│   ├── process_io.log                     # Which processes access drives
│   └── diskstats_periodic.log             # Raw /proc/diskstats over time
├── docker/                                 # Docker health (if available)
│   ├── docker_health.log                  # Container status over time
│   └── docker_restarts.log                # Restart counts per container
├── system/                                 # System resource tracking
│   ├── system_resources.log               # CPU, memory, load, vmstat
│   └── system_thermals.log                # lm-sensors data (if available)
├── events/                                 # Critical event tracking
│   ├── critical_events.log                # All CRITICAL/ERROR/WARNING events
│   ├── anomalies.log                      # Threshold violations
│   └── snapshot_YYYYMMDD_HHMMSS_NNN/      # Emergency snapshots
│       ├── dmesg_tail.log                 # Last 500 lines of dmesg
│       ├── lsusb_verbose.log
│       ├── block_fs_state.log
│       ├── smart_sdX.log                  # Per-drive SMART
│       ├── hdparm_sdX.log                 # Per-drive power state
│       ├── scsi_error_counters.log        # SCSI error counters at failure
│       ├── processes_accessing_drives.log # fuser + lsof output
│       ├── diskstats_raw.log              # /proc/diskstats at failure
│       ├── iostat.log
│       ├── docker_ps.log
│       └── system_state.log               # Includes D-state processes
└── summary/
    └── REPORT.md                           # Auto-generated summary
```

## Interpreting the Results

### 1. Firmware Bugs (Drive Resume)
**What to look for:**
- I/O latency probes detect multi-second reads (drive spinning up)
- PSI I/O pressure spikes *before* the USB disconnect
- Power state log shows standby transitions before failure
- If `hdparm -S 0` fixes the issue: firmware resume bug is confirmed.

### 2. Power Transients (Simultaneous Wake-up)
**What to look for:**
- I/O latency probes show multiple drives with >1s reads at the same timestamp
- PSI I/O pressure spike correlated with multi-drive latency spike
- Temperature CSV shows drops then rises (spin-down then spin-up cycle)

### 3. Backplane / Hardware Instability
**What to look for:**
- If crashes continue even with `hdparm -S 0` (no standby), hardware becomes the top suspect
- SMART CRC error delta tracking (UDMA_CRC_Error_Count) — any increase = link-level errors
- SCSI error counters (ioerr_cnt) increases indicate transport failures
- ext4 error counters — distinguish filesystem corruption from USB failure

### 4. Thermal Instability
**What to look for:**
- Alert fires if any drive exceeds safe temperatures (e.g., 55°C)
- Correlate temperature peak timestamps with failure timestamps

### 5. Bad USB Cable
**What to look for:**
- UDMA_CRC_Error_Count increasing = cable/connector signal integrity issue
- USB topology `lsusb -t` catches speed downgrade (e.g., 5000M→480M) after reconnect
- Pattern: errors scattered throughout the night (not correlated with load/temp) = cable

## Known Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| Can't monitor PSU voltage/current | Can't directly prove power delivery failures | Inferred from simultaneous multi-drive latency spikes |
| Script stops if system reboots | Lose in-progress monitoring | Journald persistence check warns you; periodic dmesg dumps capture history |
| hdparm -C unreliable on JMicron/USB bridge | Power state may be misreported | I/O latency probes detect real standby (>1s response = was sleeping) |
| Emergency snapshots may partially fail during I/O deadlock | Some data might not be captured | 30-second timeouts prevent infinite hangs; dmesg always works (reads kernel memory) |
| fuser/lsof may be slow under I/O pressure | Process tracking could lag | 5-second timeouts per call |

## Making hdparm -S 0 Persistent

If the experiment succeeds (no crash with standby disabled), make it permanent:

```bash
sudo tee /etc/systemd/system/disable-hdd-standby.service << 'EOF'
[Unit]
Description=Disable HDD standby on USB enclosure drives
After=local-fs.target

[Service]
Type=oneshot
# Adjust device names as needed — use /dev/disk/by-id/ for stability
ExecStart=/sbin/hdparm -S 0 /dev/sdX
ExecStart=/sbin/hdparm -S 0 /dev/sdY
# Add more lines for each drive
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now disable-hdd-standby.service
```

> **Note:** Device names (`/dev/sdX`) can change across reboots. For production use, prefer `/dev/disk/by-id/` paths.

## License

MIT
