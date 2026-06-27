#!/bin/bash
# upgrade-lxc-orchestrator.sh
# Scan LXC containers, detect OS/version, snapshot, and upgrade:
# - Debian 12 (bookworm) -> 13 (trixie)
# - Fedora -> 43 (stepwise: N -> N+1)
# - Alpine -> 3.23.3 (stepwise: 3.x -> 3.(x+1))

set -euo pipefail

TARGET_FEDORA=43
TARGET_ALPINE="3.23.3"

echo ">>> Scanning LXC containers..."
mapfile -t CT_LIST < <(pct list | awk 'NR>1 {print $1}')

if [ ${#CT_LIST[@]} -eq 0 ]; then
    echo "No containers found."
    exit 0
fi

declare -A CT_OS
declare -A CT_VER
declare -A CT_CODE
declare -A CT_UPGRADE_TYPE

detect_os() {
    local ctid="$1"

    pct start "$ctid" >/dev/null 2>&1 || true
    sleep 1

    local os_id os_ver os_code
    os_id=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$ID"' 2>/dev/null || echo "unknown")
    os_ver=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$VERSION_ID"' 2>/dev/null || echo "unknown")
    os_code=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$VERSION_CODENAME"' 2>/dev/null || echo "")

    CT_OS["$ctid"]="$os_id"
    CT_VER["$ctid"]="$os_ver"
    CT_CODE["$ctid"]="$os_code"
}

needs_upgrade() {
    local ctid="$1"
    local os_id="${CT_OS[$ctid]}"
    local os_ver="${CT_VER[$ctid]}"
    local os_code="${CT_CODE[$ctid]}"

    case "$os_id" in
        debian)
            if [ "$os_code" = "bookworm" ]; then
                CT_UPGRADE_TYPE["$ctid"]="debian"
            fi
            ;;
        fedora)
            # VERSION_ID is numeric
            local ver_int="${os_ver%%.*}"
            if [ "$ver_int" -lt "$TARGET_FEDORA" ]; then
                CT_UPGRADE_TYPE["$ctid"]="fedora"
            fi
            ;;
        alpine)
            # VERSION_ID like 3.18.4
            if [[ "$os_ver" =~ ^3\.([0-9]+)\.([0-9]+)$ ]]; then
                # Anything below 3.23.3 is eligible
                if [ "$os_ver" != "$TARGET_ALPINE" ]; then
                    CT_UPGRADE_TYPE["$ctid"]="alpine"
                fi
            fi
            ;;
    esac
}

echo ">>> Detecting OS and version..."
for ctid in "${CT_LIST[@]}"; do
    detect_os "$ctid"
done

echo
echo "Detected containers:"
printf "%-6s %-10s %-12s %-12s\n" "CTID" "OS" "VERSION" "CODENAME"
for ctid in "${CT_LIST[@]}"; do
    printf "%-6s %-10s %-12s %-12s\n" \
        "$ctid" "${CT_OS[$ctid]}" "${CT_VER[$ctid]}" "${CT_CODE[$ctid]}"
done

echo
echo ">>> Determining which containers can be upgraded..."
UPGRADE_CANDIDATES=()
for ctid in "${CT_LIST[@]}"; do
    needs_upgrade "$ctid"
    if [ -n "${CT_UPGRADE_TYPE[$ctid]:-}" ]; then
        UPGRADE_CANDIDATES+=("$ctid")
    fi
done

if [ ${#UPGRADE_CANDIDATES[@]} -eq 0 ]; then
    echo "No containers need an upgrade based on current rules."
    exit 0
fi

echo
echo "Containers eligible for upgrade:"
printf "%-6s %-10s %-18s %-20s\n" "CTID" "OS" "CURRENT" "TARGET"
for ctid in "${UPGRADE_CANDIDATES[@]}"; do
    case "${CT_UPGRADE_TYPE[$ctid]}" in
        debian)
            target="13 (trixie)"
            ;;
        fedora)
            target="Fedora $TARGET_FEDORA"
            ;;
        alpine)
            target="Alpine $TARGET_ALPINE"
            ;;
        *)
            target="unknown"
            ;;
    esac
    printf "%-6s %-10s %-18s %-20s\n" \
        "$ctid" "${CT_OS[$ctid]}" "${CT_VER[$ctid]} ${CT_CODE[$ctid]}" "$target"
done

echo
read -rp "Enter CTIDs to upgrade (space-separated), or 'none' to cancel: " -a SELECTED

if [ "${SELECTED[0]}" = "none" ]; then
    echo "Aborting."
    exit 0
fi

# 5-second warning before starting
echo
echo "WARNING: You are about to snapshot and upgrade the selected containers."
echo "Press Ctrl+C to cancel."
for i in {5..1}; do
    echo -n "$i..."
    sleep 1
done
echo
echo "Starting upgrades."

snapshot_ct() {
    local ctid="$1"
    local snap_name="pre-upgrade-$(date +%Y%m%d%H%M%S)"
    echo ">>> [$ctid] Creating snapshot: $snap_name"
    if pct snapshot "$ctid" "$snap_name"; then
        echo ">>> [$ctid] Snapshot created."
    else
        echo "!!! [$ctid] Snapshot failed. Skipping upgrade."
        return 1
    fi
}

upgrade_debian() {
    local ctid="$1"
    echo ">>> [$ctid] Upgrading Debian 12 (bookworm) -> 13 (trixie)"

    pct exec "$ctid" -- sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
    pct exec "$ctid" -- bash -c 'apt-get update'
    pct exec "$ctid" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" dist-upgrade -y'

    pct exec "$ctid" -- systemctl disable --now systemd-networkd-wait-online.service || true
    pct exec "$ctid" -- systemctl disable --now systemd-networkd.service || true
    pct exec "$ctid" -- systemctl disable --now ifupdown-wait-online || true

    pct exec "$ctid" -- apt-get install -y ifupdown2 || true
    pct exec "$ctid" -- apt-get autoremove --purge -y
    pct exec "$ctid" -- apt-get clean

    echo ">>> [$ctid] Rebooting container..."
    pct reboot "$ctid"
}

next_fedora_version() {
    local cur="$1"
    echo $((cur + 1))
}

upgrade_fedora_stepwise() {
    local ctid="$1"

    while :; do
        local cur_ver
        cur_ver=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$VERSION_ID"' 2>/dev/null || echo "0")
        local cur_int="${cur_ver%%.*}"

        if [ "$cur_int" -ge "$TARGET_FEDORA" ]; then
            echo ">>> [$ctid] Fedora is now at $cur_ver (target reached)."
            break
        fi

        local next_ver
        next_ver=$(next_fedora_version "$cur_int")
        echo ">>> [$ctid] Upgrading Fedora $cur_int -> $next_ver"

        pct exec "$ctid" -- bash -c 'dnf -y upgrade --refresh'
        pct exec "$ctid" -- bash -c "dnf -y system-upgrade download --releasever=$next_ver --allowerasing"
        pct exec "$ctid" -- bash -c 'dnf -y system-upgrade reboot' || true

        echo ">>> [$ctid] Waiting for container to come back up..."
        sleep 10
        pct start "$ctid" >/dev/null 2>&1 || true
        sleep 5
    done
}

next_alpine_version() {
    local cur="$1"
    case "$cur" in
        3.18.*) echo "3.19.0" ;;
        3.19.*) echo "3.20.0" ;;
        3.20.*) echo "3.21.0" ;;
        3.21.*) echo "3.22.0" ;;
        3.22.*) echo "3.23.0" ;;
        3.23.*) echo "$TARGET_ALPINE" ;;
        *) echo "$TARGET_ALPINE" ;;
    esac
}

alpine_repo_branch() {
    local ver="$1"
    # Convert 3.23.3 -> v3.23
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    echo "v${major}.${minor}"
}

upgrade_alpine_stepwise() {
    local ctid="$1"

    while :; do
        local cur_ver
        cur_ver=$(pct exec "$ctid" -- bash -c 'source /etc/os-release && echo "$VERSION_ID"' 2>/dev/null || echo "0")
        if [ "$cur_ver" = "$TARGET_ALPINE" ]; then
            echo ">>> [$ctid] Alpine is now at $cur_ver (target reached)."
            break
        fi

        local next_ver
        next_ver=$(next_alpine_version "$cur_ver")
        local branch
        branch=$(alpine_repo_branch "$next_ver")

        echo ">>> [$ctid] Upgrading Alpine $cur_ver -> $next_ver (branch $branch)"

        pct exec "$ctid" -- sed -i "s|/v3\.[0-9]\+|/$branch|g" /etc/apk/repositories
        pct exec "$ctid" -- apk update
        pct exec "$ctid" -- apk upgrade --available

        echo ">>> [$ctid] Rebooting container..."
        pct reboot "$ctid" || true
        sleep 10
        pct start "$ctid" >/dev/null 2>&1 || true
        sleep 5
    done
}

for ctid in "${SELECTED[@]}"; do
    if [ -z "${CT_UPGRADE_TYPE[$ctid]:-}" ]; then
        echo ">>> [$ctid] Not marked as upgradable by this script. Skipping."
        continue
    fi

    echo
    echo "=== Processing CTID $ctid (${CT_OS[$ctid]} ${CT_VER[$ctid]} ${CT_CODE[$ctid]}) ==="

    if ! snapshot_ct "$ctid"; then
        continue
    fi

    case "${CT_UPGRADE_TYPE[$ctid]}" in
        debian)
            upgrade_debian "$ctid"
            ;;
        fedora)
            upgrade_fedora_stepwise "$ctid"
            ;;
        alpine)
            upgrade_alpine_stepwise "$ctid"
            ;;
        *)
            echo ">>> [$ctid] Unknown upgrade type. Skipping."
            ;;
    esac
done

echo
echo "All requested upgrades processed."
