#!/usr/bin/env bash
# Script to renew Porkbun SSL certificates and update Proxmox PVEProxy
# Author: Proxmox Bash Architect
# Version: 2.7

set -euo pipefail

# --- Exit Codes ---
E_DEPENDENCY=1
E_PORKBUN=2
E_WRITE=3
E_PVE=4
E_OPENSSL=5
E_MISC=6

# --- Fallback Configuration ---
PORKBUN_API_URL="https://api-ipv4.porkbun.com/api/json/v3/ssl/retrieve"
# The first domain listed is treated as the "primary domain" and is the one used by pveproxy
DOMAINS=(
    "untapped.tech"
    "untapped.cloud"
    "untapped.codes"
    "untappedtechnologies.com"
)
EXIT_CODE=0
PVE_SSL_CERT="/etc/pve/local/pveproxy-ssl.pem"
ONE_WEEK_SECONDS=604800

# --- Colors ---
RED='\033[31m'
GN='\033[32m'
NC='\033[0m'

# --- Logging Hooks ---
log() { 
    # Short‑circuit immediately if verbose mode isn't enabled
    [[ "$VERBOSE" == "true" ]] || return 0
    echo -e "${GN}[$(date +%T)]${NC} $1"
}

error() { 
    echo -e "${RED}[$(date +%T)] ERROR:${NC} $1" >&2 
}

usage() {
    echo -e "${RED}ERROR: Invalid arguments${NC}" >&2
    echo "Usage: $0 [-v|--verbose] [-f|--force] <path/to/credential/file> <output/directory> [domain1 domain2 ...]" >&2
    exit 1
}

# --- Option & Argument Parsing ---
VERBOSE=false
FORCE=false
PORK_CREDS=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -*)
            usage
            ;;
        *)
            # Sequentially capture fixed positional arguments
            if [[ -z "$PORK_CREDS" ]]; then
                PORK_CREDS="$1"
                shift
            elif [[ -z "$WORK_DIR" ]]; then
                WORK_DIR="$1"
                shift
                break # Hard stop parsing flags so remaining elements are retained in $@
            fi
            ;;
    esac
done

# Ensure mandatory core arguments were provided
if [[ -z "$PORK_CREDS" || -z "$WORK_DIR" ]]; then 
    usage 
fi

# If arguments are passed via CLI, use them; otherwise, fall back to defaults
DOMAINS=("${@:-${DOMAINS[@]}}")
PRIMARY_DOMAIN="${DOMAINS[0]}"

# --- Pre-Flight Operational Validity Checks ---

# 1. Verify credentials file exists before doing anything else
if [[ ! -f "$PORK_CREDS" ]]; then
    error "Credential file not found at: $PORK_CREDS"
    exit $E_MISC
fi

# 2. Dependency execution footprint verification
deps=(jq curl pvenode sha256sum openssl)
for d in "${deps[@]}"; do
    command -v "$d" >/dev/null || { error "Required command '$d' not found."; exit $E_DEPENDENCY; }
done

# 3. Secure and verify output working environment pathing
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"

# Cleanup trap for processing wreckage
trap 'rm -f "$WORK_DIR"/*.tmp 2>/dev/null || true' EXIT

# --- Atomic Write Helper ---
save_atomic() {
    local content="$1"
    local dest="$2"

    if ! printf "%s" "$content" > "$dest.tmp"; then
        error "Failed writing temporary file for $dest"
        EXIT_CODE=$E_WRITE
        return 1
    fi

    chmod 644 "$dest.tmp"
    mv "$dest.tmp" "$dest"
}

# --- Deployment Function ---
deploy_to_pve() {
    local domain=$1
    local cert_file="$WORK_DIR/$domain.domain.cert.pem"
    local key_file="$WORK_DIR/$domain.private.key.pem"

    log "  Checking if Proxmox SSL needs update for $domain..."

    if [[ -f "$PVE_SSL_CERT" ]]; then
        local current_hash new_hash
        current_hash=$(sha256sum "$PVE_SSL_CERT" | awk '{print $1}')
        new_hash=$(sha256sum "$cert_file" | awk '{print $1}')

        if [[ "$current_hash" == "$new_hash" && "$FORCE" == "false" ]]; then
            log "Proxmox active key-pair matches local cache footprint. Skipping active deployment update."
            return 0
        fi
    fi

    log "  Deploying new keys to local PVE node via pvenode hooks..."
    if pvenode cert set "$cert_file" "$key_file" --force 1; then
        log "  PVE SSL updated successfully for $domain."
    else
        error "  Failed to update PVE SSL for $domain."
        EXIT_CODE=$E_PVE
    fi
}

# --- Main Processing Loop ---
for DOM in "${DOMAINS[@]}"; do
    local_cert="$WORK_DIR/$DOM.domain.cert.pem"

    # Short-circuit: continue to next domain if cert is valid, present, and force is false
    if [[ "$FORCE" == "false" ]] && \
       [[ -f "$local_cert" ]] && \
       openssl x509 -checkend "$ONE_WEEK_SECONDS" -noout -in "$local_cert" >/dev/null 2>&1; then
        
        log "Certificate for $DOM is still valid and present. Skipping."
        continue
    fi

    log "Action required for $DOM. Fetching from Porkbun..."

    # Fetch from Porkbun
    RESPONSE=$(curl -sf --json "@$PORK_CREDS" "${PORKBUN_API_URL}/${DOM}" || echo "")
    if [[ -z "$RESPONSE" ]]; then
        error "  HTTP error retrieving cert for $DOM"
        EXIT_CODE=$E_PORKBUN
        continue
    fi

    STATUS=$(jq -r .status <<< "$RESPONSE")
    if [[ "$STATUS" != "SUCCESS" ]]; then
        error "  $DOM status: $STATUS"
        EXIT_CODE=$E_PORKBUN
        continue
    fi

    # Parse JSON
    CHAIN=$(jq -r '.certificatechain' <<< "$RESPONSE")
    PUBKEY=$(jq -r '.publickey' <<< "$RESPONSE")
    PRIVKEY=$(jq -r '.privatekey' <<< "$RESPONSE")
    
    # Construct Full Chain (Leaf Certificate + Intermediate Chain)
    FULLCHAIN=$(printf "%s\n%s" "$PUBKEY" "$CHAIN")

    # Save components atomically
    save_atomic "$CHAIN"     "$WORK_DIR/$DOM.domain.cert.pem"  || continue
    save_atomic "$PUBKEY"    "$WORK_DIR/$DOM.public.key.pem"   || continue 
    save_atomic "$PRIVKEY"   "$WORK_DIR/$DOM.private.key.pem"  || continue
    save_atomic "$FULLCHAIN" "$WORK_DIR/$DOM.fullchain.pem"    || continue

    # Create PFX (PKCS#12 bundle)
    if ! openssl pkcs12 -export \
        -out "$WORK_DIR/$DOM.pfx.tmp" \
        -inkey "$WORK_DIR/$DOM.private.key.pem" \
        -in "$WORK_DIR/$DOM.fullchain.pem" \
        -passout pass: >/dev/null 2>&1; then
        error "  Failed to generate PFX for $DOM"
        EXIT_CODE=$E_OPENSSL
    else
        chmod 644 "$WORK_DIR/$DOM.pfx.tmp"
        mv "$WORK_DIR/$DOM.pfx.tmp" "$WORK_DIR/$DOM.pfx"
        log "  [$DOM] PFX created successfully."
    fi

    # Deploy to PVE Proxy if applicable
    if [[ "$DOM" == "$PRIMARY_DOMAIN" ]]; then
        deploy_to_pve "$DOM"
    fi
    sleep 2
done

exit $EXIT_CODE
