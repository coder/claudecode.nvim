.PHONY: check format test test-cov clean help

# Default target
all: format check test

# Detect if the required dev tools are already available; otherwise run via Nix.
ifeq (,$(shell command -v busted >/dev/null 2>&1 && command -v luacheck >/dev/null 2>&1 && echo ok))
NIX_PREFIX := nix develop .\#ci -c
else
NIX_PREFIX :=
endif

# Check for syntax errors
check:
	@echo "Checking Lua files for syntax errors..."
	$(NIX_PREFIX) find lua -name "*.lua" -type f -exec lua -e "assert(loadfile('{}'))" \;
	@echo "Running luacheck..."
	$(NIX_PREFIX) luacheck lua/ tests/ --no-unused-args --no-max-line-length

# Format all files
format:
	nix fmt

# Run tests (fast, no coverage)
test:
	@echo "Running all tests (no coverage)..."
	@TEST_FILES=$$(find tests -type f \( -name "*_test.lua" -o -name "*_spec.lua" \) | sort); \
	if [ -n "$$TEST_FILES" ]; then \
		$(NIX_PREFIX) sh -c 'export LUA_PATH="./lua/?.lua;./lua/?/init.lua;./?.lua;./?/init.lua;$$LUA_PATH"; busted -v "$$@"' -- $$TEST_FILES; \
	else \
		echo "No test files found"; \
	fi

# Run tests with coverage
# (Generates luacov.stats.out and luacov.report.out)
test-cov:
	@echo "Running all tests with coverage..."
	@TEST_FILES=$$(find tests -type f \( -name "*_test.lua" -o -name "*_spec.lua" \) | sort); \
	if [ -n "$$TEST_FILES" ]; then \
		$(NIX_PREFIX) sh -c 'export LUA_PATH="./lua/?.lua;./lua/?/init.lua;./?.lua;./?/init.lua;$$LUA_PATH"; busted --coverage -v "$$@"' -- $$TEST_FILES; \
		$(NIX_PREFIX) luacov; \
	else \
		echo "No test files found"; \
	fi

# Clean generated files
clean:
	@echo "Cleaning generated files..."
	@rm -f luacov.report.out luacov.stats.out
	@rm -f lcov.info tests/lcov.info

# Print available commands
help:
	@echo "Available commands:"
	@echo "  make check     - Check for syntax errors"
	@echo "  make format    - Format all files (uses nix fmt or stylua)"
	@echo "  make test      - Run tests (fast, no coverage)"
	@echo "  make test-cov  - Run tests with coverage (luacov)"
	@echo "  make clean     - Clean generated files"
	@echo "  make help      - Print this help message"
