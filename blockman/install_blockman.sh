#!/bin/sh
# install-blockman.sh - Installer for blockman.sh default configurations and shell completions

VERSION="1.0.0"

# Exit Codes
SUCCESS=0
ERR_GENERAL=1
ERR_INVALID_ARG=2
ERR_PERMISSION_DENIED=3
ERR_SHELL_DETECT_FAILED=4
ERR_INSTALL_PATH=5

# Function to get error message based on code
get_error_message() {
  case "$1" in
    "$SUCCESS") echo "Operation completed successfully." ;;
    "$ERR_GENERAL") echo "A general or unspecified error occurred." ;;
    "$ERR_INVALID_ARG") echo "Invalid argument or usage error." ;;
    "$ERR_PERMISSION_DENIED") echo "Permission denied." ;;
    "$ERR_SHELL_DETECT_FAILED") echo "Shell detection failed or unsupported shell." ;;
    "$ERR_INSTALL_PATH") echo "Installation path issue." ;;
    *) echo "Unknown error code." ;;
  esac
}

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

# Default configuration content for /etc/default/blockman
generate_system_config() {
  cat <<EOF
# System-wide default configuration for blockman
# This file defines global settings for blockman.
# Settings defined here for BLOCKMAN_LOG_BASE_DIR, LOG_FORMAT, and ENABLE_SYSLOG
# will override any user-specific settings or command-line arguments.

# Example: Default comment character (typically '#')
# BLOCKMAN_COMMENT_CHAR="#"

# Example: Base directory for log files (default: /var/log/blockman)
# BLOCKMAN_LOG_BASE_DIR="/var/log/blockman"

# Example: Default log format (plain or json)
# LOG_FORMAT="plain"

# Example: Enable syslog integration (0=disabled, 1=enabled). Requires 'logger' command.
# ENABLE_SYSLOG="0"

# Example: Keywords for block start markers (pipe-separated)
# START_KEYWORDS="START|BEGIN|HEAD"

# Example: Keywords for block end markers (pipe-separated)
# END_KEYWORDS="END|FINISH|TAIL"
EOF
}

# Default configuration content for ~/.config/blockman.conf
generate_user_config() {
  cat <<EOF
# User-specific configuration for blockman
# Settings here override system-wide defaults, unless they are policy-enforced
# (BLOCKMAN_LOG_BASE_DIR, LOG_FORMAT, ENABLE_SYSLOG if set in /etc/default/blockman).

# Example: Custom comment character
# BLOCKMAN_COMMENT_CHAR="//"

# Example: Custom log base directory (will be ignored if set in /etc/default/blockman)
# BLOCKMAN_LOG_BASE_DIR="$HOME/.blockman_logs"

# Example: Custom log format (will be ignored if set in /etc/default/blockman)
# LOG_FORMAT="json"

# Example: Enable syslog (will be ignored if set in /etc/default/blockman)
# ENABLE_SYSLOG="1"

# Example: Custom block start keywords
# START_KEYWORDS="MYSTART|ENTRY"

# Example: Custom block end keywords
# END_KEYWORDS="MYEND|EXIT"
EOF
}

# Bash completion script content
generate_bash_completion() {
  cat <<EOF
# Bash completion for blockman
_blockman_completion() {
    local cur prev opts
    COMPREPLY=()
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"

    opts="--file --body --contentFile --append --transform --show --list --extract --check --dry-run --format --comment-prefix --version --help"

    case "\${prev}" in
        --file|-s)
            _filedir
            return 0
            ;;
        --body|--content|--block|-b|-c)
            # No completion for direct string content
            return 0
            ;;
        --contentFile|--blockFile|--bodyFile)
            _filedir
            return 0
            ;;
        --transform)
            # Offer common shell commands for transformation
            COMPREPLY=( \$(compgen -c "\${cur}") )
            return 0
            ;;
        --format)
            COMPREPLY=( \$(compgen -W "plain json" "\${cur}") )
            return 0
            ;;
        --comment-prefix)
            # Suggest common comment prefixes
            COMPREPLY=( \$(compgen -W "# // -- ;" "\${cur}") )
            return 0
            ;;
        *)
            ;;
    esac

    # Main options and block_id
    COMPREPLY=( \$(compgen -W "\${opts}" "\${cur}") )

    # If no option or completion specified, and cur is empty,
    # suggest block_id or file paths based on context.
    # This part is simplified and might need more advanced logic for real block IDs.
    if [[ "\${cur}" == "" ]]; then
      # If no options, suggest possible block_ids (placeholder)
      # This would ideally read existing block_ids from a file if possible
      # For now, just a generic suggestion if no other option matches
      COMPREPLY+=( "example_block_id" )
    fi
    return 0
}
complete -F _blockman_completion blockman.sh
complete -F _blockman_completion blockman
EOF
}

# Zsh completion script content
generate_zsh_completion() {
  cat <<EOF
#compdef blockman blockman.sh

_blockman() {
    local -a -U comp
    local cur context state line

    _arguments \\
        '(-s --file --in --inFile)'{-s,--file,--in,--inFile}=filename[file to operate on]:file:_files \\
        '(-b --body --content --block -c)'{-b,--body,--content,--block,-c}=body[content for the block] \\
        '(--contentFile --blockFile --bodyFile)'{--contentFile,--blockFile,--bodyFile}=content_file[file containing block content]:file:_files \\
        '(-a --append)'{-a,--append}'[append content to existing block]' \\
        '--transform[command to transform block content]:command:_command_names' \\
        '(--show --list)'{--show,--list}'[display block content]' \\
        '--extract[extract and remove block]' \\
        '--check[check block integrity]' \\
        '--dry-run[perform dry run]' \\
        '--format[log output format]:format:(plain json)' \\
        '--comment-prefix[custom comment prefix]:prefix:(# // -- ;)' \\
        '--version[show version]' \\
        '--help[show help]' \\
        "*:block_id[unique block identifier]"
}

_blockman "$@"
EOF
}

# Fish completion script content
generate_fish_completion() {
  cat <<EOF
# Fish completion for blockman
complete -c blockman -s s -l file -l in -l inFile -r -f -a "(__fish_complete_directories; __fish_complete_files)" -d "Specify input file"
complete -c blockman -s b -l body -l content -l block -s c -d "Provide content directly"
complete -c blockman -l contentFile -l blockFile -l bodyFile -r -f -a "(pwd)" -d "Provide content from file"
complete -c blockman -s a -l append -d "Append content to existing block"
complete -c blockman -l transform -d "Apply shell command to block content"
complete -c blockman -l show -d "Display block content"
complete -c blockman -l list -d "List all block IDs"
complete -c blockman -l extract -d "Extract and remove block"
complete -c blockman -l check -d "Check block integrity"
complete -c blockman -l dry-run -d "Perform dry run"
complete -c blockman -l format -f -a "plain json" -d "Specify log output format"
complete -c blockman -l comment-prefix -f -a "# // -- ;" -d "Custom comment prefix"
complete -c blockman -l version -d "Display version"
complete -c blockman -l help -d "Display help"
complete -c blockman -a '(__fish_complete_subcommands)' -d "Block ID"
EOF
}


# --- Installation Functions ---

install_configs() {
  local system_config_path="/etc/default/blockman"
  local user_config_path="$HOME/.config/blockman.conf"

  echo "Installing default configuration files..."

  # Install system-wide config
  if [ -f "$system_config_path" ]; then
    echo "Warning: System-wide config '$system_config_path' already exists. Skipping."
  else
    if ! mkdir -p "$(dirname "$system_config_path")"; then
      exit_with_error "$ERR_PERMISSION_DENIED" "Could not create directory for '$system_config_path'. Run as root for system-wide configs."
    fi
    generate_system_config > "$system_config_path"
    chmod 644 "$system_config_path"
    echo "Installed system-wide config: $system_config_path"
  fi

  # Install user-specific config
  if [ -f "$user_config_path" ]; then
    echo "Warning: User config '$user_config_path' already exists. Skipping."
  else
    if ! mkdir -p "$(dirname "$user_config_path")"; then
      exit_with_error "$ERR_PERMISSION_DENIED" "Could not create directory for '$user_config_path'."
    fi
    generate_user_config > "$user_config_path"
    chmod 644 "$user_config_path"
    echo "Installed user config: $user_config_path"
  fi
}

install_completions() {
  echo "Installing shell completion scripts..."

  local script_name="blockman" # Assuming blockman.sh is linked/aliased to 'blockman'
  local install_dir=""
  local completion_content=""
  local completion_file_name=""
  local completion_path=""

  # Detect current shell
  case "$(basename "$SHELL")" in
    bash)
      completion_file_name="${script_name}.sh"
      completion_content=$(generate_bash_completion)
      install_dir="/etc/bash_completion.d" # Standard system-wide path for bash completions
      echo "Detected Bash. Attempting system-wide installation to $install_dir."
      ;;
    zsh)
      completion_file_name="_${script_name}"
      completion_content=$(generate_zsh_completion)
      install_dir="/usr/local/share/zsh/site-functions" # Standard system-wide path for zsh completions
      echo "Detected Zsh. Attempting system-wide installation to $install_dir."
      ;;
    fish)
      completion_file_name="${script_name}.fish"
      completion_content=$(generate_fish_completion)
      install_dir="$HOME/.config/fish/completions" # Standard user-specific path for fish completions
      echo "Detected Fish. Attempting user-specific installation to $install_dir."
      ;;
    *)
      exit_with_error "$ERR_SHELL_DETECT_FAILED" "Unsupported shell: $SHELL. Cannot install completions."
      ;;
  esac

  completion_path="$install_dir/$completion_file_name"

  if [ -f "$completion_path" ]; then
    echo "Warning: Completion file '$completion_path' already exists. Skipping."
  else
    if ! mkdir -p "$install_dir"; then
      exit_with_error "$ERR_PERMISSION_DENIED" "Could not create installation directory '$install_dir'. Run as root for system-wide paths or check user permissions."
    fi

    # Write completion content to file
    printf "%s\n" "$completion_content" > "$completion_path" || \
      exit_with_error "$ERR_INSTALL_PATH" "Failed to write completion file to '$completion_path'."

    chmod 644 "$completion_path"
    echo "Installed completion for $(basename "$SHELL"): $completion_path"

    # Provide instructions for sourcing (if not automatically sourced by shell)
    case "$(basename "$SHELL")" in
      bash)
        echo "Note: You might need to reload your shell or source this file for completions to take effect."
        echo "      e.g., 'source /etc/bash_completion.d/${script_name}.sh' or 'source ~/.bashrc'"
        ;;
      zsh)
        echo "Note: You might need to reload your shell or run 'autoload -U compinit; compinit' for completions to take effect."
        ;;
      fish)
        echo "Note: Completions should be active on next shell startup. Run 'exec fish' to reload."
        ;;
    esac
  fi
}

uninstall_completions() {
  echo "Uninstalling shell completion scripts (Not yet fully implemented)."
  # Placeholder for future implementation
  # This would need to reverse the logic of install_completions
  # and remove the files from the detected paths.
  exit "$SUCCESS"
}

# --- Main CLI parsing ---
install_configs_flag=0
install_completions_flag=0
uninstall_completions_flag=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install-configs) install_configs_flag=1; shift ;;
    --install-completions) install_completions_flag=1; shift ;;
    --uninstall-completions) uninstall_completions_flag=1; shift ;;
    --help|-h|'-?')
      echo "Usage: ${0} [--install-configs] [--install-completions] [--uninstall-completions]"
      echo "       Helper script to install default blockman configurations and shell completions."
      exit "$SUCCESS"
      ;;
    *) exit_with_error "$ERR_INVALID_ARG" "Unknown option: $1" ;;
  esac
done

# Validate that at least one operation is specified
[ "$install_configs_flag" -eq 0 ] && [ "$install_completions_flag" -eq 0 ] && [ "$uninstall_completions_flag" -eq 0 ] && \
  exit_with_error "$ERR_INVALID_ARG" "No operation specified. Use --help for usage."

# Run operations based on flags
if [ "$install_configs_flag" -eq 1 ]; then
  install_configs
fi

if [ "$install_completions_flag" -eq 1 ]; then
  install_completions
fi

if [ "$uninstall_completions_flag" -eq 1 ]; then
  uninstall_completions
fi

exit "$SUCCESS"
