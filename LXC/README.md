# PVE LXC Lifecycle Manager (`pve_lxc_lifecycle.sh`)

An automated, data-driven orchestration framework designed to safely handle state analysis, package optimization, storage boundary validation, and atomic distribution upgrades for Linux Containers (LXC) on Proxmox VE (PVE) hosts.

## Core Features

- **Multi-Distribution Intelligence**: Built-in support for dynamically detecting and upgrading **Debian**, **Alpine Linux**, and **Fedora** container configurations.
- **Live Upstream Metrics Sync**: Fetches stable branch definitions dynamically from authoritative upstream distribution mirrors (e.g., Debian Pages, Alpine CDN, Fedora Streams) to calculate necessary patch increments or release shifts.
- **Pre-Flight Storage Assertions**: Automatically parses the container's root file system (`rootfs`) target storage pool and calculates real-time free capacity. Halts execution safely if the storage space constraints drop below safety bounds.
- **Defensive Checkpoint Safety Traps**: Leverages the Proxmox storage subsystem to snap an automated recovery point (`pre_upgrade_*` or `pre_update_*`) before making any mutating or structural package updates to a guest.
- **LVM-Thin Thin-Provisioning Optimization**: Detects underlying thin pools dynamically, executes `pct fstrim` across running workloads, and prints exact structural allocation storage differentials (`Data%` shifts via `lvs`).
- **Virtualization Network Protection**: Automatically manages system network modules on Debian-based major transitions to prevent virtual interfaces from dropping offline due to systemd-networkd waiting delays.

---

## Prerequisites & Dependencies

The lifecycle script executes directly within the privileged host layer of a Proxmox VE node.

### Host Node Footprint

Ensure the following packages are present on your PVE host environment:

```bash
apt-get update && apt-get install -y jq curl whiptail coreutils lvm2
```

### Guest Node Compliance

- **Debian**: Must have `apt-get` and standard `coreutils` dependencies available.
- **Alpine Linux**: Must have standard `apk` and `ash`/`bash` target bindings active.
- **Fedora**: Must have `dnf` and system-upgrade plugins installed.

---

## Configuration Parameter Defaults

The script exposes customizable variables at the head of the file to manage safety limits:

- `MIN_STORAGE_FREE_MB=10240`: Sets the absolute baseline storage buffer (default: **10 GB**) required on the target storage pool before any snapshot or package mutations are allowed to start.
- `DEBIAN_MAP_FILE="/tmp/debian_distro_map.csv"`: Temporary target matrix path used to map numerical releases directly back to official release names (e.g., `12` $\rightarrow$ `bookworm`).

---

## Operational Mechanics & Phases

```text
[1. UPSTREAM LOOKUP] ----> [2. INTERACTIVE SELECTION] ----> [3. COMPREHENSIVE SCAN]
 Contact Upstream CDN        Whiptail Checklist Filter        Query OS, Version & Status
                                                                          |
                                                                          v
[6. REBOOT & POST-CLEAN] <-- [5. SAFE EXECUTION LAYER] <-- [4. HEALTH & CAPACITY CHECK]
 Post-Trim & Container        Write Snapshot Guard &         Verify Pool Space vs
 Service State Verification   Inject Distribution Updates     MIN_STORAGE_FREE_MB Baseline
```

### Phase 1: Upstream Synchronization & Mirror Query

The script contacts remote endpoints to capture real-time metadata. If internet boundaries or firewall rules block these endpoints, the script prints an inline warning and automatically falls back to hardened baseline versions rather than breaking or crashing under `set -e`.

### Phase 2: Host Interface Target Selection

An interactive `whiptail` multi-select checkbox menu parses active container elements in the cluster, listing them by VMID, assigned Hostname, and operational power states. Containers that are currently running are automatically selected as active evaluation candidates.

### Phase 3: Infrastructure Inspection & Matrix Assessment

The engine boots up selected sleeping targets, issues internal `/etc/os-release` parsing strings, and cross-references localized versions with fetched CDN records. It labels each target with an action state:

- `NONE`: Container is fully patched and matched to the current upstream version.
- `UPDATE`: Operating system minor branch holds pending package patches.
- `UPGRADE`: Container version is legacy and requires a full distribution release upgrade.

### Phase 4: Capacity Validation & Snapshot Guard

Before any update occurs, the script tracks down the target container's volume pool location (e.g., directory structures, ZFS data sets, or LVM thin pools). If free space is verified, it writes an automated recovery point:

- **Format**: `pre_[update|upgrade]_[current_version]`

### Phase 5: Managed Distribution Upgrade

The script fires targeted mutation hooks inside the guest context:

- **Debian**: Rewrites `/etc/apt/sources.list`, transitions codenames, maps full distribution tracking streams via `dist-upgrade`, and updates network handling mechanisms to maximize uptime.
- **Alpine**: Adjusts `/etc/apk/repositories` release branches, syncs metadata indexes, and forces an isolated key transition via `apk upgrade --available`.
- **Fedora**: Refreshes core components, runs `dnf system-upgrade download`, and reloads the container layout to trigger local initialization updates.

### Phase 6: Post-Upgrade Optimization & Trim

Once tracking tasks exit successfully, cache architectures (`apk cache clean`, `dnf clean all`, or `apt autopurge`) are triggered to clean up disk bloat. For LVM-Thin storage arrangements, `pct fstrim` reclaims unused blocks back to the host storage system, displaying before-and-after usage metrics.

---

## Terminal Usage Reference

Run the script manually from the command line using a privileged terminal context on your Proxmox node:

```bash
# Set file execution flags
chmod +x pve_lxc_lifecycle.sh

# Run the automated checklist script
./pve_lxc_lifecycle.sh
```

### Non-Interactive System Integration

The execution loop features an absolute exit handler if zero targets are selected, and stops safely for confirmation input prior to running calculated distribution updates. To safely run this engine via cron or automated continuous delivery hooks, ensure target container selections are piped or passed explicitly to the trailing variable array read lines.
