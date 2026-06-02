#!/bin/bash
set -euo pipefail

# Ensure the feature-installed mise is on PATH for this script.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
if ! command -v mise &>/dev/null; then
  echo "Error: mise is not on PATH after the devcontainer feature install" >&2
  exit 1
fi

# Build deps: PUC Lua builds from source, and the test rocks compile C modules.
sudo apt-get -o Acquire::Retries=3 update
sudo apt-get -o Acquire::Retries=3 install -y build-essential libreadline-dev unzip

# Activate mise in interactive shells (puts the toolchain + fixtures/bin on PATH).
if ! grep -qs 'mise activate bash' "$HOME/.bashrc"; then
  echo 'eval "$(mise activate bash)"' >>"$HOME/.bashrc"
fi

echo ""
echo "📦 Provisioning the claudecode.nvim development environment with mise..."

mise trust
mise install
mise run setup

echo ""
echo "✅ claudecode.nvim development environment ready."
echo "   mise run all      # full validation (format, lint, test)"
echo "   mise run test     # run tests"
echo "   mise run check    # lint"
echo "   mise run format   # format"
echo "   mise tasks        # list all tasks"
