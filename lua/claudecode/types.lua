---@meta
---@brief [[
--- Centralized type definitions for ClaudeCode.nvim public API.
--- This module contains all user-facing types and configuration structures.
---@brief ]]
---@module 'claudecode.types'

-- Version information type
---@class ClaudeCodeVersion
---@field major integer
---@field minor integer
---@field patch integer
---@field prerelease? string
---@field string fun(self: ClaudeCodeVersion): string

-- Diff behavior configuration
---@class ClaudeCodeDiffOptions
---@field layout ClaudeCodeDiffLayout
---@field open_in_new_tab boolean Open diff in a new tab (false = use current tab)
---@field keep_terminal_focus boolean Keep focus in terminal after opening diff
---@field hide_terminal_in_new_tab boolean Hide Claude terminal in newly created diff tab
---@field on_new_file_reject ClaudeCodeNewFileRejectBehavior Behavior when rejecting a new-file diff

-- Model selection option
---@class ClaudeCodeModelOption
---@field name string
---@field value string

-- Log level type alias
---@alias ClaudeCodeLogLevel "trace"|"debug"|"info"|"warn"|"error"

-- Diff layout type alias
---@alias ClaudeCodeDiffLayout "vertical"|"horizontal"

-- Behavior when rejecting new-file diffs
---@alias ClaudeCodeNewFileRejectBehavior "keep_empty"|"close_window"

-- Terminal split side positioning
---@alias ClaudeCodeSplitSide "left"|"right"

-- In-tree terminal provider names
---@alias ClaudeCodeTerminalProviderName "auto"|"snacks"|"native"|"external"|"none"

-- Terminal provider-specific options
---@class ClaudeCodeTerminalProviderOptions
---@field external_terminal_cmd string|(fun(cmd: string, env: table): string)|table|nil Command for external terminal (string template with %s or function)

-- Working directory resolution context and provider
---@class ClaudeCodeCwdContext
---@field file string|nil   -- absolute path of current buffer file (if any)
---@field file_dir string|nil -- directory of current buffer file (if any)
---@field cwd string        -- current Neovim working directory

---@alias ClaudeCodeCwdProvider fun(ctx: ClaudeCodeCwdContext): string|nil

-- @ mention queued for Claude Code
---@class ClaudeCodeMention
---@field file_path string The absolute file path to mention
---@field start_line number? Optional start line (0-indexed for Claude compatibility)
---@field end_line number? Optional end line (0-indexed for Claude compatibility)
---@field timestamp number Creation timestamp from vim.loop.now() for expiry tracking

-- Terminal provider interface
---@class ClaudeCodeTerminalProvider
---@field setup fun(config: ClaudeCodeTerminalConfig)
---@field open fun(cmd_string: string, env_table: table, config: ClaudeCodeTerminalConfig, focus: boolean?)
---@field close fun()
---@field toggle fun(cmd_string: string, env_table: table, effective_config: ClaudeCodeTerminalConfig)
---@field simple_toggle fun(cmd_string: string, env_table: table, effective_config: ClaudeCodeTerminalConfig)
---@field focus_toggle fun(cmd_string: string, env_table: table, effective_config: ClaudeCodeTerminalConfig)
---@field get_active_bufnr fun(): number?
---@field is_available fun(): boolean
---@field ensure_visible? function
---@field _get_terminal_for_test fun(): table?

-- Terminal configuration
---@class ClaudeCodeTerminalConfig
---@field split_side ClaudeCodeSplitSide
---@field split_width_percentage number
---@field provider ClaudeCodeTerminalProviderName|ClaudeCodeTerminalProvider
---@field show_native_term_exit_tip boolean
---@field terminal_cmd string?
---@field provider_opts ClaudeCodeTerminalProviderOptions?
---@field auto_close boolean
---@field env table<string, string>
---@field snacks_win_opts snacks.win.Config
---@field cwd string|nil                 -- static working directory for Claude terminal
---@field git_repo_cwd boolean|nil      -- use git root of current file/cwd as working directory
---@field cwd_provider? ClaudeCodeCwdProvider -- custom function to compute working directory

-- Port range configuration
---@class ClaudeCodePortRange
---@field min integer
---@field max integer

-- Server status information
---@class ClaudeCodeServerStatus
---@field running boolean
---@field port integer?
---@field client_count integer
---@field clients? table<string, any>

-- Main configuration structure
---@class ClaudeCodeConfig
---@field port_range ClaudeCodePortRange
---@field auto_start boolean
---@field terminal_cmd string|nil
---@field env table<string, string>
---@field log_level ClaudeCodeLogLevel
---@field track_selection boolean
---@field focus_after_send boolean
---@field visual_demotion_delay_ms number
---@field connection_wait_delay number
---@field connection_timeout number
---@field queue_timeout number
---@field diff_opts ClaudeCodeDiffOptions
---@field models ClaudeCodeModelOption[]
---@field disable_broadcast_debouncing? boolean
---@field enable_broadcast_debouncing_in_tests? boolean
---@field terminal ClaudeCodeTerminalConfig?

---@class (partial) PartialClaudeCodeConfig: ClaudeCodeConfig

-- Server interface for main module
---@class ClaudeCodeServerFacade
---@field start fun(config: ClaudeCodeConfig, auth_token: string|nil): (success: boolean, port_or_error: number|string)
---@field stop fun(): (success: boolean, error_message: string?)
---@field broadcast fun(method: string, params: table?): boolean
---@field get_status fun(): ClaudeCodeServerStatus

-- Main module state
---@class ClaudeCodeState
---@field config ClaudeCodeConfig
---@field server ClaudeCodeServerFacade|nil
---@field port integer|nil
---@field auth_token string|nil
---@field initialized boolean
---@field mention_queue ClaudeCodeMention[]
---@field mention_timer uv.uv_timer_t?  -- (compatible with vim.loop timer)
---@field connection_timer uv.uv_timer_t?  -- (compatible with vim.loop timer)

-- This module only defines types, no runtime functionality
return {}
