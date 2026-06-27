#!/bin/bash
# ==============================================================================
# LEAN PROXMOX LXC LIFE-CYCLE ENGINE - RECLAIM & MAINTENANCE ORCHESTRATOR
# ==============================================================================

set -euo pipefail

# Configuration Parameters & Environment Arrays
MIN_STORAGE_FREE_MB=10240  # 10 GB
DEBIAN_MAP_FILE="/tmp/debian_distro_map.csv"

declare -A CT_OS CT_VER CT_CODE CT_TARGET_VER CT_TARGET_CODE CT_ACTION

# --- ARCHITECTURAL SAFETY TERMINATION TRAP ---
trap 'echo ">>> Releasing local tracking resources..."; rm -f "$DEBIAN_MAP_FILE"' EXIT

# Text Styling Hooks
BL="\033[0;34m"
GN="\033[0;32m"
YW="\033[0;33m"
RD="\033[0;31m"
CL="\033[0;0m"

# ==============================================================================
# SECTION 1: RUNTIME MIRROR ENDPOINT RESOLUTIONS
# ==============================================================================

fetch_latest_upstream_versions() {
    echo ">>> Contacting public mirrors for distribution metrics..."
    
    # 1. Debian lookup map fetch and production filtering
    if curl -s -o "$DEBIAN_MAP_FILE" https://debian.pages.debian.net/distro-info-data/debian.csv && [ -s "$DEBIAN_MAP_FILE" ]; then
        # The '|| true' ensures that even if an intermediate line check yields no matches, set -e won't halt execution
        LATEST_DEBIAN_STABLE=$(awk -F, '$1 ~ /^[0-9]+$/ && $5 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $1}' "$DEBIAN_MAP_FILE" 2>/dev/null | sort -n | tail -n 1 || echo "")
    else
        echo -e "${YW}[Warning] Debian upstream mirror unreachable. Injecting safety fallback.${CL}"
        LATEST_DEBIAN_STABLE="13"
    fi
    [ -z "$LATEST_DEBIAN_STABLE" ] && LATEST_DEBIAN_STABLE="13"

    # 2. Alpine YAML release query lookup
    local alpine_raw
    alpine_raw=$(curl -s https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml 2>/dev/null | awk '/version:/ {print $2; exit}' | tr -d '"' || echo "")
    if [ -n "$alpine_raw" ]; then
        LATEST_ALPINE_STABLE="$alpine_raw"
    else
        echo -e "${YW}[Warning] Alpine upstream mirror unreachable. Injecting safety fallback.${CL}"
        LATEST_ALPINE_STABLE="3.24.1"
    fi

    # 3. Fedora stream JSON query lookup
    local fedora_release_str
    fedora_release_str=$(curl -s https://builds.coreos.fedoraproject.org/streams/stable.json 2>/dev/null | grep '"release":' | head -n 1 | awk -F'"' '{print $4}' || echo "")
    if [ -n "$fedora_release_str" ]; then
        LATEST_FEDORA_STABLE=$(echo "$fedora_release_str" | cut -d. -f1)
    else
        echo -e "${YW}[Warning] Fedora upstream mirror unreachable. Injecting safety fallback.${CL}"
        LATEST_FEDORA_STABLE="44"
    fi
}

resolve_debian_codename() {
    local target_numeric_version="$1"
    awk -F, -v ver="$target_numeric_version" '$1 == ver {print $3}' "$DEBIAN_MAP_FILE" | tr -d ' ' || echo ""
}

# ==============================================================================
# SECTION 2: HEALTH, CAPACITY, & RECLAIM OPTIMIZATION UTILITIES
# ==============================================================================

assert_storage_health() {
    local ctid="$1"
    local storage_pool
    storage_pool=$(pvesm parse-path "$(pct config "$ctid" | awk '/rootfs:/ {print $2}' | cut -d, -f1)" 2>/dev/null | awk '/"storage":/ {print $2}' | tr -d '",')
    [ -z "$storage_pool" ] && storage_pool=$(pct config "$ctid" | awk '/rootfs:/ {print $2}' | cut -d: -f1)

    local free_kb
    free_kb=$(pvesm status -storage "$storage_pool" | awk 'NR==2 {print $4}')
    local free_mb=$((free_kb / 1024))
    
    if [ "$free_mb" -lt "$MIN_STORAGE_FREE_MB" ]; then
        echo -e "${RD}!!! [$ctid] STORAGE FAULT: Pool '$storage_pool' only has ${free_mb}MB free (Required: ${MIN_STORAGE_FREE_MB}MB).${CL}"
        return 1
    fi
    return 0
}

lxc_quick_clean() {
    local ctid="$1"
    local name; name=$(pct exec "$ctid" hostname)
    local os_type; os_type="${CT_OS[$ctid]}"

    echo -e "${BL}[Info]${GN} Reclaiming package cache and thinning allocations in ${name} (${os_type})${CL}"
    
    case "$os_type" in
        alpine)
            pct exec "$ctid" -- ash -c "apk cache clean"
            ;;
        fedora)
            pct exec "$ctid" -- bash -c "dnf clean all -y"
            ;;
        debian)
            pct exec "$ctid" -- bash -c "apt-get -qq autoclean && apt-get autopurge -y && rm -rf /var/lib/apt/lists/*"
            ;;
    esac

    local raw_rootfs
    raw_rootfs=$(pct config "$ctid" | awk -F ':' '/^rootfs/ {print $2}' | xargs)
    local active_pool
    active_pool=$(pvesm parse-path "$raw_rootfs" 2>/dev/null | awk '/"storage":/ {print $2}' | tr -d '",')
    [ -z "$active_pool" ] && active_pool=$(echo "$raw_rootfs" | cut -d: -f1)

    if pvesm status -storage "$active_pool" | grep -q 'lvmthin'; then
        local before_trim
        before_trim=$(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$ctid"'/) {gsub(/%/, "", $7); print $7}')
        echo -e "${RD}Data before trim: $before_trim%${CL}"
        
        pct fstrim "$ctid"
        
        local after_trim
        after_trim=$(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$ctid"'/) {gsub(/%/, "", $7); print $7}')
        echo -e "${GN}Data after trim:  $after_trim%${CL}"
    else
        echo -e "${YW}Warning: Storage target for ${ctid} is not LVM-thin. Skipping fstrim execution layer.${CL}"
    fi
}

# ==============================================================================
# SECTION 3: SYSTEM CONVERSION MODULES (STRICT CORE 3)
# ==============================================================================

handle_debian() {
    local ctid="$1" mode="$2"
    local current_ver="${CT_VER[$ctid]}"

    case $mode in
        ANALYZE)
            if [ "$current_ver" -lt "$LATEST_DEBIAN_STABLE" ]; then
                local next_ver=$((current_ver + 1))
                local resolved_code
                resolved_code=$(resolve_debian_codename "$next_ver")
                
                if [ -n "$resolved_code" ]; then
                    CT_TARGET_VER["$ctid"]="$next_ver"
                    CT_TARGET_CODE["$ctid"]="$resolved_code"
                    CT_ACTION["$ctid"]=UPGRADE
                fi
            else
                echo ">>> [$ctid] Evaluating pending Debian packages..."
                pct exec "$ctid" -- apt-get update -qq
                if pct exec "$ctid" -- bash -c 'apt list --upgradable 2>/dev/null | grep -q /'; then
                    CT_ACTION["$ctid"]=UPDATE
                else
                    CT_ACTION["$ctid"]=NONE
                fi
            fi
            ;;
        UPDATE)
            echo ">>> [$ctid] Injecting native Debian patch streams..."
            pct exec "$ctid" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" upgrade -y'
            ;;
        UPGRADE)
            local target_code="${CT_TARGET_CODE[$ctid]}"
            echo ">>> [$ctid] Translating configuration repositories: ${CT_CODE[$ctid]} -> $target_code"
            
            pct exec "$ctid" -- sed -i "s/${CT_CODE[$ctid]}/$target_code/g" /etc/apt/sources.list
            pct exec "$ctid" -- apt-get update
            pct exec "$ctid" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" dist-upgrade -y'
            
            # Prevent LXC Systemd Virtualization network breaks
            pct exec "$ctid" -- systemctl disable --now systemd-networkd-wait-online.service || true
            pct exec "$ctid" -- systemctl disable --now systemd-networkd.service || true
            pct exec "$ctid" -- systemctl disable --now ifupdown-wait-online || true
            pct exec "$ctid" -- apt-get install -y ifupdown2 || true
            ;;
    esac
}

handle_alpine() {
    local ctid="$1" mode="$2"
    local current_ver="${CT_VER[$ctid]}"

    case $mode in
        ANALYZE)
            if [[ "$current_ver" =~ ^3\.([0-9]+)\. ]]; then
                local current_minor="${BASH_REMATCH[1]}"
                local latest_minor
                latest_minor=$(echo "$LATEST_ALPINE_STABLE" | cut -d. -f2 || echo "24")
                
                if [ "$current_minor" -lt "$latest_minor" ]; then
                    local next_minor=$((current_minor + 1))
                    CT_TARGET_VER["$ctid"]="3.${next_minor}.0"
                    CT_TARGET_CODE["$ctid"]="v3.${next_minor}"
                    CT_ACTION["$ctid"]=UPGRADE
                fi
            else
                pct exec "$ctid" -- apk update -q
                if pct exec "$ctid" -- bash -c 'apk upgrade -s 2>/dev/null | grep -q "Upgrading"'; then
                    CT_ACTION["$ctid"]=UPDATE
                else
                    CT_ACTION["$ctid"]=NONE
                fi
            fi
            ;;
        UPDATE)
            echo ">>> [$ctid] Applying Alpine package changes..."
            pct exec "$ctid" -- apk upgrade
            ;;
        UPGRADE)
            local target_branch="${CT_TARGET_CODE[$ctid]}"
            echo ">>> [$ctid] Running branch shift conversion: ${current_ver} -> $target_branch"
            pct exec "$ctid" -- sed -i "s|/v3\.[0-9]\+|/$target_branch|g" /etc/apk/repositories
            pct exec "$ctid" -- apk update
            pct exec "$ctid" -- apk upgrade --available
            ;;
    esac
}

handle_fedora() {
    local ctid="$1" mode="$2"
    local current_ver="${CT_VER[$ctid]%%.*}"

    case $mode in
        ANALYZE)
            if [ "$current_ver" -lt "$LATEST_FEDORA_STABLE" ]; then
                local next_ver=$((current_ver + 1))
                CT_TARGET_VER["$ctid"]="$next_ver"
                CT_TARGET_CODE["$ctid"]="f$next_ver"
                CT_ACTION["$ctid"]=UPGRADE
            else
                pct exec "$ctid" -- dnf check-update -q || { [ $? -eq 100 ] && CT_ACTION["$ctid"]=UPDATE; }
                [ -z "${CT_ACTION["$ctid"]:-}" ] && CT_ACTION["$ctid"]=NONE
            fi
            ;;
        UPDATE)
            echo ">>> [$ctid] Forcing dnf patch pipeline updates..."
            pct exec "$ctid" -- dnf upgrade -y
            ;;
        UPGRADE)
            local next_ver="${CT_TARGET_VER[$ctid]}"
            echo ">>> [$ctid] Upgrading Fedora Release: $current_ver -> $next_ver"
            pct exec "$ctid" -- bash -c "dnf -y upgrade --refresh"
            pct exec "$ctid" -- bash -c "dnf -y system-upgrade download --releasever=$next_ver --allowerasing"
            pct exec "$ctid" -- bash -c "dnf -y system-upgrade reboot" || true
            ;;
    esac
}

# ==============================================================================
# SECTION 4: INTERACTIVE CHECKLIST SELECTION PIPELINE
# ==============================================================================

get_upgrade_candidates() {
    if ! command -v whiptail &> /dev/null; then
        echo "!!! System Error: 'whiptail' is missing. Install via apt-get on host PVE node." >&2
        exit 1
    fi

    mapfile -t RAW_PCT_OUTPUT < <(pct list | awk 'NR>1 {print $1, $2, $3}')
    if [ ${#RAW_PCT_OUTPUT[@]} -eq 0 ]; then
        echo "No valid LXC container deployment mapped inside local clusters." >&2
        exit 0
    fi

    local whiptail_options=()
    for line in "${RAW_PCT_OUTPUT[@]}"; do
        local ctid status name default_toggle
        ctid=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        name=$(echo "$line" | awk '{print $3}')
        
        default_toggle="OFF"
        [ "$status" = "running" ] && default_toggle="ON"
        
        whiptail_options+=("$ctid" "Name: $name [$status]" "$default_toggle")
    done

    local chosen_ctids
    chosen_ctids=$(whiptail --title "PVE LXC Orchestration Hub" \
                            --checklist "Use [Spacebar] to highlight targets. [Enter] confirms scan configurations." 20 75 10 \
                            "${whiptail_options[@]}" 3>&1 1>&2 2>&3) || exit 0

    eval echo "$chosen_ctids"
}

# ==============================================================================
# SECTION 5: LIVE TASK PROCESSING ENGINE
# ==============================================================================

fetch_latest_upstream_versions

eval SCAN_TARGETS=($(get_upgrade_candidates))
if [ ${#SCAN_TARGETS[@]} -eq 0 ]; then
    echo "Zero infrastructure targets passed. Halting script operations."
    exit 0
fi

UPGRADE_CANDIDATES=()

# Active Inspection Subroutine
for ctid in "${SCAN_TARGETS[@]}"; do
    echo ">>> Scanning container node state: $ctid"
    pct start "$ctid" >/dev/null 2>&1 || true
    sleep 1

    CT_OS["$ctid"]=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$ID"' 2>/dev/null || echo "unknown")
    CT_VER["$ctid"]=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$VERSION_ID"' 2>/dev/null || echo "unknown")
    CT_CODE["$ctid"]=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$VERSION_CODENAME"' 2>/dev/null || echo "")

    case "${CT_OS[$ctid]}" in
        debian) handle_debian "$ctid" ANALYZE ;;
        alpine) handle_alpine "$ctid" ANALYZE ;;
        fedora) handle_fedora "$ctid" ANALYZE ;;
        *)
            echo -e "${YW}>>> [$ctid] WARNING: Operating System model '${CT_OS[$ctid]}' is unsupported. Skipping target.${CL}"
            CT_ACTION["$ctid"]=NONE
            ;;
    esac

    if [ "${CT_ACTION[$ctid]}" != "NONE" ]; then
        UPGRADE_CANDIDATES+=("$ctid")
    fi
done

if [ ${#UPGRADE_CANDIDATES[@]} -eq 0 ]; then
    echo "All parsed infrastructure elements are clean and fully operational."
    exit 0
fi

# Visual State Matrix Dashboard
clear
echo "========================== INFRASTRUCTURE MAINTENANCE ACTION MATRIX =========================="
printf "%-6s %-12s %-24s %-15s %-25s\n" "CTID" "OS MODEL" "CURRENT REVISION" "ACTION REQ" "CALCULATED DEST"
for ctid in "${UPGRADE_CANDIDATES[@]}"; do
    local dest_string="N/A (Standard Patching)"
    [ "${CT_ACTION[$ctid]}" = "UPGRADE" ] && dest_string="${CT_TARGET_VER[$ctid]} (${CT_TARGET_CODE[$ctid]:-Minor})"
    
    printf "%-6s %-12s %-24s %-15s %-25s\n" \
        "$ctid" "${CT_OS[$ctid]}" "${CT_VER[$ctid]} (${CT_CODE[$ctid]:-N/A})" "${CT_ACTION[$ctid]}" "$dest_string"
done
echo "==============================================================================================="

read -rp "Execute calculated maintenance matrices? Enter space-separated CTIDs or 'none': " -a SELECTED
if [ "${SELECTED[0]}" = "none" ] || [ ${#SELECTED[@]} -eq 0 ]; then exit 0; fi

for ctid in "${SELECTED[@]}"; do
    local action="${CT_ACTION[$ctid]:-NONE}"
    if [ "$action" = "NONE" ]; then continue; fi

    if ! assert_storage_health "$ctid"; then
        echo ">>> [$ctid] Execution thread halted due to inadequate pool space bounds."
        continue
    fi

    SNAP_NAME="pre_${action,,}_${CT_VER[$ctid]}"
    echo ">>> [$ctid] Writing safe execution layer checkpoint: $SNAP_NAME"
    if ! pct snapshot "$ctid" "$SNAP_NAME"; then
        echo "!!! [$ctid] Snapshot runtime check failed. Aborting mutation phases for target."
        continue
    fi

    case "${CT_OS[$ctid]}" in
        debian) handle_debian "$ctid" "$action" ;;
        alpine) handle_alpine "$ctid" "$action" ;;
        fedora) handle_fedora "$ctid" "$action" ;;
    esac

    lxc_quick_clean "$ctid"

    echo ">>> [$ctid] Maintenance pipeline success. Refreshing operating container states..."
    pct reboot "$ctid"
done

echo ">>> All operations completed successfully."
