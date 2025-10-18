#!/bin/bash

# ==============================================================================
# Git Auto-Commit Script for Arbitrary Files
#
# Description:
# This script monitors a specific list of files (defined in a separate file)
# for changes. When a change is detected in any of the watched files, it
# copies the changed file into a central Git repository, preserving its
# original directory structure, and then creates a commit.
#
# This is ideal for tracking changes to scattered configuration files across
# a system (e.g., /etc/nginx/nginx.conf, /opt/app/config.yml).
#
# Dependencies:
# - git: The version control system.
# - inotify-tools: For `inotifywait`.
#
# Usage:
# 1. Create a file to list the files you want to track, e.g., `files-to-track.txt`.
#    Each full path should be on a new line:
#    /etc/nginx/nginx.conf
#    /etc/samba/smb.conf
#    /opt/custom_path/config_file.env
#
# 2. Save this script as `track-files.sh` and make it executable:
#    `chmod +x track-files.sh`
#
# 3. Run the script, providing the path to your central Git repository and
#    the path to your list of files:
#    `./track-files.sh /path/to/central/repo /path/to/files-to-track.txt`
#
# Note:
# The script runs in an infinite loop. To stop it, press Ctrl+C.
# ==============================================================================

# --- Configuration and Validation ---

CENTRAL_REPO_PATH="$1"
FILE_LIST_PATH="$2"

if [ -z "$CENTRAL_REPO_PATH" ] || [ -z "$FILE_LIST_PATH" ]; then
  echo "Error: Missing arguments."
  echo "Usage: $0 <path_to_central_repo> <path_to_file_list>"
  exit 1
fi

if [ ! -f "$FILE_LIST_PATH" ]; then
  echo "Error: File list '$FILE_LIST_PATH' not found."
  exit 1
fi

if ! command -v inotifywait &> /dev/null; then
    echo "Error: 'inotifywait' not found. Please install inotify-tools."
    exit 1
fi

# --- Git and Repo Initialization ---

# Create the central repository directory if it doesn't exist.
mkdir -p "$CENTRAL_REPO_PATH"
cd "$CENTRAL_REPO_PATH" || exit

# Initialize Git repo if it's not already one.
if [ ! -d ".git" ]; then
  echo "Initializing Git repository in '$CENTRAL_REPO_PATH'..."
  git init
  # Create a .gitignore to ignore the file list if it's placed inside the repo
  echo "$(basename "$FILE_LIST_PATH")" > .gitignore
  git add .gitignore
  git commit -m "Initial commit: Repository setup"
fi

# --- Initial Sync ---
echo "Performing initial sync of all tracked files..."
INITIAL_CHANGES=0
while IFS= read -r FILE_TO_TRACK || [[ -n "$FILE_TO_TRACK" ]]; do
    if [ -z "$FILE_TO_TRACK" ]; then continue; fi # Skip empty lines

    if [ -f "$FILE_TO_TRACK" ]; then
        # Destination path inside the repo, preserving the original structure.
        # Note: We remove the leading '/' to make it a relative path.
        DEST_PATH_IN_REPO="${FILE_TO_TRACK:1}"
        DEST_DIR=$(dirname "$DEST_PATH_IN_REPO")

        echo "Syncing: $FILE_TO_TRACK"
        mkdir -p "$DEST_DIR"
        cp "$FILE_TO_TRACK" "$DEST_PATH_IN_REPO"
        git add "$DEST_PATH_IN_REPO"
    else
        echo "Warning: File '$FILE_TO_TRACK' not found during initial sync. Skipping."
    fi
done < "$FILE_LIST_PATH"

if [ -n "$(git status --porcelain)" ]; then
    git commit -m "Initial sync of tracked files"
    echo "✅ Initial sync committed."
else
    echo "No changes detected during initial sync. Repository is up to date."
fi
echo "----------------------------------------"


# --- Main Monitoring Loop ---

# Read the list of files into an array for inotifywait
mapfile -t FILES_TO_WATCH < "$FILE_LIST_PATH"

echo "👀 Watching for file changes... Press Ctrl+C to stop."
echo ""

# Monitor the specific list of files for modifications.
# The `modify` event is often sufficient for config file changes.
# Use `--format '%w'` to get the path of the file that changed.
inotifywait -m -e modify --format '%w' "${FILES_TO_WATCH[@]}" | while read -r CHANGED_FILE; do
    echo "----------------------------------------"
    echo "Change detected: MODIFY on $CHANGED_FILE"
    echo "Timestamp: $(date)"

    # The destination path inside the repo, removing the leading '/'
    DEST_PATH_IN_REPO="${CHANGED_FILE:1}"
    DEST_DIR=$(dirname "$DEST_PATH_IN_REPO")

    # Ensure the directory structure exists in the repo
    mkdir -p "$DEST_DIR"

    # Copy the modified file into the central repo
    cp "$CHANGED_FILE" "$DEST_PATH_IN_REPO"
    echo "Copied '$CHANGED_FILE' to '$CENTRAL_REPO_PATH/$DEST_PATH_IN_REPO'"

    # Stage the change
    git add "$DEST_PATH_IN_REPO"

    # Commit the change
    COMMIT_MESSAGE="Auto-commit: Update $CHANGED_FILE"
    echo "Committing with message: '$COMMIT_MESSAGE'"
    git commit -m "$COMMIT_MESSAGE"
    echo "✅ Commit successful."
    echo "----------------------------------------"
    echo ""
    echo "👀 Watching for file changes..."
done
