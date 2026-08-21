-- Shared helpers for the test::nginx suite (t/*.t).
--
-- Runs inside a real OpenResty worker with the TDengine C library mocked
-- at the Lua level (see t/helper.lua): the FFI cdefs are registered from
-- the real resty.taos.library module, then package.loaded is pointed at a
-- mock that records every C call and lets each test script the results.
--
-- This keeps the whole driver flow (connect -> query -> row conversion)
-- exercised end to end inside nginx without needing a TDengine server.

local ffi = require("ffi")

local helper = require("t.helper")

local _M = {}

-- Registers the FFI types and installs the mock.  Called once per worker
-- from init_by_lua_block (injected by the t/*.t preprocessor).
function _M.init()
    helper.init()
end

-- Re-export the mock scripting API.
_M.reset = helper.reset
_M.on = helper.on
_M.calls = helper.calls
_M.called = helper.called
_M.ptr = helper.ptr
_M.res = helper.res
_M.row = helper.row
_M.int_buf = helper.int_buf
_M.int64_buf = helper.int64_buf
_M.double_buf = helper.double_buf
_M.float_buf = helper.float_buf
_M.char_buf = helper.char_buf
_M.fields = helper.fields

-- Scripts the mock to serve a 2-column (ts, speed) result set.
--
-- This is additive: it does NOT reset the mock, so it must be called
-- before any util.on() overrides.  Each test::nginx block starts from a
-- fresh worker (fresh mock state), so no explicit reset is needed there.
function _M.mock_select(rows, affected)
    helper.on("taos_errno", function() return 0 end)
    helper.on("taos_field_count", function() return 2 end)
    helper.on("taos_fetch_fields", function()
        return helper.fields({ "ts", 9, 8 }, { "speed", 4, 4 })
    end)
    helper.on("taos_affected_rows", function() return affected or #rows end)
    local i = 0
    helper.on("taos_fetch_row", function()
        i = i + 1
        if rows[i] then
            return rows[i]
        end
        return ffi.new("void**", nil)
    end)
end

return _M
