---@meta
---@brief [[
--- Centralized type definitions for opencode.nvim public API.
--- This module contains all user-facing types and configuration structures.
---@brief ]]
---@module 'opencode.types'

-- Version information type
---@class OpenCodeVersion
---@field major integer
---@field minor integer
---@field patch integer
---@field prerelease? string
---@field string fun(self: OpenCodeVersion): string

-- Diff behavior configuration
---@class OpenCodeDiffOptions
---@field layout OpenCodeDiffLayout
---@field open_in_new_tab boolean Open diff in a new tab (false = use current tab)
---@field keep_terminal_focus boolean Keep focus in terminal after opening diff
---@field hide_terminal_in_new_tab boolean Hide OpenCode terminal in newly created diff tab
---@field on_new_file_reject OpenCodeNewFileRejectBehavior Behavior when rejecting a new-file diff

-- Model selection option
---@class OpenCodeModelOption
---@field name string
---@field value string

-- Log level type alias
---@alias OpenCodeLogLevel "trace"|"debug"|"info"|"warn"|"error"

-- Diff layout type alias
---@alias OpenCodeDiffLayout "vertical"|"horizontal"

-- Behavior when rejecting new-file diffs
---@alias OpenCodeNewFileRejectBehavior "keep_empty"|"close_window"

-- Terminal split side positioning
---@alias OpenCodeSplitSide "left"|"right"

-- In-tree terminal provider names
---@alias OpenCodeTerminalProviderName "auto"|"snacks"|"native"|"external"|"none"

-- Terminal provider-specific options
---@class OpenCodeTerminalProviderOptions
---@field external_terminal_cmd string|(fun(cmd: string, env: table): string)|table|nil Command for external terminal (string template with %s or function)

-- Working directory resolution context and provider
---@class OpenCodeCwdContext
---@field file string|nil   -- absolute path of current buffer file (if any)
---@field file_dir string|nil -- directory of current buffer file (if any)
---@field cwd string        -- current Neovim working directory

---@alias OpenCodeCwdProvider fun(ctx: OpenCodeCwdContext): string|nil

-- @ mention queued for OpenCode
---@class OpenCodeMention
---@field file_path string The absolute file path to mention
---@field start_line number? Optional start line (0-indexed for OpenCode compatibility)
---@field end_line number? Optional end line (0-indexed for OpenCode compatibility)
---@field timestamp number Creation timestamp from vim.loop.now() for expiry tracking

-- Terminal provider interface
---@class OpenCodeTerminalProvider
---@field setup fun(config: OpenCodeTerminalConfig)
---@field open fun(cmd_string: string, env_table: table, config: OpenCodeTerminalConfig, focus: boolean?)
---@field close fun()
---@field toggle fun(cmd_string: string, env_table: table, effective_config: OpenCodeTerminalConfig)
---@field simple_toggle fun(cmd_string: string, env_table: table, effective_config: OpenCodeTerminalConfig)
---@field focus_toggle fun(cmd_string: string, env_table: table, effective_config: OpenCodeTerminalConfig)
---@field send_input? fun(text: string): (boolean, string|nil)
---@field get_active_bufnr fun(): number?
---@field is_available fun(): boolean
---@field ensure_visible? function
---@field _get_terminal_for_test fun(): table?

-- Terminal configuration
---@class OpenCodeTerminalConfig
---@field split_side OpenCodeSplitSide
---@field split_width_percentage number
---@field provider OpenCodeTerminalProviderName|OpenCodeTerminalProvider
---@field show_native_term_exit_tip boolean
---@field terminal_cmd string?
---@field provider_opts OpenCodeTerminalProviderOptions?
---@field auto_close boolean
---@field env table<string, string>
---@field snacks_win_opts snacks.win.Config
---@field cwd string|nil                 -- static working directory for OpenCode terminal
---@field git_repo_cwd boolean|nil      -- use git root of current file/cwd as working directory
---@field cwd_provider? OpenCodeCwdProvider -- custom function to compute working directory

-- Port range configuration
---@class OpenCodePortRange
---@field min integer
---@field max integer

-- Server status information
---@class OpenCodeServerStatus
---@field running boolean
---@field port integer?
---@field client_count integer
---@field clients? table<string, any>

-- Main configuration structure
---@class OpenCodeConfig
---@field port_range OpenCodePortRange
---@field auto_start boolean
---@field terminal_cmd string|nil
---@field env table<string, string>
---@field log_level OpenCodeLogLevel
---@field track_selection boolean
---@field focus_after_send boolean
---@field visual_demotion_delay_ms number
---@field connection_wait_delay number
---@field connection_timeout number
---@field queue_timeout number
---@field diff_opts OpenCodeDiffOptions
---@field models OpenCodeModelOption[]
---@field disable_broadcast_debouncing? boolean
---@field enable_broadcast_debouncing_in_tests? boolean
---@field terminal OpenCodeTerminalConfig?

---@class (partial) PartialOpenCodeConfig: OpenCodeConfig

-- Server interface for main module
---@class OpenCodeServerFacade
---@field start fun(config: OpenCodeConfig, auth_token: string|nil): (success: boolean, port_or_error: number|string)
---@field stop fun(): (success: boolean, error_message: string?)
---@field broadcast fun(method: string, params: table?): boolean
---@field get_status fun(): OpenCodeServerStatus

-- Main module state
---@class OpenCodeState
---@field config OpenCodeConfig
---@field server OpenCodeServerFacade|nil
---@field port integer|nil
---@field auth_token string|nil
---@field initialized boolean
---@field mention_queue OpenCodeMention[]
---@field mention_timer uv.uv_timer_t?  -- (compatible with vim.loop timer)
---@field connection_timer uv.uv_timer_t?  -- (compatible with vim.loop timer)

-- This module only defines types, no runtime functionality
return {}
