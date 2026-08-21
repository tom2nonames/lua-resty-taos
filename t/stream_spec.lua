-- Tests for resty.taos.stream: continuous-query streams.

local ffi = require("ffi")

local helper = require("t.helper")
local stream = require("resty.taos.stream")

helper.suite("stream")

local function fake_cwrap()
    return {
        conn = helper.ptr(),
        get_error_string = function() return "" end,
    }
end

local function mock_stream_fields()
    helper.on("taos_field_count", function() return 2 end)
    helper.on("taos_fetch_fields", function()
        return helper.fields({ "ts", 9, 8 }, { "degree", 7, 8 })
    end)
end

helper.test("open() succeeds and stores the raw TAOS_STREAM handle", function()
    helper.reset()
    helper.on("taos_open_stream", function()
        return helper.ptr() -- TAOS_STREAM*
    end)

    local st = stream:new(fake_cwrap())
    local res = st:open("select count(*) from t interval(1s)", 0, function() end, function() end)

    helper.assert_eq(res.code, 0)
    -- Regression: the stream handle returned to the caller used to be the
    -- cb_param struct instead of the TAOS_STREAM* pointer.
    helper.assert_eq(res.stream, helper.ptr())
    helper.assert_eq(st.stream, helper.ptr())
end)

helper.test("open() failure reports code -1", function()
    helper.reset()
    helper.on("taos_open_stream", function() return nil end)

    local st = stream:new(fake_cwrap())
    local res = st:open("select 1", 0, function() end, nil)

    helper.assert_eq(res.code, -1)
    helper.assert_nil(st.stream)
end)

helper.test("open() without a completion callback does not crash", function()
    helper.reset()
    helper.on("taos_open_stream", function() return helper.ptr() end)

    local st = stream:new(fake_cwrap())
    local res = st:open("select 1", 0, function() end, nil)

    helper.assert_eq(res.code, 0)
end)

helper.test("handler receives converted rows and does not free the result", function()
    helper.reset()
    mock_stream_fields()
    helper.on("taos_open_stream", function()
        return helper.ptr()
    end)

    local st = stream:new(fake_cwrap())
    local got
    local res = st:open("select * from t", 0, function(item)
        got = item
    end, function() end)
    helper.assert_eq(res.code, 0)

    -- Simulate the C side invoking the HANDLEFUNC with a data row.
    local args = helper.called("taos_open_stream")
    local handler, param = args[3], args[5]
    local row = helper.row(helper.int64_buf(1600000000000), helper.double_buf(36.5))
    handler(param, helper.res(), row)

    helper.assert_not_nil(got)
    helper.assert_eq(got.ts, 1600000000000)
    helper.assert_eq(got.degree, 36.5)

    -- Regression: the handler used to call result:free() inside the
    -- callback; the result is owned by the stream machinery, so
    -- taos_free_result must never be called here.
    helper.assert_eq(#helper.calls("taos_free_result"), 0)

    -- The cb_param struct must carry the stream pointer back.
    local p = ffi.cast("cb_param *", param)
    helper.assert_eq(p.stream, helper.ptr())
end)

helper.test("close() passes the TAOS_STREAM handle to the C library", function()
    helper.reset()
    helper.on("taos_open_stream", function() return helper.ptr() end)

    local st = stream:new(fake_cwrap())
    st:open("select 1", 0, function() end, nil)

    local ok = st:close()
    helper.assert_true(ok)

    -- Regression: close() previously passed the cb_param struct instead
    -- of the TAOS_STREAM* handle.
    local args = helper.called("taos_close_stream")
    helper.assert_eq(#args, 1)
    helper.assert_eq(args[1], helper.ptr())

    -- Closing again is reported instead of calling the C library.
    local ok2, err = st:close()
    helper.assert_nil(ok2)
    helper.assert_eq(err, "no stream opened.")
    helper.assert_eq(#helper.calls("taos_close_stream"), 1)
end)
