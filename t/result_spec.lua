-- Tests for resty.taos.result: result-set wrapper behaviour.

local ffi = require("ffi")

local helper = require("t.helper")
local result = require("resty.taos.result")

helper.suite("result")

-- Scripts the mock to serve a 2-column result set (ts, speed) with the
-- given rows; each row is a helper.row(...) value.
local function mock_select(rows, affected)
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

helper.test("new() rejects non-TAOS_RES values", function()
    helper.assert_nil(result:new("not a cdata"))
    helper.assert_nil(result:new(42))
end)

helper.test("new() rejects a NULL result pointer", function()
    -- taos_query() returns NULL when it cannot produce a result set; a
    -- NULL cdata passes istype(), but wrapping it would dereference NULL.
    helper.assert_nil(result:new(ffi.cast("TAOS_RES *", 0)))
end)

helper.test("new() accepts a TAOS_RES* handle", function()
    local r = result:new(helper.res())
    helper.assert_not_nil(r)
end)

helper.test("errstr/errno are safe on a NULL result", function()
    -- Regression: a NULL cdata is truthy, so the old `if self.result then`
    -- guard passed and the C function was called with NULL.  errstr/errno
    -- must return "" / 0 and never touch the C library.
    helper.reset()
    -- new() already rejects a NULL pointer, so build a wrapper and null
    -- out its handle to exercise the accessor guards (e.g. after free()).
    local r = result:new(helper.res())
    r.result = nil
    helper.assert_eq(r:errstr(), "")
    helper.assert_eq(r:errno(), 0)
    helper.assert_eq(#helper.calls("taos_errstr"), 0)
    helper.assert_eq(#helper.calls("taos_errno"), 0)
end)

helper.test("totable() maps a full result set to Lua tables", function()
    helper.reset()
    local rows = {
        helper.row(helper.int64_buf(1600000000000), helper.int_buf(42)),
        helper.row(helper.int64_buf(1600000000001), helper.int_buf(43)),
    }
    mock_select(rows, 3)

    local r = result:new(helper.res())
    local t = r:totable()

    helper.assert_eq(t.code, 0)
    helper.assert_eq(t.affected, 3)
    helper.assert_eq(#t.item, 2)
    helper.assert_eq(t.item[1].ts, 1600000000000)
    helper.assert_eq(t.item[1].speed, 42)
    helper.assert_eq(t.item[2].ts, 1600000000001)
    helper.assert_eq(t.item[2].speed, 43)
end)

helper.test("totable() reports query errors", function()
    helper.reset()
    helper.on("taos_errno", function() return 90001 end)
    helper.on("taos_errstr", function() return "syntax error" end)

    local r = result:new(helper.res())
    local t = r:totable()

    helper.assert_eq(t.code, 90001)
    helper.assert_eq(t.error, "syntax error")
    helper.assert_nil(t.item)
end)

helper.test("fetch_row() returns nil at end of result set", function()
    helper.reset()
    helper.on("taos_fetch_row", function()
        return ffi.new("void**", nil)
    end)

    local r = result:new(helper.res())
    helper.assert_nil(r:fetch_row())
end)

helper.test("fetch_fields() parses field metadata", function()
    helper.reset()
    helper.on("taos_field_count", function() return 2 end)
    helper.on("taos_fetch_fields", function()
        return helper.fields({ "ts", 9, 8 }, { "speed", 4, 4 })
    end)

    local r = result:new(helper.res())
    local fields = r:fetch_fields()

    helper.assert_eq(#fields, 2)
    helper.assert_eq(fields[1].name, "ts")
    helper.assert_eq(fields[1].type, 9)
    helper.assert_eq(fields[1].len, 8)
    helper.assert_eq(fields[2].name, "speed")
    helper.assert_eq(fields[2].type, 4)
end)

helper.test("passthrough methods forward to the C library", function()
    helper.reset()
    helper.on("taos_result_precision", function() return 1 end)
    helper.on("taos_num_fields", function() return 2 end)
    helper.on("taos_affected_rows", function() return 7 end)

    local r = result:new(helper.res())
    helper.assert_eq(r:precision(), 1)
    helper.assert_eq(r:num_fields(), 2)
    helper.assert_eq(r:affected_rows(), 7)

    r:stop()
    helper.assert_eq(#helper.calls("taos_stop_query"), 1)
end)

helper.test("free() releases the C result exactly once", function()
    helper.reset()
    local r = result:new(helper.res())

    r:free()
    r:free() -- idempotent

    local calls = helper.calls("taos_free_result")
    helper.assert_eq(#calls, 1)
end)

helper.test("fetch_block() forwards to the C library", function()
    helper.reset()
    helper.on("taos_fetch_block", function() return 2 end)

    local r = result:new(helper.res())
    local count, rows = r:fetch_block()

    helper.assert_eq(count, 2)
    -- rows is the out-parameter cdata (NULL-initialised; the real C
    -- library fills it).  Note: a NULL cdata compares equal to nil, so
    -- check the type rather than assert_not_nil.
    helper.assert_eq(type(rows), "cdata")
    helper.assert_eq(#helper.calls("taos_fetch_block"), 1)
end)

helper.test("fetch_lengths() forwards to the C library", function()
    helper.reset()
    helper.on("taos_fetch_lengths", function() return helper.ptr() end)

    local r = result:new(helper.res())
    local lens = r:fetch_lengths()

    helper.assert_not_nil(lens)
    helper.assert_eq(#helper.calls("taos_fetch_lengths"), 1)
end)

helper.test("totable() uses taos_fetch_lengths() for binary columns", function()
    -- S1 regression: binary/NCHAR columns are not NUL terminated and can
    -- contain embedded NULs.  totable() must slice them with the byte
    -- length reported per row instead of reading until the first NUL.
    helper.reset()
    helper.on("taos_errno", function() return 0 end)
    helper.on("taos_field_count", function() return 1 end)
    helper.on("taos_fetch_fields", function()
        return helper.fields({ "owner", 8, 10 })
    end)
    helper.on("taos_affected_rows", function() return 1 end)
    helper.on("taos_fetch_lengths", function()
        return ffi.new("int[1]", 5)
    end)

    local buf = ffi.new("char[6]")
    ffi.copy(buf, "ab\0cd")                            -- 5 bytes, embedded NUL
    local i = 0
    helper.on("taos_fetch_row", function()
        i = i + 1
        if i == 1 then
            return helper.row(buf)
        end
        return ffi.new("void**", nil)
    end)

    local r = result:new(helper.res())
    local t = r:totable()

    helper.assert_eq(t.code, 0)
    helper.assert_eq(#t.item, 1)
    helper.assert_eq(t.item[1].owner, "ab\0cd")
    -- lengths are queried once per fetched row (only the data row here).
    helper.assert_eq(#helper.calls("taos_fetch_lengths"), 1)
end)

helper.test("totable() logs an error for unknown column types", function()
    helper.reset()
    helper.on("taos_errno", function() return 0 end)
    helper.on("taos_field_count", function() return 1 end)
    helper.on("taos_fetch_fields", function()
        -- Type 999 has no converter in resty.taos.data.
        return helper.fields({ "weird", 999, 4 })
    end)
    helper.on("taos_affected_rows", function() return 1 end)
    local i = 0
    helper.on("taos_fetch_row", function()
        i = i + 1
        if i == 1 then
            return helper.row(helper.int_buf(7))
        end
        return ffi.new("void**", nil)
    end)

    local r = result:new(helper.res())
    local t = r:totable()

    helper.assert_eq(t.code, 0)
    helper.assert_eq(#t.item, 1)
    -- The unknown column must not be present in the converted row.
    helper.assert_nil(t.item[1].weird)
end)
