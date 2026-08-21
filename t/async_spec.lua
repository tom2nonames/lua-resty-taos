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
