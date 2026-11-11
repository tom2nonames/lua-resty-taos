-- Test helper for lua-resty-taos.
--
-- Provides:
--   * a minimal assertion framework (no external dependencies, runs on
--     plain LuaJIT)
--   * an `ngx` global stub so the library modules can be loaded outside of
--     OpenResty
--   * a mock for `resty.taos.library` that records every C call and lets
--     tests script the return values
--
-- IMPORTANT (single-require constraint): the modules under test declare
-- their FFI types with ffi.cdef(), which LuaJIT refuses to re-run.  Every
-- module (and the real resty.taos.library) must therefore be required
-- exactly once per process.  The mock is a single mutable instance shared
-- by all specs: tests script it per-case with helper.on() and reset it
-- with helper.reset().

local ffi = require("ffi")

local _M = {}

---------------------------------------------------------------------------
-- Assertion framework
---------------------------------------------------------------------------

local tests = {}
-- Exported so external runners (e.g. the coverage runner) can execute the
-- registered tests without going through run()/os.exit.
_M.tests = tests
local current_suite = "default"
local assert_count = 0
local failure_count = 0

local sfmt = string.format

function _M.suite(name)
    current_suite = name
end

function _M.test(name, fn)
    tests[#tests + 1] = { suite = current_suite, name = name, fn = fn }
end

local function fmt_val(v)
    if v == nil then
        return "nil"
    end
    local t = type(v)
    if t == "cdata" then
        return tostring(v) .. " (" .. t .. ")"
    end
    return sfmt("%q (%s)", tostring(v), t)
end

local function fail(msg)
    failure_count = failure_count + 1
    error("ASSERTION FAILED: " .. msg, 3)
end

function _M.assert_eq(actual, expected, msg)
    assert_count = assert_count + 1
    if actual ~= expected then
        fail(sfmt("%s: expected %s, got %s",
                  msg or "assert_eq", fmt_val(expected), fmt_val(actual)))
    end
end

function _M.assert_true(v, msg)
    assert_count = assert_count + 1
    if not v then
        fail(sfmt("%s: expected truthy value, got %s", msg or "assert_true", fmt_val(v)))
    end
end

function _M.assert_false(v, msg)
    assert_count = assert_count + 1
    if v then
        fail(sfmt("%s: expected falsy value, got %s", msg or "assert_false", fmt_val(v)))
    end
end

function _M.assert_nil(v, msg)
    assert_count = assert_count + 1
    if v ~= nil then
        fail(sfmt("%s: expected nil, got %s", msg or "assert_nil", fmt_val(v)))
    end
end

function _M.assert_not_nil(v, msg)
    assert_count = assert_count + 1
    if v == nil then
        fail(sfmt("%s: expected non-nil value, got nil", msg or "assert_not_nil"))
    end
end

-- Numeric comparison within a tolerance (for float round-tripping).
function _M.assert_close(actual, expected, eps, msg)
    assert_count = assert_count + 1
    eps = eps or 1e-9
    if type(actual) ~= "number" or math.abs(actual - expected) > eps then
        fail(sfmt("%s: expected %s within %s, got %s",
                  msg or "assert_close", fmt_val(expected), tostring(eps), fmt_val(actual)))
    end
end

-- Asserts that fn() raises an error whose message contains `pattern`.
function _M.assert_error(fn, pattern, msg)
    assert_count = assert_count + 1
    local ok, err = pcall(fn)
    if ok then
        fail(sfmt("%s: expected an error%s, but no error was raised",
                  msg or "assert_error",
                  pattern and sfmt(" matching %q", pattern) or ""))
    end
    if pattern and not tostring(err):find(pattern, 1, true) then
        fail(sfmt("%s: error %q does not contain %q", msg or "assert_error",
                  tostring(err), pattern))
    end
end

function _M.run()
    local passed = 0
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            io.write(sfmt("  [PASS] %s :: %s\n", t.suite, t.name))
        else
            io.write(sfmt("  [FAIL] %s :: %s\n         %s\n",
                          t.suite, t.name, tostring(err)))
        end
    end
    io.write(sfmt("\n%d/%d tests passed (%d assertions)\n",
                  passed, #tests, assert_count))
    if passed ~= #tests or failure_count ~= 0 then
        os.exit(1)
    end
    os.exit(0)
end

---------------------------------------------------------------------------
-- ngx global stub
---------------------------------------------------------------------------

function _M.setup_ngx()
    if not ngx then
        -- Constants mirror real OpenResty values: log levels are
        -- STDERR=0..DEBUG=8, while ngx.ERROR is the API error return
        -- code (-1), NOT a log level.  Using the wrong one (e.g.
        -- ngx.log(ngx.ERROR, ...)) is a real bug that only shows up
        -- against the real ngx.log, so keep the stub faithful.
        ngx = {
            STDERR  = 0,
            EMERG   = 1,
            ALERT   = 2,
            CRIT    = 3,
            ERR     = 4,
            WARN    = 5,
            NOTICE  = 6,
            INFO    = 7,
            DEBUG   = 8,
            ERROR   = -1,
            -- Mirrors the real ngx.log validation: the first argument must
            -- be a log level (0..8), so passing ngx.ERROR (-1) raises.
            log = function(level, ...)
                if type(level) ~= "number" or level < 0 or level > 8 then
                    error("bad log level: " .. tostring(level), 2)
                end
            end,
            update_time = function() end,
            now     = function() return 0 end,
            sleep   = function() end,
            thread  = { spawn = function() end },
        }
    end
end

---------------------------------------------------------------------------
-- FFI helper values
---------------------------------------------------------------------------

-- A non-NULL pointer that can stand in for any TAOS_* handle.
local fake_storage = ffi.new("char[64]")

function _M.ptr()
    return ffi.cast("void *", fake_storage)
end

function _M.null()
    return ffi.new("void *", nil)
end

-- Builds a TAOS_ROW (void**) whose columns point at the given buffers.
--
-- The returned pointer is raw address data: ffi.cast() does not keep the
-- row array (or buffers created inline at the call site) reachable, so
-- without an anchor the GC can collect them while the library is still
-- dereferencing the row.  That use-after-free is invisible most of the
-- time but turns into garbage reads (and segfaults) under a debug hook,
-- which runs the GC much more often.
local row_anchors = {}

function _M.row(...)
    local cols = { ... }
    local arr = ffi.new("void *[?]", #cols)
    for i = 1, #cols do
        arr[i - 1] = ffi.cast("void *", cols[i])
    end
    row_anchors[#row_anchors + 1] = { arr = arr, cols = cols }
    return ffi.cast("void **", arr)
end

function _M.int_buf(v)
    local b = ffi.new("int[1]", v)
    return b
end

function _M.int64_buf(v)
    local b = ffi.new("int64_t[1]", v)
    return b
end

function _M.double_buf(v)
    local b = ffi.new("double[1]", v)
    return b
end

function _M.float_buf(v)
    local b = ffi.new("float[1]", v)
    return b
end

function _M.char_buf(s)
    local b = ffi.new("char[?]", #s + 1)
    ffi.copy(b, s)
    return b
end

-- Builds a TAOS_FIELD[] array from {name, type, bytes} triples.
function _M.fields(...)
    local specs = { ... }
    local arr = ffi.new("TAOS_FIELD[?]", #specs)
    for i, s in ipairs(specs) do
        ffi.copy(arr[i - 1].name, s[1])
        arr[i - 1].type = s[2]
        arr[i - 1].bytes = s[3]
    end
    return arr
end

-- A fake TAOS_RES* handle (result set).
function _M.res()
    return ffi.cast("TAOS_RES *", _M.ptr())
end

---------------------------------------------------------------------------
-- Mock for resty.taos.library
---------------------------------------------------------------------------

-- Every C symbol the Lua side may call.  Unlisted symbols are created on
-- demand by __index, so a mock never fails on an unexpected function name.
local SYMBOLS = {
    "taos_init", "taos_cleanup", "taos_options", "taos_set_config",
    "taos_connect", "taos_connect_auth", "taos_close",
    "taos_stmt_init", "taos_stmt_prepare", "taos_stmt_set_tbname_tags",
    "taos_stmt_set_tbname", "taos_stmt_set_sub_tbname", "taos_stmt_is_insert",
    "taos_stmt_num_params", "taos_stmt_get_param", "taos_stmt_bind_param",
    "taos_stmt_bind_param_batch", "taos_stmt_bind_single_param_batch",
    "taos_stmt_add_batch", "taos_stmt_execute", "taos_stmt_use_result",
    "taos_stmt_close", "taos_stmt_errstr",
    "taos_query", "taos_fetch_row", "taos_result_precision",
    "taos_free_result", "taos_field_count", "taos_num_fields",
    "taos_affected_rows", "taos_fetch_fields", "taos_select_db",
    "taos_print_row", "taos_print_row_ex", "taos_print_field",
    "taos_stop_query", "taos_is_null", "taos_is_update_query",
    "taos_fetch_block", "taos_fetch_lengths", "taos_result_block",
    "taos_validate_sql", "taos_reset_current_db",
    "taos_get_server_info", "taos_get_client_info",
    "taos_errstr", "taos_errno",
    "taos_query_a", "taos_fetch_rows_a",
    "taos_subscribe", "taos_consume", "taos_unsubscribe",
    "taos_open_stream", "taos_close_stream", "taos_load_table_info",
    "taos_schemaless_insert", "taos_parse_time",
}

local mock = nil

-- Scriptable call handlers; a handler receives the recorded args unpacked
-- and its return value(s) become the mock's return value(s).
local handlers = {}
-- Recorded calls: { {name=..., args={...}}, ... }
local calls = {}

local function record(name, args)
    calls[#calls + 1] = { name = name, args = args }
end

function _M.reset()
    handlers = {}
    calls = {}
end

-- Registers (or replaces) a handler for symbol `name`.
function _M.on(name, fn)
    handlers[name] = fn
end

-- Returns the list of recorded calls for `name` (or all calls when nil).
function _M.calls(name)
    if name == nil then
        return calls
    end
    local out = {}
    for _, c in ipairs(calls) do
        if c.name == name then
            out[#out + 1] = c
        end
    end
    return out
end

-- Returns the args of the nth call to `name` (1-based), or nil.
function _M.called(name, n)
    local cs = _M.calls(name)
    n = n or 1
    if cs[n] then
        return cs[n].args
    end
    return nil
end

local function invoke(name, ...)
    local args = { ... }
    record(name, args)
    local h = handlers[name]
    if h then
        return h(...)
    end
    -- Sensible defaults for void / informational functions so tests do
    -- not need to script everything.
    if name == "taos_errno" then
        return 0
    elseif name == "taos_errstr" then
        return "mock: no error"
    elseif name == "taos_field_count" or name == "taos_num_fields"
        or name == "taos_affected_rows" then
        return 0
    elseif name == "taos_validate_sql" or name == "taos_select_db" then
        return 0
    elseif name == "taos_get_client_info" or name == "taos_get_server_info" then
        return "mock: " .. name
    end
    return nil
end

-- Creates the shared mock instance and installs it as
-- package.loaded["resty.taos.library"].  Must run before any module under
-- test is required.  Returns the mock.
function _M.install_mock()
    if mock then
        return mock
    end
    mock = setmetatable({}, {
        __index = function(_, name)
            local fn = function(...)
                return invoke(name, ...)
            end
            rawset(mock, name, fn)
            return fn
        end
    })
    for _, name in ipairs(SYMBOLS) do
        rawset(mock, name, function(...)
            return invoke(name, ...)
        end)
    end
    package.loaded["resty.taos.library"] = mock
    return mock
end

---------------------------------------------------------------------------
-- Module loading (single-require aware)
---------------------------------------------------------------------------

-- Registers the real FFI cdefs once, then installs the mock.  Call this in
-- run.lua before loading any spec.
function _M.init()
    _M.setup_ngx()
    -- Require the real library module: registers every FFI type via
    -- ffi.cdef() and, when libtaos is absent, returns the placeholder.
    -- We then discard it in favour of the mock.
    local real = require("resty.taos.library")
    _M.loaded_native = real
    -- Expose whether the real libtaos is available (placeholder loaded).
    _M.has_real_lib = not (real and real._placeholder)
    _M.install_mock()
end

-- Returns the (cached) module under test; the mock installed by init()
-- is what its `C` handle points at.
function _M.require_module(name)
    return require(name)
end

return _M
