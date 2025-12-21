#!/bin/bash
# ssh-setup.sh - Configure SSH connection reuse to minimize rate-limiting
#
# This script sets up SSH ControlMaster for connection multiplexing.
# Multiple SSH commands will reuse the same connection, reducing rate-limiting.
#
# Usage: Source this script in your SSH-using scripts:
#   source "$(dirname "$0")/../ssh-setup.sh" || source "$(dirname "$0")/ssh-setup.sh"
#   # ... then use ssh/scp normally ...
#   cleanup_ssh_connection  # Call this at the end

# Setup SSH control socket directory
SSH_CONTROL_DIR="${SSH_CONTROL_DIR:-$HOME/.ssh/control}"
mkdir -p "$SSH_CONTROL_DIR"

# Enable SSH connection multiplexing via environment
# This makes all ssh/scp commands in this script session reuse a single connection
export SSH_CONTROL_PATH="$SSH_CONTROL_DIR/%r@%h:%p"

# Update SSH command to use ControlMaster
# Note: We use ControlMaster=auto which reuses existing connections or creates new ones
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh}"
export SSH_OPTIONS="-o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH -o ControlPersist=300"

# Wrapper function that adds our SSH options
ssh() {
    command ssh $SSH_OPTIONS "$@"
}

scp() {
    command scp $SSH_OPTIONS "$@"
}

# Export the functions so they're available to the calling script
export -f ssh
export -f scp

# Cleanup function to close the master connection
cleanup_ssh_connection() {
    if [ -n "$REMOTE_HOST" ]; then
        # Check if any control socket exists for this host
        # Use find to safely check without glob expansion issues
        # Note: REMOTE_HOST is from .env (trusted input)
        local socket_count
        socket_count=$(find "$SSH_CONTROL_DIR" -maxdepth 1 -type s -name "*${REMOTE_HOST}*" 2>/dev/null | wc -l)
        
        if [ "$socket_count" -gt 0 ]; then
            command ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" "$REMOTE_HOST" 2>/dev/null || true
        fi
    fi
}

# Register cleanup on script exit
trap cleanup_ssh_connection EXIT
