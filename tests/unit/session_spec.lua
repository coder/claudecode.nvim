---Tests for the session manager module.
---@module 'tests.unit.session_spec'

-- Setup test environment
require("tests.busted_setup")

describe("Session Manager", function()
  local session_manager

  before_each(function()
    -- Reset module state before each test
    package.loaded["claudecode.session"] = nil
    session_manager = require("claudecode.session")
    session_manager.reset()
  end)

  describe("create_session", function()
    it("should create a new session with unique ID", function()
      local session_id = session_manager.create_session()

      assert.is_string(session_id)
      assert.is_not_nil(session_id)
      assert.truthy(session_id:match("^session_"))
    end)

    it("should create sessions with unique IDs", function()
      local id1 = session_manager.create_session()
      local id2 = session_manager.create_session()
      local id3 = session_manager.create_session()

      assert.are_not.equal(id1, id2)
      assert.are_not.equal(id2, id3)
      assert.are_not.equal(id1, id3)
    end)

    it("should set first session as active", function()
      local session_id = session_manager.create_session()

      assert.are.equal(session_id, session_manager.get_active_session_id())
    end)

    it("should not change active session when creating additional sessions", function()
      local first_id = session_manager.create_session()
      session_manager.create_session()
      session_manager.create_session()

      assert.are.equal(first_id, session_manager.get_active_session_id())
    end)

    it("should accept optional name parameter", function()
      local session_id = session_manager.create_session({ name = "Test Session" })
      local session = session_manager.get_session(session_id)

      assert.are.equal("Test Session", session.name)
    end)

    it("should generate default name if not provided", function()
      local session_id = session_manager.create_session()
      local session = session_manager.get_session(session_id)

      assert.is_string(session.name)
      assert.truthy(session.name:match("^Session %d+$"))
    end)
  end)

  describe("destroy_session", function()
    it("should remove session from sessions table", function()
      local session_id = session_manager.create_session()
      assert.is_not_nil(session_manager.get_session(session_id))

      local result = session_manager.destroy_session(session_id)

      assert.is_true(result)
      assert.is_nil(session_manager.get_session(session_id))
    end)

    it("should return false for non-existent session", function()
      local result = session_manager.destroy_session("non_existent")

      assert.is_false(result)
    end)

    it("should switch active session when destroying active session", function()
      local id1 = session_manager.create_session()
      local id2 = session_manager.create_session()

      assert.are.equal(id1, session_manager.get_active_session_id())

      session_manager.destroy_session(id1)

      assert.are.equal(id2, session_manager.get_active_session_id())
    end)

    it("should clear active session when destroying last session", function()
      local session_id = session_manager.create_session()

      session_manager.destroy_session(session_id)

      assert.is_nil(session_manager.get_active_session_id())
    end)
  end)

  describe("get_session", function()
    it("should return session by ID", function()
      local session_id = session_manager.create_session()
      local session = session_manager.get_session(session_id)

      assert.is_table(session)
      assert.are.equal(session_id, session.id)
    end)

    it("should return nil for non-existent session", function()
      local session = session_manager.get_session("non_existent")

      assert.is_nil(session)
    end)
  end)

  describe("set_active_session", function()
    it("should change active session", function()
      local id1 = session_manager.create_session()
      local id2 = session_manager.create_session()

      assert.are.equal(id1, session_manager.get_active_session_id())

      local result = session_manager.set_active_session(id2)

      assert.is_true(result)
      assert.are.equal(id2, session_manager.get_active_session_id())
    end)

    it("should return false for non-existent session", function()
      session_manager.create_session()

      local result = session_manager.set_active_session("non_existent")

      assert.is_false(result)
    end)
  end)

  describe("list_sessions", function()
    it("should return empty array when no sessions", function()
      local sessions = session_manager.list_sessions()

      assert.is_table(sessions)
      assert.are.equal(0, #sessions)
    end)

    it("should return all sessions", function()
      session_manager.create_session()
      session_manager.create_session()
      session_manager.create_session()

      local sessions = session_manager.list_sessions()

      assert.are.equal(3, #sessions)
    end)

    it("should return sessions sorted by creation time", function()
      local id1 = session_manager.create_session()
      local id2 = session_manager.create_session()
      local id3 = session_manager.create_session()

      local sessions = session_manager.list_sessions()

      -- Just verify all sessions are returned (order may vary if timestamps are equal)
      local ids = {}
      for _, s in ipairs(sessions) do
        ids[s.id] = true
      end
      assert.is_true(ids[id1])
      assert.is_true(ids[id2])
      assert.is_true(ids[id3])

      -- Verify sorted by created_at (ascending)
      for i = 1, #sessions - 1 do
        assert.is_true(sessions[i].created_at <= sessions[i + 1].created_at)
      end
    end)
  end)

  describe("get_session_count", function()
    it("should return 0 when no sessions", function()
      assert.are.equal(0, session_manager.get_session_count())
    end)

    it("should return correct count", function()
      session_manager.create_session()
      session_manager.create_session()

      assert.are.equal(2, session_manager.get_session_count())

      session_manager.create_session()

      assert.are.equal(3, session_manager.get_session_count())
    end)
  end)

  describe("client binding", function()
    it("should bind client to session", function()
      local session_id = session_manager.create_session()

      local result = session_manager.bind_client(session_id, "client_123")

      assert.is_true(result)
      local session = session_manager.get_session(session_id)
      assert.are.equal("client_123", session.client_id)
    end)

    it("should find session by client ID", function()
      local session_id = session_manager.create_session()
      session_manager.bind_client(session_id, "client_123")

      local found_session = session_manager.find_session_by_client("client_123")

      assert.is_not_nil(found_session)
      assert.are.equal(session_id, found_session.id)
    end)

    it("should unbind client from session", function()
      local session_id = session_manager.create_session()
      session_manager.bind_client(session_id, "client_123")

      local result = session_manager.unbind_client("client_123")

      assert.is_true(result)
      local session = session_manager.get_session(session_id)
      assert.is_nil(session.client_id)
    end)

    it("should return false when binding to non-existent session", function()
      local result = session_manager.bind_client("non_existent", "client_123")

      assert.is_false(result)
    end)

    it("should return false when unbinding non-bound client", function()
      local result = session_manager.unbind_client("non_existent_client")

      assert.is_false(result)
    end)
  end)

  describe("terminal info", function()
    it("should update terminal info for session", function()
      local session_id = session_manager.create_session()

      session_manager.update_terminal_info(session_id, {
        bufnr = 42,
        winid = 100,
        jobid = 200,
      })

      local session = session_manager.get_session(session_id)
      assert.are.equal(42, session.terminal_bufnr)
      assert.are.equal(100, session.terminal_winid)
      assert.are.equal(200, session.terminal_jobid)
    end)

    it("should find session by buffer number", function()
      local session_id = session_manager.create_session()
      session_manager.update_terminal_info(session_id, { bufnr = 42 })

      local found_session = session_manager.find_session_by_bufnr(42)

      assert.is_not_nil(found_session)
      assert.are.equal(session_id, found_session.id)
    end)

    it("should return nil when buffer not found", function()
      session_manager.create_session()

      local found_session = session_manager.find_session_by_bufnr(999)

      assert.is_nil(found_session)
    end)
  end)

  describe("selection tracking", function()
    it("should update session selection", function()
      local session_id = session_manager.create_session()
      local selection = { text = "test", filePath = "/test.lua" }

      session_manager.update_selection(session_id, selection)

      local stored_selection = session_manager.get_selection(session_id)
      assert.are.same(selection, stored_selection)
    end)

    it("should return nil for session without selection", function()
      local session_id = session_manager.create_session()

      local selection = session_manager.get_selection(session_id)

      assert.is_nil(selection)
    end)
  end)

  describe("mention queue", function()
    it("should queue mentions for session", function()
      local session_id = session_manager.create_session()
      local mention = { file = "/test.lua", line = 10 }

      session_manager.queue_mention(session_id, mention)

      local session = session_manager.get_session(session_id)
      assert.are.equal(1, #session.mention_queue)
    end)

    it("should flush mention queue", function()
      local session_id = session_manager.create_session()
      session_manager.queue_mention(session_id, { file = "/a.lua" })
      session_manager.queue_mention(session_id, { file = "/b.lua" })

      local mentions = session_manager.flush_mention_queue(session_id)

      assert.are.equal(2, #mentions)

      -- Queue should be empty after flush
      local session = session_manager.get_session(session_id)
      assert.are.equal(0, #session.mention_queue)
    end)
  end)

  describe("ensure_session", function()
    it("should return existing active session", function()
      local original_id = session_manager.create_session()

      local session_id = session_manager.ensure_session()

      assert.are.equal(original_id, session_id)
    end)

    it("should create new session if none exists", function()
      local session_id = session_manager.ensure_session()

      assert.is_string(session_id)
      assert.is_not_nil(session_manager.get_session(session_id))
    end)
  end)

  describe("reset", function()
    it("should clear all sessions", function()
      session_manager.create_session()
      session_manager.create_session()

      session_manager.reset()

      assert.are.equal(0, session_manager.get_session_count())
      assert.is_nil(session_manager.get_active_session_id())
    end)
  end)

  describe("update_session_name", function()
    it("should update session name", function()
      local session_id = session_manager.create_session()

      session_manager.update_session_name(session_id, "New Name")

      local session = session_manager.get_session(session_id)
      assert.are.equal("New Name", session.name)
    end)

    it("should strip Claude - prefix", function()
      local session_id = session_manager.create_session()

      session_manager.update_session_name(session_id, "Claude - implement vim mode")

      local session = session_manager.get_session(session_id)
      assert.are.equal("implement vim mode", session.name)
    end)

    it("should strip claude - prefix (lowercase)", function()
      local session_id = session_manager.create_session()

      session_manager.update_session_name(session_id, "claude - fix bug")

      local session = session_manager.get_session(session_id)
      assert.are.equal("fix bug", session.name)
    end)

    it("should trim whitespace", function()
      local session_id = session_manager.create_session()

      session_manager.update_session_name(session_id, "  trimmed name  ")

      local session = session_manager.get_session(session_id)
      assert.are.equal("trimmed name", session.name)
    end)

    it("should limit name length to 100 characters", function()
      local session_id = session_manager.create_session()
      local long_name = string.rep("x", 150)

      session_manager.update_session_name(session_id, long_name)

      local session = session_manager.get_session(session_id)
      assert.are.equal(100, #session.name)
      assert.truthy(session.name:match("%.%.%.$"))
    end)

    it("should not update if name is empty", function()
      local session_id = session_manager.create_session()
      local original_name = session_manager.get_session(session_id).name

      session_manager.update_session_name(session_id, "")

      local session = session_manager.get_session(session_id)
      assert.are.equal(original_name, session.name)
    end)

    it("should not update if name is unchanged", function()
      local session_id = session_manager.create_session()
      session_manager.update_session_name(session_id, "Test Name")

      -- This should not trigger an update (same name)
      session_manager.update_session_name(session_id, "Test Name")

      local session = session_manager.get_session(session_id)
      assert.are.equal("Test Name", session.name)
    end)

    it("should not error for non-existent session", function()
      assert.has_no.errors(function()
        session_manager.update_session_name("non_existent", "New Name")
      end)
    end)

    it("should not update if only Claude prefix remains after stripping", function()
      local session_id = session_manager.create_session()
      local original_name = session_manager.get_session(session_id).name

      -- "Claude - " stripped leaves empty string
      session_manager.update_session_name(session_id, "Claude - ")

      local session = session_manager.get_session(session_id)
      assert.are.equal(original_name, session.name)
    end)
  end)
end)
