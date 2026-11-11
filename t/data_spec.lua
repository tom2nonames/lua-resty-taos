-- Tests for resty.taos.data: TDengine column type -> Lua value conversion.
--
-- These tests use real FFI buffers (no C library needed): each case
-- function receives a pointer to a value and must convert it.

local ffi = require("ffi")

local helper = require("t.helper")
local data = require("resty.taos.data")

local T = {
    NULL      = 0,
    BOOL      = 1,
    TINYINT   = 2,
    SMALLINT  = 3,
    INT       = 4,
    BIGINT    = 5,
    FLOAT     = 6,
    DOUBLE    = 7,
    BINARY    = 8,
    TIMESTAMP = 9,
    NCHAR     = 10,
    UTINYINT  = 11,
    USMALLINT = 12,
    UINT      = 13,
    UBIGINT   = 14,
}

helper.suite("data")

helper.test("NULL converts to nil", function()
    helper.assert_nil(data[T.NULL](helper.ptr()))
end)

helper.test("BOOL: 1 -> true, 0 -> false", function()
    helper.assert_eq(data[T.BOOL](ffi.new("char[1]", 1)), true)
    helper.assert_eq(data[T.BOOL](ffi.new("char[1]", 0)), false)
end)

helper.test("TINYINT signed conversion", function()
    helper.assert_eq(data[T.TINYINT](ffi.new("char[1]", -5)), -5)
    helper.assert_eq(data[T.TINYINT](ffi.new("char[1]", 127)), 127)
end)

helper.test("SMALLINT conversion", function()
    helper.assert_eq(data[T.SMALLINT](ffi.new("short[1]", 12345)), 12345)
    helper.assert_eq(data[T.SMALLINT](ffi.new("short[1]", -12345)), -12345)
end)

helper.test("INT conversion", function()
    helper.assert_eq(data[T.INT](ffi.new("int[1]", -123456)), -123456)
    helper.assert_eq(data[T.INT](ffi.new("int[1]", 2147483647)), 2147483647)
end)

helper.test("BIGINT is returned as a string to preserve precision", function()
    -- 2^53 + 1 is not representable exactly as a Lua 5.1 number, so the
    -- driver deliberately returns BIGINT as a string.  (The test value is
    -- given as a hex int64 literal: the decimal literal itself would lose
    -- precision before reaching ffi.new.)
    helper.assert_eq(data[T.BIGINT](ffi.new("int64_t[1]", 12345678901234)), "12345678901234")
    helper.assert_eq(data[T.BIGINT](ffi.new("int64_t[1]", 0x20000000000001LL)), "9007199254740993")
    helper.assert_eq(data[T.BIGINT](ffi.new("int64_t[1]", -9876543210)), "-9876543210")
end)

helper.test("FLOAT is rounded to float32 precision", function()
    -- 3.14f read through FFI is 3.1400001049041748; it must come back as 3.14.
    helper.assert_close(data[T.FLOAT](ffi.new("float[1]", 3.14)), 3.14, 1e-6)
    helper.assert_close(data[T.FLOAT](ffi.new("float[1]", 0.1)), 0.1, 1e-6)
    helper.assert_eq(data[T.FLOAT](ffi.new("float[1]", 100.0)), 100)
    helper.assert_close(data[T.FLOAT](ffi.new("float[1]", -3.14)), -3.14, 1e-6)
    -- Max float32 precision: 3.1415927f reads back as 3.1415927410125732.
    helper.assert_close(data[T.FLOAT](ffi.new("float[1]", 3.1415927)), 3.141593, 1e-6)
end)

helper.test("DOUBLE is returned exactly (no precision loss)", function()
    -- LuaJIT doubles are IEEE-754 doubles identical to the C side, so the
    -- value must round-trip bit-exactly without the old rounding helper.
    local v = 3.141592653589793
    helper.assert_eq(data[T.DOUBLE](ffi.new("double[1]", v)), v)
    helper.assert_eq(data[T.DOUBLE](ffi.new("double[1]", 1e300)), 1e300)
    helper.assert_eq(data[T.DOUBLE](ffi.new("double[1]", -0.5)), -0.5)
    helper.assert_eq(data[T.DOUBLE](ffi.new("double[1]", 0)), 0)
end)

helper.test("BINARY and NCHAR strings", function()
    helper.assert_eq(data[T.BINARY](helper.char_buf("hello")), "hello")
    helper.assert_eq(data[T.NCHAR](helper.char_buf("中文")), "中文")
    helper.assert_eq(data[T.BINARY](helper.char_buf("")), "")
end)

helper.test("BINARY/NCHAR honour an explicit byte length", function()
    -- S1 regression: a fixed-length BINARY column is not guaranteed to be
    -- NUL terminated, and its value may legitimately contain embedded NULs.
    -- The converter must use the byte length reported by
    -- taos_fetch_lengths() instead of reading until the first NUL.
    local embedded = ffi.new("char[6]")
    ffi.copy(embedded, "ab\0cd")                       -- 5 bytes + terminator
    helper.assert_eq(data[T.BINARY](embedded, 5), "ab\0cd")
    helper.assert_eq(data[T.BINARY](embedded, 2), "ab")

    -- Buffer with no NUL terminator at all: the old ffi_string(data) would
    -- read past the end of the allocation.
    local raw = ffi.new("char[3]")
    ffi.copy(raw, "abc", 3)
    helper.assert_eq(data[T.BINARY](raw, 3), "abc")

    -- A reported length of zero means the empty string.
    helper.assert_eq(data[T.BINARY](embedded, 0), "")

    -- NCHAR is a UTF-8 byte string; slicing by byte length is exact.
    local cn = helper.char_buf("中文")
    helper.assert_eq(data[T.NCHAR](cn, 6), "中文")
    helper.assert_eq(data[T.NCHAR](cn, 3), "中")

    -- Without a length the historical NUL-terminated behaviour is kept.
    helper.assert_eq(data[T.BINARY](embedded), "ab")
    helper.assert_eq(data[T.NCHAR](helper.char_buf("中文")), "中文")
end)

helper.test("TIMESTAMP converts to a Lua number", function()
    helper.assert_eq(data[T.TIMESTAMP](ffi.new("int64_t[1]", 1600000000000)), 1600000000000)
    helper.assert_eq(data[T.TIMESTAMP](ffi.new("int64_t[1]", -1)), -1)
end)

helper.test("unsigned integer types", function()
    -- Regression: the driver used to read unsigned values through signed
    -- casts, so 200 (UTINYINT) came back as -56, 60000 (USMALLINT) as
    -- -5536 and 4000000000 (UINT) as -294967296.
    helper.assert_eq(data[T.UTINYINT](ffi.new("uint8_t[1]", 200)), 200)
    helper.assert_eq(data[T.USMALLINT](ffi.new("uint16_t[1]", 60000)), 60000)
    helper.assert_eq(data[T.UINT](ffi.new("uint32_t[1]", 4000000000)), 4000000000)
    -- Values in the signed range keep working.
    helper.assert_eq(data[T.UTINYINT](ffi.new("uint8_t[1]", 5)), 5)
    helper.assert_eq(data[T.UINT](ffi.new("uint32_t[1]", 42)), 42)
end)

helper.test("UBIGINT above 2^63 stays positive", function()
    -- Regression: the old code printed uint64 values with %lld, so
    -- 2^63 (0x8000000000000000) came back as a *negative* number.
    local buf = ffi.new("uint64_t[1]", 9223372036854775808ULL)
    local v = data[T.UBIGINT](buf)
    helper.assert_true(v > 0, "2^63 must convert to a positive number")
    helper.assert_close(v, 9223372036854775808.0, 1e-3)
    -- Small values keep working.
    helper.assert_eq(data[T.UBIGINT](ffi.new("uint64_t[1]", 42)), 42)
end)
