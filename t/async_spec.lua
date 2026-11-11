-- Tests for resty.taos.async: asynchronous query callbacks.

local ffi = require("ffi")

local helper = require("t.helper")
local async = require("resty.taos.async")

helper.suite("async")

local function fake_cwrap()
    return {
        conn = helper.ptr(),
        get_error_string = function(self, res)
            return "async error"
        end,
    }
end

helper.test("query() rejects a missing callback", function()
    helper.reset()
    local a = async:new(fake_cwrap())
    local ok, err = a:query("select 1", nil)
    helper.assert_nil(ok)
    helper.assert_eq(err, "callback set error!")
end)

helper.test("query() success callback receives affected rows", function()
    helper.reset()
    helper.on("taos_affected_rows", function() return 2 end)

    local a = async:new(fake_cwrap())
    local got
    local ok = a:query("insert into t values (1)", function(t)
        got = t
    end)
    helper.assert_true(ok)

    local args = helper.called("taos_query_a")
    helper.assert_eq(args[2], "insert into t values (1)")

    -- Simulate the C side completing the async query successfully.
    args[3](args[4], helper.res(), 0)

    helper.assert_not_nil(got)
    helper.assert_eq(got.code, 0)
    helper.assert_eq(got.error, "ok")
    helper.assert_eq(got.affected, 2)
    helper.assert_eq(got.res, helper.res())
end)

helper.test("query() error callback receives the error", function()
    helper.reset()
    local a = async:new(fake_cwrap())
    local got
    a:query("bad sql", function(t)
        got = t
    end)

    local args = helper.called("taos_query_a")
    args[3](args[4], helper.res(), -1)

    helper.assert_not_nil(got)
    helper.assert_eq(got.code, -1)
    helper.assert_eq(got.error, "async error")
end)

helper.test("callback cdata stays alive after query() returns (regression)", function()
    helper.reset()
    local a = async:new(fake_cwrap())
    local got
    a:query("select 1", function(t)
        got = t
    end)

    -- The old code called handle:free() right after taos_query_a(), which
    -- is a use-after-free because the async callback can fire later.  The
    -- wrapper must keep the callback cdata referenced.
    helper.assert_not_nil(a.handle)
    helper.assert_not_nil(a.param)

    -- Firing the stored handle must still work and reach the user callback.
    a.handle(a.param, helper.res(), 0)
    helper.assert_not_nil(got)
    helper.assert_eq(got.code, 0)
end)

helper.test("fetch_rows() forwards the row count", function()
    helper.reset()
    local a = async:new(fake_cwrap())
    local got
    local ok = a:fetch_rows(helper.res(), function(t)
        got = t
    end)
    helper.assert_true(ok)

    -- taos_fetch_rows_a(res, handle, param): handle is arg 2, param arg 3.
    local args = helper.called("taos_fetch_rows_a")
    args[2](args[3], helper.res(), 5)

    helper.assert_not_nil(got)
    helper.assert_eq(got.num_of_rows, 5)
    helper.assert_eq(got.res, helper.res())
end)

helper.test("fetch_rows() rejects a missing callback", function()
    helper.reset()
    local a = async:new(fake_cwrap())
    local ok, err = a:fetch_rows(helper.res(), nil)
    helper.assert_nil(ok)
    helper.assert_eq(err, "callback set error!")
end)

helper.test("a fired query_async callback is removed from the driver list", function()
    helper.reset()
    local taos = require("resty.taos")

    local d = taos:new()
    helper.on("taos_connect", function() return helper.ptr() end)
    d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

    local got
    d:query_async("select 1", function(t)
        got = t
    end)
    helper.assert_eq(#d.asyncs, 1)

    -- LEAK FIX regression: once the async callback fires (exactly once),
    -- the wrapper must be dropped from the driver's keep-alive list so
    -- the callback trampoline becomes garbage-collectable and the list
    -- stays bounded.
    local args = helper.called("taos_query_a")
    args[3](args[4], helper.res(), 0)

    helper.assert_eq(#d.asyncs, 0)
    helper.assert_not_nil(got)
    helper.assert_eq(got.code, 0)
end)

-- P6: the keep-alive list is capped, and slots are reused once a callback
-- fires in an arbitrary order.
local function pending_count(asyncs)
    local n = 0
    for _ in pairs(asyncs or {}) do
        n = n + 1
    end
    return n
end

local function connected_driver()
    local taos = require("resty.taos")
    local d = taos:new()
    helper.on("taos_connect", function() return helper.ptr() end)
    d:connect({ host = "127.0.0.1", port = 6030,
                user = "root", password = "x" })
    return d
end

helper.test("driver query_async() rejects a missing callback", function()
    helper.reset()
    local d = connected_driver()
    local ok, err = d:query_async("select 1", nil)
    helper.assert_nil(ok)
    helper.assert_eq(err, "callback set error!")
end)

helper.test("driver fetch_rows_async() rejects a missing callback", function()
    helper.reset()
    local d = connected_driver()
    local ok, err = d:fetch_rows_async(helper.res(), nil)
    helper.assert_nil(ok)
    helper.assert_eq(err, "callback set error!")
end)

helper.test("the callback cdata stays referenced while the trampoline runs", function()
    helper.reset()
    local a = async:new(fake_cwrap())
    local inside_handle, inside_param
    a:query("select 1", function(t)
        inside_handle = a.handle
        inside_param = a.param
    end)

    local args = helper.called("taos_query_a")
    args[3](args[4], helper.res(), 0)

    -- The old code dropped these references before returning from the
    -- trampoline, which could free the machine code still on the C stack.
    helper.assert_not_nil(inside_handle)
    helper.assert_not_nil(inside_param)
end)

helper.test("a fired fetch_rows_async callback is removed from the driver list", function()
    helper.reset()
    local d = connected_driver()
    local got
    local ok = d:fetch_rows_async(helper.res(), function(t) got = t end)
    helper.assert_true(ok)
    helper.assert_eq(#d.asyncs, 1)

    local args = helper.called("taos_fetch_rows_a")
    args[2](args[3], helper.res(), 3)

    helper.assert_eq(#d.asyncs, 0)
    helper.assert_eq(got.num_of_rows, 3)
end)

helper.test("the driver caps pending async operations and reuses slots", function()
    helper.reset()
    local d = connected_driver()

    for i = 1, 64 do
        local ok, err = d:query_async("select " .. i, function() end)
        helper.assert_true(ok, "async " .. i .. " should be accepted")
        helper.assert_nil(err)
    end

    local ok, err = d:query_async("select 65", function() end)
    helper.assert_nil(ok)
    helper.assert_true(tostring(err):find("too many pending async queries", 1, true) ~= nil)

    -- Fire the second operation, leaving a hole in slot 2; the next call
    -- must reuse it (and `#` must not be trusted for the count).
    local cs = helper.calls("taos_query_a")
    cs[2].args[3](cs[2].args[4], helper.res(), 0)
    helper.assert_nil(d.asyncs[2])

    local ok2, err2 = d:query_async("select again", function() end)
    helper.assert_true(ok2)
    helper.assert_nil(err2)
    helper.assert_not_nil(d.asyncs[2])
    helper.assert_eq(pending_count(d.asyncs), 64)

    local ok3 = d:query_async("select 66", function() end)
    helper.assert_nil(ok3)
end)

helper.test("fetch_rows_async() honours the pending-operation cap", function()
    helper.reset()
    local d = connected_driver()
    for i = 1, 64 do
        helper.assert_true(d:query_async("select " .. i, function() end))
    end
    local ok, err = d:fetch_rows_async(helper.res(), function() end)
    helper.assert_nil(ok)
    helper.assert_true(tostring(err):find("too many pending async queries", 1, true) ~= nil)
end)

helper.test("a raising async callback still detaches the wrapper", function()
    helper.reset()
    local d = connected_driver()
    d:query_async("select 1", function() error("boom") end)
    helper.assert_eq(#d.asyncs, 1)

    local args = helper.called("taos_query_a")
    local ok = pcall(function() args[3](args[4], helper.res(), 0) end)
    helper.assert_false(ok)
    helper.assert_eq(#d.asyncs, 0)
end)

helper.test("close() drops pending async wrappers", function()
    helper.reset()
    local d = connected_driver()
    helper.assert_true(d:query_async("select 1", function() end))
    helper.assert_eq(#d.asyncs, 1)

    local res = d:close()
    helper.assert_eq(res.code, 0)
    helper.assert_nil(d.asyncs)
end)
