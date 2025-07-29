#!/bin/bash

# common.sh - Shared functions for fixture scripts

# Get available configurations
get_configs() {
  local fixtures_dir="$1"
  find "$fixtures_dir" -maxdepth 1 -type d \
    ! -name ".*" \
    ! -name "fixtures" \
    ! -name "bin" \
    ! -path "$fixtures_dir" \
    -exec basename {} \; | sort
}

# Validate config exists
validate_config() {
  local fixtures_dir="$1"
  local config="$2"

  if [[ ! -d "$fixtures_dir/$config" ]]; then
    echo "Error: Configuration '$config' not found in fixtures/"
    echo "Available configs:"
    get_configs "$fixtures_dir" | while read -r c; do
      echo "  • $c"
    done
    return 1
  fi
  return 0
}

# Interactive config selection
select_config() {
  local fixtures_dir="$1"

  if command -v fzf >/dev/null 2>&1; then
    get_configs "$fixtures_dir" | fzf --prompt="Neovim Configs > " --height=~50% --layout=reverse --border --exit-0
  else
    echo "Available configs:"
    get_configs "$fixtures_dir" | while read -r config; do
      echo "  • $config"
    done
    echo -n "Select config: "
    read -r config
    echo "$config"
  fi
}
