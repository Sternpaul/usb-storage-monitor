#!/usr/bin/env bash
###############################################################################
#  USB Storage Monitor — Setup & Preflight Check
#  ───────────────────────────────────────────────
#  Run this first to install dependencies and validate the environment.
#  Usage: sudo ./setup.sh
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'

echo -e "${CYN}═══════════════════════════════════════════════════════${RST}"
echo -e "${CYN}  USB Storage Monitor — Setup & Preflight Check${RST}"
echo -e "${CYN}═══════════════════════════════════════════════════════${RST}"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}ERROR: Run as root: sudo ./setup.sh${RST}"
    exit 1
fi

# ── Install dependencies ─────────────────────────────────────────────────────
echo -e "${CYN}[1/5] Installing dependencies...${RST}"
apt-get update -qq
apt-get install -y -qq smartmontools hdparm sysstat usbutils udev util-linux lm-sensors 2>/dev/null
echo -e "${GRN}  ✓ Packages installed${RST}"

# ── Validate tools ───────────────────────────────────────────────────────────
echo ""
echo -e "${CYN}[2/5] Validating tools...${RST}"
TOOLS=(smartctl hdparm iostat lsusb udevadm journalctl blkid findmnt)
ALL_OK=true
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        echo -e "  ${GRN}✓${RST} $tool ($(command -v "$tool"))"
    else
        echo -e "  ${RED}✗${RST} $tool — MISSING"
        ALL_OK=false
    fi
done

# Optional tools
echo ""
echo "  Optional:"
if command -v docker &>/dev/null; then
    echo -e "  ${GRN}✓${RST} docker"
else
    echo -e "  ${YEL}○${RST} docker (not installed, Docker monitoring will be skipped)"
fi
if command -v sensors &>/dev/null; then
    echo -e "  ${GRN}✓${RST} sensors (lm-sensors)"
else
    echo -e "  ${YEL}○${RST} sensors (not installed, system thermal monitoring will be limited)"
fi

if ! $ALL_OK; then
    echo -e "\n${RED}ERROR: Required tools missing. Install them and re-run.${RST}"
    exit 1
fi

# ── USB enclosure detection ──────────────────────────────────────────────────
echo ""
echo -e "${CYN}[3/5] Detecting USB enclosure (USB bridge, 152d:0567)...${RST}"
USB_LINE=$(lsusb 2>/dev/null | grep "152d:0567" || true)
if [[ -n "$USB_LINE" ]]; then
    echo -e "  ${GRN}✓${RST} Found: $USB_LINE"

    # Show USB tree path
    echo ""
    echo "  USB topology:"
    lsusb -t 2>/dev/null | head -20 | sed 's/^/    /'
else
    echo -e "  ${RED}✗${RST} Target USB bridge not detected!"
    echo -e "  ${YEL}  Check that the multi-bay enclosure is connected and powered on.${RST}"
fi

# ── Drive detection ──────────────────────────────────────────────────────────
echo ""
echo -e "${CYN}[4/5] Detecting enclosure drives...${RST}"

DRIVE_COUNT=0
for dev in /dev/sd?; do
    [[ -b "$dev" ]] || continue
    udev_info=$(udevadm info --query=all --name="$dev" 2>/dev/null || true)
    if echo "$udev_info" | grep -qi "152d"; then
        DRIVE_COUNT=$((DRIVE_COUNT + 1))
        devname=$(basename "$dev")
        model=$(smartctl -i "$dev" 2>/dev/null | awk -F: '/Device Model|Model Number/ {gsub(/^[ \t]+/, "", $2); print $2}' | head -1 || echo "unknown")
        serial=$(smartctl -i "$dev" 2>/dev/null | awk -F: '/Serial Number/ {gsub(/^[ \t]+/, "", $2); print $2}' | head -1 || echo "unknown")
        capacity=$(smartctl -i "$dev" 2>/dev/null | awk -F'[\\[\\]]' '/User Capacity/ {print $2}' | head -1 || echo "unknown")
        power=$(hdparm -C "$dev" 2>/dev/null | awk '/drive state/ {print $NF}' || echo "unknown")
        temp=$(smartctl -A "$dev" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature/ {print $10"°C"}' | head -1 || echo "N/A")

        echo -e "  ${GRN}✓${RST} $dev"
        echo "      Model:    $model"
        echo "      Serial:   $serial"
        echo "      Capacity: $capacity"
        echo "      Temp:     $temp"
        echo "      Power:    $power (bridge may misreport)"
        echo ""
    fi
done

if [[ $DRIVE_COUNT -eq 0 ]]; then
    echo -e "  ${RED}✗${RST} No enclosure drives found!"
    echo -e "  ${YEL}  Trying broader detection...${RST}"
    lsblk -o NAME,SIZE,MODEL,TRAN | grep -i usb | sed 's/^/    /' || echo "    (no USB block devices found)"
else
    echo -e "  ${GRN}Found $DRIVE_COUNT drive(s) behind USB bridge.${RST}"
fi

# ── Standby check ────────────────────────────────────────────────────────────
echo ""
echo -e "${CYN}[5/5] Checking drive standby settings...${RST}"
for dev in /dev/sd?; do
    [[ -b "$dev" ]] || continue
    udev_info=$(udevadm info --query=all --name="$dev" 2>/dev/null || true)
    if echo "$udev_info" | grep -qi "152d"; then
        devname=$(basename "$dev")
        standby_val=$(hdparm -I "$dev" 2>/dev/null | grep -i "standby timer" || echo "  (not available)")
        apm_val=$(hdparm -I "$dev" 2>/dev/null | grep -i "Advanced power" || echo "  (not available)")
        echo "  $dev:"
        echo "    Standby timer: $standby_val"
        echo "    APM: $apm_val"

        # Verify hdparm -S 0 is active
        spindown=$(hdparm -I "$dev" 2>/dev/null | awk '/Standby timer values/ {found=1} found && /are:/ {print $NF}' || true)
        echo ""
    fi
done

# ── Make monitor script executable ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/usb_storage_monitor.sh" ]]; then
    chmod +x "$SCRIPT_DIR/usb_storage_monitor.sh"
    echo ""
    echo -e "${GRN}✓ Monitor script is ready: $SCRIPT_DIR/usb_storage_monitor.sh${RST}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}═══════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  Setup complete!${RST}"
echo -e "${GRN}═══════════════════════════════════════════════════════${RST}"
echo ""
echo "  To start monitoring, run:"
echo ""
echo "    sudo ./usb_storage_monitor.sh"
echo ""
echo "  Options:"
echo "    --duration HOURS   Monitoring duration (default: 12)"
echo "    --output DIR       Output directory (default: /var/log/usb-monitor)"
echo ""
echo "  Example for overnight monitoring:"
echo "    sudo nohup ./usb_storage_monitor.sh --duration 14 > /dev/null 2>&1 &"
echo ""
echo "  Or use screen/tmux:"
echo "    screen -S usb-monitor"
echo "    sudo ./usb_storage_monitor.sh --duration 14"
echo "    # Press Ctrl+A, D to detach"
echo ""
