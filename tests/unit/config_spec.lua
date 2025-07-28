-- luacheck: globals expect
require("tests.busted_setup")

describe("Configuration", function()
  local config

  local function setup()
    package.loaded["claudecode.config"] = nil

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
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
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
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
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

  it("should reject invalid show_terminal_on_at_mention type", function()
    local invalid_config = {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "debug",
      track_selection = false,
      show_terminal_on_at_mention = "invalid", -- Should be boolean
      visual_demotion_delay_ms = 50,
      diff_opts = {
        auto_close_on_accept = true,
        show_diff_stats = true,
        vertical_split = true,
        open_in_current_tab = true,
      },
      models = {
        { name = "Test Model", value = "test-model" },
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
    expect(merged_config.show_terminal_on_at_mention).to_be(config.defaults.show_terminal_on_at_mention)
    expect(merged_config.models).to_be_table()
  end)

  teardown()
end)
