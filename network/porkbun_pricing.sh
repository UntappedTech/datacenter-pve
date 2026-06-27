#!/usr/bin/env bash

# Exit immediately if a pipeline fails or an unassigned variable is evaluated
set -euo pipefail

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed."
    echo "Please install jq and try again."
    exit 2
fi


API_URL="https://api-ipv4.porkbun.com/api/json/v3/pricing/get"

# Default TLDs
TLDS=(
    "cloud"
    "codes"
    "com"
    "tech"
)

# If arguments are passed via CLI, use them; otherwise, fall back to defaults
TLDS=("${@:-${TLDS[@]}}")

# Safely build an escaped JSON payload from the Bash array using jq
json_payload=$(jq -n '{tlds: $ARGS.positional}' --args "${TLDS[@]}")

response=$(curl -s "$API_URL" \
  --request POST \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data "$json_payload")

# Simple verification loop to check API execution health
if [[ "$(jq -r '.status // empty' <<< "$response")" != "SUCCESS" ]]; then
    echo "ERROR: Failed to fetch valid data from Porkbun API."
    exit 1
fi

# Print clean, fixed-width table header suitable for email layouts
printf "\n%-10s | %-12s | %-12s\n" "TLD" "Registration" "Renewal"
printf "%-10s-+-%-12s-+-%-12s\n" "----------" "------------" "------------"

for tld in "${TLDS[@]}"; do
    # Normalize input string to lowercase to handle casing discrepancies safely
    tld_lower=$(echo "$tld" | tr '[:upper:]' '[:lower:]')

    # Query the nested JSON map targets using keys
    # Use bracket notation to safely handle complex TLDs (ie. co.uk)
    renewal=$(jq -r '.pricing[$tld].renewal // empty' --arg tld "$tld_lower" <<< "$response")
    registration=$(jq -r '.pricing[$tld].registration // empty' --arg tld "$tld_lower" <<< "$response")

    # Error handling clause for dead/typo'd extensions
    if [[ -z "$registration" || -z "$renewal" ]]; then
        printf "%-10s | %-27s\n" "$tld_lower" "Not Found / Unsupported"
        continue
    fi

    printf "%-10s | \$%-11s | \$%-11s\n" "$tld_lower" "$registration" "$renewal"
done

echo ""