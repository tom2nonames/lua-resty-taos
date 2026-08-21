local taos_lib  = require("resty.taos.library")
local taos_data = require("resty.taos.data")

local ffi = require("ffi")
local ffi_cast   = ffi.cast
local ffi_new    = ffi.new
local ffi_copy   = ffi.copy
local ffi_string = ffi.string

local ffi_cdef   = ffi.cdef

local C = taos_lib

local ngx = ngx
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_WARN  = ngx.WARN

local sfmt = string.format

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _M = { _VERSION = '0.1' }

local mt = { __index = _M }

ffi_cdef([[
    typedef struct {
        CALLBACK callback;
      } async_query_callback_param;
]])

function _M.new(self, cwrap)

    local wrapper = {
        cwrap = cwrap
    }
    return setmetatable(wrapper, mt)
end

function _M.query(self, sql, callback)

    if not callback or type(callback) ~= "function" then
        return nil, "callback set error!"
    end

    local handle = ffi_new("TAOS_QUERY_CALLBACK",
                            function(param, res, code)
                                -- `callback` is captured as an upvalue and
                                -- invoked directly as a Lua function.
                                -- Previously the callback was wrapped in a
                                -- CALLBACK cdata and called with a Lua
                                -- table, which made LuaJIT raise
                                -- "cannot convert 'table' to 'void *'"
                                -- whenever the async callback fired.
                                local ret
                                if code < 0 then
                                    ret = callback({
                                            code  = code,
                                            error = self.cwrap:get_error_string(res)
                                        })
                                else
                                    local affect_rows = C.taos_affected_rows(res)
                                    ret = callback({
                                        code = 0,
                                        error = "ok",
                                        affected = affect_rows,
                                        res = res
                                    })
                                end

                                -- LEAK FIX: taos_query_a() invokes its
                                -- callback exactly once, so once we are
                                -- here the C side will never call this
                                -- trampoline again.  Drop the references so
                                -- the callback cdata (and its machine-code
                                -- trampoline) become garbage-collectable,
                                -- and remove the wrapper from the driver's
                                -- keep-alive list.  Otherwise every
                                -- query_async() leaks one wrapper + one
                                -- trampoline for the lifetime of the
                                -- driver.
                                self.handle = nil
                                self.param = nil
                                if self._driver and self._driver.asyncs
                                   and self._driver.asyncs[self._slot] == self then
                                    self._driver.asyncs[self._slot] = nil
                                end
                                return ret
                            end)

    local p = ffi_new("async_query_callback_param")
    local param = ffi_new("void *", p)

    local taos = self.cwrap.conn
    C.taos_query_a(taos, sql, handle, param)

    -- IMPORTANT: do NOT call handle:free() here.  taos_query_a() is
    -- asynchronous and may still invoke the callback after this function
    -- returns; freeing the cdata now would be a use-after-free.  Keep the
    -- reference on the wrapper so the trampoline survives until the
    -- callback has fired (the callback cdata is then reclaimed by GC once
    -- `self` goes out of scope).
    self.handle = handle
    self.param = p

    return true

end

function _M.fetch_rows(self, res, callback)
    if not callback or type(callback) ~= "function" then
        return nil, "callback set error!"
    end

    local handle = ffi_new("TAOS_QUERY_CALLBACK",
                            function(param, tres, num_of_rows)
                                -- See query(): invoke the Lua callback
                                -- directly rather than through a cdata.
                                return callback({
                                    num_of_rows = num_of_rows,
                                    res = tres
                                })
                            end)

    local p = ffi_new("async_query_callback_param")
    local param = ffi_new("void *", p)

    C.taos_fetch_rows_a(res, handle, param)

    -- See the note in query(): the callback cdata must not be freed
    -- before the async operation completes.
    self.handle = handle
    self.param = p

    return true
end

return _M