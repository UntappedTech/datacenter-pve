#!/bin/bash

# ──────────────────────────────────────────────────────────────────────────────
# Caddyfile Generator (JSON + jq + array-based handlers)
#
# This script reads a JSON configuration describing apex domains, services,
# handlers, and redirect rules, then generates a complete Caddyfile for each
# apex domain. It is designed for:
#   - Deterministic output
#   - Safe JSON parsing via jq
#   - Array-based handler blocks (no multiline string issues)
#   - Strict indentation via indent_block()
#
# Output files are written to:
#   /etc/caddy/conf.d/<apex>.site
#
# Usage:
#   ./create_sites.sh
#   ./create_sites.sh /path/to/sites.json
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

CADDY_CONF_DIR="/etc/caddy"
DEFAULT_CONFIG_FILE="${CADDY_CONF_DIR}/sites.json"
OUTPUT_FILENAME_TEMPLATE="${CADDY_CONF_DIR}/conf.d/{apex_domain}.site"
LOG_SNIPPET="slog"


# ──────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ──────────────────────────────────────────────────────────────────────────────

# indent_block(content, level)
# --------------------------------
# Indents each line of a block by N indentation levels (4 spaces each).
# This ensures consistent formatting throughout generated Caddyfiles.
#
# Arguments:
#   $1 - content (string or multi-line)
#   $2 - indentation level (integer)
indent_block() {
    local content="$1"
    local level="$2"
    local indent
    indent=$(printf '%*s' $((level * 4)) '')

    while IFS= read -r line; do
        printf '%s%s\n' "$indent" "$line"
    done <<< "$content"
}

# check_for_collisions(file)
# --------------------------------
# Ensures no hostname (apex or subdomain) appears more than once across all
# active, enabled configuration blocks. This prevents Caddy from rejecting the configuration.
#
# Extracts:
#   - Apex domains
#   - Active service hostnames expanded to FQDNs
check_for_collisions() {
    local file="$1"
    echo "🔍 Verifying hostname integrity..."

    local all_hosts
    all_hosts=$(jq -r '
        .[] as $blk |
        $blk.domains[] as $d |
        (
            $d,
            ($blk.services[]? | select(.enabled != false) | .hostnames[]? | select(. != $d) | . + "." + $d)
        )
    ' "$file")

    local dups
    dups=$(echo "$all_hosts" | sort | uniq -d)

    if [[ -n "$dups" ]]; then
        echo "❌ Collision Error: Duplicate hostnames detected:" >&2
        echo "$dups" | sed 's|^|  - |' >&2
        exit 1
    fi

    echo "✅ Integrity check passed."
}

# sort_config_file(file)
# --------------------------------
# Sorts services inside each block by:
#   1. IP address (numerically)
#   2. Port number
#   3. Key name (alphabetically) - guarantees stable ordering for static handlers
#
# This ensures deterministic output and reduces diff noise.
# This implementation categorizes and sorts host types safely:
#   - Class 1: IPv4 addresses (sorted numerically)
#   - Class 2: IPv6 addresses (sorted alphabetically)
#   - Class 3: DNS Hostnames (sorted alphabetically)
sort_config_file() {
    local file="$1"
    echo "🔄 Sorting services by network address..."

    local sort_cmd='
        map(
            if .services then
                .services |= (
                    to_entries
                    | sort_by(
                        (
                            .value.proxy_target.host_address // ""
                            | if (contains(".") and test("^[0-9.]+$")) then
                                [1] + (split(".") | map(try tonumber catch 0))
                              elif contains(":") then
                                [2, .]
                              else
                                [3, .]
                              end
                        )
                        + [(.value.proxy_target.port // "0" | try tonumber catch 0)]
                        + [.key]
                    )
                    | from_entries
                )
            else . end
        )
    '

    local tmp
    tmp=$(mktemp)

    if jq --indent 4 "$sort_cmd" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        echo "❌ Sorting failed; original file preserved." >&2
        rm -f "$tmp"
        exit 1
    fi
}


# ──────────────────────────────────────────────────────────────────────────────
# Generator Functions
# ──────────────────────────────────────────────────────────────────────────────

# generate_redirect_block(domain, target)
# --------------------------------
# Generates a redirect-only Caddyfile block for domains that forward to another.
# Includes:
#   - Apex redirect
#   - Wildcard redirect using {labels.0}
generate_redirect_block() {
    local DOMAIN="$1"
    local TARGET="$2"

    cat <<EOF
# Wildcard Redirect Configuration
# ${DOMAIN} -> ${TARGET}

${DOMAIN}, *.${DOMAIN} {
    tls /certs/${DOMAIN}.fullchain.pem /certs/${DOMAIN}.private.key.pem

    @subdomain host *.${DOMAIN}
    handle @subdomain {
$(indent_block "redir https://{labels.2}.${TARGET}{uri}" 2)
$(indent_block "}" 1)

    handle {
$(indent_block "redir https://${TARGET}{uri}" 2)
$(indent_block "}" 1)
}
EOF
}

# generate_site_block(site_json, apex_domain)
# --------------------------------
# Generates a full Caddyfile site block for a domain with services.
# Handles:
#   - TLS
#   - Path-to-subdomain redirects
#   - Custom handlers (array-based)
#   - Reverse proxy handlers
#   - Dynamic Root Imports
#   - Fallback handler
generate_site_block() {
    local SITE_JSON="$1"
    local APEX_DOMAIN="$2"

    cat <<EOF
# Generated Site Configuration for: ${APEX_DOMAIN}
# Generated on: $(date)

*.${APEX_DOMAIN}, ${APEX_DOMAIN} {
    tls /certs/${APEX_DOMAIN}.fullchain.pem /certs/${APEX_DOMAIN}.private.key.pem
EOF

    # Build regex for path-based redirects (only pulling from active/enabled services)
    local path_regex
    path_regex=$(echo "$SITE_JSON" | jq -r '
        [.services[]? |
            select(.enabled != false) |
            ((.redirect_paths? | select(length > 0)) // .hostnames)[] |
            select(. != "")
        ] | unique | join("|")
    ')

    if [[ -n "$path_regex" ]]; then
        echo
        indent_block "@path_to_subdomain path_regexp ^/(${path_regex})(/.*)?\$" 1
        indent_block "redir @path_to_subdomain https://{re.1}.${APEX_DOMAIN}{re.2}" 1
    fi

    # Iterate through services
    local services
    services=$(echo "$SITE_JSON" | jq -r '.services // {} | keys[]?')

    for service in $services; do
        local svc_cfg
        svc_cfg=$(echo "$SITE_JSON" | jq -c --arg svc "$service" '.services[$svc]')

        # Skip generating service block if explicitly disabled (safe from jq boolean coercion)
        local enabled
        enabled=$(echo "$svc_cfg" | jq -r '.enabled != false')
        if [[ "$enabled" == "false" ]]; then
            continue
        fi

        # Check if log is enabled (defaults to true; safe from jq boolean coercion)
        local service_log
        service_log=$(echo "$svc_cfg" | jq -r '.log != false')

        local host_list
        host_list=$(echo "$svc_cfg" | jq -r --arg apex ".${APEX_DOMAIN}" '.hostnames | map(. + $apex) | join(" ")')

        local handler_lines
        handler_lines=$(echo "$svc_cfg" | jq -r '.handler[]?')

        local svc_imports
        svc_imports=$(echo "$svc_cfg" | jq -r '.import[]?')

        # Assemble log line if logging is requested (maps cleanly to service.domain log outputs)
        local log_line=""
        if [[ "$service_log" == "true" ]]; then
            log_line="import ${LOG_SNIPPET} ${service}.${APEX_DOMAIN}"
        fi

        # Inspect if a proxy_target configuration object exists
        local has_proxy
        has_proxy=$(echo "$svc_cfg" | jq -r 'if .proxy_target then "true" else "false" end')

        # Case A: Reverse Proxy routing configuration is present
        if [[ "$has_proxy" == "true" ]]; then
            local proto addr port
            proto=$(echo "$svc_cfg" | jq -r '.proxy_target.protocol // "http://"')
            addr=$(echo "$svc_cfg" | jq -r '.proxy_target.host_address // ""')
            port=$(echo "$svc_cfg" | jq -r '.proxy_target.port // empty')

            # Strip existing square brackets if they were already pre-wrapped in the config file
            local clean_addr="${addr#[}"
            clean_addr="${clean_addr%]}"

            # Handle IPv6 Addresses safely: always wrap in brackets if the address contains colons (IPv6)
            local full_proxy
            if [[ "$clean_addr" =~ : ]]; then
                full_proxy="${proto}[${clean_addr}]${port:+:$port}"
            else
                full_proxy="${proto}${clean_addr}${port:+:$port}"
            fi

            echo
            indent_block "@${service} host ${host_list}" 1
            if [[ -n "$log_line" ]]; then
                indent_block "$log_line" 1
            fi
            indent_block "handle @${service} {" 1

            # Cleanly render single-line proxy or block mapping depending on snippet inclusion
            if [[ -n "$svc_imports" ]]; then
                indent_block "reverse_proxy ${full_proxy} {" 2
                while IFS= read -r snippet; do
                    if [[ -n "$snippet" ]]; then
                        indent_block "import $snippet" 3
                    fi
                done <<< "$svc_imports"
                indent_block "}" 2
            else
                indent_block "reverse_proxy ${full_proxy}" 2
            fi

            indent_block "}" 1

        # Case B: Custom Handlers and/or Snippet Imports are used (No proxy directive present)
        else
            echo
            indent_block "@${service} host ${host_list}" 1
            if [[ -n "$log_line" ]]; then
                indent_block "$log_line" 1
            fi
            indent_block "handle @${service} {" 1

            # Print service-level snippet imports inside the handle block if defined
            if [[ -n "$svc_imports" ]]; then
                while IFS= read -r snippet; do
                    if [[ -n "$snippet" ]]; then
                        indent_block "import $snippet" 2
                    fi
                done <<< "$svc_imports"
            fi

            # Print custom handler lines inside the handle block if defined
            if [[ -n "$handler_lines" ]]; then
                while IFS= read -r line; do
                    indent_block "$line" 2
                done <<< "$handler_lines"
            fi

            indent_block "}" 1
        fi
    done

    # Print root-level domain imports (positioned safely before the fallback block)
    local root_log
    root_log=$(echo "$SITE_JSON" | jq -r '.log != false')

    local root_imports
    root_imports=$(echo "$SITE_JSON" | jq -r '.import[]?')

    # Only print a single spacing newline if we have root logging or custom imports
    if [[ "$root_log" == "true" || -n "$root_imports" ]]; then
        echo
    fi

    if [[ "$root_log" == "true" ]]; then
        indent_block "import ${LOG_SNIPPET} ${APEX_DOMAIN}" 1
    fi

    if [[ -n "$root_imports" ]]; then
        while IFS= read -r snippet; do
            if [[ -n "$snippet" ]]; then
                indent_block "import $snippet" 1
            fi
        done <<< "$root_imports"
    fi

    # Fallback handler
    indent_block "handle {" 1

    local fallback_lines
    fallback_lines=$(echo "$SITE_JSON" | jq -r '.fallback_handler[]?')

    if [[ -n "$fallback_lines" ]]; then
        while IFS= read -r line; do
            indent_block "$line" 2
        done <<< "$fallback_lines"
    else
        indent_block "redir https://home.${APEX_DOMAIN}" 2
    fi

    indent_block "}" 1
    indent_block "}" 0
}


# ──────────────────────────────────────────────────────────────────────────────
# Execution
# ──────────────────────────────────────────────────────────────────────────────

CONFIG_FILE="${1:-$DEFAULT_CONFIG_FILE}"

# Validate file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Error: Config file not found."
    exit 1
fi

# Validate JSON syntax
jq -e . "$CONFIG_FILE" >/dev/null || {
    echo "❌ Invalid JSON in config file."
    exit 1
}

check_for_collisions "$CONFIG_FILE"
sort_config_file "$CONFIG_FILE"

# Read each top-level block
readarray -t blocks < <(jq -c '.[]' "$CONFIG_FILE")

# Generate configurations directly to production paths safely via atomic swap
for block in "${blocks[@]}"; do
    readarray -t domains < <(jq -r '.domains[]' <<< "$block")
    target=$(jq -r '.redirect_to // empty' <<< "$block")

    for domain in "${domains[@]}"; do
        echo "▶️  Generating: ${domain}"
        output_file="${OUTPUT_FILENAME_TEMPLATE/\{apex_domain\}/$domain}"
        mkdir -p "$(dirname "$output_file")"

        tmp_output="${output_file}.tmp"
        if [[ -n "$target" ]]; then
            generate_redirect_block "$domain" "$target" > "$tmp_output"
        else
            generate_site_block "$block" "$domain" > "$tmp_output"
        fi

        mv "$tmp_output" "$output_file"
    done
done

echo "🎉 All configurations generated and verified."