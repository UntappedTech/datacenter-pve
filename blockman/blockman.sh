#!/bin/sh
# blockman.sh — Manage named shell script blocks in config files.
# Supports insertion, removal, appending, transformation, and extraction of named blocks.
# Logs all actions to /var/log/blockman/<flattened-filename>.log and outputs diffs by default.

VERSION="1.0.0"

# Exit Codes
SUCCESS=0
ERR_GENERAL=1
ERR_INVALID_ARG=2
ERR_FILE_NOT_FOUND=3
ERR_PERMISSION_DENIED=4
ERR_BLOCK_NOT_FOUND=5
# ERR_BLOCK_EXISTS=6 # Less likely to be used given current replace/append logic
ERR_BLOCK_INTEGRITY=7
ERR_TRANSFORM_FAILED=8
ERR_LOGGING=9

# Function to get error message based on code
get_error_message() {
  case "$1" in
    "$SUCCESS") echo "Operation completed successfully." ;;
    "$ERR_GENERAL") echo "A general or unspecified error occurred." ;;
    "$ERR_INVALID_ARG") echo "Invalid argument or usage error." ;;
    "$ERR_FILE_NOT_FOUND") echo "Input file does not exist." ;;
    "$ERR_PERMISSION_DENIED") echo "Permission denied." ;;
    "$ERR_BLOCK_NOT_FOUND") echo "Block not found for operation." ;;
    "$ERR_BLOCK_INTEGRITY") echo "Block integrity check failed." ;;
    "$ERR_TRANSFORM_FAILED") echo "Transform command failed." ;;
    "$ERR_LOGGING") echo "Logging operation failed." ;;
    *) echo "Unknown error code." ;;
  esac
}

# Global variables for enforcing system-level settings (do NOT modify directly outside load_config)
_SYSTEM_SYSLOG_ENABLED=""
_SYSTEM_LOG_BASE_DIR=""
_SYSTEM_LOG_FORMAT=""

# Default values for configurable aspects (can be overridden by environment variables and configs)
: "${START_KEYWORDS:=START|BEGIN|HEAD}"
: "${END_KEYWORDS:=END|FINISH|TAIL}"
: "${BLOCKMAN_USER_CONFIG:=$HOME/.config/blockman.conf}"
: "${BLOCKMAN_COMMENT_CHAR:=#}" # Default comment character, can be overridden
: "${BLOCKMAN_LOG_BASE_DIR:=/var/log/blockman}" # Default log directory, can be overridden
: "${LOG_FORMAT:=plain}" # Default log format, can be overridden by --format
: "${ENABLE_SYSLOG:=0}" # Enable syslog integration (0 for disabled, 1 for enabled)

export START_KEYWORDS END_KEYWORDS

# Assign final paths and comment character based on defaults and potential overrides
DEFAULT_CONFIG="/etc/default/blockman" # System-wide default config path (not overridable by env var)
USER_CONFIG="$BLOCKMAN_USER_CONFIG"    # User-specific config path (overridable by env var)
COMMENT_CHAR="$BLOCKMAN_COMMENT_CHAR"
LOG_BASE_DIR="$BLOCKMAN_LOG_BASE_DIR"
# LOG_FORMAT and ENABLE_SYSLOG are handled later based on final precedence logic

# Global variables for script context
CURRENT_USER=$(whoami) # Get current effective username

# Helper function for consistent error output and exit codes
exit_with_error() {
  local code="$1"
  local specific_context_message="$2"
  local generic_message=$(get_error_message "$code")

  local final_message="$generic_message"
  if [ -n "$specific_context_message" ]; then
    final_message="$final_message: $specific_context_message"
  fi

  echo "Error ($code): $final_message" >&2
  exit "$code"
}

# Load configuration files
load_config() {
  # First, source system-wide config if it exists, and capture "locked" variables.
  # This is done in a subshell to avoid affecting current shell state with other variables,
  # and only the specific "locked" variables are extracted using eval.
  if [ -f "$DEFAULT_CONFIG" ]; then
    eval "$(
      (
        . "$DEFAULT_CONFIG" 2>/dev/null || true # Source, suppress errors, continue if malformed
        [ -n "${ENABLE_SYSLOG+x}" ] && echo "_SYSTEM_SYSLOG_ENABLED=\"$ENABLE_SYSLOG\""
        [ -n "${BLOCKMAN_LOG_BASE_DIR+x}" ] && echo "_SYSTEM_LOG_BASE_DIR=\"$BLOCKMAN_LOG_BASE_DIR\""
        [ -n "${LOG_FORMAT+x}" ] && echo "_SYSTEM_LOG_FORMAT=\"$LOG_FORMAT\""
      )
    )"
  fi

  # Now, source configs normally. This will set variables based on precedence
  # (system config first, then user config) which will then be overridden by CLI,
  # and finally by the system-level locks if present.
  [ -f "$DEFAULT_CONFIG" ] && . "$DEFAULT_CONFIG"
  [ -f "$USER_CONFIG" ] && . "$USER_CONFIG"
}

# Escape special characters in a string to make it safe for regex matching
escape_regex() {
  printf "%s" "$1" | sed 's/[][\\.*^$(){}?+|/]/\\\\&/g'
}

# Build a regex pattern to match the start and end of a named block
build_block_regex() {
  block_id="$1"
  keywords="$2"
  escaped_id=$(escape_regex "$block_id")
  # Use COMMENT_CHAR and escape it for regex
  escaped_comment_char=$(escape_regex "$COMMENT_CHAR")
  printf "^${escaped_comment_char} *(${keywords})[[:space:]]+${escaped_id}|${escaped_id}[[:space:]]+(${keywords}).*$"
}

# Remove a named block from a file
remove_block() {
  sed -E "/$1/,/$2/d" "$3"
}

# Write a named block to a file
write_block() {
  # Use COMMENT_CHAR
  printf "%s BEGIN %s\n%s\n%s END %s\n" "$COMMENT_CHAR" "$1" "$2" "$COMMENT_CHAR" "$1"
}

# Extract the content of a named block from a file
# Returns 0 if block markers found (even if content is empty), 1 if markers not found.
extract_block_content() {
  local start_re="$1"
  local end_re="$2"
  local file="$3"
  awk -v start_re="$start_re" -v end_re="$end_re" '
    BEGIN { in_block = 0; content_found = 0; }
    $0 ~ start_re { in_block = 1; content_found = 1; next }
    $0 ~ end_re   { in_block = 0; exit } # Exit after end marker, as content is complete
    in_block      { print }
    END { if (content_found == 0) exit 1; } # Signal if block markers never found
  ' "$file"
}


# Flatten a file path to make it safe for use in log filenames
flatten_path() {
  printf "%s" "$1" | sed 's|/|_|g' # Changed __ to _
}

# Escape a string for safe use in shell commands
escape_shell() {
  printf "%s" "$1" | sed "s/'/'\\'/g; s/^/'/; s/\$/'/"
}

# Escape a string for safe use in JSON
escape_json() {
  printf "%s" "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\\"/g' \
    -e ':a;N;$!ba;s/\n/\\n/g' \
    -e 's/\t/\\t/g' \
    -e 's/\r/\\r/g' \
    -e 's/^/"/; s/$/"/'
}

# Log an action to a file and optionally syslog
log_action() {
  log_path="$LOG_BASE_DIR/$(flatten_path "$file").log"
  # Attempt to create log directory, return ERR_LOGGING on failure (warn, don't exit)
  if ! mkdir -p "$(dirname "$log_path")" 2>/dev/null; then
    echo "Warning: Could not create log directory '$LOG_BASE_DIR' for '$log_path'." >&2
    return "$ERR_LOGGING"
  fi

  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  action="$1"
  block_id="$2"
  after="$3"
  before="$4"
  transform_cmd="$5"

  local log_message_summary="blockman: User '$CURRENT_USER' $action block '$block_id' in '$file'"

  # Calculate diff_txt for both plain and JSON logs if relevant
  local diff_txt=""
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    tmp1=$(mktemp)
    tmp2=$(mktemp)
    printf "%s\n" "$before" > "$tmp1"
    printf "%s\n" "$after" > "$tmp2"
    diff_txt=$(diff -u "$tmp1" "$tmp2")
    rm -f "$tmp1" "$tmp2"
  fi

  # Construct the nested JSON object for content changes
  local content_changes_json="{ \"before\": $(escape_json "$before"), \"after\": $(escape_json "$after")"
  if [ -n "$diff_txt" ]; then
    content_changes_json="${content_changes_json}, \"diff_output\": $(escape_json "$diff_txt")"
  fi
  content_changes_json="${content_changes_json} }"


  if [ "$LOG_FORMAT" = "json" ]; then
    printf "{ \"timestamp\": \"%s\", \"user\": \"%s\", \"action\": \"%s\", \"block_id\": \"%s\", \"file\": \"%s\", \"content_changes\": %s, \"transform\": %s }\n" \
      "$timestamp" "$CURRENT_USER" "$action" "$block_id" "$(escape_json "$file")" "$content_changes_json" "$(escape_json "$transform_cmd")" >> "$log_path"
  else
    printf "[%s] User: %s - %s block '%s' in file '%s'\n" "$timestamp" "$CURRENT_USER" "$action" "$block_id" "$file" >> "$log_path"
    [ -n "$transform_cmd" ] && printf ">>> pipeline: %s\n" "$transform_cmd" >> "$log_path"
    [ -n "$before" ] && printf ">>> before: %s\n" "$before" >> "$log_path"
    [ -n "$after" ] && printf ">>> after: %s\n" "$after" >> "$log_path"

    # Use the already calculated diff_txt
    if [ -n "$diff_txt" ]; then
      printf ">>> diff: %s\n" "$diff_txt" >> "$log_path"
    fi
    printf "\n" >> "$log_path"
  fi

  if [ "$ENABLE_SYSLOG" = "1" ]; then
    command -v logger >/dev/null 2>&1 && logger -t blockman "$log_message_summary" || \
    echo "Warning: logger command not found, cannot send to syslog." >&2
  fi
}

# Finalize changes to a file
finalize_file() {
  if cmp -s "$file" "$tmpfile"; then
    [ "$dry_run" = 1 ] && cat "$tmpfile"
    return "$SUCCESS"
  fi

  if [ "$suppress_diff" != 1 ]; then
    tmp1=$(mktemp)
    tmp2=$(mktemp)
    cp "$file" "$tmp1"
    cp "$tmpfile" "$tmp2"
    diff_txt=$(diff -u "$tmp1" "$tmp2")
    printf "%s" "$diff_txt" | sed \
      -e 's/^-/\\x1b[31m&\\x1b[0m/' \
      -e 's/^+/\\x1b[32m&\\x1b[0m/' \
      -e 's/^@.*/\\x1b[36m&\\x1b[0m/'
    rm -f "$tmp1" "$tmp2"
  fi

  [ "$dry_run" = 1 ] || mv "$tmpfile" "$file"
  return "$SUCCESS"
}

# Show the content of a named block
# This function does not exit on block not found; it returns empty string and exit 1
# if block markers were not found. Callers should check its output/status if block presence is critical.
show_block() {
  extract_block_content "$start_re" "$end_re" "$file"
}

# Extract and remove a named block from a file
extract_block() {
  local captured_content
  # Check if block exists first
  if ! grep -Eq "$start_re" "$file"; then
    exit_with_error "$ERR_BLOCK_NOT_FOUND" "Block '$block_id' not found in file '$file' for extraction."
  fi
  captured_content=$(show_block) # This will get the content, or empty if only markers exist
  local show_status=$?

  echo "$captured_content" # Output content to stdout
  remove_block "$start_re" "$end_re" "$file" > "$tmpfile"
  finalize_file "$tmpfile"
  log_action "extract" "$block_id" "" "$captured_content" # 'after' is empty for extract
  exit "$SUCCESS"
}

# Transform the content of a named block
transform_block() {
  local before
  local after
  
  # Check if block exists first
  if ! grep -Eq "$start_re" "$file"; then
    exit_with_error "$ERR_BLOCK_NOT_FOUND" "Block '$block_id' not found in file '$file' for transformation."
  fi

  before=$(show_block)
  
  # Use a subshell to capture exit code of the pipeline
  if ! after=$(printf "%s" "$before" | eval "$transforms"); then
    exit_with_error "$ERR_TRANSFORM_FAILED" "Transform command failed (pipeline: '$transforms')."
  fi

  remove_block "$start_re" "$end_re" "$file" > "$tmpfile"
  write_block "$block_id" "$after" >> "$tmpfile"
  finalize_file "$tmpfile"
  log_action "transform" "$block_id" "$after" "$before" "$transforms"
  exit "$SUCCESS"
}

# --- CLI parsing ---
# Parse command-line arguments and initialize variables
input_file=""
block_id=""
body_chunks=""
append_flags=""
next_append=0
show=0
extract=0
list_blocks=0
check_blocks=0

dry_run=0
transforms=""
suppress_diff=0

# Use the global TMP_DIR for temporary files
tmpfile="$(mktemp /tmp/blockman.XXXXXXXXXX)"
cleanup() { [ -f "$tmpfile" ] && rm -f "$tmpfile"; }
trap cleanup EXIT INT TERM

load_config # Load config files first, then CLI args will override (before final policy enforcement)

# Temporary variable to capture CLI --format, then apply to global LOG_FORMAT
log_format_cli=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file|--in|--inFile|-s)
      input_file="$2"; shift 2 ;;
    --body|--content|--block|-b|-c)
      body_chunks="${body_chunks}__SEP__$(cat <<EOF
$2
EOF
)"; append_flags="${append_flags}__SEP__${next_append}"; next_append=0; shift 2 ;;
    --contentFile|--blockFile|--bodyFile)
      body_chunks="${body_chunks}__SEP__$(cat "$2")"; append_flags="${append_flags}__SEP__${next_append}"; next_append=0; shift 2 ;;
    --append|-a)
      next_append=1; shift ;;
    --transform)
      transforms="${transforms:+$transforms | }$2"; shift 2 ;;
    --show|--list) show=1; shift ;;
    --extract) extract=1; shift ;;
    --check) check_blocks=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --format) log_format_cli="$2"; shift 2 ;; # Store CLI format temporarily
    --comment-prefix|--prefix) COMMENT_CHAR="$2"; shift 2 ;; # CLI argument overrides COMMENT_CHAR
    --version) echo "blockman $VERSION"; exit "$SUCCESS" ;;
    --help|-h|'-?') echo "Usage: blockman [--file FILE] [--body STR|--contentFile FILE] [--append] ..."; exit "$SUCCESS" ;;
    *) [ -z "$block_id" ] && block_id="$1" || exit_with_error "$ERR_INVALID_ARG" "Unexpected argument: $1"; shift ;;
  esac
done

# Apply CLI format override to global LOG_FORMAT after all arguments are parsed
if [ -n "$log_format_cli" ]; then
  LOG_FORMAT="$log_format_cli"
fi

# --- Enforce System-Level Policy Overrides (final step for specific variables) ---
if [ -n "$_SYSTEM_SYSLOG_ENABLED" ]; then
  ENABLE_SYSLOG="$_SYSTEM_SYSLOG_ENABLED"
fi

if [ -n "$_SYSTEM_LOG_BASE_DIR" ]; then
  BLOCKMAN_LOG_BASE_DIR="$_SYSTEM_LOG_BASE_DIR"
  LOG_BASE_DIR="$BLOCKMAN_LOG_BASE_DIR" # Ensure this variable is updated too
fi

if [ -n "$_SYSTEM_LOG_FORMAT" ]; then
  LOG_FORMAT="$_SYSTEM_LOG_FORMAT"
fi
# --- End of Policy Enforcement ---

# Validate required arguments and file access
[ -z "$input_file" ] && exit_with_error "$ERR_INVALID_ARG" "--file is required."
file="$input_file"

# --- File Access Checks ---
if [ ! -f "$file" ]; then
  exit_with_error "$ERR_FILE_NOT_FOUND" "Input file '$file' does not exist."
fi

if [ ! -r "$file" ]; then
  exit_with_error "$ERR_PERMISSION_DENIED" "No read permission for input file '$file'."
fi

# Check write permission if any modification operations are requested
if [ -n "$body_chunks" ] || [ -n "$transforms" ] || [ "$extract" = 1 ]; then
  if [ ! -w "$file" ]; then
    exit_with_error "$ERR_PERMISSION_DENIED" "No write permission for input file '$file'. Cannot modify."
  fi
fi
# --- End of File Access Checks ---

# Default block_id from filename if omitted
if [ -z "$block_id" ]; then
  case "$(basename "$file")" in
    .?*rc|.?*profile)
      block_id=$(basename "$file" | sed 's/^\.//' | awk '{print toupper($1)}')RC_D ;;
    *) exit_with_error "$ERR_INVALID_ARG" "block_id required for non-*rc files." ;;
  esac
fi

# Build regex patterns for the start and end of the block
start_re=$(build_block_regex "$block_id" "$START_KEYWORDS")
end_re=$(build_block_regex "$block_id" "$END_KEYWORDS")

# List all block IDs
if [ "$list_blocks" = 1 ]; then
  # Extract IDs based on the dynamic COMMENT_CHAR and START_KEYWORDS
  grep -E "^$(escape_regex "$COMMENT_CHAR") *(${START_KEYWORDS})[[:space:]]+" "$file" | \
  sed -E "s/^$(escape_regex "$COMMENT_CHAR") *(${START_KEYWORDS})[[:space:]]+(.*)$/\3/"
  exit "$SUCCESS"
fi

# Check for block integrity
if [ "$check_blocks" = 1 ]; then
  if ! awk -v start_re="$start_re" -v end_re="$end_re" \
            -v block_id_awk="$block_id" -v file_awk="$file" '
    BEGIN { in_block = 0; }
    $0 ~ start_re {
      if (in_block == 1) { print "Error: Nested or duplicate start marker for block '" block_id_awk "' in file '" file_awk "'." > "/dev/stderr"; exit 2; }
      in_block = 1;
      next;
    }
    $0 ~ end_re {
      if (in_block == 0) { print "Error: End marker for block '" block_id_awk "' found without a preceding start marker in file '" file_awk "'." > "/dev/stderr"; exit 3; }
      in_block = 0;
      next;
    }
    END {
      if (in_block == 1) { print "Error: Unclosed block detected for block '" block_id_awk "' in file '" file_awk "'." > "/dev/stderr"; exit 4; }
    }
  ' "$file"; then
    awk_exit_code=$?
    case "$awk_exit_code" in
      2) exit_with_error "$ERR_BLOCK_INTEGRITY" "Nested or duplicate start marker detected for block '$block_id' in file '$file'." ;;
      3) exit_with_error "$ERR_BLOCK_INTEGRITY" "End marker for block '$block_id' found without a preceding start marker in file '$file'." ;;
      4) exit_with_error "$ERR_BLOCK_INTEGRITY" "Unclosed block detected for block '$block_id' in file '$file'." ;;
      *) exit_with_error "$ERR_GENERAL" "An unexpected error occurred during block integrity check ($awk_exit_code)." ;; # Fallback for other awk errors
    esac
  fi
  exit "$SUCCESS"
fi

# Show
if [ "$show" = 1 ]; then show_block; exit "$SUCCESS"; fi

# Extract
if [ "$extract" = 1 ]; then extract_block; fi

# Transform
if [ -n "$transforms" ]; then transform_block; fi

# Apply/appends
if [ -n "$body_chunks" ]; then
  IFS="__SEP__" read -r _chunk $body_chunks
  IFS="__SEP__" read -r _flag $append_flags
  i=0
  for chunk in $body_chunks; do
    flag=$(echo "$append_flags" | cut -d'__SEP__' -f$((i+2)))
    if grep -Eq "$start_re" "$file"; then
      if [ "$flag" = "1" ]; then
        # Append the new content to the existing block
        before=$(show_block)
        after="$before\n$chunk"
        remove_block "$start_re" "$end_re" "$file" > "$tmpfile"
        write_block "$block_id" "$after" >> "$tmpfile"
        finalize_file "$tmpfile"
        log_action "append" "$block_id" "$after" "$before"
      else
        # Replace the existing block with new content
        before=$(show_block)
        after="$chunk"
        remove_block "$start_re" "$end_re" "$file" > "$tmpfile"
        write_block "$block_id" "$after" >> "$tmpfile"
        finalize_file "$tmpfile"
        log_action "replace" "$block_id" "$after" "$before"
      fi
    else
      # Create a new block if it doesn't exist
      write_block "$block_id" "$chunk" >> "$tmpfile"
      finalize_file "$tmpfile"
      log_action "create" "$block_id" "$chunk" ""
    fi
    i=$((i+1))
  done
  exit "$SUCCESS"
fi

# If no operation specified, show help and exit with general error
exit_with_error "$ERR_INVALID_ARG" "No operation specified. Use --help for usage."

# Packaging files for RPM and DEB (These are typically part of a build process, not the runtime script)
# They remain commented out as they are not executed during normal script operation.
generate_rpm_spec_file() {
  cat <<EOF
Name: blockman
Version: 1.0.0
Release: 1%{?dist}
Summary: Manage named shell script blocks in config files
License: MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch

%description
Blockman is a shell script for managing named blocks in configuration files.

%prep
%setup -q

%install
mkdir -p %{buildroot}/usr/bin
install -m 755 blockman.sh %{buildroot}/usr/bin/blockman
mkdir -p %{buildroot}/etc/bash_completion.d
install -m 644 blockman.sh %{buildroot}/etc/bash_completion.d/blockman.sh

%files
/usr/bin/blockman
/etc/bash_completion.d/blockman.sh

%changelog
EOF
}

generate_deb_control_file() {
  cat <<EOF
Package: blockman
Version: 1.0.0
Section: utils
Priority: optional
Architecture: all
Depends: bash
Maintainer: Your Name <you@example.com>
Description: Manage named shell script blocks in config files
EOF
}

generate_readme_file() {
  cat <<EOF
# Blockman

Blockman is a shell script for managing named blocks in configuration files.

## Features
- Insert, remove, append, transform, and extract named blocks
- Logs actions to /var/log/blockman
- Supports shell completions for Bash, Zsh, and Fish

## Installation
- For Bash: Copy blockman.sh to /usr/bin and install completions to /etc/bash_completion.d
- For Zsh: Copy blockman.sh to /usr/bin and install completions to /usr/local/share/zsh/site-functions
- For Fish: Copy blockman.sh to /usr/bin and install completions to ~/.config/fish/completions

## Usage
Run \`blockman.sh --help\` for detailed usage instructions.
EOF
}
