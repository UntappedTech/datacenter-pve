# datacenter-pve

This repository serves as the central configuration and orchestration engine for managing Proxmox VE (PVE) hypervisor environments, automated LXC guest configurations, and edge network automation.

## Repository Topography

```text
datacenter-pve/
├── blockman/              # Block-level configuration parsing engine
├── blockman-simple/       # Streamlined, low-complexity variant of blockman
├── caddy/                 # Declarative JSON-to-Caddyfile layout generator
├── fedora/                # Fedora guest operating system optimization workflows
├── LXC/                   # Hypervisor guest life-cycle management
│   └── archive/           # Deprecated script archive
├── network/               # Dynamic DNS, edge probe profiling, and Porkbun SSL API layers
├── templates/             # Baseline aliases, hooks, and environment configurations for LXC
└── [Root Scripts]         # Global monitoring and initialization tools executed on PVE Host

```

---

## Directory Reference Matrix

| Subdirectory      | Focus Area            | Primary Function                                                                      | Target Architecture      |
| ----------------- | --------------------- | ------------------------------------------------------------------------------------- | ------------------------ |
| `blockman`        | Document Tokenization | Executes atomic CRUD boundaries on matching text blocks.                              | System Agnostic          |
| `blockman-simple` | Document Tokenization | Low-complexity text asset manipulation layer.                                         | System Agnostic          |
| `caddy`           | Edge Routing          | Compiles explicit, standard `Caddyfile` layouts using compact JSON syntax.            | Web Ingress / Proxies    |
| `fedora`          | Guest Provisioning    | Automation assets targeted at Fedora Core/Server guest lifecycle optimization.        | Fedora Environments      |
| `LXC`             | Container Lifecycle   | Hosts the dynamic `pve-lxc-lifecycle` runtime automation engine.                      | Proxmox LXC Subsystem    |
| `network`         | Ingress & Edge DNS    | Core dynamic DNS, distributed web probes, and Porkbun TLS cert automation.            | Global Edge Ingress      |
| `templates`       | Container Profiles    | Houses default configurations, functional profiles, and custom `.bashrc.d` fragments. | LXC Provisioning Targets |

---

## Root-Level Host Scripts

These tools operate globally directly from the Proxmox host shell (`.`) to maintain stability, watch filesystems, and provision fresh guests.

### 1. `auto_track_changes.sh` (FileSystem Monitor)

Leverages the kernel subsystem via `inotifywait` to handle continuous file modification tracking across arbitrary system file paths (e.g., `/etc/pve/...`, `/etc/nginx/`).

- **Mechanism**: When a tracked modification event trips, the engine copies the file relatives, sets the target directories inside an absolute central Git repository wrapper, and generates automated Git commits.
- **Usage**:

```bash
./auto_track_changes.sh <path_to_central_repo> <path_to_file_list.txt>
```

### 2. `lxc-post-init.sh` (Guest Bootstrapper)

An initialization pipeline run immediately after a container instance deployment is spun up on the local node.

- **Mechanism**: Mounts global certificate pools (`/srv/certs` $\rightarrow$ `/certs`), formats structural boundaries for `/root/.bashrc.d`, pushes configuration profile hooks down via `pct push`, and forces initialization elements like `00-lxc-run-once.sh` to trigger.
- **Usage**:

```bash
./lxc-post-init.sh <CTID>
```

### 3. `qemu_reboot_high_mem.sh` (Memory Leak Mitigator)

A daemon utility focused on tracking memory leaks or system bloat in targeted QEMU virtual machines.

- **Mechanism**: Queries `pvesh` metrics continuously over fixed temporal loops. If a designated VM's physical consumption remains past a given percentage threshold over consecutive samples, it issues a hard command reload sequence (`qm reboot`).
- **Usage**:

```bash
./qemu_reboot_high_mem.sh <VMID> <THRESHOLD_PERCENT>
```

---

## Core Lifecycle Focus: LXC Subdirectory

The `LXC/` directory handles container lifecycle operations:

- **`pve-lxc-lifecycle`**: The flagship automated orchestration framework that handles state scanning, explicit storage constraints verification, snapshotting safety barriers, multi-distribution version checking (Debian, Alpine, Fedora), and atomic container upgrades.
- **`archive/`**: Contains an unlinked storage index holding older standalone, single-distribution patch utilities that have been deprecated and superceeded by the unified lifecycle tool.
