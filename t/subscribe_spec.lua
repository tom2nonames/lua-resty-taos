-- Tests for resty.taos.subscribe: topic subscription.

local ffi = require("ffi")

local helper = require("t.helper")
local subscribe = require("resty.taos.subscribe")

helper.suite("subscribe")

local function fake_cwrap()
    return { conn = helper.ptr() }
end

local function mock_consume_result()
    helper.on("taos_errno", function() return 0 end)
    helper.on("taos_field_count", function() return 1 end)
    helper.on("taos_fetch_fields", function()
        return helper.fields({ "degree", 7, 8 })
    end)
    helper.on("taos_affected_rows", function() return 1 end)
    local i = 0
    helper.on("taos_fetch_row", function()
        i = i + 1
        if i == 1 then
            return helper.row(helper.double_buf(36.5))
        end
        return ffi.new("void**", nil)
    end)
end

helper.test("subscribe() with a callback succeeds and stores the handle", function()
    helper.reset()
    helper.on("taos_subscribe", function()
        return helper.ptr() -- TAOS_SUB*
    end)

    local sub = subscribe:new(fake_cwrap())
    local seen = {}
    local res = sub:subscribe(true, "topic1", "select * from t", function(t)
        seen[#seen + 1] = t
    end, nil, 1000)

    helper.assert_eq(res.code, 0)
    helper.assert_not_nil(sub.subs)

    local args = helper.called("taos_subscribe")
    helper.assert_eq(args[1], helper.calls("taos_subscribe")[1].args[1]) -- taos handle
    helper.assert_eq(args[2], 1, "restart=1 when restart=true")
    helper.assert_eq(args[3], "topic1")
    helper.assert_eq(args[4], "select * from t")
    helper.assert_eq(args[7], 1000, "interval forwarded")
    helper.assert_not_nil(args[5], "callback cdata passed when callback given")
end)

helper.test("subscribe() callback receives converted rows (code 0)", function()
    helper.reset()
    mock_consume_result()
    helper.on("taos_subscribe", function() return helper.ptr() end)

    local sub = subscribe:new(fake_cwrap())
    local got
    local res = sub:subscribe(false, "topic1", "select * from t", function(t)
        got = t
    end, nil, 0)

    helper.assert_eq(res.code, 0)

    -- Simulate the C side firing the subscription callback with a result.
    local args = helper.called("taos_subscribe")
    local cb = args[5]
    cb(helper.ptr(), helper.res(), args[6], 0)

    helper.assert_not_nil(got)
    helper.assert_eq(got.code, 0)
    helper.assert_eq(got.item[1].degree, 36.5)
end)

helper.test("subscribe() error callback does not crash (regression)", function()
    helper.reset()
    helper.on("taos_errstr", function() return "subscribe failed" end)
    helper.on("taos_subscribe", function() return helper.ptr() end)

    local sub = subscribe:new(fake_cwrap())
    local got
    local res = sub:subscribe(true, "topic1", "select 1", function(t)
        got = t
    end, nil, 0)
    helper.assert_eq(res.code, 0)

    -- Fire the callback with a non-zero code.  Previously the error branch
    -- referenced `result` before its local declaration, raising
    -- "attempt to index a nil value" and crashing the worker.
    local args = helper.called("taos_subscribe")
    args[5](helper.ptr(), helper.res(), args[6], -1)

    helper.assert_not_nil(got)
    helper.assert_eq(got.code, -1)
    helper.assert_eq(got.error, "subscribe failed")
end)

helper.test("subscribe() without a callback passes a NULL callback", function()
    helper.reset()
    helper.on("taos_subscribe", function() return helper.ptr() end)

    local sub = subscribe:new(fake_cwrap())
    local res = sub:subscribe(false, "topic1", "select 1", nil, nil, 0)

    helper.assert_eq(res.code, 0)
    local args = helper.called("taos_subscribe")
    helper.assert_nil(args[5], "no callback cdata allocated when callback is nil")
end)

helper.test("subscribe() failure reports code -1", function()
    helper.reset()
    helper.on("taos_subscribe", function() return nil end)

    local sub = subscribe:new(fake_cwrap())
    local res = sub:subscribe(false, "topic1", "select 1", nil, nil, 0)

    helper.assert_eq(res.code, -1)
    helper.assert_nil(sub.subs)
end)

helper.test("consume() converts the polled result set", function()
    helper.reset()
    mock_consume_result()
    helper.on("taos_subscribe", function() return helper.ptr() end)
    helper.on("taos_consume", function() return helper.res() end)

    local sub = subscribe:new(fake_cwrap())
    sub:subscribe(false, "topic1", "select * from t", nil, nil, 0)

    local t = sub:consume()
    helper.assert_eq(t.code, 0)
    helper.assert_eq(t.item[1].degree, 36.5)
end)

helper.test("consume() releases the C result set", function()
    helper.reset()
    mock_consume_result()
    helper.on("taos_subscribe", function() return helper.ptr() end)
    helper.on("taos_consume", function() return helper.res() end)

    local sub = subscribe:new(fake_cwrap())
    sub:subscribe(false, "topic1", "select * from t", nil, nil, 0)

    sub:consume()
    -- LEAK FIX: taos_consume()'s result set must be released with
    -- taos_free_result() (per the official demoSubscribe.c).
    helper.assert_eq(#helper.calls("taos_free_result"), 1)
end)

helper.test("consume() re-raises when row conversion raises", function()
    helper.reset()
    helper.on("taos_subscribe", function() return helper.ptr() end)
    helper.on("taos_consume", function() return helper.res() end)
    -- Force totable() to raise; consume() must release the result and
    -- re-raise the original error.
    helper.on("taos_errno", function() error("consume boom") end)

    local sub = subscribe:new(fake_cwrap())
    sub:subscribe(false, "topic1", "select 1", nil, nil, 0)

    helper.assert_error(function()
        sub:consume()
    end, "consume boom")
    helper.assert_eq(#helper.calls("taos_free_result"), 1)
end)

helper.test("consume() returns nil when no result wrapper can be built", function()
    helper.reset()
    helper.on("taos_subscribe", function() return helper.ptr() end)
    helper.on("taos_consume", function() return 42 end) -- non-TAOS_RES

    local sub = subscribe:new(fake_cwrap())
    sub:subscribe(false, "topic1", "select 1", nil, nil, 0)

    helper.assert_nil(sub:consume())
end)

helper.test("unsubscribe() forwards the keep flag and frees the callback", function()
    helper.reset()
    helper.on("taos_subscribe", function() return helper.ptr() end)

    local sub = subscribe:new(fake_cwrap())
    sub:subscribe(true, "topic1", "select 1", function() end, nil, 0)

    local ok = sub:unsubscribe(true)
    helper.assert_true(ok)

    local args = helper.called("taos_unsubscribe")
    helper.assert_eq(args[2], 1, "keep_progress=1 forwarded")
    helper.assert_nil(sub.subs)
end)

helper.test("unsubscribe() without an active subscription is reported", function()
    helper.reset()
    local sub = subscribe:new(fake_cwrap())
    local ok, err = sub:unsubscribe(false)
    helper.assert_nil(ok)
    helper.assert_eq(err, "not subscribed.")
    -- No C call must be made when there is nothing to unsubscribe.
    helper.assert_eq(#helper.calls("taos_unsubscribe"), 0)
end)
