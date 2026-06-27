#!/usr/bin/env bash

# Exit immediately if a pipeline fails or an unassigned variable is evaluated
set -uo pipefail

# --- Colors ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

# --- Fallback Configuration ---
DOMAINS=(
    "untapped.cloud"
    "untapped.codes"
    "untapped.tech"
    "untappedtechnologies.com"
)

API_BASE="https://api.porkbun.com/api/json/v3"

# --- Argument Parsing & Logging Initialization ---
VERBOSE=false
PORK_CREDS=""

usage() {
    echo -e "${RED}ERROR: Invalid arguments${NC}" >&2
    echo "Usage: $0 [-v] <path/to/credential/file> [domain1 domain2 ...]" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v)
            VERBOSE=true
            shift
            ;;
        -*)
            usage
            ;;
        *)
            # The first non-flag argument is our credentials file
            PORK_CREDS="$1"
            shift
            break # Stop parsing options so trailing domains remain untouched in $@
            ;;
    esac
done

if [[ -z "$PORK_CREDS" ]]; then usage; fi

# If arguments are passed via CLI, use them; otherwise, fall back to defaults
DOMAINS=("${@:-${DOMAINS[@]}}")

# --- Smart Dynamic Layout & Logging Functions ---

say() {
    if [[ "$VERBOSE" == "true" ]]; then
        local indent=0
        if [[ $# -gt 1 && "$1" =~ ^[0-9]+$ ]]; then
            indent=$1
            shift
        fi
        printf "%*s%b\n" "$indent" "" "$*"
    fi
}

err() {
    local indent=0
    if [[ $# -gt 1 && "$1" =~ ^[0-9]+$ ]]; then
        indent=$1
        shift
    fi
    printf "%*s%b\n" "$indent" "" "$*" >&2
}

# Verify credential file exists before executing network connections
if [[ ! -f "$PORK_CREDS" ]]; then
    err "${RED}ERROR: Credential file not found at: $PORK_CREDS${NC}"
    exit 1
fi

# --- Resilient IP Detection Hooks ---
fetch_ipv4() {
    local ip=""
    ip=$(curl -4 -s --max-time 5 --json "@$PORK_CREDS" "$API_BASE/ping" 2>/dev/null | jq -r '.yourIp // empty' 2>/dev/null) || true
    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]') || true
    fi
    echo "$ip"
}

fetch_ipv6() {
    local ip=""
    ip=$(curl -6 -s --max-time 5 --json "@$PORK_CREDS" "$API_BASE/ping" 2>/dev/null | jq -r '.yourIp // empty' 2>/dev/null) || true
    if [[ -z "$ip" ]]; then
        ip=$(curl -6 -s --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]') || true
    fi
    echo "$ip"
}

say "Resolving current WAN network endpoints..."
IP_V4=$(fetch_ipv4)
IP_V6=$(fetch_ipv6)

# --- Fail-Fast Clause ---
if [[ -z "$IP_V4" && -z "$IP_V6" ]]; then
    err "${RED}CRITICAL: Could not resolve either IPv4 or IPv6 endpoints. Leaving DNS intact.${NC}"
    exit 1
fi

if [[ -n "$IP_V4" ]]; then
    say 2 "Detected IPv4: ${GREEN}$IP_V4${NC}"
else
    say 2 "Detected IPv4: ${YELLOW}None (Skipping A updates)${NC}"
fi

if [[ -n "$IP_V6" ]]; then
    say 2 "Detected IPv6: ${GREEN}$IP_V6${NC}"
else
    say 2 "Detected IPv6: ${YELLOW}None (Skipping AAAA updates)${NC}"
fi
say ""

# Global Counters for telemetry summaries
UPDATED=0
SKIPPED=0
FAILED=0

# --- Process Domains Dynamically ---
for DOM in "${DOMAINS[@]}"; do
    say "[$DOM] Scrutinizing live DNS maps..."
    
    records_json=$(curl -s --max-time 10 --json "@$PORK_CREDS" "$API_BASE/dns/retrieve/$DOM") || continue
    status=$(jq -r '.status // empty' <<< "$records_json")

    if [[ "$status" != "SUCCESS" ]]; then
        message=$(jq -r '.message // "Unknown error (check API Key deployment status)"' <<< "$records_json")
        err 2 "${RED}[$DOM] Failure tracking zone: $message${NC}"
        ((FAILED++))
        say ""
        continue
    fi

    has_records=false
    
    while IFS='|' read -r rec_id rec_name rec_type rec_content; do
        [[ -z "$rec_id" ]] && continue
        has_records=true

        target_ip=""
        if [[ "$rec_type" == "A" ]]; then
            target_ip="$IP_V4"
        elif [[ "$rec_type" == "AAAA" ]]; then
            target_ip="$IP_V6"
        fi

        if [[ -z "$target_ip" ]]; then
            continue
        fi

        if [[ "$rec_content" == "$target_ip" ]]; then
            say 2 "$rec_type ($rec_name): ${GREEN}Up to date${NC} ($rec_content)."
            ((SKIPPED++))
            continue
        fi

        echo "[$DOM] $rec_type ($rec_name): Shifting ${YELLOW}$rec_content -> $target_ip${NC}..."
        
        if [[ "$rec_name" == "$DOM" ]]; then
            subdomain=""
        else
            subdomain="${rec_name%.$DOM}"
        fi

        payload=$(jq -c --arg type "$rec_type" --arg name "$subdomain" --arg content "$target_ip" \
            '. + {type: $type, name: $name, content: $content}' "$PORK_CREDS")

        update_resp=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$API_BASE/dns/edit/$DOM/$rec_id")

        up_status=$(jq -r '.status' <<< "$update_resp")
        up_message=$(jq -r '.message // empty' <<< "$update_resp")

        if [[ "$up_status" == "SUCCESS" ]]; then
            echo "  -> Status: ${GREEN}Updated Successfully!${NC}"
            ((UPDATED++))
        else
            err 2 "  -> Status: ${RED}Modification Rejected: $up_message${NC}"
            ((FAILED++))
        fi

        sleep 1.5
    done < <(jq -r '.records[]? | select(.type == "A" or .type == "AAAA") | "\(.id)|\(.name)|\(.type)|\(.content)"' <<< "$records_json")

    if [[ "$has_records" == "false" ]]; then
        say 2 "${YELLOW}No active A/AAAA footprints detected inside this zone.${NC}"
    fi

    say ""
    sleep 1
done

# --- Operational Metrics Telemetry Block ---
say "=========================================="
say "${BLUE}DDNS Execution Run Summary:${NC}"
say 2 "Records Unchanged:  ${GREEN}$SKIPPED${NC}"
say 2 "Records Mutated:    ${YELLOW}$UPDATED${NC}"
say 2 "Errors Encountered: ${RED}$FAILED${NC}"
say "=========================================="

[[ $FAILED -gt 0 ]] && exit 1 || exit 0
