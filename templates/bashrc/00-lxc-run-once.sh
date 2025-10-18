#!/bin/bash
# ==============================================================================
# LXC Container First-Run Bootstrap Script
#
# Description:
# This script is intended to be run once inside a new LXC container to
# perform initial setup. It detects the OS, performs a full system upgrade,
# and installs a set of useful baseline packages, including 'eza' on all
# supported distributions. After execution, it removes itself.
#
# Designed to be run via `pct exec <vmid> -- /path/to/script.sh`
#
# Improvements in this version:
# - Added 'set -e' to exit on any error for safer execution.
# - Ensured all distros perform a full system upgrade and install packages.
# - Added more comments for clarity (e.g., EXTERNALLY-MANAGED).
# - Refactored special installation logic into functions.
# - Installs 'eza' universally by adding required repos where needed.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
BASE_PACKAGES="nano eza jq curl git" # Use eza instead of exa

# --- Helper Functions ---

# Enables the COPR repository required to install 'eza' on RHEL-based systems.
install_eza_on_el() {
  echo "Checking for eza installation on RHEL-based system..."
  if ! (command -v eza || command -v exa); then
    echo "eza not found. Enabling COPR repository 'ganto/eza'..."
    dnf copr enable -y ganto/eza
  else
    echo "eza (or exa) is already installed. Skipping repo setup."
  fi
}

# Adds the necessary repository to install 'eza' on Debian-based systems.
install_eza_on_debian_ubuntu() {
  echo "Checking for eza installation on Debian-based system..."
  if ! (command -v eza || command -v exa); then
    echo "eza not found. Setting up repository to install eza..."
    # 1. Install dependencies for managing repositories
    apt-get update -qq
    apt-get install -yq gpg apt-transport-https
    
    # 2. Create a dedicated directory for apt keyrings
    mkdir -p /etc/apt/keyrings
    
    # 3. Download and store the GPG key for the repository
    gpg --dearmor -o /etc/apt/keyrings/gierens.gpg \
      --keyserver keyserver.ubuntu.com \
      --recv-keys 0x25E694723049317E
      
    # 4. Add the eza repository to the system's sources
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | \
      tee /etc/apt/sources.list.d/gierens.list
      
    # 5. Refresh package list to include the new repository
    apt-get update -qq
  else
    echo "eza (or exa) is already installed. Skipping repo setup."
  fi
}


# --- Main Execution ---

echo "🚀 Starting LXC container bootstrap sequence..."

# Determine the OS distribution
if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  OS=$ID
else
  echo "❌ Cannot determine OS distribution. /etc/os-release not found."
  exit 1
fi

echo "Detected Distribution: $OS"

# Perform updates and package installation based on the detected OS
case "$OS" in
  alpine)
    apk update
    apk upgrade
    apk add $BASE_PACKAGES
    ;;

  arch)
    pacman -Syyu --noconfirm
    pacman -S --noconfirm $BASE_PACKAGES
    ;;

  centos | alma | rocky)
    dnf -y upgrade
    # dnf-plugins-core is needed for 'dnf copr' command
    dnf install -y epel-release dnf-plugins-core
    # Prepare the system to be able to find the eza package
    install_eza_on_el
    dnf install -y $BASE_PACKAGES
    ;;

  fedora)
    dnf -y upgrade
    dnf -y install $BASE_PACKAGES
    ;;

  ubuntu | debian | devuan)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -yq dist-upgrade
    # Prepare the system to be able to find the eza package
    install_eza_on_debian_ubuntu
    # On newer Debian/Ubuntu, this prevents breaking system python tools
    rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED
    apt-get -yq install $BASE_PACKAGES --no-install-recommends
    ;;

  opensuse-tumbleweed | opensuse-leap)
    zypper --non-interactive refresh
    zypper --non-interactive dist-upgrade
    zypper --non-interactive install -y $BASE_PACKAGES
    ;;

  *)
    echo "⚠️ Unsupported distribution: $OS. Skipping package installation."
    ;;
esac

echo "✅ System updated and base packages installed."

# --- Cleanup ---

echo "🔥 Self-destruct sequence activated. Deleting script."
rm -- "$0" || true

echo "🎉 Bootstrap complete."
