local taos_lib  = require("resty.taos.library")
local taos_result = require("resty.taos.result")

local ffi = require("ffi")
local ffi_cast   = ffi.cast
local ffi_new    = ffi.new
local ffi_copy   = ffi.copy
local ffi_string = ffi.string

local C = taos_lib

local ngx = ngx
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERROR = ngx.ERR
local ngx_WARN  = ngx.WARN

local sfmt = string.format

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _M = { _VERSION = '0.1' }

local mt = { __index = _M }

function _M.new(self, cwrap)

    local wrapper = {
        cwrap = cwrap
    }
    return setmetatable(wrapper, mt)
end

function _M.subscribe(self, restart, topic, sql, callback, param, interval)
    local reset = restart and 1 or 0
    local subs, code = nil, -1
    -- Only set when a callback is given; keep it nil otherwise so that
    -- unsubscribe() does not try to free a plain NULL void* cdata (which
    -- LuaJIT rejects).
    local subs_handle = nil
    param = param or ffi_new("void *", nil)

    if callback and type(callback) == "function" then
        subs_handle = ffi_new("TAOS_SUBSCRIBE_CALLBACK",
            function(tsub, res, cparam, ccode)

                local result = taos_result:new(res)
                local ret = nil

                -- Note: `result` must be created before the error branch
                -- below.  Previously the error branch referenced `result`
                -- before its local declaration, which crashed with
                -- "attempt to index a nil value" whenever the C side
                -- reported a non-zero code.
                if ccode ~= 0 then
                    local err = "unknown error"
                    if result ~= nil then
                        err = result:errstr()
                    end
                    ngx_log(ngx_ERROR, "callback error, code: ", ccode, ", error: ", err)
                    ret = {
                        code = ccode,
                        error = err
                    }
                    return callback(ret)
                end

                if result then
                    ret = result:totable()
                end

                return callback(ret)

            end)
    end

    local taos = self.cwrap.conn
    local s = C.taos_subscribe(taos, reset , topic, sql , subs_handle, param, interval)

    -- NULL cdata is truthy in Lua, so compare against nil explicitly.
    if s ~= nil then
            code = 0
            subs = s
    end

    -- Keep the callback cdata referenced so it is not garbage-collected
    -- while the C side can still invoke it.  (No ffi.gc finalizer on the
    -- subscription handle: closure finalizers on TDengine handles have
    -- been shown to segfault under tight loops with this client version;
    -- the subscription is released via explicit unsubscribe().)
    self.handle = subs_handle
    self.subs = subs

    return {
        code = code,
        error = "" --self.cwrap:get_error_string() --ffi_string(C.taos_errstr(taos)),
    }
end

function _M.consume(self)
    local res = C.taos_consume(self.subs)

    local result = taos_result:new(res)
    if result then
        -- LEAK FIX: taos_consume() allocates a result set that the caller
        -- MUST release with taos_free_result() (see the official
        -- demoSubscribe.c).  It was never freed before, so every consume()
        -- in a polling loop leaked one result set -- the classic
        -- "nginx memory grows forever" symptom.  pcall() guarantees the
        -- release even if totable() raises.
        local ok, ret = pcall(function()
            return result:totable()
        end)
        result:free()
        if ok then
            return ret
        end
        error(ret, 0)
    end

    return nil

end

function _M.unsubscribe(self, keep_progress)
    if self.subs == nil then
        return nil, "not subscribed."
    end

    local keep = keep_progress and 1 or 0
    C.taos_unsubscribe(self.subs, keep)
    self.subs = nil

    -- The callback cdata is only freed after the C side has stopped
    -- invoking it (taos_unsubscribe above).
    if self.handle ~= nil then
        self.handle:free()
        self.handle = nil
    end

    return true
end

return _M