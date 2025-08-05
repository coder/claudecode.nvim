# Development Guide

Quick guide for contributors to the claudecode.nvim project.

## Project Structure

```none
claudecode.nvim/
├── .github/workflows/       # CI workflow definitions
├── fixtures/                # Test Neovim configurations for integration testing
│   ├── bin/                 # Helper scripts (vv, vve, list-configs)
│   ├── mini-files/          # Neovim config testing with mini.files
│   ├── netrw/               # Neovim config testing with built-in file explorer
│   ├── nvim-tree/           # Neovim config testing with nvim-tree.lua
│   ├── oil/                 # Neovim config testing with oil.nvim
│   └── nvim-aliases.sh      # Shell aliases for fixture testing
├── lua/claudecode/          # Plugin implementation
│   ├── server/              # WebSocket server implementation
│   ├── tools/               # MCP tool implementations and schema management
│   ├── config.lua           # Configuration management
│   ├── diff.lua             # Diff provider system (native Neovim support)
│   ├── init.lua             # Plugin entry point
│   ├── lockfile.lua         # Lock file management
│   ├── selection.lua        # Selection tracking
│   └── terminal.lua         # Terminal management
├── plugin/                  # Plugin loader
├── tests/                   # Test suite
│   ├── unit/                # Unit tests
│   ├── component/           # Component tests
│   ├── integration/         # Integration tests
│   └── mocks/               # Test mocks
├── README.md                # User documentation
├── ARCHITECTURE.md          # Architecture documentation
└── DEVELOPMENT.md           # Development guide
```

## Core Components Implementation Status

| Component              | Status  | Priority | Notes                                                                |
| ---------------------- | ------- | -------- | -------------------------------------------------------------------- |
| Basic plugin structure | ✅ Done | -        | Initial setup complete                                               |
| Configuration system   | ✅ Done | -        | Support for user configuration                                       |
| WebSocket server       | ✅ Done | -        | Pure Lua RFC 6455 compliant                                          |
| Lock file management   | ✅ Done | -        | Basic implementation complete                                        |
| Selection tracking     | ✅ Done | -        | Enhanced with multi-mode support                                     |
| MCP tools framework    | ✅ Done | -        | Dynamic tool registration and schema system                          |
| Core MCP tools         | ✅ Done | -        | openFile, openDiff, getCurrentSelection, getOpenEditors              |
| Diff integration       | ✅ Done | -        | Native Neovim diff with configurable options                         |
| Terminal integration   | ✅ Done | -        | Snacks.nvim and native terminal support                              |
| Tests                  | ✅ Done | -        | Comprehensive test suite with unit, component, and integration tests |
| CI pipeline            | ✅ Done | -        | GitHub Actions configured                                            |
| Documentation          | ✅ Done | -        | Complete documentation                                               |

## Development Priorities

1. **Advanced MCP Tools**

   - Add Neovim-specific tools (LSP integration, diagnostics, Telescope integration)
   - Implement diffview.nvim integration for the diff provider system
   - Add Git integration tools (branch info, status, etc.)

2. **Performance Optimization**

   - Monitor WebSocket server performance under load
   - Optimize selection tracking for large files
   - Fine-tune debouncing and event handling

3. **User Experience**

   - Add more user commands and keybindings
   - Improve error messages and user feedback
   - Create example configurations for popular setups

4. **Integration Testing**
   - Test with real Claude Code CLI
   - Validate compatibility across Neovim versions
   - Create end-to-end test scenarios

## Testing

Run tests using:

```bash
# Run all tests
make test

# Run specific test file
nvim --headless -u tests/minimal_init.lua -c "lua require('tests.unit.config_spec')"

# Run linting
make check

# Format code
make format
```

## Implementation Guidelines

1. **Error Handling**

   - All public functions should have error handling
   - Return `success, result_or_error` pattern
   - Log meaningful error messages

2. **Performance**

   - Minimize impact on editor performance
   - Debounce event handlers
   - Use asynchronous operations where possible

3. **Compatibility**

   - Support Neovim >= 0.8.0
   - Zero external dependencies (pure Lua implementation)
   - Follow Neovim plugin best practices

4. **Testing**
   - Write tests before implementation (TDD)
   - Aim for high code coverage
   - Mock external dependencies

## Contributing

1. Fork the repository
2. Create a feature branch
3. Implement your changes with tests
4. Run the test suite to ensure all tests pass
5. **For integrations**: Create a fixture configuration for testing
6. Submit a pull request

### Integration Testing with Fixtures

When adding support for new integrations (file explorers, terminals, etc.), you **must** provide a fixture configuration for testing:

**Requirements**:

- Complete Neovim configuration in `fixtures/[integration-name]/`
- Include plugin dependencies and proper setup
- Add `dev-claudecode.lua` with development keybindings
- Test all relevant claudecode.nvim features with the integration

**Usage**:

```bash
# Source fixture aliases
source fixtures/nvim-aliases.sh

# Test with specific integration
vv nvim-tree  # Start Neovim with nvim-tree configuration
vv oil        # Start Neovim with oil.nvim configuration
vv mini-files # Start Neovim with mini.files configuration
vv netrw      # Start Neovim with built-in netrw configuration

# List available configurations
list-configs
```

**Example fixture structure** (`fixtures/my-integration/`):

```
my-integration/
├── init.lua                    # Main Neovim config
├── lua/
│   ├── config/
│   │   └── lazy.lua           # Plugin manager setup
│   └── plugins/
│       ├── dev-claudecode.lua # claudecode.nvim development config
│       ├── init.lua           # Base plugins
│       └── my-integration.lua # Integration-specific plugin config
└── lazy-lock.json             # Plugin lockfile (if using lazy.nvim)
```

## Implementation Details

### WebSocket Server

The WebSocket server is implemented in pure Lua with zero external dependencies:

- **Pure Neovim Implementation**: Uses `vim.loop` (libuv) for TCP operations
- **RFC 6455 Compliant**: Full WebSocket protocol implementation
- **JSON-RPC 2.0**: MCP message handling with proper framing
- **Security**: Pure Lua SHA-1 implementation for WebSocket handshake
- **Performance**: Optimized with lookup tables and efficient algorithms

### MCP Tool System

The plugin implements a sophisticated tool system following MCP 2025-03-26:

**Current Tools:**

- `openFile` - Opens files with optional line/text selection
- `openDiff` - Native Neovim diff views with configurable options
- `getCurrentSelection` - Gets current text selection
- `getOpenEditors` - Lists currently open files

**Tool Architecture:**

- Dynamic registration: `M.register(name, schema, handler)`
- Automatic MCP exposure based on schema presence
- JSON schema validation for parameters
- Centralized tool definitions in `tools/init.lua`

**Future Tools:**

- Neovim-specific diagnostics
- LSP integration (hover, references, definitions)
- Telescope integration for file finding
- Git integration (status, branch info, blame)

## Next Steps

1. Implement diffview.nvim integration for the diff provider system
2. Add advanced MCP tools (LSP integration, Telescope, Git)
3. Add integration tests with real Claude Code CLI
4. Optimize performance for large codebases
5. Create example configurations for popular Neovim setups (LazyVim, NvChad, etc.)
