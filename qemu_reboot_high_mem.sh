#!/usr/bin/env bash
set -euo pipefail

# ============================
# ARGUMENTS
# ============================

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <VMID> <THRESHOLD_PERCENT>"
    exit 1
fi

VMID="$1"
THRESHOLD="$2"

# Optional: number of consecutive samples & interval
SAMPLES=3
INTERVAL=60

NODE="$(hostname)"
counter=0

# ============================
# FUNCTIONS
# ============================

get_mem_usage() {
    # Parse the pvesh table output safely
    pvesh get /nodes/${NODE}/qemu/${VMID}/status/current \
    | awk -F'│' '
        / mem /     { gsub(/[^0-9.]/,"",$3); mem=$3 }
        / maxmem /  { gsub(/[^0-9.]/,"",$3); max=$3 }
        END { if (max > 0) print (mem / max * 100); else print 0 }
    '
}

reboot_vm() {
    echo "$(date -Is) :: Rebooting VM ${VMID} due to sustained high memory usage"
    qm reboot "${VMID}"
}

# ============================
# MAIN LOOP
# ============================

while true; do
    mem=$(get_mem_usage)
    mem_int=${mem%.*}

    echo "$(date -Is) :: VM ${VMID} memory: ${mem_int}% (threshold: ${THRESHOLD}%)"

    if (( mem_int > THRESHOLD )); then
        ((counter++))
        echo "$(date -Is) :: Above threshold (${counter}/${SAMPLES})"
    else
        counter=0
    fi

    if (( counter >= SAMPLES )); then
        reboot_vm
        counter=0
    fi

    sleep "${INTERVAL}"
done
