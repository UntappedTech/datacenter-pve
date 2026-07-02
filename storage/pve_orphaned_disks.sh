#!/usr/bin/env bash
# ==============================================================================
# PROXMOX ORPHANED DISK PURGE & AUDIT TOOL
# ==============================================================================
set -euo pipefail

echo ">>> Scanning Proxmox cluster configurations for active VMID definitions..."
declare -A ASSIGNED_VMIDS

# Map all active VMs and LXCs in the cluster
for vmid in $(pvesh get /cluster/resources --type vm | jq -r '.[].vmid'); do
    ASSIGNED_VMIDS["$vmid"]=1
done

echo ">>> Analyzing storage allocations..."
# Loop through all activated storage engines
for storage in $(pvesm status | awk 'NR>1 {print $1}'); do
    # Skip shared storage pools if necessary, or check standard disk types
    echo "Evaluating pool: [$storage]"
    
    # List volume allocations
    pvesm list "$storage" 2>/dev/null | awk 'NR>1 {print $1}' | while read -r volume; do
        # Extract the VMID from common volume naming schemes (e.g., storage:vm-100-disk-0)
        if [[ "$volume" =~ vm-([0-9]+)- ]]; then
            vmid="${BASH_REMATCH[1]}"
            if [[ -z "${ASSIGNED_VMIDS[$vmid]:-}" ]]; then
                echo -e "\033[0;31m[ORPHAN DETECTED]\033[0m Storage volume '$volume' belongs to nonexistent VMID $vmid"
                echo "To remove manually: pvesm free $volume"
            fi
        fi
    done
done
