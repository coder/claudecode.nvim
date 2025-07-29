#!/bin/bash

# Test Neovim configurations with fixture configs
# This script provides aliases that call the executable scripts in bin/

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

# Create aliases that call the bin scripts
# shellcheck disable=SC2139
alias vv="$BIN_DIR/vv"
# shellcheck disable=SC2139
alias vve="$BIN_DIR/vve"
# shellcheck disable=SC2139
alias list-configs="$BIN_DIR/list-configs"

echo "Neovim configuration aliases loaded!"
echo "Use 'vv <config>' or 'vve <config>' to test configurations"
echo "Use 'list-configs' to see available options"
