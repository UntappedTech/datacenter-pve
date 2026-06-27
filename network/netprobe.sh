#!/usr/bin/env bash

# --- BASH SAFETY MODE (no -e so loop continues on failures) ---
set -uo pipefail
# --------------------------------------------------------------

# --- CONFIGURATION ---
TARGET_DOMAINS=(
  "untappedtechnologies.com"
  "untapped.tech"
)
# ---------------------

VERBOSE=false

# Parse flags
for arg in "$@"; do
  case $arg in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
  esac
done

# --- COLOR CONSTANTS ---
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
RESET="\033[0m"

# Disable color automatically when output is piped or redirected
if [ ! -t 1 ]; then
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; RESET=""
fi

# --- LOG FILE ---
# --- SCRIPT NAME DERIVATION ---
SCRIPT_NAME="$(basename "$0")"
SCRIPT_BASE="${SCRIPT_NAME%.*}"

# --- LOG FILE ---
LOG_FILE="/var/log/${SCRIPT_BASE}.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/${SCRIPT_BASE}.log"
# ------------------------------------------------------------

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

# --- LOGGING ENGINE ---
log() {
  # Short‑circuit if not verbose
  [ "${VERBOSE}" = true ] || return 0

  local LEVEL="$1"
  local MSG="$2"
  local COLOR="$RESET"

  case "$LEVEL" in
    INFO) COLOR="$BLUE" ;;
    SUCCESS) COLOR="$GREEN" ;;
    API) COLOR="$CYAN" ;;
    POLL) COLOR="$MAGENTA" ;;
    DEBUG) COLOR="$YELLOW" ;;
  esac

  echo -e "${COLOR}[$(timestamp)] [$LEVEL]${RESET} ${MSG}"
}

err() {
  local MSG="$1"

  # Always print errors to stderr (with color if terminal)
  echo -e "${RED}[$(timestamp)] [CRITICAL]${RESET} ${MSG}" >&2

  # Always log errors to file (no color)
  echo "[$(timestamp)] [CRITICAL] ${MSG}" >> "$LOG_FILE"
}
# ------------------------------------------------------------

GLOBAL_FAILURE_COUNT=0

log INFO "Initializing global network checks for ${#TARGET_DOMAINS[@]} domain(s)..."

for DOMAIN in "${TARGET_DOMAINS[@]}"; do

  log INFO "--------------------------------------------------------"
  log INFO "Starting verification loop for target: ${DOMAIN}"

  # Sanitize domain
  CLEAN_TARGET=$(echo "${DOMAIN}" | sed -e 's|^[^/]*//||' -e 's|/.*||')
  log API "[${DOMAIN}] Testing bare domain endpoint: ${CLEAN_TARGET}"

  # Schedule Globalping measurement
  API_REQUEST=$(curl -s -X POST "https://api.globalping.io/v1/measurements" \
    -H "accept: application/json" \
    -H "content-type: application/json" \
    -d '{"type":"http","target":"'"${CLEAN_TARGET}"'","measurementOptions":{"request":{"method":"GET"},"protocol":"HTTPS"}}')

  MEASUREMENT_ID=$(echo "${API_REQUEST}" \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | head -n1 \
    | cut -d'"' -f4)

  if [ -z "${MEASUREMENT_ID}" ]; then
    err "Failed to communicate with API or schedule test frame for: ${DOMAIN}"
    ((GLOBAL_FAILURE_COUNT++))
    continue
  fi

  log API "[${DOMAIN}] Scheduled test frame successfully. ID: ${MEASUREMENT_ID}"

  # Poll for completion
  MAX_ATTEMPTS=5
  ATTEMPT=0
  JOB_FINISHED=false

  while [ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]; do
    sleep 2
    log POLL "[${DOMAIN}] Checking job status (Attempt $((ATTEMPT + 1))/${MAX_ATTEMPTS})..."

    RESULT_PAYLOAD=$(curl -s "https://api.globalping.io/v1/measurements/${MEASUREMENT_ID}")

    if echo "${RESULT_PAYLOAD}" | grep -q '"status"[[:space:]]*:[[:space:]]*"finished"'; then
      log POLL "[${DOMAIN}] Job complete. Parsing results."
      JOB_FINISHED=true
      break
    fi

    ((ATTEMPT++))
  done

  if [ "${JOB_FINISHED}" = false ]; then
    err "Globalping API timed out waiting for testing probes on: ${DOMAIN}"
    ((GLOBAL_FAILURE_COUNT++))
    continue
  fi

  # Detect Globalping error messages
  if echo "${RESULT_PAYLOAD}" | grep -q '"error"'; then
    ERROR_MSG=$(echo "${RESULT_PAYLOAD}" \
      | grep -oE '"error"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | cut -d'"' -f4)
    err "Globalping error for [${DOMAIN}]: ${ERROR_MSG}"
    ((GLOBAL_FAILURE_COUNT++))
    continue
  fi

  # Extract HTTP status code safely
  HTTP_STATUS=$(echo "${RESULT_PAYLOAD}" \
    | grep -oE '"statusCode"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -n1 \
    | grep -oE '[0-9]+' \
    || echo "UNREACHABLE")

  # Final evaluation
  if [[ "${HTTP_STATUS}" =~ ^(200|30[1|2|7|8]|401)$ ]]; then
    log SUCCESS "[${DOMAIN}] Global node successfully verified domain. HTTP Status: ${HTTP_STATUS}"
  else
    err "External probe failed to verify [${DOMAIN}]. Response Status: ${HTTP_STATUS}"
    ((GLOBAL_FAILURE_COUNT++))
  fi

done

log INFO "--------------------------------------------------------"
log INFO "All network assessment processes completed."

# Exit status
if [ "${GLOBAL_FAILURE_COUNT}" -gt 0 ]; then
  err "Scan completed with ${GLOBAL_FAILURE_COUNT} total unreachable domain failure(s)."
  exit 1
else
  log SUCCESS "All configured domains are fully online and accessible."
  exit 0
fi
