-- luacheck: globals expect
require("tests.busted_setup")

describe("session_manager.find_unbound_session", function()
  local session_manager

  before_each(function()
    package.loaded["claudecode.session"] = nil
    session_manager = require("claudecode.session")
    session_manager.reset()
  end)

  after_each(function()
    session_manager.reset()
  end)

  it("returns nil when there are no sessions", function()
    expect(session_manager.find_unbound_session()).to_be_nil()
  end)

  it("returns the session when only one exists and is unbound", function()
    local sid = session_manager.create_session({ name = "Only" })
    local found = session_manager.find_unbound_session()
    assert.is_not_nil(found)
    expect(found.id).to_be(sid)
  end)

  it("returns nil when every session already has a client_id", function()
    local sid = session_manager.create_session({ name = "Bound" })
    session_manager.bind_client(sid, "client-1")
    expect(session_manager.find_unbound_session()).to_be_nil()
  end)

  it("prefers the most recently created unbound session", function()
    local first = session_manager.create_session({ name = "First" })
    -- Force differing created_at values; the mocked vim.loop.now may collide.
    session_manager.sessions[first].created_at = 100
    local second = session_manager.create_session({ name = "Second" })
    session_manager.sessions[second].created_at = 200
    local third = session_manager.create_session({ name = "Third" })
    session_manager.sessions[third].created_at = 300

    local found = session_manager.find_unbound_session()
    assert.is_not_nil(found)
    expect(found.id).to_be(third)
  end)

  it("skips bound sessions and returns the newest unbound", function()
    local s1 = session_manager.create_session({ name = "One" })
    session_manager.sessions[s1].created_at = 100
    local s2 = session_manager.create_session({ name = "Two" })
    session_manager.sessions[s2].created_at = 200
    local s3 = session_manager.create_session({ name = "Three" })
    session_manager.sessions[s3].created_at = 300

    -- Bind the newest one; the helper should skip it and return s2.
    session_manager.bind_client(s3, "client-3")
    local found = session_manager.find_unbound_session()
    assert.is_not_nil(found)
    expect(found.id).to_be(s2)
  end)
end)
