.PHONY: check format test clean

# Default target
all: format check test

# Check for syntax errors
check:
	@echo "Checking Lua files for syntax errors..."
	nix develop .#ci -c find lua -name "*.lua" -type f -exec lua -e "assert(loadfile('{}'))" \;
	@echo "Running luacheck..."
	nix develop .#ci -c luacheck lua/ tests/ --no-unused-args --no-max-line-length

# Format all files
format:
	nix fmt

# Run tests
test:
	@echo "Running tests..."
	@./run_tests.sh

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	@rm -f luacov.report.out luacov.stats.out
	@rm -f tests/lcov.info

# Print available commands
help:
	@echo "Available commands:"
	@echo "  make check  - Check for syntax errors"
	@echo "  make format - Format all files (uses nix fmt or stylua)"
	@echo "  make test   - Run tests"
	@echo "  make clean  - Clean generated files"
	@echo "  make help   - Print this help message"
