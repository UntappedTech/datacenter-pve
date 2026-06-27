# Network Architecture & Domain Automation Suite

This directory contains a suite of automation tools designed to manage dynamic DNS updates, SSL certificate rotation, external edge verification, and upstream registrar cost auditing for infrastructure running on Proxmox VE (PVE).

## Table of Contents

1. [Suite Overview & Matrix](https://www.google.com/search?q=%23suite-overview--matrix)
2. [Prerequisites & Core Dependencies](https://www.google.com/search?q=%23prerequisites--core-dependencies)
3. [Configuration & Credentials](https://www.google.com/search?q=%23configuration--credentials)
4. [Tool Deep-Dives](https://www.google.com/search?q=%23tool-deep-dives)

- [netprobe.sh](https://www.google.com/search?q=%231-netprobesh)
- [porkbun_certs.sh](https://www.google.com/search?q=%232-porkbun_certssh)
- [porkbun_dns.sh](https://www.google.com/search?q=%233-porkbun_dnssh)
- [porkbun_pricing.sh](https://www.google.com/search?q=%234-porkbun_pricingsh)

5. [Crontab Reference Automation](https://www.google.com/search?q=%23crontab-reference-automation)

---

## Suite Overview & Matrix

| Script               | Purpose                                 | Targeting Model                | External API Dependency | PVE Host Interaction                    |
| -------------------- | --------------------------------------- | ------------------------------ | ----------------------- | --------------------------------------- |
| `netprobe.sh`        | Globally distributed network edge tests | HTTP status validation         | `api.globalping.io`     | None (Pipes Alert/Logs)                 |
| `porkbun_certs.sh`   | Retrieves SSL chains & compiles bundles | `pveproxy` Primary Leaf + SANs | `api-ipv4.porkbun.com`  | Mutates `/etc/pve/local/` via `pvenode` |
| `porkbun_dns.sh`     | Resilient IPv4/IPv6 Dynamic DNS updates | Dynamic A/AAAA records         | `api.porkbun.com`       | None (Read WAN IP)                      |
| `porkbun_pricing.sh` | Registrar financial telemetry           | Real-time TLD matrix mapping   | `api-ipv4.porkbun.com`  | None (CLI Text Table)                   |

---

## Prerequisites & Core Dependencies

The scripts assume execution directly on a Proxmox VE hypervisor host or a designated orchestration controller. Ensure the following tooling footprint is present:

```bash
apt-get update && apt-get install -y jq curl openssl grep coreutils
```

---

## Configuration & Credentials

The API-driven scripts depend on `porkbun_credentials.json`. Protect this file using standard POSIX filesystem ACLs to safeguard key-pairs.

### 1. Structure of `porkbun_credentials.json`

```json
{
    "secretapikey": "YOUR_PORKBUN_SECRET_API_KEY",
    "apikey": "YOUR_PORKBUN_PUBLIC_API_KEY"
}
```

### 2. Lock Down Permissions

```bash
chmod 600 /path/to/porkbun_credentials.json
```

---

## Tool Deep-Dives

### 1. `netprobe.sh`

Leverages the Globalping API network to launch decentralized, external HTTP tests targeting your production sites from global nodes. This verifies that third-party routing, edge reverse proxies, and your native home networks are operational.

- **Key Feature**: Safely handles standard upstream redirections (e.g., `301`, `302`, `307`, `308`) alongside native `200 OK` status returns. Logs errors to `/var/log/netprobe.log` with a fallback to `/tmp/`.
- **Usage**:

```bash
./netprobe.sh [-v|--verbose]
```

### 2. `porkbun_certs.sh`

Queries Porkbun's automated Let's Encrypt engine to capture leaf certificates, validates expiration buffers locally via `openssl`, packages structural components into raw PKCS#12 (`.pfx`) formats, and directly overrides `pveproxy`.

- **Key Feature**: Short-circuits execution completely if your certificates are valid for longer than 7 days, eliminating API throttling issues.
- **Usage**:

```bash
./porkbun_certs.sh [-v] [-f] <path/to/credentials.json> <output/directory> [domains...]
```

- **Example**:

```bash
./porkbun_certs.sh -v ./porkbun_credentials.json /etc/ssl/porkbun_certs
```

### 3. `porkbun_dns.sh`

Monitors the host's current public IPv4 and IPv6 connections. If a mismatch is detected between live parameters and remote zones, it edits Porkbun DNS entries automatically.

- **Key Feature**: Queries Porkbun first to detect WAN IPs; falls back automatically to `icanhazip.com` if the registrar API is under load.
- **Usage**:

```bash
./porkbun_dns.sh [-v] <path/to/porkbun_credentials.json> [domain1.com domain2.tech ...]
```

- **Example**:

```bash
./porkbun_dns.sh -v ./porkbun_credentials.json untapped.tech untappedtechnologies.com
```

### 4. `porkbun_pricing.sh`

A lightweight tool designed to extract registration and renewal costs for selected Top-Level Domains. Output is printed in a clean fixed-width table layout, ideal for scheduling automated summary updates via email.

- **Usage**:

```bash
./porkbun_pricing.sh [tld1 tld2 ...]
```

- **Example**:

```bash
./porkbun_pricing.sh com net tech co.uk
```

---

## Crontab Reference Automation

To operationalize this suite completely within your datacenter git tracking framework, load these execution intervals into the Proxmox host crontab (`crontab -e`):

```cron
# [PROBE] Check edge usability status every 15 minutes in verbose mode
*/15 * * * * /root/pve-datacenter/network/netprobe.sh --verbose > /dev/null

# [SSL] Check certificates daily at 02:30 AM; automatically updates pveproxy if expired
30 2 * * * /root/pve-datacenter/network/porkbun_certs.sh /root/pve-datacenter/network/porkbun_credentials.json /etc/ssl/porkbun_certs > /dev/null

# [DDNS] Check network updates hourly, write stdout straight to syslog
0 * * * * /root/pve-datacenter/network/porkbun_dns.sh /root/pve-datacenter/network/porkbun_credentials.json > /dev/null
```
