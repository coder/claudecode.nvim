---@meta vim_api_definitions
-- This file provides type definitions for parts of the Neovim API
-- to help the Lua language server (LuaLS) with diagnostics.

---@class vim_log_levels
---@field NONE number
---@field ERROR number
---@field WARN number
---@field INFO number
---@field DEBUG number
---@field TRACE number

---@class vim_log
---@field levels vim_log_levels

---@class vim_notify_opts
---@field title string|nil
---@field icon string|nil
---@field on_open fun(winid: number)|nil
---@field on_close fun()|nil
---@field timeout number|nil
---@field keep fun()|nil
---@field plugin string|nil
---@field hide_from_history boolean|nil
---@field once boolean|nil
---@field on_close_timeout number|nil

---@class vim_options_table: table<string, any>
---@field columns number Global option: width of the screen
---@field lines number Global option: height of the screen
-- Add other commonly used vim.o options as needed

---@class vim_buffer_options_table: table<string, any>

---@class vim_bo_proxy: vim_buffer_options_table
---@field __index fun(self: vim_bo_proxy, bufnr: number): vim_buffer_options_table Allows vim.bo[bufnr]

---@class vim_diagnostic_info
---@field bufnr number
---@field col number
---@field end_col number|nil
---@field end_lnum number|nil
---@field lnum number
---@field message string
---@field severity number
---@field source string|nil
---@field user_data any|nil

---@class vim_diagnostic_module
---@field get fun(bufnr?: number, ns_id?: number): vim_diagnostic_info[]
-- Add other vim.diagnostic functions as needed, e.g., get_namespace, set, etc.

---@class vim_fs_module
---@field remove fun(path: string, opts?: {force?: boolean, recursive?: boolean}):boolean|nil

---@class vim_filetype_module
---@field match fun(args: {filename: string, contents?: string}):string|nil

---@class vim_fn_table
---@field mode fun(mode_str?: string, full?: boolean|number):string
---@field delete fun(name: string, flags?: string):integer For file deletion
---@field filereadable fun(file: string):integer
---@field fnamemodify fun(fname: string, mods: string):string
---@field expand fun(str: string, ...):string|table
---@field getcwd fun(winid?: number, tabnr?: number):string
---@field mkdir fun(name: string, path?: string, prot?: number):integer
---@field buflisted fun(bufnr: number|string):integer
---@field bufname fun(expr?: number|string):string
---@field bufnr fun(expr?: string|number, create?: boolean):number
---@field win_getid fun(win?: number, tab?: number):number
---@field win_gotoid fun(winid: number):boolean
---@field line fun(expr: string, winid?: number):number
---@field col fun(expr: string, winid?: number):number
---@field virtcol fun(expr: string|string[], winid?: number):number|number[]
---@field getpos fun(expr: string, winid?: number):number[]
---@field setpos fun(expr: string, pos: number[], winid?: number):boolean
---@field tempname fun():string
---@field globpath fun(path: string, expr: string, ...):string
---@field stdpath fun(type: "cache"|"config"|"data"|"log"|"run"|"state"|"config_dirs"|"data_dirs"):string|string[]
---@field json_encode fun(expr: any):string
---@field json_decode fun(string: string, opts?: {null_value?: any}):any
---@field termopen fun(cmd: string|string[], opts?: table):number For vim.fn.termopen()
-- Add other vim.fn functions as needed

---@class vim_v_table
---@field event table Event data containing status and other event information

---@class vim_global_api
---@field notify fun(msg: string | string[], level?: number, opts?: vim_notify_opts):nil
---@field log vim_log
---@field v vim_v_table For vim.v.event access
---@field _last_echo table[]? table of tables, e.g. { {"message", "HighlightGroup"} }
---@field _last_error string?
---@field o vim_options_table For vim.o.option_name
---@field bo vim_bo_proxy      For vim.bo.option_name and vim.bo[bufnr].option_name
---@field diagnostic vim_diagnostic_module For vim.diagnostic.*
---@field empty_dict fun(): table For vim.empty_dict()
---@field schedule_wrap fun(fn: function): function For vim.schedule_wrap()
---@field deepcopy fun(val: any): any For vim.deepcopy() -- Added based on test mocks
---@field _current_mode string? For mocks in tests
---@class vim_api_table
---@field nvim_create_augroup fun(name: string, opts: {clear: boolean}):integer
---@field nvim_create_autocmd fun(event: string|string[], opts: {group?: string|integer, pattern?: string|string[], buffer?: number, callback?: function|string, once?: boolean, desc?: string}):integer
---@field nvim_clear_autocmds fun(opts: {group?: string|integer, event?: string|string[], pattern?: string|string[], buffer?: number}):nil
---@field nvim_get_current_buf fun():integer
---@field nvim_get_mode fun():{mode: string, blocking: boolean}
---@field nvim_win_get_cursor fun(window: integer):integer[] Returns [row, col] (1-based for row, 0-based for col)
---@field nvim_buf_get_name fun(buffer: integer):string
---@field nvim_buf_get_lines fun(buffer: integer, start: integer, end_line: integer, strict_indexing: boolean):string[]
-- Add other nvim_api functions as needed
---@field cmd fun(command: string):nil For vim.cmd() -- Added based on test mocks
---@field api vim_api_table For vim.api.*
---@field fn vim_fn_table For vim.fn.*
---@field fs vim_fs_module For vim.fs.*
---@field filetype vim_filetype_module For vim.filetype.*
---@field test vim_test_utils? For test utility mocks
---@field split fun(str: string, pat?: string, opts?: {plain?: boolean, trimempty?: boolean}):string[] For vim.split()
-- Add other vim object definitions here if they cause linting issues
-- e.g. vim.api, vim.loop, vim.deepcopy, etc.

---@class SpyCall
---@field vals table[] table of arguments passed to the call
---@field self any the 'self' object for the call if it was a method

---@class SpyInformation
---@field calls SpyCall[] A list of calls made to the spy.
---@field call_count number The number of times the spy has been called.
-- Add other spy properties if needed e.g. returned, threw

---@class SpyAsserts
---@field was_called fun(self: SpyAsserts, count?: number):boolean
---@field was_called_with fun(self: SpyAsserts, ...):boolean
---@field was_not_called fun(self: SpyAsserts):boolean
-- Add other spy asserts if needed

---@class SpyableFunction : function
---@field __call fun(self: SpyableFunction, ...):any
---@field spy fun(self: SpyableFunction):SpyAsserts Returns an assertion object for the spy.
---@field calls SpyInformation[]? Information about calls made to the spied function.
-- Note: In some spy libraries, 'calls' might be directly on the spied function,
-- or on an object returned by `spy()`. Adjust as per your spy library's specifics.
-- For busted's default spy, `calls` is often directly on the spied function.

---@class vim_test_utils
---@field add_buffer fun(bufnr: number, filename: string, content: string|string[]):nil
---@field set_cursor fun(bufnr: number, row: number, col: number):nil
-- Add other test utility functions as needed

-- This section helps LuaLS understand that 'vim' is a global variable
-- with the structure defined above. It's for type hinting only and
-- does not execute or overwrite the actual 'vim' global provided by Neovim.
---@type vim_global_api
