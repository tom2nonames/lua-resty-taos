-- Idle-connection pool for resty.taos.
--
-- The TDengine connection handle is opaque to this module: callers pass
-- the handle together with a `close` callback that releases it
-- (taos_close).  The pool is per worker -- an nginx worker runs Lua
-- single-threaded, so a plain table is a safe store and no locking is
-- needed.
--
-- An entry expires after `idle_timeout` milliseconds and each key keeps
-- at most `max_idle` idle handles.  A pool created without a `close`
-- callback never releases expired handles; production always passes one
-- (the unit tests use this to observe what would have been closed).

local _M = { _VERSION = '0.1' }

local mt = { __index = _M }

local function now_ms()
    if ngx and ngx.now then
        return ngx.now() * 1000
    end
    return os.time() * 1000
end

function _M.new(self, opts)
    opts = opts or {}
    return setmetatable({
        max_idle     = opts.max_idle or 16,
        idle_timeout = opts.idle_timeout or 30000, -- milliseconds
        now          = opts.now or now_ms,
        close        = opts.close,
        idle         = {},
    }, mt)
end

-- Takes the most recently released handle for `key`, or nil when the
-- pool has none.  Expired entries are dropped on the way (and closed
-- when a close callback is configured).
function _M.acquire(self, key)
    local idle = self.idle[key]
    if idle == nil then
        return nil
    end

    local now = self.now()
    while #idle > 0 do
        local entry = table.remove(idle)
        if now - entry.time <= self.idle_timeout then
            return entry.conn
        end
        if self.close ~= nil then
            self.close(entry.conn)
        end
    end

    return nil
end

-- Stores a handle for later reuse.  Returns false -- after closing the
-- handle -- when the per-key limit has been reached.
function _M.release(self, key, conn)
    local idle = self.idle[key]
    if idle == nil then
        idle = {}
        self.idle[key] = idle
    end

    if #idle >= self.max_idle then
        if self.close ~= nil then
            self.close(conn)
        end
        return false
    end

    idle[#idle + 1] = { conn = conn, time = self.now() }
    return true
end

-- Number of idle handles currently held for `key`.
function _M.size(self, key)
    local idle = self.idle[key]
    if idle == nil then
        return 0
    end
    return #idle
end

-- Closes and forgets every idle handle in the pool.
function _M.clear(self)
    for key, idle in pairs(self.idle) do
        if self.close ~= nil then
            for i = 1, #idle do
                self.close(idle[i].conn)
            end
        end
        self.idle[key] = nil
    end
end

return _M
