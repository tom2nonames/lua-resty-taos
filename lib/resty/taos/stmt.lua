local taos_lib  = require("resty.taos.library")
local taos_data = require("resty.taos.data")

local ffi = require("ffi")
local ffi_cast   = ffi.cast
local ffi_new    = ffi.new
local ffi_copy   = ffi.copy
local ffi_string = ffi.string

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

function _M.new(self, conn)

    if conn == nil then
        return nil, "not connected."
    end

    local stmt = C.taos_stmt_init(conn)

    -- NOTE: no ffi.gc finalizer.  Attaching finalizers to TDengine handles
    -- has been shown to segfault under tight loops with the 2.4 client
    -- (verified with bare FFI), so the statement is released exclusively
    -- by the explicit close().
    local wrapper = {
        stmt = stmt
    }
    return setmetatable(wrapper, mt)
end

-- The SQL length is optional; when omitted it is derived from the string
-- itself (previously the caller had to pass it explicitly).
function _M.prepare(self, sql, length)
    length = length or #sql
    return C.taos_stmt_prepare(self.stmt, sql, length)
end

function _M.bind_param(self, bind)
    return C.taos_stmt_bind_param(self.stmt, bind)
end

function _M.add_batch(self)
    return C.taos_stmt_add_batch(self.stmt)
end


function _M.execute(self)
    return C.taos_stmt_execute(self.stmt)
end


function _M.use_result(self)
    local res = C.taos_stmt_use_result(self.stmt)
    return res
end

function _M.close(self)
    -- Releases the prepared statement (there is no GC finalizer, so this
    -- must be called explicitly).
    C.taos_stmt_close(self.stmt)
    self.stmt = nil
end

return _M