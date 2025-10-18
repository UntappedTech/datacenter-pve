#!/bin/bash

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
# This script reads a monolithic JSON config and generates a complete,
# self-contained Caddyfile for each primary apex domain defined within.
#
# Usage:
#   To generate Caddyfiles: ./subdomain_generator.sh [path_to_config_file]
#   To sort the config file: ./subdomain_generator.sh --sort [path_to_config_file]
# ──────────────────────────────────────────────────────────────────────────────

# Base directory for Caddy configurations.
CADDY_CONF_DIR="/etc/caddy"
# Default config file path.
DEFAULT_CONFIG_FILE="${CADDY_CONF_DIR}/sites.json"
# Template for the output filename. Use {apex_domain} as a placeholder.
OUTPUT_FILENAME_TEMPLATE="${CADDY_CONF_DIR}/conf.d/{apex_domain}.site"

# ──────────────────────────────────────────────────────────────────────────────
# Script Logic
# ──────────────────────────────────────────────────────────────────────────────

set -e

# --- Helper Functions ---

# Indents a multi-line string by a given level.
# $1: The string content to indent.
# $2: The indentation level (integer, e.g., 1 for 4 spaces, 2 for 8).
indent_block() {
    local content="$1"
    local level="$2"
    local indent=""
    for ((i=0; i<level; i++)); do
        indent+="    "
    done
    # Use sed to prepend the indentation to each line.
    echo "$content" | sed "s|^|${indent}|"
}

# Creates and prints the final fallback handler block.
# $1: The APEX_DOMAIN name.
# $2: The custom fallback content from the config (can be empty).
create_fallback_handler() {
    local APEX_DOMAIN="$1"
    local custom_fallback_content="$2"

    if [ -n "$custom_fallback_content" ]; then
        cat <<EOF

    # Fallback Handler
    handle {
$(indent_block "$custom_fallback_content" 2)
    }
EOF
    else
        cat <<EOF

    # Default Handler
    handle {
        redir https://home.${APEX_DOMAIN}
    }
EOF
    fi
}

# Sorts the JSON configuration file in-place.
# $1: The path to the configuration file to sort.
sort_config_file() {
    local file_to_sort="$1"
    echo "🔄 Sorting services in '$file_to_sort' by IP address and port..."
    
    local tmp_file
    tmp_file=$(mktemp)
    
    # This robust jq command correctly sorts services numerically by host_address and then port.
    local sort_command='
        with_entries(
            # For each domain, if it has a non-empty services object...
            if .value.services and (.value.services | length) > 0 then
                .value.services |= (
                    to_entries
                    | sort_by(
                        # Create a single, flat array for the sort key: [oct1, oct2, oct3, oct4, port]
                        (
                            (.value.proxy_target.host_address // "0.0.0.0")
                            | split(".")
                            | map(try tonumber catch 0)
                        )
                        + # Add the port to the array
                        [
                            (.value.proxy_target.port // "0")
                            | try tonumber catch 0
                        ]
                      )
                    | from_entries
                )
            else
                # If no services or an empty services object, leave the entry unchanged.
                .
            end
        )
    '
    
    if jq --indent 4 "$sort_command" "$file_to_sort" > "$tmp_file"; then
        # Atomically replace the old file with the sorted one
        mv "$tmp_file" "$file_to_sort"
        echo "✅ Successfully sorted '$file_to_sort'."
    else
        echo "❌ Error: Failed to sort JSON file. Check for syntax errors." >&2
        rm -f "$tmp_file"
        exit 1
    fi
}

# --- Argument Parsing & Pre-flight Checks ---
if [[ "$1" == "--sort" ]]; then
    CONFIG_FILE="${2:-$DEFAULT_CONFIG_FILE}"
    if [ ! -f "$CONFIG_FILE" ]; then echo "❌ Error: Config file not found at '$CONFIG_FILE'" >&2; exit 1; fi
    sort_config_file "$CONFIG_FILE"
    exit 0
fi

# Default behavior: Generation
CONFIG_FILE="${1:-$DEFAULT_CONFIG_FILE}"

if ! command -v jq &> /dev/null; then echo "❌ Error: 'jq' is not installed." >&2; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then echo "❌ Error: Config file not found at '$CONFIG_FILE'" >&2; exit 1; fi
mkdir -p "$(dirname "$OUTPUT_FILENAME_TEMPLATE")"

check_for_conflicts() {
    local redirect_sources
    redirect_sources=$(jq -r '[.[] | .redirects_from[]? | select(. != null)] | .[]' "$CONFIG_FILE")
    local primary_domains
    primary_domains=$(jq -r 'keys[]' "$CONFIG_FILE")
    for domain in $redirect_sources; do
        if [[ " ${primary_domains[*]} " =~ " ${domain} " ]]; then
            echo "❌ Config Conflict: '${domain}' is in a 'redirects_from' list but is also a primary apex domain." >&2
            exit 1
        fi
    done
}
check_for_conflicts

# --- Main Generator Function ---
generate_content_for_apex() {
    local APEX_DOMAIN="$1"

    # --- Header ---
    cat <<EOF
# This file is automatically generated for the '${APEX_DOMAIN}' apex domain.
# It contains the full site block configuration for this domain and any
# associated redirects.
# Generated on: $(date)

EOF

    # --- TLD Redirects ---
    local redirect_domains
    redirect_domains=$(jq -r --arg apex "$APEX_DOMAIN" '.[$apex].redirects_from[]? // ""' "$CONFIG_FILE")
    if [ -n "$redirect_domains" ]; then
        echo "# TLD Redirects"
        echo
        for domain in $redirect_domains; do
            cat <<EOF
${domain}, *.$domain {
    tls /certs/${domain}.fullchain.pem /certs/${domain}.private.key.pem
    redir https://${APEX_DOMAIN}{uri}
}

EOF
        done
    fi

    # --- Main Block Start ---
    cat <<EOF
# ------------------------------------------------------------------------------
# Main Apex Block for ${APEX_DOMAIN}
# ------------------------------------------------------------------------------
*.${APEX_DOMAIN}, ${APEX_DOMAIN} {
    tls /certs/${APEX_DOMAIN}.fullchain.pem /certs/${APEX_DOMAIN}.private.key.pem
#    import block_non_en_us
EOF

    # --- Path-to-Subdomain Redirects ---
    local path_redirects
    path_redirects=$(jq -r --arg apex "$APEX_DOMAIN" '[.[$apex].services[]? | ((.redirect_paths? | select(length > 0)) // .hostnames)[] | select(. != "")] | unique | join("|")' "$CONFIG_FILE")
    if [ -n "$path_redirects" ]; then
        cat <<EOF

    # Secure Path-to-Subdomain Redirects
    @path_to_subdomain path_regexp ^/(${path_redirects})\$
    redir @path_to_subdomain https://{re.1}.${APEX_DOMAIN}
EOF
    fi

    # --- Service Handlers ---
    echo
    echo "    # --- Service Handlers (sorted by IP address) ---"
    local services
    services=$(jq -r --arg apex "$APEX_DOMAIN" '.[$apex].services | keys[]?' "$CONFIG_FILE")
    
    for service in $services; do
        local service_json
        service_json=$(jq -c --arg apex "$APEX_DOMAIN" --arg svc "$service" '.[$apex].services[$svc]' "$CONFIG_FILE")
        
        local host_list
        host_list=$(jq -r --arg apex_domain ".${APEX_DOMAIN}" '.hostnames | map(. + $apex_domain) | join(" ")' <<< "$service_json")
        local custom_handler
        custom_handler=$(jq -r '.custom_handler // ""' <<< "$service_json")

        if [ -n "$custom_handler" ]; then
            cat <<EOF

    # Custom handler for ${service}
    @${service} host ${host_list}
    handle @${service} {
$(indent_block "$custom_handler" 2)
    }
EOF
        else
            # Reconstruct the full proxy address from the structured object
            local protocol
            protocol=$(jq -r '.proxy_target.protocol // ""' <<< "$service_json")
            local host_address
            host_address=$(jq -r '.proxy_target.host_address // ""' <<< "$service_json")
            local port
            port=$(jq -r '.proxy_target.port // ""' <<< "$service_json")
            
            local full_proxy_address="${protocol}${host_address}"
            if [ -n "$port" ]; then
                full_proxy_address+=":${port}"
            fi

            local mixin_name
            mixin_name=$(jq -r '.proxy_mixin // ""' <<< "$service_json")
            
#    import proxy_service ${full_proxy_address} ${service}.${APEX_DOMAIN} "${mixin_name}" ${host_list}
            cat <<EOF

$(indent_block  "@${service} host ${host_list}" 1)
$(indent_block "handle @${service} {" 1)
$(indent_block "reverse_proxy ${full_proxy_address} {" 2)
EOF
            if [ -n "$mixin_name" ]; then
                cat <<EOF
$(indent_block "import ${mixin_name}" 3)
EOF
            fi
            cat <<EOF
$(indent_block "}" 2)
$(indent_block "}" 1)
EOF
        fi
    done

    # --- Fallback Handler ---
    local custom_fallback_content
    custom_fallback_content=$(jq -r --arg apex "$APEX_DOMAIN" '.[$apex].fallback_handler // ""' "$CONFIG_FILE")
    create_fallback_handler "$APEX_DOMAIN" "$custom_fallback_content"

    # --- Main Block End ---
    echo "}"
}

# --- Main Execution Loop ---
while IFS= read -r apex_domain; do
    if [ -z "$apex_domain" ]; then continue; fi

    echo "▶️  Generating configuration for ${apex_domain}..."
    output_sitefile="${OUTPUT_FILENAME_TEMPLATE/\{apex_domain\}/$apex_domain}"
    
    generate_content_for_apex "$apex_domain" > "$output_sitefile"
    
    echo "✅ Self-contained apex block successfully created at '$output_sitefile'"
done < <(jq -r 'keys[]' "$CONFIG_FILE")

echo "🎉 All configurations generated successfully."
echo "ℹ️  Remember to update your main Caddyfile to import the generated files as needed."

