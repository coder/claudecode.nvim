-- luacheck: globals expect
require("tests.busted_setup")

describe("Configuration", function()
  local config

  local function setup()
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.terminal"] = nil

    config = require("claudecode.config")
  end

  local function teardown()
    -- Nothing to clean up for now
  end

  setup()

  it("should have default configuration", function()
    expect(config.defaults).to_be_table()
    expect(config.defaults).to_have_key("port_range")
    expect(config.defaults).to_have_key("auto_start")
    expect(config.defaults).to_have_key("log_level")
    expect(config.defaults).to_have_key("track_selection")
    expect(config.defaults).to_have_key("models")
    expect(config.defaults).to_have_key("diff_opts")
    expect(config.defaults.diff_opts).to_have_key("keep_terminal_focus")
    expect(config.defaults.diff_opts.keep_terminal_focus).to_be_false()
  end)

  it("should apply and validate user configuration", function()
    local user_config = {
      terminal_cmd = "toggleterm",
      log_level = "debug",
      track_selection = false,
      models = {
        { name = "Test Model", value = "test-model" },
      },
    }

    local final_config = config.apply(user_config)
    expect(final_config).to_be_table()
    expect(final_config.terminal_cmd).to_be("toggleterm")
    expect(final_config.log_level).to_be("debug")
    expect(final_config.track_selection).to_be_false()
    expect(final_config.env).to_be_table() -- Should inherit default empty table
  end)

  it("should reject invalid port range", function()
    local invalid_config = {
      port_range = { min = -1, max = 65536 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
    }

    local success, _ = pcall(function() -- Use _ for unused error variable
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should reject invalid log level", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "invalid_level",
      track_selection = false,
    }

    local success, _ = pcall(function() -- Use _ for unused error variable
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should reject invalid models configuration", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
      visual_demotion_delay_ms = 50,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
      },
      models = {}, -- Empty models array should be rejected
    }

    local success, _ = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should reject models with invalid structure", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
      visual_demotion_delay_ms = 50,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
      },
      models = {
        { name = "Test Model" }, -- Missing value field
      },
    }

    local success, _ = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should merge user config with defaults", function()
    local user_config = {
      auto_start = true,
      log_level = "debug",
    }

    local merged_config = config.apply(user_config)

    expect(merged_config.auto_start).to_be_true()
    expect(merged_config.log_level).to_be("debug")
    expect(merged_config.port_range.min).to_be(config.defaults.port_range.min)
    expect(merged_config.track_selection).to_be(config.defaults.track_selection)
    expect(merged_config.models).to_be_table()
  end)

  it("should accept valid keep_terminal_focus configuration", function()
    local user_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
    }

    local final_config = config.apply(user_config)
    expect(final_config.diff_opts.keep_terminal_focus).to_be_true()
  end)

  it("should reject invalid keep_terminal_focus configuration", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = "invalid", -- Should be boolean
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
    }

    local success, _ = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
  end)

  it("should accept function for external_terminal_cmd", function()
    local valid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = function(cmd, env)
            return "terminal " .. cmd
          end,
        },
      },
    }

    local success, _ = pcall(function()
      config.validate(valid_config)
    end)

    expect(success).to_be_true()
  end)

  it("should accept string for external_terminal_cmd", function()
    local valid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = "alacritty -e %s",
        },
      },
    }

    local success, _ = pcall(function()
      config.validate(valid_config)
    end)

    expect(success).to_be_true()
  end)

  it("should reject invalid type for external_terminal_cmd", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      env = {},
      models = {
        { name = "Test Model", value = "test" },
      },
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = 123, -- Invalid: number
        },
      },
    }

    local success, err = pcall(function()
      config.validate(invalid_config)
    end)

    expect(success).to_be_false()
    expect(tostring(err)).to_match("must be a string or function")
  end)

  teardown()
end)
