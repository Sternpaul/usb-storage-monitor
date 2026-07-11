#!/usr/bin/env bash
###############################################################################
#  USB Storage Overnight Monitor
#  ─────────────────────────────
#  Purpose : Pinpoint the root cause of intermittent USB storage failures on
#            a multi-bay USB enclosure connected
#            to a Linux server.
#
#  Usage   : sudo ./usb_storage_monitor.sh [--duration HOURS] [--output DIR]
#
#  What it monitors:
#    • Kernel messages (USB resets, xhci errors, SCSI timeouts, I/O errors)
#    • udev USB device add/remove events
#    • Per-drive SMART attributes, temperatures, and power states
#    • I/O latency per block device (iostat + custom read probes)
#    • USB topology snapshots (lsusb)
#    • Docker container health
#    • System resources (CPU, memory, load, thermals)
#    • Filesystem mount status (read-only detection)
#
#  Output  : Creates a timestamped directory with structured logs and a
#            post-run summary report.
#
#  Requirements: smartmontools, hdparm, sysstat (iostat), udev, lsusb
#                Optional: docker, lm-sensors
#
#  Author  : Generated for USB enclosure diagnostics
#  License : MIT
###############################################################################

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_DURATION_HOURS=12
DEFAULT_OUTPUT_BASE="/var/log/usb-monitor"
POLL_INTERVAL_IO=30          # seconds between I/O snapshots
POLL_INTERVAL_SMART=900      # seconds between SMART checks (15 min — reduced to avoid
                             # perturbing the bridge with ATA commands)
POLL_INTERVAL_USB=300        # seconds between USB topology snapshots
POLL_INTERVAL_DOCKER=120     # seconds between Docker health checks
POLL_INTERVAL_SYSTEM=60      # seconds between system resource snapshots
POLL_INTERVAL_MOUNT=60       # seconds between mount status checks
POLL_INTERVAL_LATENCY=60     # seconds between latency probes
POLL_INTERVAL_DMESG=600      # seconds between full dmesg dumps (10 min)
POLL_INTERVAL_PROC_IO=60     # seconds between process I/O snapshots (reduced from 30s
                             # to lower overhead — fuser can be expensive)
POLL_INTERVAL_SCSI=300       # seconds between SCSI error counter checks
POLL_INTERVAL_PSI=10         # seconds between PSI (Pressure Stall Information) checks
POLL_INTERVAL_DSTATE=30      # seconds between D-state process scans
POLL_INTERVAL_EXT4=300       # seconds between ext4 error counter checks
EMERGENCY_TIMEOUT=30         # seconds before emergency snapshot gives up
IO_LATENCY_WARN_MS=500       # warn if single-read exceeds this (ms)
TEMP_WARN_C=55               # drive temperature warning threshold (°C)
PSI_IO_WARN_THRESHOLD=10     # warn if PSI io some avg10 exceeds this %

# USB bridge ID
USB_VENDOR_PRODUCT="152d:0567"

# ── Color / formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

# ── Parse arguments ──────────────────────────────────────────────────────────
DURATION_HOURS="$DEFAULT_DURATION_HOURS"
OUTPUT_BASE="$DEFAULT_OUTPUT_BASE"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)  DURATION_HOURS="$2"; shift 2 ;;
        --output)    OUTPUT_BASE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: sudo $0 [--duration HOURS] [--output DIR]"
            echo ""
            echo "  --duration HOURS   How long to monitor (default: $DEFAULT_DURATION_HOURS)"
            echo "  --output DIR       Base output directory (default: $DEFAULT_OUTPUT_BASE)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

DURATION_SECONDS=$((DURATION_HOURS * 3600))

# ── Preflight checks ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${RST}"
    exit 1
fi

MISSING_TOOLS=()
for tool in smartctl hdparm iostat lsusb udevadm journalctl blkid findmnt; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    echo -e "${RED}Missing required tools: ${MISSING_TOOLS[*]}${RST}"
    echo ""
    echo "Install with:"
    echo "  apt-get install smartmontools hdparm sysstat usbutils udev util-linux"
    exit 1
fi

HAS_DOCKER=false
if command -v docker &>/dev/null; then
    HAS_DOCKER=true
fi

HAS_SENSORS=false
if command -v sensors &>/dev/null; then
    HAS_SENSORS=true
fi

# ── Create output directory ──────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="${OUTPUT_BASE}/run_${TIMESTAMP}"
mkdir -p "${RUN_DIR}"/{baseline,continuous,events,smart,io,docker,system,summary,dmesg}

MASTER_LOG="${RUN_DIR}/master.log"
EVENT_LOG="${RUN_DIR}/events/critical_events.log"
ANOMALY_LOG="${RUN_DIR}/events/anomalies.log"

touch "$MASTER_LOG" "$EVENT_LOG" "$ANOMALY_LOG"

# ── Logging helpers ──────────────────────────────────────────────────────────
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    echo "[$ts] $*" | tee -a "$MASTER_LOG"
}

log_event() {
    local ts severity msg
    ts=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    severity="$1"
    shift
    msg="$*"
    echo "[$ts] [$severity] $msg" | tee -a "$EVENT_LOG" "$MASTER_LOG"

    # On critical events, trigger an immediate snapshot
    if [[ "$severity" == "CRITICAL" || "$severity" == "ERROR" ]]; then
        trigger_emergency_snapshot "$msg" &
    fi
}

log_anomaly() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    echo "[$ts] $*" | tee -a "$ANOMALY_LOG" "$MASTER_LOG"
}

# ── Discover enclosure drives ────────────────────────────────────────────────
discover_enclosure_drives() {
    # Find all block devices behind the USB bridge
    local drives=()

    # Method 1: Walk sysfs for our USB vendor:product
    for dev in /sys/block/sd*; do
        [[ -e "$dev" ]] || continue
        local devname
        devname=$(basename "$dev")

        # Resolve the device path and look for our USB ID
        local devpath
        devpath=$(readlink -f "$dev/device" 2>/dev/null || true)
        if [[ -n "$devpath" ]]; then
            # Walk up to find the USB device
            local usbpath="$devpath"
            while [[ -n "$usbpath" && "$usbpath" != "/" ]]; do
                if [[ -f "$usbpath/idVendor" && -f "$usbpath/idProduct" ]]; then
                    local vid pid
                    vid=$(cat "$usbpath/idVendor" 2>/dev/null || true)
                    pid=$(cat "$usbpath/idProduct" 2>/dev/null || true)
                    if [[ "${vid}:${pid}" == "$USB_VENDOR_PRODUCT" ]]; then
                        drives+=("/dev/$devname")
                    fi
                    break
                fi
                usbpath=$(dirname "$usbpath")
            done
        fi
    done

    # Method 2: Fallback - if sysfs walk didn't work, use lsblk + udevadm
    if [[ ${#drives[@]} -eq 0 ]]; then
        for dev in /dev/sd?; do
            [[ -b "$dev" ]] || continue
            local udev_info
            udev_info=$(udevadm info --query=all --name="$dev" 2>/dev/null || true)
            if echo "$udev_info" | grep -qi "152d.*0567"; then
                drives+=("$dev")
            fi
        done
    fi

    echo "${drives[@]}"
}

# ── Get drive model/serial for logging ────────────────────────────────────────
get_drive_info() {
    local dev="$1"
    smartctl -i "$dev" 2>/dev/null | grep -E "^(Device Model|Serial Number|User Capacity)" | \
        sed 's/^/  /' || echo "  (unable to query)"
}

# ── Emergency snapshot on critical event ──────────────────────────────────────
# Wrapped in timeout to prevent hanging during I/O deadlock
trigger_emergency_snapshot() {
    local reason="$1"
    local snap_ts
    snap_ts=$(date +%Y%m%d_%H%M%S_%3N)
    local snap_dir="${RUN_DIR}/events/snapshot_${snap_ts}"
    mkdir -p "$snap_dir"

    log "EMERGENCY SNAPSHOT triggered: $reason"

    # Each capture runs with a timeout to prevent hanging during I/O deadlock
    # dmesg reads from kernel memory (not disk), so it should always work
    {
        echo "=== Emergency Snapshot ==="
        echo "Trigger: $reason"
        echo "Time: $(date -Iseconds)"
        echo ""
        echo "=== dmesg (last 500 lines) ==="
        dmesg --time-format=iso | tail -500
    } > "$snap_dir/dmesg_tail.log" 2>&1

    # These may hang if USB is dead, so use timeout
    timeout "$EMERGENCY_TIMEOUT" lsusb -v > "$snap_dir/lsusb_verbose.log" 2>&1 || echo "(timed out or failed)" >> "$snap_dir/lsusb_verbose.log"
    timeout "$EMERGENCY_TIMEOUT" lsusb -t > "$snap_dir/lsusb_tree.log" 2>&1 || echo "(timed out or failed)" >> "$snap_dir/lsusb_tree.log"

    {
        echo "=== Block devices ==="
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,STATE,ROTA,SCHED,RQ-SIZE 2>/dev/null || true
        echo ""
        echo "=== /proc/mounts ==="
        cat /proc/mounts 2>/dev/null || true
        echo ""
        echo "=== findmnt ==="
        findmnt 2>/dev/null || true
    } > "$snap_dir/block_fs_state.log" 2>&1

    # Grab SMART for each drive (with timeout — may hang if drive is gone)
    local drives
    IFS=' ' read -ra drives <<< "$(discover_enclosure_drives)"
    for drv in "${drives[@]}"; do
        local devname
        devname=$(basename "$drv")
        timeout "$EMERGENCY_TIMEOUT" smartctl -a "$drv" > "$snap_dir/smart_${devname}.log" 2>&1 || echo "(timed out or failed)" >> "$snap_dir/smart_${devname}.log"
        timeout "$EMERGENCY_TIMEOUT" hdparm -C "$drv" > "$snap_dir/hdparm_${devname}.log" 2>&1 || echo "(timed out or failed)" >> "$snap_dir/hdparm_${devname}.log"
    done

    # SCSI error counters at moment of event (reads from sysfs, should not hang)
    {
        echo "=== SCSI Error Counters ==="
        for drv in "${drives[@]}"; do
            local devname
            devname=$(basename "$drv")
            echo "--- $devname ---"
            for counter in /sys/block/$devname/device/{ioerr_cnt,iodone_cnt,iorequest_cnt,timeout}; do
                [[ -f "$counter" ]] && echo "  $(basename $counter) = $(cat $counter 2>/dev/null)"
            done
        done
    } > "$snap_dir/scsi_error_counters.log" 2>&1

    # Which processes have the enclosure drives open?
    {
        echo "=== Processes accessing enclosure drives ==="
        for drv in "${drives[@]}"; do
            echo "--- $drv ---"
            timeout 5 fuser -vm "$drv" 2>&1 || echo "  (fuser failed or timed out)"
        done
        echo ""
        echo "=== lsof on enclosure drives ==="
        for drv in "${drives[@]}"; do
            echo "--- $drv ---"
            timeout 5 lsof "$drv" 2>&1 | head -20 || echo "  (lsof failed or timed out)"
        done
    } > "$snap_dir/processes_accessing_drives.log" 2>&1

    # I/O stats at moment of event
    timeout "$EMERGENCY_TIMEOUT" iostat -dxmt 1 2 > "$snap_dir/iostat.log" 2>&1 || true

    # /proc/diskstats for raw I/O counters
    cp /proc/diskstats "$snap_dir/diskstats_raw.log" 2>/dev/null || true

    # Docker state
    if $HAS_DOCKER; then
        timeout 10 docker ps -a > "$snap_dir/docker_ps.log" 2>&1 || true
    fi

    # System state
    {
        echo "=== uptime ==="
        uptime
        echo ""
        echo "=== free ==="
        free -h
        echo ""
        echo "=== top snapshot ==="
        top -bn1 | head -30
        echo ""
        echo "=== blocked processes (D state) ==="
        ps aux | awk '$8 ~ /D/ {print}' || true
    } > "$snap_dir/system_state.log" 2>&1

    log "Emergency snapshot saved to $snap_dir"
}

# ── PID tracking for cleanup ─────────────────────────────────────────────────
CHILD_PIDS=()

#  PHASE 4: SUMMARY REPORT
###############################################################################

generate_summary() {
    local report="${RUN_DIR}/summary/REPORT.md"
    local run_duration=$(($(date +%s) - START_TIME))

    log "Generating summary report..."

    cat > "$report" <<HEADER
# USB Storage Monitor — Summary Report

- **Run ID**: ${TIMESTAMP}
- **Started**: $(date -d @$START_TIME -Iseconds)
- **Stopped**: $(date -Iseconds)
- **Duration**: $((run_duration/3600))h $((run_duration%3600/60))m $((run_duration%60))s
- **Output**: ${RUN_DIR}

## System
- **Host**: $(hostname)
- **Kernel**: $(uname -r)
- **Enclosure drives monitored**: ${#ENCLOSURE_DRIVES[@]}

---

HEADER

    # Count events by severity
    local critical_count warning_count error_count anomaly_count
    critical_count=$(grep -c "\[CRITICAL\]" "$EVENT_LOG" 2>/dev/null || true)
    error_count=$(grep -c "\[ERROR\]" "$EVENT_LOG" 2>/dev/null || true)
    warning_count=$(grep -c "\[WARNING\]" "$EVENT_LOG" 2>/dev/null || true)
    anomaly_count=$(wc -l < "$ANOMALY_LOG" 2>/dev/null || echo "0")

    cat >> "$report" <<EVENTS
## Event Summary

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | ${critical_count} |
| 🟠 ERROR | ${error_count} |
| 🟡 WARNING | ${warning_count} |
| 📊 Anomalies | ${anomaly_count} |

EVENTS

    if [[ $critical_count -gt 0 ]]; then
        cat >> "$report" <<CRIT
## 🔴 Critical Events

\`\`\`
$(grep "\[CRITICAL\]" "$EVENT_LOG" 2>/dev/null || echo "None")
\`\`\`

CRIT
    fi

    if [[ $error_count -gt 0 ]]; then
        cat >> "$report" <<ERR
## 🟠 Errors

\`\`\`
$(grep "\[ERROR\]" "$EVENT_LOG" 2>/dev/null || echo "None")
\`\`\`

ERR
    fi

    if [[ $warning_count -gt 0 ]]; then
        cat >> "$report" <<WARN
## 🟡 Warnings

\`\`\`
$(grep "\[WARNING\]" "$EVENT_LOG" 2>/dev/null || echo "None")
\`\`\`

WARN
    fi

    if [[ $anomaly_count -gt 0 ]]; then
        cat >> "$report" <<ANOM
## 📊 Anomalies

\`\`\`
$(cat "$ANOMALY_LOG" 2>/dev/null || echo "None")
\`\`\`

ANOM
    fi

    # Temperature summary
    if [[ -f "${RUN_DIR}/smart/temperatures.csv" ]]; then
        cat >> "$report" <<TEMP
## 🌡️ Temperature Summary

\`\`\`
$(head -1 "${RUN_DIR}/smart/temperatures.csv")
...
$(tail -5 "${RUN_DIR}/smart/temperatures.csv")
\`\`\`

TEMP
    fi

    # Emergency snapshots
    local snap_count
    snap_count=$(find "${RUN_DIR}/events/" -maxdepth 1 -type d -name "snapshot_*" 2>/dev/null | wc -l || echo "0")
    cat >> "$report" <<SNAPS
## 📸 Emergency Snapshots

${snap_count} emergency snapshot(s) captured during this run.
$(find "${RUN_DIR}/events/" -maxdepth 1 -type d -name "snapshot_*" -printf "- %f\n" 2>/dev/null || echo "None")

SNAPS

    # Hypothesis evaluation
    cat >> "$report" <<HYPO
## 🔍 Interpreting the Results

### 1. Firmware Bugs (Drive Resume)
- Check \`smart/power_states.log\` for standby → active transitions before failures
- Check \`io/latency_probes.log\` for slow reads (>1000ms) indicating drive wake-up
- Check \`continuous/psi_io.log\` for PSI I/O pressure spikes before disconnect
- Check \`continuous/dstate_processes.log\` for buildup of D-state processes
- Check \`events/critical_events.log\` for USB reset/disconnect timing

### 2. Power Transients (Simultaneous Wake-up)
- Check \`io/latency_probes.log\` for multiple drives showing slow reads simultaneously
- Check \`continuous/psi_io.log\` for PSI I/O pressure spike correlated with multi-drive latency spike
- Check \`smart/temperatures.csv\` for sudden drops (indicating spin-down/spin-up)
- Cross-reference with \`continuous/kernel_usb_errors.log\` timing

### 3. Backplane / Hardware Instability
- If failures occur even with \`hdparm -S 0\` active (no standby), this is more likely
- Check \`smart/smart_error_deltas.log\` for UDMA_CRC_Error_Count changes (link errors)
- Check \`continuous/ext4_error_counters.log\` to distinguish FS corruption from USB failure

### 4. Thermal Instability
- Check \`smart/temperatures.csv\` for temperatures exceeding ${TEMP_WARN_C}°C
- Check \`system/system_thermals.log\` for system-level overheating
- Correlate temperature spikes with failure timing

### 5. Bad USB Cable
- Check \`smart/smart_error_deltas.log\` for UDMA_CRC_Error_Count increases
- Check \`continuous/usb_topology_snapshots.log\` for speed downgrade (5000M→480M)
- Consistent CRC errors suggest cable or connector problems

---

## 📁 File Manifest

\`\`\`
$(find "${RUN_DIR}" -type f | sort | sed "s|${RUN_DIR}/||")
\`\`\`

---
*Generated by USB Storage Overnight Monitor*
HYPO

    log "Summary report written to $report"
    echo -e "${GRN}Summary report: ${report}${RST}"
}

# The summary is generated by the cleanup() trap

cleanup() {
    log "Shutting down monitors..."
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    # Wait briefly for children
    sleep 2
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    generate_summary
    log "Monitor stopped. Output in: $RUN_DIR"
    echo -e "${GRN}Monitor stopped. Full output in: ${RUN_DIR}${RST}"
}

trap cleanup EXIT INT TERM

###############################################################################
#  PHASE 1: BASELINE CAPTURE
###############################################################################

log "═══════════════════════════════════════════════════════════════════"
log "  USB Storage Overnight Monitor — Starting"
log "  Duration: ${DURATION_HOURS} hours"
log "  Output:   ${RUN_DIR}"
log "═══════════════════════════════════════════════════════════════════"

echo -e "${CYN}Phase 1: Capturing baseline...${RST}"

# ── System info ──────────────────────────────────────────────────────────────
{
    echo "=== System Information ==="
    echo "Hostname: $(hostname)"
    echo "Date: $(date -Iseconds)"
    echo "Uptime: $(uptime)"
    echo ""
    echo "=== Kernel ==="
    uname -a
    echo ""
    echo "=== OS Release ==="
    cat /etc/os-release 2>/dev/null || true
    echo ""
    echo "=== CPU ==="
    lscpu | head -20
    echo ""
    echo "=== Memory ==="
    free -h
    echo ""
    echo "=== Kernel Command Line ==="
    cat /proc/cmdline 2>/dev/null || true
} > "${RUN_DIR}/baseline/system_info.log"
log "Baseline: system info captured"

# ── USB topology ─────────────────────────────────────────────────────────────
{
    echo "=== lsusb ==="
    lsusb 2>/dev/null || true
    echo ""
    echo "=== lsusb -t (tree) ==="
    lsusb -t 2>/dev/null || true
    echo ""
    echo "=== lsusb -v (verbose, target bridge only) ==="
    # Find the bus/device for our bridge
    local_bus_dev=$(lsusb 2>/dev/null | grep "$USB_VENDOR_PRODUCT" | head -1 | \
        sed -n 's/Bus \([0-9]*\) Device \([0-9]*\).*/\1:\2/p' || true)
    if [[ -n "$local_bus_dev" ]]; then
        bus=$(echo "$local_bus_dev" | cut -d: -f1)
        dev=$(echo "$local_bus_dev" | cut -d: -f2)
        lsusb -v -s "$bus:$dev" 2>/dev/null || true
    else
        echo "(Target bridge not found in lsusb)"
    fi
} > "${RUN_DIR}/baseline/usb_topology.log"
log "Baseline: USB topology captured"

# ── xHCI host controller baseline ────────────────────────────────────────────
{
    echo "=== PCI USB Controllers (lspci) ==="
    lspci -vv 2>/dev/null | grep -A 20 -iE "USB|xHCI" || echo "(lspci not available)"
    echo ""
    echo "=== USB Devices (usb-devices) ==="
    usb-devices 2>/dev/null || echo "(usb-devices not available)"
} > "${RUN_DIR}/baseline/xhci_host_controller.log" 2>&1
log "Baseline: xHCI host controller captured"

# ── USB power management ─────────────────────────────────────────────────────
{
    echo "=== USB Autosuspend Settings ==="
    for f in /sys/bus/usb/devices/*/power/control; do
        [[ -f "$f" ]] || continue
        dev_path=$(dirname "$(dirname "$f")")
        product=""
        [[ -f "$dev_path/product" ]] && product=$(cat "$dev_path/product" 2>/dev/null || true)
        vid="" pid=""
        [[ -f "$dev_path/idVendor" ]] && vid=$(cat "$dev_path/idVendor" 2>/dev/null || true)
        [[ -f "$dev_path/idProduct" ]] && pid=$(cat "$dev_path/idProduct" 2>/dev/null || true)
        echo "$f = $(cat "$f" 2>/dev/null)  [${vid}:${pid} $product]"
    done
    echo ""
    echo "=== USB Autosuspend Delay ==="
    for f in /sys/bus/usb/devices/*/power/autosuspend_delay_ms; do
        [[ -f "$f" ]] || continue
        echo "$f = $(cat "$f" 2>/dev/null)"
    done
    echo ""
    echo "=== xHCI Driver Info ==="
    for f in /sys/bus/pci/drivers/xhci_hcd/*/uevent; do
        [[ -f "$f" ]] || continue
        echo "--- $f ---"
        cat "$f" 2>/dev/null || true
        echo ""
    done
} > "${RUN_DIR}/baseline/usb_power_mgmt.log" 2>&1
log "Baseline: USB power management captured"

# ── Block device layout ──────────────────────────────────────────────────────
{
    echo "=== lsblk ==="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,MODEL,SERIAL,STATE,ROTA,TRAN 2>/dev/null || true
    echo ""
    echo "=== blkid ==="
    blkid 2>/dev/null || true
    echo ""
    echo "=== findmnt ==="
    findmnt 2>/dev/null || true
    echo ""
    echo "=== /proc/mounts ==="
    cat /proc/mounts 2>/dev/null || true
    echo ""
    echo "=== mount ==="
    mount 2>/dev/null || true
} > "${RUN_DIR}/baseline/block_devices.log"
log "Baseline: block device layout captured"

# ── Discover and document enclosure drives ────────────────────────────────────
ENCLOSURE_DRIVES=()
IFS=' ' read -ra ENCLOSURE_DRIVES <<< "$(discover_enclosure_drives)"

{
    echo "=== Discovered Enclosure Drives ==="
    echo "USB ID: $USB_VENDOR_PRODUCT"
    echo "Drive count: ${#ENCLOSURE_DRIVES[@]}"
    echo ""
    for drv in "${ENCLOSURE_DRIVES[@]}"; do
        echo "--- $drv ---"
        get_drive_info "$drv"
        echo ""
    done
} > "${RUN_DIR}/baseline/enclosure_drives.log"

if [[ ${#ENCLOSURE_DRIVES[@]} -eq 0 ]]; then
    log_event "WARNING" "No enclosure drives discovered! Check USB connection."
    echo -e "${YEL}WARNING: No drives found behind target bridge.${RST}"
    echo -e "${YEL}The script will continue but drive-specific monitoring will be limited.${RST}"
else
    log "Discovered ${#ENCLOSURE_DRIVES[@]} enclosure drive(s): ${ENCLOSURE_DRIVES[*]}"
fi

# ── Full SMART baseline for each drive ────────────────────────────────────────
for drv in "${ENCLOSURE_DRIVES[@]}"; do
    devname=$(basename "$drv")
    smartctl -x "$drv" > "${RUN_DIR}/baseline/smart_${devname}_full.log" 2>&1 || true
    log "Baseline: SMART data captured for $drv"
done

# ── hdparm baseline ──────────────────────────────────────────────────────────
{
    echo "=== hdparm Drive Power State ==="
    for drv in "${ENCLOSURE_DRIVES[@]}"; do
        echo "--- $drv ---"
        hdparm -C "$drv" 2>/dev/null || echo "(failed)"
        echo ""
        echo "--- $drv -I (identify, APM/standby) ---"
        hdparm -I "$drv" 2>/dev/null | grep -iE "power|standby|apm|sleep|idle" || echo "(no matches)"
        echo ""
    done
} > "${RUN_DIR}/baseline/hdparm_baseline.log" 2>&1
log "Baseline: hdparm data captured"

# ── Docker baseline ──────────────────────────────────────────────────────────
if $HAS_DOCKER; then
    {
        echo "=== Docker Version ==="
        docker version 2>/dev/null || true
        echo ""
        echo "=== Docker Containers ==="
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
        echo ""
        echo "=== Docker Restart Counts ==="
        docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r cname; do
            restart_count=$(docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "N/A")
            started_at=$(docker inspect --format '{{.State.StartedAt}}' "$cname" 2>/dev/null || echo "N/A")
            finished_at=$(docker inspect --format '{{.State.FinishedAt}}' "$cname" 2>/dev/null || echo "N/A")
            echo "  $cname: restarts=$restart_count started=$started_at finished=$finished_at"
        done
        echo ""
        echo "=== Docker Volumes ==="
        docker volume ls 2>/dev/null || true
    } > "${RUN_DIR}/baseline/docker_baseline.log" 2>&1
    log "Baseline: Docker state captured"
fi

# ── Kernel ring buffer baseline ──────────────────────────────────────────────
dmesg --time-format=iso > "${RUN_DIR}/baseline/dmesg_baseline.log" 2>&1 || true
log "Baseline: kernel ring buffer captured"

# ── I/O baseline ─────────────────────────────────────────────────────────────
iostat -dxmt 1 3 > "${RUN_DIR}/baseline/iostat_baseline.log" 2>&1 || true
cp /proc/diskstats "${RUN_DIR}/baseline/diskstats_baseline.log" 2>/dev/null || true
log "Baseline: I/O stats captured"

# ── SCSI error counter baseline ──────────────────────────────────────────────
{
    echo "=== SCSI Error Counters (baseline) ==="
    for drv in "${ENCLOSURE_DRIVES[@]}"; do
        devname=$(basename "$drv")
        echo "--- $devname ---"
        for counter in /sys/block/$devname/device/{ioerr_cnt,iodone_cnt,iorequest_cnt,timeout}; do
            [[ -f "$counter" ]] && echo "  $(basename $counter) = $(cat $counter 2>/dev/null)"
        done
    done
} > "${RUN_DIR}/baseline/scsi_error_counters_baseline.log" 2>&1
log "Baseline: SCSI error counters captured"

# ── ext4 error counters baseline ─────────────────────────────────────────────
{
    echo "=== ext4 Error Counters (baseline) ==="
    for errdir in /sys/fs/ext4/*/; do
        [[ -d "$errdir" ]] || continue
        devname=$(basename "$errdir")
        echo "--- $devname ---"
        [[ -f "$errdir/errors_count" ]] && echo "  errors_count = $(cat "$errdir/errors_count" 2>/dev/null)"
        [[ -f "$errdir/first_error_time" ]] && echo "  first_error_time = $(cat "$errdir/first_error_time" 2>/dev/null)"
        [[ -f "$errdir/last_error_time" ]] && echo "  last_error_time = $(cat "$errdir/last_error_time" 2>/dev/null)"
        [[ -f "$errdir/first_error_func" ]] && echo "  first_error_func = $(cat "$errdir/first_error_func" 2>/dev/null)"
        [[ -f "$errdir/last_error_func" ]] && echo "  last_error_func = $(cat "$errdir/last_error_func" 2>/dev/null)"
    done
} > "${RUN_DIR}/baseline/ext4_error_counters_baseline.log" 2>&1
log "Baseline: ext4 error counters captured"

# ── /proc/locks baseline ─────────────────────────────────────────────────────
cp /proc/locks "${RUN_DIR}/baseline/proc_locks_baseline.log" 2>/dev/null || true
log "Baseline: /proc/locks captured"

# ── PSI (Pressure Stall Information) baseline ────────────────────────────────
{
    echo "=== PSI Baseline ==="
    echo "--- /proc/pressure/io ---"
    cat /proc/pressure/io 2>/dev/null || echo "(PSI not available — kernel may need CONFIG_PSI=y)"
    echo "--- /proc/pressure/cpu ---"
    cat /proc/pressure/cpu 2>/dev/null || true
    echo "--- /proc/pressure/memory ---"
    cat /proc/pressure/memory 2>/dev/null || true
} > "${RUN_DIR}/baseline/psi_baseline.log" 2>&1
log "Baseline: PSI pressure data captured"

# ── System thermal baseline ──────────────────────────────────────────────────
if $HAS_SENSORS; then
    sensors > "${RUN_DIR}/baseline/sensors_baseline.log" 2>&1 || true
    log "Baseline: system thermal data captured"
fi

# ── Journald persistence check ───────────────────────────────────────────────
{
    echo "=== Journald Configuration ==="
    if [[ -f /etc/systemd/journald.conf ]]; then
        grep -vE '^#|^$' /etc/systemd/journald.conf 2>/dev/null || true
    fi
    echo ""
    echo "=== Journal storage location ==="
    journalctl --disk-usage 2>/dev/null || true
    echo ""
    if [[ -d /var/log/journal ]]; then
        echo "Storage: PERSISTENT (/var/log/journal exists)"
        echo "Journal logs will survive a reboot."
    else
        echo "Storage: VOLATILE (/var/log/journal does NOT exist)"
        echo "WARNING: Journal logs will be LOST on reboot!"
        echo "If the failure causes a reboot, kernel logs will be gone."
        echo "To fix: mkdir -p /var/log/journal && systemctl restart systemd-journald"
    fi
} > "${RUN_DIR}/baseline/journald_check.log" 2>&1

# Warn the user if journal is volatile
if [[ ! -d /var/log/journal ]]; then
    log_event "WARNING" "JOURNALD: Storage is VOLATILE — logs will be lost on reboot! Run: mkdir -p /var/log/journal && systemctl restart systemd-journald"
    echo -e "${YEL}⚠ WARNING: journald is volatile. Kernel logs will be lost on reboot!${RST}"
    echo -e "${YEL}  Fix with: sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald${RST}"
fi
log "Baseline: journald persistence checked"

echo -e "${GRN}Phase 1 complete. Baseline captured.${RST}"
log "Baseline capture complete"

###############################################################################
#  PHASE 2: CONTINUOUS MONITORING
###############################################################################

echo -e "${CYN}Phase 2: Starting continuous monitors...${RST}"
log "Starting continuous monitors for ${DURATION_HOURS} hours"

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SECONDS))

# ── Helper: check if we should still be running ──────────────────────────────
still_running() {
    [[ $(date +%s) -lt $END_TIME ]]
}

# ── Monitor 1: Kernel log watcher (journalctl) ───────────────────────────────
# Watches for USB, SCSI, xhci, I/O, ext4, and hung task messages
monitor_kernel_logs() {
    local logfile="${RUN_DIR}/continuous/kernel_usb_errors.log"
    local full_logfile="${RUN_DIR}/continuous/kernel_all_relevant.log"

    # Patterns that indicate problems
    local error_patterns="USB disconnect|usb_reset|DID_TIME_OUT|I/O error|Buffer I/O error\
|xhci|SCSI error|sd [a-z]: .*error|task .* blocked|hung_task|EXT4-fs error\
|journal abort|Remounting filesystem read-only|protocol error|URB status\
|device descriptor read|reset .* USB|port .* disabled|overcurrent|Cannot enable"

    # Patterns relevant but not necessarily errors
    local info_patterns="usb |scsi |sd[a-z]|ata[0-9]|xhci|ext4|jbd2|blk_update"

    journalctl -kf --since="now" --no-pager 2>/dev/null | while IFS= read -r line; do
        # Log all storage-relevant kernel messages
        if echo "$line" | grep -qiE "$info_patterns"; then
            echo "$line" >> "$full_logfile"
        fi

        # Flag error patterns
        if echo "$line" | grep -qiE "$error_patterns"; then
            echo "$line" >> "$logfile"

            # Classify severity
            if echo "$line" | grep -qiE "USB disconnect|journal abort|read-only|overcurrent"; then
                log_event "CRITICAL" "KERNEL: $line"
            elif echo "$line" | grep -qiE "DID_TIME_OUT|I/O error|xhci.*error|protocol error"; then
                log_event "ERROR" "KERNEL: $line"
            elif echo "$line" | grep -qiE "usb_reset|reset.*USB|hung_task|blocked"; then
                log_event "WARNING" "KERNEL: $line"
            fi
        fi
    done
}

monitor_kernel_logs &
CHILD_PIDS+=($!)
log "Monitor started: kernel log watcher (PID $!)"

# ── Monitor 2: udev device event monitor ─────────────────────────────────────
monitor_udev() {
    local logfile="${RUN_DIR}/continuous/udev_events.log"

    udevadm monitor --subsystem-match=usb --subsystem-match=block \
        --property 2>/dev/null | while IFS= read -r line; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $line" >> "$logfile"

        # Flag device removals
        if echo "$line" | grep -qiE "remove.*sd[a-z]|unbind"; then
            log_event "CRITICAL" "UDEV: Device removal detected: $line"
        elif echo "$line" | grep -qiE "remove.*usb"; then
            log_event "ERROR" "UDEV: USB removal event: $line"
        elif echo "$line" | grep -qiE "add.*usb|add.*sd[a-z]"; then
            log_event "WARNING" "UDEV: Device add event (possible reconnect): $line"
        fi
    done
}

monitor_udev &
CHILD_PIDS+=($!)
log "Monitor started: udev event watcher (PID $!)"

# ── Monitor 3: I/O statistics (iostat) ───────────────────────────────────────
monitor_io_stats() {
    local logfile="${RUN_DIR}/io/iostat_continuous.log"

    while still_running; do
        echo "" >> "$logfile"
        echo "=== $(date -Iseconds) ===" >> "$logfile"
        iostat -dxmt 1 2 2>/dev/null | tail -n +4 >> "$logfile"

        # Check for high await (I/O latency) on enclosure drives
        for drv in "${ENCLOSURE_DRIVES[@]}"; do
            local devname
            devname=$(basename "$drv")
            local await
            await=$(iostat -dxm "$devname" 1 2 2>/dev/null | awk -v dev="$devname" \
                '$1 == dev {print $10}' | tail -1 || true)
            if [[ -n "$await" ]]; then
                # Compare as floating point
                local await_int
                await_int=$(printf "%.0f" "$await" 2>/dev/null || echo "0")
                if [[ $await_int -gt $IO_LATENCY_WARN_MS ]]; then
                    log_anomaly "HIGH_AWAIT: $devname await=${await}ms (threshold: ${IO_LATENCY_WARN_MS}ms)"
                fi
            fi
        done

        sleep "$POLL_INTERVAL_IO"
    done
}

monitor_io_stats &
CHILD_PIDS+=($!)
log "Monitor started: I/O statistics (PID $!, interval: ${POLL_INTERVAL_IO}s)"

# ── Monitor 4: Drive I/O latency probe ───────────────────────────────────────
# Attempts a small direct read from each drive and measures latency
monitor_io_latency() {
    local logfile="${RUN_DIR}/io/latency_probes.log"

    while still_running; do
        for drv in "${ENCLOSURE_DRIVES[@]}"; do
            local devname
            devname=$(basename "$drv")

            # Time a 4K read from the device
            local start_ns end_ns elapsed_ms
            start_ns=$(date +%s%N)

            # Use dd to read a single block - this will catch "drive asleep" delays
            if dd if="$drv" of=/dev/null bs=4096 count=1 iflag=direct 2>/dev/null; then
                end_ns=$(date +%s%N)
                elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
                echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $devname read_latency=${elapsed_ms}ms" >> "$logfile"

                if [[ $elapsed_ms -gt $IO_LATENCY_WARN_MS ]]; then
                    log_anomaly "SLOW_READ: $devname latency=${elapsed_ms}ms (threshold: ${IO_LATENCY_WARN_MS}ms) — possible wake-up from standby?"
                fi
                if [[ $elapsed_ms -gt 5000 ]]; then
                    log_event "WARNING" "VERY_SLOW_READ: $devname latency=${elapsed_ms}ms — drive may be spinning up"
                fi
            else
                log_event "ERROR" "READ_FAILED: dd read from $drv failed — drive may be offline"
                echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $devname READ_FAILED" >> "$logfile"
            fi
        done

        sleep "$POLL_INTERVAL_LATENCY"
    done
}

monitor_io_latency &
CHILD_PIDS+=($!)
log "Monitor started: I/O latency probes (PID $!, interval: ${POLL_INTERVAL_LATENCY}s)"

# ── Monitor 5: SMART + temperature + power state ─────────────────────────────
monitor_smart() {
    local logfile="${RUN_DIR}/smart/smart_periodic.log"
    local temp_logfile="${RUN_DIR}/smart/temperatures.csv"
    local power_logfile="${RUN_DIR}/smart/power_states.log"
    local error_logfile="${RUN_DIR}/smart/smart_error_deltas.log"

    # CSV header for temperatures
    local header="timestamp"
    for drv in "${ENCLOSURE_DRIVES[@]}"; do
        header+=",$(basename "$drv")"
    done
    echo "$header" > "$temp_logfile"

    # Capture initial error counts for delta tracking
    declare -A baseline_reallocated
    declare -A baseline_pending
    declare -A baseline_crc
    for drv in "${ENCLOSURE_DRIVES[@]}"; do
        local devname
        devname=$(basename "$drv")
        baseline_reallocated[$devname]=$(smartctl -A "$drv" 2>/dev/null | \
            awk '/Reallocated_Sector_Ct/ {print $10}' || echo "0")
        baseline_pending[$devname]=$(smartctl -A "$drv" 2>/dev/null | \
            awk '/Current_Pending_Sector/ {print $10}' || echo "0")
        baseline_crc[$devname]=$(smartctl -A "$drv" 2>/dev/null | \
            awk '/UDMA_CRC_Error_Count/ {print $10}' || echo "0")
    done

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        local temp_row="$ts"

        for drv in "${ENCLOSURE_DRIVES[@]}"; do
            local devname
            devname=$(basename "$drv")

            # Temperature
            local temp
            temp=$(smartctl -A "$drv" 2>/dev/null | \
                awk '/Temperature_Celsius/ {print $10}' || true)
            if [[ -z "$temp" ]]; then
                temp=$(smartctl -A "$drv" 2>/dev/null | \
                    awk '/Airflow_Temperature_Cel/ {print $10}' || true)
            fi
            temp_row+=",${temp:-N/A}"

            if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
                if [[ $temp -ge $TEMP_WARN_C ]]; then
                    log_anomaly "HIGH_TEMP: $devname temperature=${temp}°C (threshold: ${TEMP_WARN_C}°C)"
                fi
            fi

            # Power state (hdparm)
            local power_state
            power_state=$(hdparm -C "$drv" 2>/dev/null | grep "drive state" | \
                awk '{print $NF}' || echo "unknown")
            echo "[$ts] $devname power_state=$power_state" >> "$power_logfile"

            # Note: We know some bridges misreport power state, but still log it for completeness
            if [[ "$power_state" == "standby" ]]; then
                # Check if this is real standby or a false report
                echo "[$ts] $devname reports standby (may be false positive)" >> "$power_logfile"
            fi

            # SMART error counter deltas
            local current_reallocated current_pending current_crc
            current_reallocated=$(smartctl -A "$drv" 2>/dev/null | \
                awk '/Reallocated_Sector_Ct/ {print $10}' || echo "0")
            current_pending=$(smartctl -A "$drv" 2>/dev/null | \
                awk '/Current_Pending_Sector/ {print $10}' || echo "0")
            current_crc=$(smartctl -A "$drv" 2>/dev/null | \
                awk '/UDMA_CRC_Error_Count/ {print $10}' || echo "0")

            if [[ "${current_reallocated:-0}" != "${baseline_reallocated[$devname]:-0}" ]]; then
                log_event "CRITICAL" "SMART: $devname Reallocated_Sector_Ct changed: ${baseline_reallocated[$devname]} → $current_reallocated"
            fi
            if [[ "${current_pending:-0}" != "${baseline_pending[$devname]:-0}" ]]; then
                log_event "ERROR" "SMART: $devname Current_Pending_Sector changed: ${baseline_pending[$devname]} → $current_pending"
            fi
            if [[ "${current_crc:-0}" != "${baseline_crc[$devname]:-0}" ]]; then
                log_event "WARNING" "SMART: $devname UDMA_CRC_Error_Count changed: ${baseline_crc[$devname]} → $current_crc (indicates USB/SATA link errors)"
            fi

            # Full periodic SMART dump
            echo "" >> "$logfile"
            echo "=== [$ts] $drv ===" >> "$logfile"
            smartctl -A "$drv" >> "$logfile" 2>&1 || true
        done

        echo "$temp_row" >> "$temp_logfile"
        sleep "$POLL_INTERVAL_SMART"
    done
}

monitor_smart &
CHILD_PIDS+=($!)
log "Monitor started: SMART + temperature + power (PID $!, interval: ${POLL_INTERVAL_SMART}s)"

# ── Monitor 6: USB topology changes ──────────────────────────────────────────
monitor_usb_topology() {
    local logfile="${RUN_DIR}/continuous/usb_topology_snapshots.log"
    local prev_snapshot=""

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        local current_snapshot
        current_snapshot=$(lsusb 2>/dev/null || true)

        echo "=== [$ts] ===" >> "$logfile"
        echo "$current_snapshot" >> "$logfile"
        lsusb -t >> "$logfile" 2>/dev/null || true
        echo "" >> "$logfile"

        # Detect changes
        if [[ -n "$prev_snapshot" && "$current_snapshot" != "$prev_snapshot" ]]; then
            log_event "CRITICAL" "USB_TOPOLOGY_CHANGE: USB device list changed!"

            # Show the diff
            local diff_output
            diff_output=$(diff <(echo "$prev_snapshot") <(echo "$current_snapshot") || true)
            echo "=== TOPOLOGY DIFF at $ts ===" >> "$logfile"
            echo "$diff_output" >> "$logfile"
            log "USB topology diff: $diff_output"
        fi

        prev_snapshot="$current_snapshot"
        sleep "$POLL_INTERVAL_USB"
    done
}

monitor_usb_topology &
CHILD_PIDS+=($!)
log "Monitor started: USB topology watcher (PID $!, interval: ${POLL_INTERVAL_USB}s)"

# ── Monitor 7: Mount status (detect read-only remount) ────────────────────────
monitor_mounts() {
    local logfile="${RUN_DIR}/continuous/mount_status.log"
    local prev_mount_state=""

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        local current_mount_state
        current_mount_state=$(findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | \
            grep -E "ext4|xfs|btrfs" || true)

        echo "=== [$ts] ===" >> "$logfile"
        echo "$current_mount_state" >> "$logfile"
        echo "" >> "$logfile"

        # Check for read-only remounts
        if echo "$current_mount_state" | grep -q ",ro,\|,ro$"; then
            log_event "CRITICAL" "READ_ONLY_MOUNT: Filesystem remounted read-only!"
            echo "[$ts] READ-ONLY DETECTED:" >> "$logfile"
            echo "$current_mount_state" | grep ",ro" >> "$logfile"
        fi

        # Check for mount changes
        if [[ -n "$prev_mount_state" && "$current_mount_state" != "$prev_mount_state" ]]; then
            log_event "WARNING" "MOUNT_CHANGE: Filesystem mount state changed"
            local diff_output
            diff_output=$(diff <(echo "$prev_mount_state") <(echo "$current_mount_state") || true)
            echo "=== MOUNT DIFF at $ts ===" >> "$logfile"
            echo "$diff_output" >> "$logfile"
        fi

        prev_mount_state="$current_mount_state"
        sleep "$POLL_INTERVAL_MOUNT"
    done
}

monitor_mounts &
CHILD_PIDS+=($!)
log "Monitor started: mount status watcher (PID $!, interval: ${POLL_INTERVAL_MOUNT}s)"

# ── Monitor 8: Docker container health ────────────────────────────────────────
if $HAS_DOCKER; then
    monitor_docker() {
        local logfile="${RUN_DIR}/docker/docker_health.log"
        local restart_logfile="${RUN_DIR}/docker/docker_restarts.log"
        local prev_state=""

        # Capture initial restart counts
        declare -A baseline_restarts
        while read -r cname; do
            [[ -z "$cname" ]] && continue
            baseline_restarts[$cname]=$(docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "0")
        done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)

        while still_running; do
            local ts
            ts=$(date -Iseconds)
            local current_state
            current_state=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null || echo "DOCKER_UNREACHABLE")

            echo "=== [$ts] ===" >> "$logfile"
            echo "$current_state" >> "$logfile"
            echo "" >> "$logfile"

            if [[ "$current_state" == "DOCKER_UNREACHABLE" ]]; then
                log_event "ERROR" "DOCKER: Docker daemon unreachable"
            fi

            # Track restart counts (catches container restarts)
            echo "=== [$ts] ===" >> "$restart_logfile"
            while read -r cname; do
                [[ -z "$cname" ]] && continue
                local rc started finished
                rc=$(docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "N/A")
                started=$(docker inspect --format '{{.State.StartedAt}}' "$cname" 2>/dev/null || echo "N/A")
                finished=$(docker inspect --format '{{.State.FinishedAt}}' "$cname" 2>/dev/null || echo "N/A")
                echo "  $cname: restarts=$rc started=$started finished=$finished" >> "$restart_logfile"

                if [[ "$rc" != "N/A" && "$rc" != "${baseline_restarts[$cname]:-0}" ]]; then
                    log_event "WARNING" "DOCKER: $cname restart count changed: ${baseline_restarts[$cname]:-0} → $rc"
                    baseline_restarts[$cname]=$rc
                fi
            done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
            echo "" >> "$restart_logfile"

            # Detect container state changes
            if [[ -n "$prev_state" && "$current_state" != "$prev_state" ]]; then
                local diff_output
                diff_output=$(diff <(echo "$prev_state") <(echo "$current_state") || true)
                if echo "$diff_output" | grep -qiE "Exited|Dead|unhealthy"; then
                    log_event "WARNING" "DOCKER: Container state change detected (possible crash)"
                    echo "=== DOCKER DIFF at $ts ===" >> "$logfile"
                    echo "$diff_output" >> "$logfile"
                fi
            fi

            prev_state="$current_state"
            sleep "$POLL_INTERVAL_DOCKER"
        done
    }

    monitor_docker &
    CHILD_PIDS+=($!)
    log "Monitor started: Docker health + restart tracking (PID $!, interval: ${POLL_INTERVAL_DOCKER}s)"
fi

# ── Monitor 9: System resources ───────────────────────────────────────────────
monitor_system() {
    local logfile="${RUN_DIR}/system/system_resources.log"
    local thermal_logfile="${RUN_DIR}/system/system_thermals.log"

    while still_running; do
        local ts
        ts=$(date -Iseconds)

        {
            echo "=== [$ts] ==="
            echo "--- uptime ---"
            uptime
            echo "--- free ---"
            free -h
            echo "--- load ---"
            cat /proc/loadavg
            echo "--- vmstat ---"
            vmstat 1 2 | tail -1
            echo ""
        } >> "$logfile"

        if $HAS_SENSORS; then
            echo "=== [$ts] ===" >> "$thermal_logfile"
            sensors >> "$thermal_logfile" 2>/dev/null || true
            echo "" >> "$thermal_logfile"
        fi

        sleep "$POLL_INTERVAL_SYSTEM"
    done
}

monitor_system &
CHILD_PIDS+=($!)
log "Monitor started: system resources (PID $!, interval: ${POLL_INTERVAL_SYSTEM}s)"

# ── Monitor 10: USB error counter from sysfs ─────────────────────────────────
monitor_usb_errors() {
    local logfile="${RUN_DIR}/continuous/usb_error_counters.log"

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        echo "=== [$ts] ===" >> "$logfile"

        # Check xHCI event ring and error counters
        for host in /sys/bus/usb/devices/usb*; do
            [[ -d "$host" ]] || continue
            local hostnum
            hostnum=$(basename "$host")

            # URB counts (if available)
            if [[ -f "$host/urbnum" ]]; then
                echo "  $host/urbnum = $(cat "$host/urbnum" 2>/dev/null)" >> "$logfile"
            fi
        done

        # xHCI debug info (if available)
        for f in /sys/kernel/debug/usb/xhci/*/command-ring-trbs; do
            [[ -f "$f" ]] && {
                echo "  $f:" >> "$logfile"
                head -5 "$f" >> "$logfile" 2>/dev/null || true
            }
        done

        echo "" >> "$logfile"
        sleep "$POLL_INTERVAL_USB"
    done
}

monitor_usb_errors &
CHILD_PIDS+=($!)
log "Monitor started: USB error counters (PID $!, interval: ${POLL_INTERVAL_USB}s)"

# ── Monitor 11: Periodic raw dmesg dumps (prevent ring buffer loss) ───────────
# The kernel ring buffer is finite (~256KB). If the failure happens and then
# normal messages keep flowing, early failure context could be overwritten.
# Periodic dumps ensure we never lose kernel messages.
monitor_dmesg_dumps() {
    local dump_num=0

    while still_running; do
        dump_num=$((dump_num + 1))
        dmesg --time-format=iso > "${RUN_DIR}/dmesg/dmesg_dump_$(printf '%04d' $dump_num).log" 2>&1 || true
        sleep "$POLL_INTERVAL_DMESG"
    done

    # Final dump
    dump_num=$((dump_num + 1))
    dmesg --time-format=iso > "${RUN_DIR}/dmesg/dmesg_dump_$(printf '%04d' $dump_num)_FINAL.log" 2>&1 || true
}

monitor_dmesg_dumps &
CHILD_PIDS+=($!)
log "Monitor started: periodic dmesg dumps (PID $!, interval: ${POLL_INTERVAL_DMESG}s)"

# ── Monitor 12: Process I/O tracking ──────────────────────────────────────────
# Identifies WHICH process is accessing enclosure drives. Critical for
# determining whether a workload, cron, fstrim, etc. triggers the failure.
monitor_process_io() {
    local logfile="${RUN_DIR}/io/process_io.log"
    local diskstats_log="${RUN_DIR}/io/diskstats_periodic.log"

    while still_running; do
        local ts
        ts=$(date -Iseconds)

        # Raw diskstats for precise I/O counters per device
        echo "=== [$ts] ===" >> "$diskstats_log"
        cat /proc/diskstats 2>/dev/null >> "$diskstats_log"
        echo "" >> "$diskstats_log"

        # Check which processes have enclosure drives open
        echo "=== [$ts] ===" >> "$logfile"
        for drv in "${ENCLOSURE_DRIVES[@]}"; do
            local devname
            devname=$(basename "$drv")

            # Find mount points for partitions on this drive
            local partitions
            partitions=$(lsblk -nro NAME,MOUNTPOINT "$drv" 2>/dev/null | awk '$2 != "" {print $2}' || true)

            if [[ -n "$partitions" ]]; then
                for mnt in $partitions; do
                    # Count open files on this mount
                    local open_count
                    open_count=$( { timeout 5 fuser -m "$mnt" 2>/dev/null || true; } | wc -w )
                    if [[ "$open_count" -gt 0 ]]; then
                        echo "  $devname ($mnt): $open_count processes" >> "$logfile"
                        # List top processes by name
                        timeout 5 fuser -vm "$mnt" 2>&1 | head -10 >> "$logfile" || true
                    fi
                done
            fi
        done
        echo "" >> "$logfile"

        sleep "$POLL_INTERVAL_PROC_IO"
    done
}

monitor_process_io &
CHILD_PIDS+=($!)
log "Monitor started: process I/O tracking (PID $!, interval: ${POLL_INTERVAL_PROC_IO}s)"

# ── Monitor 13: SCSI error counters from sysfs ───────────────────────────────
# These counters track errors at the SCSI transport layer — closer to the
# actual failure point than kernel log messages.
monitor_scsi_errors() {
    local logfile="${RUN_DIR}/continuous/scsi_error_counters.log"

    # Capture baseline values
    declare -A baseline_ioerr
    for drv in "${ENCLOSURE_DRIVES[@]}"; do
        local devname
        devname=$(basename "$drv")
        baseline_ioerr[$devname]=$(cat /sys/block/$devname/device/ioerr_cnt 2>/dev/null || echo "0")
    done

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        echo "=== [$ts] ===" >> "$logfile"

        for drv in "${ENCLOSURE_DRIVES[@]}"; do
            local devname
            devname=$(basename "$drv")

            local ioerr iodone iorequest dev_timeout
            ioerr=$(cat /sys/block/$devname/device/ioerr_cnt 2>/dev/null || echo "N/A")
            iodone=$(cat /sys/block/$devname/device/iodone_cnt 2>/dev/null || echo "N/A")
            iorequest=$(cat /sys/block/$devname/device/iorequest_cnt 2>/dev/null || echo "N/A")
            dev_timeout=$(cat /sys/block/$devname/device/timeout 2>/dev/null || echo "N/A")

            echo "  $devname: ioerr=$ioerr iodone=$iodone iorequest=$iorequest timeout=${dev_timeout}s" >> "$logfile"

            # Alert on new SCSI errors
            if [[ "$ioerr" != "N/A" && "$ioerr" != "${baseline_ioerr[$devname]:-0}" ]]; then
                log_event "ERROR" "SCSI_ERROR: $devname ioerr_cnt changed: ${baseline_ioerr[$devname]:-0} → $ioerr"
                baseline_ioerr[$devname]=$ioerr
            fi
        done

        echo "" >> "$logfile"
        sleep "$POLL_INTERVAL_SCSI"
    done
}

monitor_scsi_errors &
CHILD_PIDS+=($!)
log "Monitor started: SCSI error counters (PID $!, interval: ${POLL_INTERVAL_SCSI}s)"

# ── Monitor 14: PSI (Pressure Stall Information) — I/O pressure ───────────────
# This is the single best early-warning indicator. When storage starts hanging,
# PSI io avg10 spikes to 90%+ BEFORE the USB bridge fully disconnects.
# This tells us processes are piling up waiting for I/O.
monitor_psi() {
    local logfile="${RUN_DIR}/continuous/psi_io.log"

    # Check if PSI is available
    if [[ ! -f /proc/pressure/io ]]; then
        log_event "WARNING" "PSI: /proc/pressure/io not available (kernel may need CONFIG_PSI=y)"
        return
    fi

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        local psi_io
        psi_io=$(cat /proc/pressure/io 2>/dev/null || true)

        echo "[$ts] $psi_io" >> "$logfile"

        # Parse avg10 from the 'some' line and alert on pressure
        local some_avg10
        some_avg10=$(echo "$psi_io" | awk '/^some/ {for(i=1;i<=NF;i++) if($i ~ /avg10=/) {split($i,a,"="); printf "%.0f", a[2]}}' || echo "0")
        local full_avg10
        full_avg10=$(echo "$psi_io" | awk '/^full/ {for(i=1;i<=NF;i++) if($i ~ /avg10=/) {split($i,a,"="); printf "%.0f", a[2]}}' || echo "0")

        if [[ -n "$some_avg10" && "$some_avg10" -gt "$PSI_IO_WARN_THRESHOLD" ]]; then
            log_anomaly "PSI_IO_PRESSURE: some avg10=${some_avg10}% full avg10=${full_avg10}% (threshold: ${PSI_IO_WARN_THRESHOLD}%)"
        fi
        if [[ -n "$full_avg10" && "$full_avg10" -gt 50 ]]; then
            log_event "CRITICAL" "PSI_IO_STALL: full avg10=${full_avg10}% — severe I/O stall, storage subsystem likely failing"
        fi

        sleep "$POLL_INTERVAL_PSI"
    done
}

monitor_psi &
CHILD_PIDS+=($!)
log "Monitor started: PSI I/O pressure (PID $!, interval: ${POLL_INTERVAL_PSI}s)"

# ── Monitor 15: D-state (uninterruptible sleep) process tracking ──────────────
# Processes entering D state often precede total storage collapse.
# Continuous tracking catches the BUILDUP before the crash.
monitor_dstate() {
    local logfile="${RUN_DIR}/continuous/dstate_processes.log"

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        local dstate_procs
        dstate_procs=$(ps -eo state,pid,comm,wchan:32 2>/dev/null | awk '$1 == "D" {print}' || true)

        if [[ -n "$dstate_procs" ]]; then
            echo "=== [$ts] ===" >> "$logfile"
            echo "$dstate_procs" >> "$logfile"
            echo "" >> "$logfile"

            # Count D-state processes
            local dcount
            dcount=$(echo "$dstate_procs" | wc -l)
            if [[ $dcount -ge 5 ]]; then
                log_event "WARNING" "DSTATE: $dcount processes in D state (uninterruptible sleep) — I/O likely stalling"
            elif [[ $dcount -ge 10 ]]; then
                log_event "CRITICAL" "DSTATE: $dcount processes in D state — storage subsystem likely failing"
            fi
        fi

        sleep "$POLL_INTERVAL_DSTATE"
    done
}

monitor_dstate &
CHILD_PIDS+=($!)
log "Monitor started: D-state process tracking (PID $!, interval: ${POLL_INTERVAL_DSTATE}s)"

# ── Monitor 16: ext4 filesystem error counters ────────────────────────────────
# Distinguishes whether ext4 is accumulating corruption independently or merely
# reacting to disappearing storage.
monitor_ext4_errors() {
    local logfile="${RUN_DIR}/continuous/ext4_error_counters.log"

    # Capture baseline error counts
    declare -A baseline_ext4_errors
    for errdir in /sys/fs/ext4/*/; do
        [[ -d "$errdir" ]] || continue
        local devname
        devname=$(basename "$errdir")
        baseline_ext4_errors[$devname]=$(cat "$errdir/errors_count" 2>/dev/null || echo "0")
    done

    while still_running; do
        local ts
        ts=$(date -Iseconds)
        echo "=== [$ts] ===" >> "$logfile"

        for errdir in /sys/fs/ext4/*/; do
            [[ -d "$errdir" ]] || continue
            local devname
            devname=$(basename "$errdir")
            local err_count
            err_count=$(cat "$errdir/errors_count" 2>/dev/null || echo "N/A")
            echo "  $devname: errors_count=$err_count" >> "$logfile"

            if [[ "$err_count" != "N/A" && "$err_count" != "${baseline_ext4_errors[$devname]:-0}" ]]; then
                local first_err last_err
                first_err=$(cat "$errdir/first_error_func" 2>/dev/null || echo "unknown")
                last_err=$(cat "$errdir/last_error_func" 2>/dev/null || echo "unknown")
                log_event "CRITICAL" "EXT4_ERROR: $devname errors_count changed: ${baseline_ext4_errors[$devname]:-0} → $err_count (first=$first_err last=$last_err)"
                baseline_ext4_errors[$devname]=$err_count
            fi
        done

        echo "" >> "$logfile"
        sleep "$POLL_INTERVAL_EXT4"
    done
}

monitor_ext4_errors &
CHILD_PIDS+=($!)
log "Monitor started: ext4 error counters (PID $!, interval: ${POLL_INTERVAL_EXT4}s)"

###############################################################################
#  PHASE 2.5: STATUS DISPLAY
###############################################################################

echo ""
echo -e "${GRN}════════════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  All monitors running. Monitoring until $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')${RST}"
echo -e "${GRN}  Output directory: ${RUN_DIR}${RST}"
echo -e "${GRN}  Press Ctrl+C to stop early and generate summary report${RST}"
echo -e "${GRN}════════════════════════════════════════════════════════════════${RST}"
echo ""

log "All ${#CHILD_PIDS[@]} monitors active"

###############################################################################
#  PHASE 3: WAIT
###############################################################################

# Periodic status heartbeat
elapsed_ticks=0
while still_running; do
    # Sleep in small increments so we don't overshoot the end time
    sleep 60 &
    HEARTBEAT_PID=$!

    if wait $HEARTBEAT_PID 2>/dev/null; then
        elapsed_ticks=$((elapsed_ticks + 60))
        # Every 30 minutes, log a heartbeat
        if [[ $elapsed_ticks -ge 1800 ]]; then
            elapsed_ticks=0
            if still_running; then
                elapsed=$(($(date +%s) - START_TIME))
                remaining=$((END_TIME - $(date +%s)))
                log "HEARTBEAT: Running for $((elapsed/3600))h$((elapsed%3600/60))m, $((remaining/3600))h$((remaining%3600/60))m remaining. Active monitors: ${#CHILD_PIDS[@]}"

                # Re-discover drives in case of reconnection
                current_drives=()
                IFS=' ' read -ra current_drives <<< "$(discover_enclosure_drives)"
                if [[ ${#current_drives[@]} -ne ${#ENCLOSURE_DRIVES[@]} ]]; then
                    log_event "WARNING" "HEARTBEAT: Drive count changed! Was ${#ENCLOSURE_DRIVES[@]}, now ${#current_drives[@]}"
                fi

                # Check if any monitor processes died
                for i in "${!CHILD_PIDS[@]}"; do
                    if ! kill -0 "${CHILD_PIDS[$i]}" 2>/dev/null; then
                        log_event "WARNING" "HEARTBEAT: Monitor PID ${CHILD_PIDS[$i]} is no longer running"
                    fi
                done
            fi
        fi
    fi
done

###############################################################################
