local ffi = require("ffi")

local ffi_cast   = ffi.cast
local ffi_new    = ffi.new
local ffi_copy   = ffi.copy
local ffi_string = ffi.string
local tonumber = tonumber
local sfmt = string.format

-- Convert a C float32 value to a Lua number.
--
-- Reading a C `float` through FFI promotes it to a double, which exposes
-- the float32 noise (e.g. 3.14f becomes 3.1400001049041748).  Round it to
-- the 7 significant decimal digits a float32 can actually represent.
local function c_float_to_lua(data)
    local val = ffi_cast("float *", data)
    return tonumber(sfmt("%.7g", val[0]))
end

-- Convert a C double value to a Lua number.
--
-- LuaJIT doubles are IEEE-754 doubles, identical to the C side, so the
-- value is returned as-is without any rounding (rounding here would only
-- lose precision).
local function c_double_to_lua(data)
    local val = ffi_cast("double *", data)
    return val[0]
end

-- Data type definition
local db_type = {
    TSDB_DATA_TYPE_NULL       = 0 ,    -- 1 bytes
    TSDB_DATA_TYPE_BOOL       = 1 ,    -- 1 bytes
    TSDB_DATA_TYPE_TINYINT    = 2 ,    -- 1 byte
    TSDB_DATA_TYPE_SMALLINT   = 3 ,    -- 2 bytes
    TSDB_DATA_TYPE_INT        = 4 ,    -- 4 bytes
    TSDB_DATA_TYPE_BIGINT     = 5 ,    -- 8 bytes
    TSDB_DATA_TYPE_FLOAT      = 6 ,    -- 4 bytes
    TSDB_DATA_TYPE_DOUBLE     = 7 ,    -- 8 bytes
    TSDB_DATA_TYPE_BINARY     = 8 ,    -- string
    TSDB_DATA_TYPE_TIMESTAMP  = 9 ,    -- 8 bytes
    TSDB_DATA_TYPE_NCHAR      = 10,    -- unicode string
    TSDB_DATA_TYPE_UTINYINT   = 11,    -- 1 byte
    TSDB_DATA_TYPE_USMALLINT  = 12,    -- 2 bytes
    TSDB_DATA_TYPE_UINT       = 13,    -- 4 bytes
    TSDB_DATA_TYPE_UBIGINT    = 14,    -- 8 bytes
    }

-- PERF: a single reusable buffer for the %lld/%llu conversions below.
-- LuaJIT is cooperative (one thread at a time), and ffi_string() copies
-- the bytes into a Lua string immediately, so reusing one buffer is safe
-- and avoids allocating a short-lived cdata per BIGINT/TIMESTAMP/UBIGINT
-- column while converting large result sets.
local num_buf = ffi_new("char[?]", 25)

local function c_int64_to_string(data, is_unsigned)
    local val = ffi_cast(is_unsigned and "uint64_t *" or "int64_t *", data)
    ffi.C.sprintf(num_buf, is_unsigned and "%llu" or "%lld", val[0])
    return ffi_string(num_buf)
end

local case = {}

    case[db_type.TSDB_DATA_TYPE_NULL] = function(data)
        return nil
    end

    case[db_type.TSDB_DATA_TYPE_BOOL] = function(data)
        local val = ffi_cast("char *", data)
        return tonumber(val[0])==1
    end

    case[db_type.TSDB_DATA_TYPE_TINYINT] = function(data)
        local val = ffi_cast("char *", data)
        return val[0]
    end

    case[db_type.TSDB_DATA_TYPE_SMALLINT] = function(data)
        local val = ffi_cast("short *", data)
        return val[0]
    end

    case[db_type.TSDB_DATA_TYPE_INT] = function(data)
        local val = ffi_cast("int *", data)
        return val[0]
    end

    case[db_type.TSDB_DATA_TYPE_BIGINT] = function(data)
        -- Returned as a string to preserve 64-bit precision (Lua 5.1
        -- numbers cannot represent values beyond 2^53 exactly).
        return c_int64_to_string(data, false)
    end

    case[db_type.TSDB_DATA_TYPE_FLOAT] = function(data)
        return c_float_to_lua(data)
    end

    case[db_type.TSDB_DATA_TYPE_DOUBLE] = function(data)
        return c_double_to_lua(data)
    end

    case[db_type.TSDB_DATA_TYPE_BINARY] = function(data, len)
        -- Do not rely on NUL termination.  TDengine reports the exact byte
        -- length of each value through taos_fetch_lengths(); a fixed-length
        -- BINARY column is not guaranteed to be NUL terminated (reading it
        -- with ffi_string(data) can overrun the buffer) and the value may
        -- legitimately contain embedded NULs (which would be silently
        -- truncated).  Callers that pass a length get an exact slice.
        if len ~= nil then
            return ffi_string(data, len)
        end
        -- Historical fallback for callers that do not supply a length.
        return ffi_string(data)
    end

    case[db_type.TSDB_DATA_TYPE_TIMESTAMP] = function(data)
        return tonumber(c_int64_to_string(data, false))
    end

    case[db_type.TSDB_DATA_TYPE_NCHAR] = function(data, len)
        -- NCHAR values are UTF-8 byte strings; the C library reports the
        -- byte length via taos_fetch_lengths().  Use it for the same
        -- reasons as BINARY above (no NUL-termination guarantee, embedded
        -- NULs, fixed-length columns).
        if len ~= nil then
            return ffi_string(data, len)
        end
        return ffi_string(data)
    end

    case[db_type.TSDB_DATA_TYPE_UTINYINT] = function(data)
        -- Must be read as unsigned: casting to (signed) char turned values
        -- above 127 into negative numbers.
        local val = ffi_cast("uint8_t *", data)
        return val[0]
    end

    case[db_type.TSDB_DATA_TYPE_USMALLINT] = function(data)
        local val = ffi_cast("uint16_t *", data)
        return val[0]
    end

    case[db_type.TSDB_DATA_TYPE_UINT] = function(data)
        local val = ffi_cast("uint32_t *", data)
        return val[0]
    end

    case[db_type.TSDB_DATA_TYPE_UBIGINT] = function(data)
        -- Must print with %llu on a uint64_t: using %lld here would turn
        -- values above 2^63 into negative numbers.
        return tonumber(c_int64_to_string(data, true))
    end


return case
