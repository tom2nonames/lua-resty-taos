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

-- Removes a fired wrapper from its driver's keep-alive list.
--
-- Do NOT clear self.handle / self.param here: this runs inside the callback
-- trampoline, while the machine code C invoked is still on the stack.
-- Dropping the last Lua reference to the callback cdata from here would let
-- the GC free that machine code mid-call (use-after-free).  Removing the
-- driver reference is enough: with no other reference the
-- self -> callback cdata -> closure -> self cycle becomes garbage and is
-- reclaimed only after this trampoline has returned.
local function detach(self)
    local driver = self._driver
    if driver ~= nil and driver.asyncs ~= nil
       and driver.asyncs[self._slot] == self then
        driver.asyncs[self._slot] = nil
    end
    self._driver = nil
    self._slot = nil
end

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
                                -- The driver no longer needs to keep this
                                -- wrapper alive.  Detach first so a user
                                -- callback that raises cannot pin it, but
                                -- keep self.handle/self.param referenced
                                -- until the trampoline returns (see
                                -- detach()).
                                detach(self)

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
                                -- See query(): detach first (so a raising
                                -- callback cannot pin the wrapper), then
                                -- invoke the Lua callback directly rather
                                -- than through a cdata.
                                detach(self)
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