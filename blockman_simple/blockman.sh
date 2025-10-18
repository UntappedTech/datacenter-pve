#!/bin/sh
# blockman.sh — Manage named shell script blocks in config files.
# Supports insertion, removal, appending, transformation, and extraction of named blocks.
# Logs all actions and outputs diffs by default.

# --- Configuration ---
VERSION="1.8.0"
: "${START_KEYWORDS:=START|BEGIN|HEAD}"
: "${END_KEYWORDS:=END|FINISH|TAIL}"
: "${LOG_DIR:=/var/log/blockman}"
: "${TMPDIR:=/tmp}"

# Default configuration file paths
DEFAULT_CONFIG="/etc/default/blockman"
USER_CONFIG="$HOME/.config/blockman/blockman.conf"

# Load configuration files if they exist
if [ -f "$DEFAULT_CONFIG" ]; then . "$DEFAULT_CONFIG"; fi
if [ -f "$USER_CONFIG" ]; then . "$USER_CONFIG"; fi

# --- Utility Functions ---

# Print an error message and exit.
err() {
  printf "Error: %s\n" "$1" >&2
  exit "${2:-1}"
}

# Escape special characters in a string for use in a sed basic regex.
escape_regex() {
  printf '%s' "$1" | sed 's/[][\\.*^$]/\\&/g'
}

# Build a regex pattern to match the start or end of a named block.
build_block_regex() {
  comment_char="$1"
  block_id="$2"
  keywords="$3"
  escaped_comment=$(escape_regex "$comment_char")
  escaped_id=$(escape_regex "$block_id")
  printf "%s" "${escaped_comment}[[:space:]]*\\(${keywords}\\)[[:space:]]\\{1,\\}${escaped_id}"
}

# Find the start and end line numbers of a block.
# Sets global variables: start_line, end_line
find_block_markers() {
    _file="$1"
    _comment_char="$2"
    _block_id="$3"

    start_re=$(build_block_regex "$_comment_char" "$_block_id" "$START_KEYWORDS")
    end_re=$(build_block_regex "$_comment_char" "$_block_id" "$END_KEYWORDS")

    start_line=$(sed -n "/${start_re}/=" "$_file" | head -1)
    end_line=$(sed -n "/${end_re}/=" "$_file" | head -1)
}

# Log an action to the appropriate log file.
log_action() {
  target_file="$1"
  action="$2"
  block_id="$3"
  diff_content="$4"
  transform_cmd="$5"

  log_file="$LOG_DIR/$(printf '%s' "$target_file" | sed 's|/|__|g').log"
  mkdir -p "$LOG_DIR" 2>/dev/null || err "Cannot create log directory: $LOG_DIR"

  {
    printf "timestamp=%s action=%s block_id='%s'\n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$action" "$block_id"
    if [ -n "$transform_cmd" ]; then
      printf "pipeline: %s\n" "$transform_cmd"
    fi
    if [ -n "$diff_content" ]; then
      printf "diff:\n---\n%s\n---\n" "$diff_content"
    fi
  } >> "$log_file"
}

# Convert the log file associated with a target file to JSON.
blockman_convert_log_to_json() {
  target_file="$1"
  log_file="$LOG_DIR/$(printf '%s' "$target_file" | sed 's|/|__|g').log"

  if ! command -v awk >/dev/null 2>&1; then err "'awk' is required for JSON conversion."; fi
  if ! command -v jq >/dev/null 2>&1; then err "'jq' is required for JSON conversion."; fi
  if [ ! -f "$log_file" ]; then err "Log file not found for '$target_file'."; fi

  # This awk script converts the hybrid log format to a stream of JSON objects.
  # It is designed to be piped into jq.
  awk '
    function escape(s) {
      gsub(/\\/, "\\\\", s);
      gsub(/"/, "\\\"", s);
      return s;
    }
    /^timestamp=/ {
      if (json) { print json "}"; }
      json = "{";
      gsub(/"/, "\\\"", $0);
      sub(/=/, "\":\"", $0);
      json = json "\"" $0;
    }
    /^pipeline:/ {
      sub(/^pipeline: /, "");
      json = json ", \"pipeline\":\"" escape($0) "\"";
    }
    /^diff:/ { in_diff = 1; diff = ""; }
    in_diff && /^---$/ { next; }
    in_diff { diff = diff $0 "\\n"; }
    !in_diff && /^---$/ {
      in_diff = 0;
      json = json ", \"diff\":\"" escape(diff) "\"";
    }
    END { if (json) { print json "}"; } }
  ' "$log_file" | jq -s '.'
}

# Show usage information.
usage() {
  printf "Usage: %s --file FILE [options] [--id BLOCK_ID]\n" "$0"
  printf "Options:\n"
  printf "  -b, --body STR          Content to write into the block.\n"
  printf "  -B, --body-file FILE    Read content from a file.\n"
  printf "  -a, --append            Append content instead of replacing.\n"
  printf "  -n, --no-clobber        Do not overwrite an existing block.\n"
  printf "  -t, --transform CMD     Transform block content with a shell command.\n"
  printf "  -x, --extract           Print block content and remove it from the file.\n"
  printf "  -l, --list              List all block IDs in the file.\n"
  printf "  -s, --show              Show the content of a specific block (requires --id).\n"
  printf "  --to-json               Convert this file's log to JSON and print to stdout.\n"
  printf "  --comment-char CHAR     Character for block comments (default: #).\n"
  printf "  --dry-run               Print result to stdout instead of modifying file.\n"
  printf "  --no-diff               Do not output a diff of changes.\n"
  printf "  -h, --help              Show this help message.\n"
  printf "  -v, --version           Show version information.\n"
}

# --- Main Execution Function ---
main() {
  # Initialize variables
  file=""
  block_id=""
  body=""
  append=0
  no_clobber=0
  transform=""
  extract=0
  list_action=0
  show_action=0
  to_json_action=0
  dry_run=0
  no_diff=0
  comment_char="#"

  # Parse command-line arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="$2"; shift 2 ;;
      --id) block_id="$2"; shift 2 ;;
      -b|--body) body="$2"; shift 2 ;;
      -B|--body-file) body=$(cat -- "$2"); shift 2 ;;
      -a|--append) append=1; shift ;;
      -n|--no-clobber) no_clobber=1; shift ;;
      -t|--transform) transform="$2"; shift 2 ;;
      -x|--extract) extract=1; shift ;;
      -l|--list) list_action=1; shift ;;
      -s|--show) show_action=1; shift ;;
      --to-json) to_json_action=1; shift ;;
      --comment-char) comment_char="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --no-diff) no_diff=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) printf "blockman %s\n" "$VERSION"; exit 0 ;;
      *) err "Unknown argument: $1" ;;
    esac
  done

  # Validate required arguments
  if [ -z "$file" ]; then err "--file is required."; fi
  if ! [ -f "$file" ] && [ "$to_json_action" -ne 1 ]; then err "File not found: $file"; fi

  # Handle --to-json action
  if [ "$to_json_action" = 1 ]; then
    blockman_convert_log_to_json "$file"
    exit 0
  fi

  # Handle --list action (list all block IDs)
  if [ "$list_action" = 1 ]; then
    escaped_comment=$(escape_regex "$comment_char")
    sed -n "s/^${escaped_comment}[[:space:]]*\\(${START_KEYWORDS}\\)[[:space:]]\\{1,\\}\\([^[:space:]]\\{1,\\}\\).*/\\2/p" "$file" | sort -u
    exit 0
  fi

  # Handle --show action (show content of one block)
  if [ "$show_action" = 1 ]; then
    if [ -z "$block_id" ]; then err "--id is required for --show."; fi
    find_block_markers "$file" "$comment_char" "$block_id"
    if [ -z "$start_line" ]; then err "Block '$block_id' not found in $file."; fi
    if [ -z "$end_line" ]; then err "Block '$block_id' is malformed (missing END marker)."; fi
    sed -n "$((start_line + 1)),$((end_line - 1))p" "$file"
    exit 0
  fi

  # If we are here, it's a modification action. All modifications require an ID.
  if [ -z "$block_id" ]; then err "--id is required for this action."; fi

  # Setup temporary file and cleanup trap
  tmpfile="$TMPDIR/blockman.$$.tmp"
  trap 'rm -f "$tmpfile"' EXIT

  # Find the block and get its content
  find_block_markers "$file" "$comment_char" "$block_id"
  original_content=""
  if [ -n "$start_line" ]; then
    if [ -z "$end_line" ]; then err "Block '$block_id' is malformed (missing END marker)."; fi
    
    # Check for --no-clobber before any modification logic
    if [ "$no_clobber" = 1 ] && [ "$extract" -ne 1 ]; then
      printf "Block '%s' already exists, skipping due to --no-clobber.\n" "$block_id" >&2
      exit 0
    fi
    
    original_content=$(sed -n "$((start_line + 1)),$((end_line - 1))p" "$file")
  fi

  # Determine the final content for the block
  final_content="$body"
  action="replace" # Default action

  if [ -n "$transform" ]; then
    action="transform"
    final_content=$(printf "%s\n" "$original_content" | sh -c "$transform")
  elif [ -n "$body" ]; then
    if [ "$append" = 1 ] && [ -n "$start_line" ]; then
      action="append"
      final_content="$original_content
$body"
    elif [ -z "$start_line" ]; then
      action="create"
    fi
  else # No body or transform provided, treat as replace with empty content
      action="replace"
      final_content=""
  fi

  # Handle --extract action
  if [ "$extract" = 1 ]; then
    action="extract"
    printf "%s\n" "$original_content"
    final_content="" # We want to remove the block
  fi

  # If content is unchanged, do nothing.
  if [ "$final_content" = "$original_content" ] && [ "$extract" -ne 1 ]; then
    exit 0
  fi

  # Construct the new file content in the temporary file
  start_marker="$comment_char START $block_id"
  end_marker="$comment_char END $block_id"
  {
    # 1. Write content before the block
    if [ -n "$start_line" ]; then
      sed "1,$((start_line - 1))p;d" "$file"
    else
      cat -- "$file" # If block doesn't exist, copy whole file
      if [ -n "$(tail -c1 "$file")" ]; then printf "\n"; fi
    fi

    # 2. Write the new/modified block, unless it's an extraction of a non-existent block
    if ! { [ "$extract" = 1 ] && [ -z "$start_line" ]; }; then
        printf "%s\n" "$start_marker"
        printf "%s\n" "$final_content"
        printf "%s\n" "$end_marker"
    fi

    # 3. Write content after the block
    if [ -n "$end_line" ]; then
      sed "1,$((end_line))d" "$file"
    fi
  } > "$tmpfile"

  # Finalize changes: calculate diff, log, and replace original file
  diff_output=""
  if [ "$no_diff" != 1 ]; then
    diff_output=$(diff -u "$file" "$tmpfile" || true)
  fi

  log_action "$file" "$action" "$block_id" "$diff_output" "$transform"

  if [ "$dry_run" = 1 ]; then
    cat -- "$tmpfile"
    if [ "$no_diff" != 1 ] && [ -n "$diff_output" ]; then
        printf "\n--- Diff ---\n%s\n" "$diff_output" >&2
    fi
  else
    if [ "$no_diff" != 1 ] && [ -n "$diff_output" ]; then
      printf '%s\n' "$diff_output" | sed -e 's/^-/\\033[31m&\\033[0m/' -e 's/^+/\\033[32m&\\033[0m/' -e 's/^@/\\033[36m&\\033[0m/'
    fi
    mv "$tmpfile" "$file"
  fi

  exit 0
}

# Call the main function with all script arguments
main "$@"
