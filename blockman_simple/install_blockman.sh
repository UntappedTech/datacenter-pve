#!/bin/sh
# install.sh for blockman — Installs, uninstalls, and packages the blockman script.

# --- Configuration ---
VERSION="1.8.0"

# System-wide paths (require root)
SYS_INSTALL_DIR="/usr/local/bin"
SYS_CONFIG_DIR="/etc/default"
SYS_BASH_COMPLETION_DIR="/etc/bash_completion.d"
SYS_ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
SYS_TCSH_COMPLETION_DIR="/etc/profile.d"

# User-local paths (no root required)
USER_INSTALL_DIR="$HOME/.local/bin"
USER_CONFIG_DIR="$HOME/.config/blockman"
USER_BASH_COMPLETION_DIR="$HOME/.local/share/bash-completion/completions"
USER_ZSH_COMPLETION_DIR="$HOME/.local/share/zsh/site-functions"
USER_FISH_COMPLETION_DIR="$HOME/.config/fish/completions"

PACKAGING_DIR="./packaging"

# --- Utility Functions ---

# Print an error message and exit.
err() {
  printf "Error: %s\n" "$1" >&2
  exit "${2:-1}"
}

# Check for a command's existence in a POSIX-compliant way.
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# --- Generation Functions ---

generate_default_config() { cat <<'EOF'
# Default configuration for blockman.sh
START_KEYWORDS="START|BEGIN|HEAD"
END_KEYWORDS="END|FINISH|TAIL"
LOG_DIR="/var/log/blockman"
EOF
}
generate_bash_completion() { cat <<'EOF'
_blockman_completions(){local cur prev opts;COMPREPLY=();cur="${COMP_WORDS[COMP_CWORD]}";prev="${COMP_WORDS[COMP_CWORD-1]}";opts="--file --id --body --body-file --append --no-clobber -n --transform --extract --list --show --to-json --no-diff --help --version";case "${prev}" in --file|--body-file)COMPREPLY=($(compgen -f -- "${cur}"));return 0;;--id|--body|--transform)return 0;;esac;if [[ ${cur} == -* ]];then COMPREPLY=($(compgen -W "${opts}" -- ${cur}));fi};complete -F _blockman_completions blockman
EOF
}
generate_zsh_completion() { cat <<'EOF'
#compdef blockman
_arguments \
  '--file[Input file]:_files' \
  '--id[Block identifier]' \
  '--body[Block content string]' \
  '--body-file[File containing block content]:_files' \
  '--append[Append content]' \
  '(-n --no-clobber)'{-n,--no-clobber}'[Do not overwrite existing block]' \
  '--transform[Shell command]' \
  '--extract[Extract block]' \
  '--list[List all block IDs]' \
  '--show[Show a block''s content]' \
  '--to-json[Convert log to JSON]' \
  '--no-diff[Suppress diff output]' \
  '--version[Show version]' \
  '--help[Show help]' \
  '*: :_files'
EOF
}
generate_fish_completion() { cat <<'EOF'
complete -c blockman -l file -d "Input file" -r;complete -c blockman -l id -d "Block identifier";complete -c blockman -l body-file -d "File containing block content" -r;complete -c blockman -l append -d "Append content";complete -c blockman -s n -l no-clobber -d "Do not overwrite existing block";complete -c blockman -l transform -d "Shell command to transform";complete -c blockman -l extract -d "Extract block";complete -c blockman -l list -d "List all block IDs";complete -c blockman -l show -d "Show a block's content";complete -c blockman -l to-json -d "Convert log to JSON"
EOF
}
generate_tcsh_completion() { cat <<'EOF'
if($?tcsh&&$?prompt)then;set _blockman_opts=(--file --id --body --body-file --append --no-clobber -n --transform --extract --list --show --to-json --no-diff --help --version);complete blockman "p/1/(${_blockman_opts})/" "n/--file/f/" "n/--body-file/f/";endif
EOF
}
generate_rpm_spec() { changelog_date=$(date +"%a %b %d %Y"); cat <<EOF
Name: blockman
Version: ${VERSION}
Release: 1%{?dist}
Summary: Manage named blocks in configuration files.
License: MIT
URL: https://github.com/user/blockman
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
Requires: /bin/sh
%description
A POSIX-compliant shell script to manage named blocks within text and config files.
%prep
%setup -q
%install
install -D -m 755 blockman.sh %{buildroot}%{_bindir}/blockman
%files
%{_bindir}/blockman
%changelog
* ${changelog_date} Your Name <you@example.com> - ${VERSION}-1
- Initial RPM release
EOF
}
generate_deb_control() { cat <<EOF
Package: blockman
Version: ${VERSION}
Architecture: all
Maintainer: Your Name <you@example.com>
Description: Manage named blocks in configuration files.
 A POSIX-compliant shell script to manage named blocks within text and config files.
Depends: dash | bash | sh
EOF
}
generate_makefile() { cat <<'EOF'
VERSION := ${VERSION}
PREFIX ?= /usr/local

.PHONY: all help install uninstall clean package

all: help

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install          Install blockman for the current user (~/.local/bin)."
	@echo "  uninstall        Uninstall blockman for the current user."
	@echo "  install-system   Install blockman system-wide (/usr/local/bin). Requires sudo."
	@echo "  uninstall-system Uninstall blockman system-wide. Requires sudo."
	@echo "  package          Generate source tarball and packaging files (RPM/DEB)."
	@echo "  clean            Remove the packaging directory."

install:
	@sh install.sh install --user

install-system:
	@sudo sh install.sh install

uninstall:
	@sh install.sh uninstall --user

uninstall-system:
	@sudo sh install.sh uninstall

package:
	@sh install.sh package

clean:
	@rm -rf ./packaging
EOF
}

# --- Main Actions ---

do_install() {
  install_mode="$1" # "system" or "user"

  if [ "$install_mode" = "system" ]; then
    if [ "$(id -u)" -ne 0 ]; then err "System-wide install must be run as root."; fi
    printf "Performing system-wide installation...\n"
    _INSTALL_DIR="$SYS_INSTALL_DIR"
    _CONFIG_DIR="$SYS_CONFIG_DIR"
    _BASH_DIR="$SYS_BASH_COMPLETION_DIR"
    _ZSH_DIR="$SYS_ZSH_COMPLETION_DIR"
    _TCSH_DIR="$SYS_TCSH_COMPLETION_DIR"
  else
    printf "Performing user-local installation...\n"
    _INSTALL_DIR="$USER_INSTALL_DIR"
    _CONFIG_DIR="$USER_CONFIG_DIR"
    _BASH_DIR="$USER_BASH_COMPLETION_DIR"
    _ZSH_DIR="$USER_ZSH_COMPLETION_DIR"
    _FISH_DIR="$USER_FISH_COMPLETION_DIR"
  fi

  # Install script
  mkdir -p "$_INSTALL_DIR"
  install -m 755 ./blockman.sh "$_INSTALL_DIR/blockman" || err "Failed to install script."
  printf "-> Script installed to %s/blockman\n" "$_INSTALL_DIR"

  # Install config
  if [ "$install_mode" = "system" ]; then
    mkdir -p "$_CONFIG_DIR"
    install -m 644 /dev/null "$_CONFIG_DIR/blockman"
    generate_default_config > "$_CONFIG_DIR/blockman"
    printf "-> System config created at %s/blockman\n" "$_CONFIG_DIR"
  fi

  # Install completions
  printf "Installing shell completions...\n"
  if command_exists bash; then mkdir -p "$_BASH_DIR"; generate_bash_completion > "$_BASH_DIR/blockman"; printf "-> Bash completion installed.\n"; fi
  if command_exists zsh; then mkdir -p "$_ZSH_DIR"; generate_zsh_completion > "$_ZSH_DIR/_blockman"; printf "-> Zsh completion installed.\n"; fi
  if [ "$install_mode" = "system" ] && command_exists tcsh; then mkdir -p "$_TCSH_DIR"; generate_tcsh_completion > "$_TCSH_DIR/blockman.csh"; printf "-> tcsh completion installed.\n"; fi
  if [ "$install_mode" = "user" ] && command_exists fish; then
    printf "-> Fish shell detected. Install user completions to %s? [y/N] " "$_FISH_DIR"
    read -r answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
      mkdir -p "$_FISH_DIR"; generate_fish_completion > "$_FISH_DIR/blockman.fish"; printf "-> Fish completion installed.\n"
    fi
  fi

  printf "\nInstallation finished. Please restart your shell or source your profile.\n"
  if ! command -v blockman >/dev/null 2>&1 && [ "$install_mode" = "user" ]; then
    printf "NOTE: Ensure '%s' is in your PATH.\n" "$USER_INSTALL_DIR"
  fi
}

do_uninstall() {
  uninstall_mode="$1"

  if [ "$uninstall_mode" = "system" ]; then
    if [ "$(id -u)" -ne 0 ]; then err "System-wide uninstall must be run as root."; fi
    printf "Performing system-wide uninstallation...\n"
    rm -f "$SYS_INSTALL_DIR/blockman"
    rm -f "$SYS_CONFIG_DIR/blockman"
    rm -f "$SYS_BASH_COMPLETION_DIR/blockman"
    rm -f "$SYS_ZSH_COMPLETION_DIR/_blockman"
    rm -f "$SYS_TCSH_COMPLETION_DIR/blockman.csh"
  else
    printf "Performing user-local uninstallation...\n"
    rm -f "$USER_INSTALL_DIR/blockman"
    # Note: We don't remove user config files by default.
    rm -f "$USER_BASH_COMPLETION_DIR/blockman"
    rm -f "$USER_ZSH_COMPLETION_DIR/_blockman"
    rm -f "$USER_FISH_COMPLETION_DIR/blockman.fish"
  fi
  printf "Uninstallation finished.\n"
}

do_package() {
  printf "Generating packaging files in %s/...\n" "$PACKAGING_DIR"
  if ! [ -f ./blockman.sh ]; then err "'blockman.sh' not found in the current directory."; fi

  mkdir -p "$PACKAGING_DIR/SOURCES" "$PACKAGING_DIR/SPECS" "$PACKAGING_DIR/DEBIAN"
  tar -czf "$PACKAGING_DIR/SOURCES/blockman-${VERSION}.tar.gz" ./blockman.sh
  printf "-> Source tarball created.\n"
  generate_rpm_spec > "$PACKAGING_DIR/SPECS/blockman.spec" && printf "-> RPM .spec file created.\n"
  generate_deb_control > "$PACKAGING_DIR/DEBIAN/control" && printf "-> DEB control file created.\n"
  generate_makefile > ./Makefile && printf "-> Makefile created.\n"
  printf "\nPackaging files generated.\n"
  printf "To build and install, you can now use 'make'.\n"
}

usage() {
    printf "Usage: %s [command]\n" "$0"
    printf "Commands:\n"
    printf "  install [--user]   Install blockman system-wide (default) or for the current user.\n"
    printf "  uninstall [--user] Uninstall blockman.\n"
    printf "  package            Generate files needed to build RPM and DEB packages.\n"
    printf "  help               Show this help message.\n"
}

# --- Main Dispatcher ---

main() {
  command="${1:-help}"
  user_flag="${2:-}"

  install_mode="system"
  if [ "$user_flag" = "--user" ]; then
    install_mode="user"
  fi

  case "$command" in
    install)
      do_install "$install_mode"
      ;;
    uninstall)
      do_uninstall "$install_mode"
      ;;
    package)
      do_package
      ;;
    *)
      usage
      exit 0
      ;;
  esac
}

main "$@"
exit 0
