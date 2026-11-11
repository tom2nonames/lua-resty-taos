local taos_lib    = require("resty.taos.library")
local taos_data   = require("resty.taos.data")
local taos_result = require("resty.taos.result")

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

local _M = { _VERSION = '0.1-3' }

local mt = { __index = _M }

ffi_cdef([[
    typedef struct{
        CALLBACK callback;
        void *stream;
    } cb_param;
]])

function _M.new(self, cwrap)

    local wrapper = {
        cwrap = cwrap
    }
    return setmetatable(wrapper, mt)
end

function _M.open(self, sql, stime, handle, callback )
    local taos = self.cwrap.conn
    local code = -1
    local stream = nil
    local stream_handle = ffi_new("HANDLEFUNC",  function(param, res, row)


        local result = taos_result:new(res)
        if result == nil then
            -- The stream machinery can invoke the handler with a NULL
            -- result (e.g. at teardown); there is no row to convert.
            return
        end

        local fields = result:fetch_fields()
        local num_fields = result:field_count()
        -- Byte lengths of the current row, needed to convert BINARY/NCHAR
        -- columns exactly (they are not NUL-terminated and may embed NULs).
        local lens = result:fetch_lengths()

        local item = {}

        for i = 0, num_fields-1, 1 do

            if ffi_cast("void *",row[i]) > nil then
                local name = fields[i+1].name
                local type = fields[i+1].type
                local func = taos_data[type]
                local len = nil
                if lens ~= nil then
                    len = lens[i]
                end
                item[name] = func(row[i], len)
            end
        end

        -- Note: the result set is owned and freed by the TDengine stream
        -- machinery after the handler returns; do NOT call result:free()
        -- here (this has flip-flopped in git history and double-frees).

        handle(item)
    end)


    local p = ffi_new( "cb_param")
    local cb
    if callback and type(callback) == "function" then
        cb = ffi_new("CALLBACK", callback)
        self.callback = cb
        ngx_log(ngx_DEBUG, "has callback")
    else
        -- Use a NULL function pointer instead of a NULL void*: assigning
        -- the latter to the CALLBACK struct field is a type mismatch.
        cb = ffi_new("CALLBACK", nil)
        self.callback = nil

        ngx_log(ngx_DEBUG, "not callback")
    end
    p.callback = cb
    local param = ffi_new( "void *", p)

    local s = C.taos_open_stream(taos, sql, stream_handle, stime, param, cb)

    -- NULL cdata is truthy in Lua, so compare against nil explicitly.
    if s ~= nil then
        code = 0
        local sp = ffi_cast("void *",s)
        p.stream = sp
        -- `stream` is the TAOS_STREAM* handle that close() must pass back
        -- to taos_close_stream(); the cb_param `p` is kept alive in
        -- self.param so the callback context survives.
        stream = sp
    end

    self.stream = stream
    self.param = p
    self.handle = stream_handle

    return {
        code = code,
        error = self.cwrap:get_error_string(),
        stream = stream
    }
end

function _M.close(self)
    if self.stream == nil then
        return nil, "no stream opened."
    end

    C.taos_close_stream(self.stream)
    self.stream = nil
    self.param = nil

    -- The handler and callback cdata are referenced by self, so they stay
    -- alive for as long as the stream is open; the garbage collector
    -- reclaims them once unreferenced.
    self.handle = nil
    self.callback = nil
    return true
end

return _M