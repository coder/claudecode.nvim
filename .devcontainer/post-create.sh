#!/bin/bash

# Source Nix environment
. /home/vscode/.nix-profile/etc/profile.d/nix.sh

# Verify Nix is available
if ! command -v nix &>/dev/null; then
  echo "Error: Nix is not installed properly"
  exit 1
fi

echo "✅ Nix is installed and available"
echo ""
echo "📦 claudecode.nvim Development Container Ready!"
echo ""
echo "To enter the development shell with all dependencies, run:"
echo "  nix develop"
echo ""
echo "This will provide:"
echo "  - Neovim"
echo "  - Lua and LuaJIT"
echo "  - busted (test framework)"
echo "  - luacheck (linter)"
echo "  - stylua (formatter)"
echo "  - All other development tools"
echo ""
echo "You can also run development commands directly:"
echo "  - make        # Run full validation (format, lint, test)"
echo "  - make test   # Run tests"
echo "  - make check  # Run linter"
echo "  - make format # Format code"
