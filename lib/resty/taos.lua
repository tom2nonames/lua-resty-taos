local taos_lib    = require("resty.taos.library")
local taos_result = require("resty.taos.result")
local taos_async  = require("resty.taos.async")
local taos_stmt   = require("resty.taos.stmt")
local taos_pool   = require("resty.taos.pool")
local ffi = require("ffi")


local ffi_cast   = ffi.cast
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


-- Per-worker idle connection pool (see resty.taos.pool and the README).
-- It is created lazily the first time a connection is opened with
-- conf.pool = true, so drivers that do not opt in never touch it.
local pool_instance
local function get_pool()
    if pool_instance == nil then
        pool_instance = taos_pool:new({
            max_idle     = 16,
            idle_timeout = 30000, -- 30 s
            close        = function(conn)
                C.taos_close(conn)
            end,
        })
    end
    return pool_instance
end

-- Pooled connections are only interchangeable when they point at the same
-- server, user and default database.
local function pool_key_of(conf)
    return sfmt("%s:%s:%s:%s", conf.host or "", conf.port or "",
                conf.user or "", conf.database or "")
end


local _M = { _VERSION = '0.1' }


local mt = { __index = _M }

function _M.new(self)
    local cwrap = {
        conn = nil
    }
    return setmetatable(cwrap, mt)
end

local function get_error_string(res)

    local str = C.taos_errstr(res)
          str = ffi_string(str)

    return  str
end

function _M.get_error_string(self, res)
    if res ~= nil then
        return get_error_string(res)
    end
    -- A NULL cdata is truthy in Lua, so `self.conn` must be compared
    -- against nil explicitly.
    if self.conn ~= nil then
        return get_error_string(self.conn)
    end
    return "not connect."
end

local function get_error_no(res)
    return C.taos_errno(res)
end

function _M.get_error_no(self, res)
    if res ~= nil then
        return get_error_no(res)
    end
    if self.conn ~= nil then
        return get_error_no(self.conn)
    end
    return 0
end

function _M.init(self)
    C.taos_init()
end

function _M.cleanup(self)
    C.taos_cleanup()
end

function _M.get_client_info(self)
    local client_info = C.taos_get_client_info()
          client_info = ffi_string(client_info)
    return client_info
end

--[[ opts = {
        charset  = "UTF-8",
        locale   = "en_US.UTF-8",
        timezone = "UTC-8" }
--]]
function _M.options(self, opts)
    local match = {
        locale    = ffi.C.TSDB_OPTION_LOCALE,
        charset   = ffi.C.TSDB_OPTION_CHARSET,
        timezone  = ffi.C.TSDB_OPTION_TIMEZONE,
        cfgdir    = ffi.C.TSDB_OPTION_CONFIGDIR,
        -- shell_activity_timer = ffi.C.TSDB_OPTION_SHELL_ACTIVITY_TIMER,
        -- max_otpions  = ffi.C.TSDB_MAX_OPTIONS,
    }

    -- opts is a key/value map, so it must be iterated with pairs().  The
    -- previous implementation used ipairs() against the option *values*,
    -- which made this function a silent no-op.
    for k, v in pairs(opts) do
        local option = match[k]
        if option then
            C.taos_options(option, v )
        end
    end

    return true
end

function _M.connect(self, conf)
    -- Reset the pooling bookkeeping from any previous session on this
    -- driver object.
    self._pooled = nil
    self._pool_key = nil
    self._bad = nil
    self._db_dirty = nil

    -- Opt-in connection reuse: when conf.pool is set, try to take an idle
    -- connection for the same target from the per-worker pool first.
    local pkey = nil
    if conf.pool then
        pkey = pool_key_of(conf)
        local conn = get_pool():acquire(pkey)
        if conn ~= nil then
            self.conn = conn
            self._pooled = true
            self._pool_key = pkey
            return {
                code  = 0,
                conn  = conn,
                error = nil
            }
        end
    end

    local code = 0
    local err_msg = nil
    self:init()

    local port      = ffi_cast("uint16_t",      conf.port)
    local user      = ffi_cast("const char *",  conf.user)
    local password  = ffi_cast("const char *",  conf.password)
    local host      = ffi_cast("const char *",  conf.host)
    local db        = ffi_cast("const char *",  conf.database or "")

    local taos = C.taos_connect(host, user, password, db, port)

    -- On failure taos_connect returns NULL.  Note: NULL cdata is truthy in
    -- Lua, so this must be an explicit comparison against nil (and the
    -- previous `<= nil` idiom, while working, was unreadable).
    if taos == nil then
        code = -1
        -- There is no valid handle to ask for a detailed error string, so
        -- report the target instead of calling taos_errstr(NULL).
        err_msg = "failed to connect server " .. tostring(conf.host or "?")
                  .. ":" .. tostring(conf.port)
    else
        -- NOTE: we deliberately do NOT attach a ffi.gc finalizer to the
        -- connection handle.  With the TDengine 2.4 client library,
        -- attaching ANY finalizer (C function or closure) to the TAOS*
        -- handle makes tightly-looped queries segfault under LuaJIT (a
        -- client/library interaction; verified with bare FFI).  The
        -- connection is therefore released explicitly: by close(), or by
        -- the pool's idle-expiry cleanup.
        self.conn = taos
        if pkey ~= nil then
            self._pooled = true
            self._pool_key = pkey
        end
    end

    return {
        code  = code,
        conn  = taos,
        error = err_msg
    }
end

function _M.query(self, sql)
    local taos = self.conn

    local res = C.taos_query(taos, sql)
    local result = taos_result:new(res)
    if result then
        -- LEAK FIX: release the C result even when totable() raises, so
        -- an unexpected Lua error mid-conversion does not leak the result
        -- set (there is no GC finalizer: attaching one to TDengine handles
        -- segfaults with this client under tight loops).
        local ok, ret = pcall(function()
            return result:totable()
        end)
        result:free()
        if ok then
            -- A failed statement can leave the connection in an unknown
            -- state; never hand it to the next pooled user.
            if ret ~= nil and ret.code ~= 0 then
                self._bad = true
            end
            return ret
        end
        self._bad = true
        error(ret, 0)
    end

    -- No result handle at all: the C call itself failed, so the connection
    -- must not be reused by the pool either.
    self._bad = true
    return nil
end

-- Upper bound on async callbacks pinned per connection.  A driver cannot
-- know whether the C side will ever deliver a reply, so a callback that
-- never fires would otherwise pin its wrapper (and the callback trampoline)
-- forever.  Past the limit, new async work is refused instead of growing
-- the keep-alive list without bound.
local MAX_PENDING_ASYNC = 64

local function pending_asyncs(self)
    local n = 0
    local asyncs = self.asyncs
    if asyncs ~= nil then
        for _ in pairs(asyncs) do
            n = n + 1
        end
    end
    return n
end

-- Slot reuse keeps the keep-alive array compact when callbacks fire in an
-- arbitrary order.  (`#` is not reliable once a slot has been emptied.)
local function first_free_async_slot(asyncs)
    local slot = 1
    while asyncs[slot] ~= nil do
        slot = slot + 1
    end
    return slot
end

function _M.query_async(self, sql, callback)
    if type(callback) ~= "function" then
        return nil, "callback set error!"
    end
    if pending_asyncs(self) >= MAX_PENDING_ASYNC then
        return nil, sfmt("too many pending async queries (max %d)",
                         MAX_PENDING_ASYNC)
    end
    local async = taos_async:new(self)
    local ok, err = async:query(sql, callback)
    if ok then
        -- The C side may still invoke the callback after this function
        -- returns, so the async wrapper (and the callback trampoline it
        -- references) must stay alive.  Retain it on the driver until the
        -- callback fires; async.lua detaches it then (and the list is
        -- capped above, so it cannot grow without bound).
        self.asyncs = self.asyncs or {}
        local slot = first_free_async_slot(self.asyncs)
        self.asyncs[slot] = async
        async._driver = self
        async._slot = slot
    end
    return ok, err
end

function _M.fetch_rows_async(self, res, callback)
    if type(callback) ~= "function" then
        return nil, "callback set error!"
    end
    if pending_asyncs(self) >= MAX_PENDING_ASYNC then
        return nil, sfmt("too many pending async queries (max %d)",
                         MAX_PENDING_ASYNC)
    end
    local async = taos_async:new(self)
    local ok, err = async:fetch_rows(res, callback)
    if ok then
        self.asyncs = self.asyncs or {}
        local slot = first_free_async_slot(self.asyncs)
        self.asyncs[slot] = async
        async._driver = self
        async._slot = slot
    end
    return ok, err
end

function _M.close(self)
    local taos = self.conn
    local code = -1
    local err_msg = "null pointer."

    if taos ~= nil then
        -- Return the handle to the pool only when it is still reusable:
        -- a failed statement, a changed default database (select_db) or a
        -- pending async operation all leave state the next user must not
        -- inherit, so those handles are closed for real.
        if self._pooled and not self._bad and not self._db_dirty
           and self.asyncs == nil then
            get_pool():release(self._pool_key, taos)
        else
            C.taos_close(taos)
        end
        code = 0
        err_msg = "done."
    end

    if self.asyncs ~= nil then
        local pending = pending_asyncs(self)
        if pending > 0 then
            ngx_log(ngx_WARN, "taos close() with ", pending,
                    " async callback(s) still in flight; the callbacks ",
                    "must not fire after close()")
        end
    end

    self.conn = nil
    -- Release any async wrappers whose callbacks never fired.  NOTE: the
    -- C side may still hold the callback pointer, so a caller must not
    -- close() a driver while its async operations are in flight.
    self.asyncs = nil
    self._pooled = nil
    self._pool_key = nil
    self._bad = nil
    self._db_dirty = nil
    return {
        code  = code,
        error = err_msg
    }
end

function _M.get_server_info(self)
    if self.conn then
        local ver = C.taos_get_server_info(self.conn)
        ver = ffi_string(ver)
        return ver
    end
    return nil, "not connected."
end

function _M.select_db(self, db)
    if self.conn ~= nil and db then
        local recode = C.taos_select_db(self.conn, db)
        if recode < 0 then
            -- The connection is now in an unknown state: do not pool it.
            self._bad = true
            return nil, self:get_error_string()
        elseif recode == 0 then
            -- A pooled connection now points at a different database than
            -- its pool key claims, so close() must not return it.
            if self._pooled then
                self._db_dirty = true
            end
            return true, nil
        end
    end
    return nil, "param error"
end

function _M.validate_sql(self, sql)
    if self.conn == nil then
        return nil, "not connected."
    end
    local code = C.taos_validate_sql(self.conn, sql)
    return code
end

-- Create a prepared-statement wrapper bound to this connection.
function _M.stmt(self)
    if self.conn == nil then
        return nil, "not connected."
    end
    return taos_stmt:new(self.conn)
end

return _M
