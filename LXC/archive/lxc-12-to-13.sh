#!/bin/bash
# Usage: ./lxc-12-to-13 <CTID>

set -e

CTID="$1"

if [ -z "$CTID" ]; then
    echo "Usage: $0 <CTID>"
    exit 1
fi

echo ">>> Checking container $CTID OS version..."

# Ensure container is running
pct start "$CTID" || true
sleep 2

# Extract OS info from inside the container
OS_ID=$(pct exec "$CTID" -- bash -c "source /etc/os-release && echo \$ID")
OS_CODENAME=$(pct exec "$CTID" -- bash -c "source /etc/os-release && echo \$VERSION_CODENAME")

if [ "$OS_ID" != "debian" ]; then
    echo "ERROR: Container $CTID is not running Debian (found: $OS_ID)"
    exit 1
fi

if [ "$OS_CODENAME" != "bookworm" ]; then
    echo "ERROR: Container $CTID is not Debian 12 (bookworm). Found: $OS_CODENAME"
    echo "Refusing to continue."
    exit 1
fi

echo ">>> OS check passed: Debian 12 (bookworm)"

echo ">>> Upgrading LXC container $CTID from Debian 12 → Debian 13"

echo ">>> Updating sources.list (bookworm → trixie)"
pct exec "$CTID" -- sed -i 's/bookworm/trixie/g' /etc/apt/sources.list

echo ">>> Running apt update"
pct exec "$CTID" -- apt-get update

echo ">>> Running full dist-upgrade"
pct exec "$CTID" -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" dist-upgrade -y'

echo ">>> Disabling services that break inside LXC"
pct exec "$CTID" -- systemctl disable --now systemd-networkd-wait-online.service || true
pct exec "$CTID" -- systemctl disable --now systemd-networkd.service || true
pct exec "$CTID" -- systemctl disable --now ifupdown-wait-online || true

echo ">>> Installing ifupdown2 (recommended for LXC networking)"
pct exec "$CTID" -- apt-get install -y ifupdown2 || true

echo ">>> Cleaning up"
pct exec "$CTID" -- apt-get autoremove --purge -y
pct exec "$CTID" -- apt-get clean

echo ">>> Upgrade complete. Rebooting container..."
pct reboot "$CTID"

echo ">>> Done! Container $CTID is now Debian 13 (Trixie)."
