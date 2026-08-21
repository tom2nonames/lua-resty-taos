-- Tests for resty.taos.library: FFI type registration and the graceful
-- fallback when the native libtaos is not installed.

local helper = require("t.helper")

helper.suite("library")

helper.test("cdef types are registered", function()
    -- Requiring any module that depends on the library registers these
    -- types; if the cdef block had not run, ffi.typeof would raise.
    local ffi = require("ffi")
    helper.assert_not_nil(ffi.typeof("TAOS *"))
    helper.assert_not_nil(ffi.typeof("TAOS_RES *"))
    helper.assert_not_nil(ffi.typeof("TAOS_STMT *"))
    helper.assert_not_nil(ffi.typeof("TAOS_STREAM *"))
    helper.assert_not_nil(ffi.typeof("TAOS_SUB *"))
    helper.assert_not_nil(ffi.typeof("TAOS_FIELD"))
    helper.assert_not_nil(ffi.typeof("TAOS_QUERY_CALLBACK"))
    helper.assert_not_nil(ffi.typeof("TSDB_OPTION"))
end)

-- Only meaningful when the native library is absent (e.g. CI without
-- libtaos installed).  When libtaos is present these tests are skipped.
helper.test("placeholder raises a descriptive error when called", function()
    if helper.has_real_lib then
        return -- native library present; nothing to test here
    end

    local lib = helper.loaded_native
    helper.assert_true(lib._placeholder, "expected the placeholder fallback")

    helper.assert_error(function()
        lib.taos_connect("127.0.0.1", "root", "", "", 6030)
    end, "not loaded")
end)
