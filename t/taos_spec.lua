-- Tests for resty.taos: the top-level driver API (connect/query/close/...).

local ffi = require("ffi")

local helper = require("t.helper")
local taos = require("resty.taos")

local DEFAULT_CONF = {
    host = "127.0.0.1",
    port = 6030,
    database = "",
    user = "root",
    password = "taosdata",
}

helper.suite("taos")

local function connect_ok(driver)
    helper.on("taos_connect", function()
        return helper.ptr()
    end)
    local res = driver:connect(DEFAULT_CONF)
    helper.assert_eq(res.code, 0, "connect should succeed")
    return res
end

-- Scripts the mock to serve a 2-column result set through taos_query.
local function mock_query_result()
    helper.on("taos_query", function() return helper.res() end)
    helper.on("taos_errno", function() return 0 end)
    helper.on("taos_field_count", function() return 2 end)
    helper.on("taos_fetch_fields", function()
        return helper.fields({ "ts", 9, 8 }, { "speed", 4, 4 })
    end)
    helper.on("taos_affected_rows", function() return 1 end)
    local i = 0
    helper.on("taos_fetch_row", function()
        i = i + 1
        if i == 1 then
            return helper.row(helper.int64_buf(1600000000000), helper.int_buf(42))
        end
        return ffi.new("void**", nil)
    end)
end

helper.test("new() returns an unconnected driver", function()
    local driver = taos:new()
    helper.assert_not_nil(driver)
    helper.assert_nil(driver.conn)
end)

helper.test("connect() succeeds and forwards connection args", function()
    helper.reset()
    local driver = taos:new()
    local res = connect_ok(driver)

    helper.assert_eq(res.code, 0)
    helper.assert_not_nil(res.conn)
    helper.assert_eq(driver.conn, res.conn)

    -- taos_init() must be called before connecting.
    helper.assert_eq(#helper.calls("taos_init"), 1)

    local args = helper.called("taos_connect")
    helper.assert_eq(args[1], "127.0.0.1")
    helper.assert_eq(args[2], "root")
    helper.assert_eq(args[3], "taosdata")
    helper.assert_eq(args[4], "")
    helper.assert_eq(args[5], 6030)
end)

helper.test("connect() with a missing database defaults to empty string", function()
    helper.reset()
    local driver = taos:new()
    local conf = { host = "127.0.0.1", port = 6030, user = "root", password = "taosdata" }
    helper.on("taos_connect", function() return helper.ptr() end)
    local res = driver:connect(conf)
    helper.assert_eq(res.code, 0)
    helper.assert_eq(helper.called("taos_connect")[4], "")
end)

helper.test("connect() failure reports code -1 and keeps conn nil", function()
    helper.reset()
    local driver = taos:new()
    helper.on("taos_connect", function() return nil end)

    local res = driver:connect(DEFAULT_CONF)

    helper.assert_eq(res.code, -1)
    helper.assert_nil(res.conn)
    -- Regression: on failure the wrapper must NOT hold a NULL cdata as
    -- `conn` (NULL cdata is truthy, which used to break later checks and
    -- lead to taos_errstr(NULL) calls).
    helper.assert_nil(driver.conn)
    helper.assert_true(tostring(res.error):find("failed to connect server", 1, true) ~= nil)
end)

helper.test("close() closes an open connection and is idempotent-safe", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    local c = driver:close()
    helper.assert_eq(c.code, 0)
    helper.assert_eq(#helper.calls("taos_close"), 1)
    helper.assert_nil(driver.conn)

    -- Closing again reports an error instead of calling the C library.
    local c2 = driver:close()
    helper.assert_eq(c2.code, -1)
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("options() forwards every configured option", function()
    helper.reset()
    local driver = taos:new()
    local ok = driver:options({
        locale = "en_US.UTF-8",
        charset = "UTF-8",
        timezone = "UTC-8",
    })
    helper.assert_true(ok)

    -- Regression: options() previously used ipairs() over a map, which
    -- iterated zero times and silently did nothing.
    local calls = helper.calls("taos_options")
    helper.assert_eq(#calls, 3)

    -- Enum order from the cdef: LOCALE=0, CHARSET=1, TIMEZONE=2, CONFIGDIR=3.
    local seen = {}
    for _, c in ipairs(calls) do
        local opt, val = c.args[1], c.args[2]
        seen[opt] = val
    end
    helper.assert_eq(seen[0], "en_US.UTF-8")
    helper.assert_eq(seen[1], "UTF-8")
    helper.assert_eq(seen[2], "UTC-8")
end)

helper.test("query() returns converted rows and frees the C result", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)
    mock_query_result()

    local t = driver:query("select * from m1")

    helper.assert_eq(t.code, 0)
    helper.assert_eq(t.affected, 1)
    helper.assert_eq(#t.item, 1)
    helper.assert_eq(t.item[1].ts, 1600000000000)
    helper.assert_eq(t.item[1].speed, 42)
    helper.assert_eq(#helper.calls("taos_free_result"), 1)
end)

helper.test("query() error path returns code and message", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)
    helper.on("taos_query", function() return helper.res() end)
    helper.on("taos_errno", function() return 90001 end)
    helper.on("taos_errstr", function() return "syntax error" end)

    local t = driver:query("bad sql")

    helper.assert_eq(t.code, 90001)
    helper.assert_eq(t.error, "syntax error")
    helper.assert_nil(t.item)
end)

helper.test("select_db() forwards and reports results", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    helper.on("taos_select_db", function() return 0 end)
    local ok, err = driver:select_db("demo")
    helper.assert_true(ok)
    helper.assert_nil(err)

    helper.on("taos_select_db", function() return -1 end)
    helper.on("taos_errstr", function() return "no such database" end)
    local ok2, err2 = driver:select_db("nope")
    helper.assert_nil(ok2)
    helper.assert_eq(err2, "no such database")
end)

helper.test("validate_sql() forwards; not connected is reported", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    helper.on("taos_validate_sql", function() return 0 end)
    helper.assert_eq(driver:validate_sql("select 1"), 0)

    local d2 = taos:new()
    local code, err = d2:validate_sql("select 1")
    helper.assert_nil(code)
    helper.assert_eq(err, "not connected.")
end)

helper.test("server/client info", function()
    helper.reset()
    local driver = taos:new()
    helper.assert_eq(driver:get_client_info(), "mock: taos_get_client_info")

    connect_ok(driver)
    helper.assert_eq(driver:get_server_info(), "mock: taos_get_server_info")

    local d2 = taos:new()
    local v, err = d2:get_server_info()
    helper.assert_nil(v)
    helper.assert_eq(err, "not connected.")
end)

helper.test("error helpers are safe before connecting", function()
    helper.reset()
    local driver = taos:new()
    helper.assert_eq(driver:get_error_string(), "not connect.")
    helper.assert_eq(driver:get_error_no(), 0)
    helper.assert_eq(#helper.calls("taos_errstr"), 0)
    helper.assert_eq(#helper.calls("taos_errno"), 0)
end)

helper.test("error helpers forward an explicit res", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    helper.on("taos_errstr", function() return "custom error" end)
    helper.on("taos_errno", function() return 1234 end)

    -- With an explicit result handle both the string and the number
    -- helper must forward to the C library.
    helper.assert_eq(driver:get_error_string(helper.res()), "custom error")
    helper.assert_eq(driver:get_error_no(helper.res()), 1234)
end)

helper.test("get_error_no() falls back to the connection handle", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    -- No res given, but the driver is connected: taos_errno must be
    -- called with the connection handle.
    helper.on("taos_errno", function() return 42 end)
    helper.assert_eq(driver:get_error_no(), 42)
    helper.assert_eq(#helper.calls("taos_errno"), 1)
end)

helper.test("cleanup() forwards to taos_cleanup", function()
    helper.reset()
    local driver = taos:new()
    driver:cleanup()
    helper.assert_eq(#helper.calls("taos_cleanup"), 1)
end)

helper.test("query() re-raises when row conversion raises", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)
    helper.on("taos_query", function() return helper.res() end)
    -- Force totable() to raise; query() must still release the result
    -- (pcall guard) and re-raise the original error.
    helper.on("taos_errno", function() error("conversion boom") end)
    helper.assert_error(function()
        driver:query("select 1")
    end, "conversion boom")
    -- The C result set must have been freed despite the error.
    helper.assert_eq(#helper.calls("taos_free_result"), 1)
end)

helper.test("query() returns nil when no result wrapper can be built", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)
    -- taos_query returns a non-TAOS_RES value: taos_result:new() yields
    -- nil and query() must return nil.
    helper.on("taos_query", function() return 42 end)
    helper.assert_nil(driver:query("select 1"))
end)

helper.test("select_db() without a connection reports param error", function()
    helper.reset()
    local driver = taos:new()
    local ok, err = driver:select_db("demo")
    helper.assert_nil(ok)
    helper.assert_eq(err, "param error")
end)

helper.test("query_async() and fetch_rows_async() delegate to the async module", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    local ok = driver:query_async("select 1", function() end)
    helper.assert_true(ok)
    helper.assert_eq(#helper.calls("taos_query_a"), 1)

    local ok2 = driver:fetch_rows_async(helper.res(), function() end)
    helper.assert_true(ok2)
    helper.assert_eq(#helper.calls("taos_fetch_rows_a"), 1)
end)

helper.test("driver retains async wrappers so callbacks stay alive", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)

    -- Regression: query_async() used to drop the async wrapper as soon as
    -- it returned; the wrapper holds the C callback trampoline, so once
    -- the wrapper was garbage-collected the still-pending async callback
    -- became a use-after-free.  The driver must retain every wrapper.
    local ok = driver:query_async("select 1", function() end)
    helper.assert_true(ok)
    helper.assert_not_nil(driver.asyncs)
    helper.assert_eq(#driver.asyncs, 1)

    local ok2 = driver:fetch_rows_async(helper.res(), function() end)
    helper.assert_true(ok2)
    helper.assert_eq(#driver.asyncs, 2)
end)

helper.test("stmt() creates a prepared statement bound to the connection", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)
    helper.on("taos_stmt_init", function(conn) return helper.ptr() end)

    local stmt = driver:stmt()
    helper.assert_not_nil(stmt)
    helper.assert_eq(#helper.calls("taos_stmt_init"), 1)
    helper.assert_eq(helper.called("taos_stmt_init")[1], driver.conn)

    local d2 = taos:new()
    local s2, err = d2:stmt()
    helper.assert_nil(s2)
    helper.assert_eq(err, "not connected.")
end)

-- ---------------------------------------------------------------------------
-- Connection pooling (opt-in via conf.pool).  Every test uses a unique
-- target so the module-level pool never leaks state between cases.
-- ---------------------------------------------------------------------------

local function pool_conf(n)
    return {
        host = "pool-host-" .. n,
        port = 6030,
        user = "root",
        password = "taosdata",
        database = "pool_db_" .. n,
        pool = true,
    }
end

helper.test("pooled connect()/close() reuses the C connection", function()
    helper.reset()
    local conf = pool_conf(1)
    helper.on("taos_connect", function() return helper.ptr() end)

    local d1 = taos:new()
    local c1 = d1:connect(conf)
    helper.assert_eq(c1.code, 0)
    helper.assert_eq(#helper.calls("taos_connect"), 1)

    -- A healthy connection is returned to the pool, not closed.
    d1:close()
    helper.assert_eq(#helper.calls("taos_close"), 0)

    local d2 = taos:new()
    local c2 = d2:connect(conf)
    helper.assert_eq(c2.code, 0)
    helper.assert_eq(c2.conn, c1.conn)
    -- Reuse must not create another C connection nor re-run taos_init.
    helper.assert_eq(#helper.calls("taos_connect"), 1)
    helper.assert_eq(#helper.calls("taos_init"), 1)

    d2:close()
    helper.assert_eq(#helper.calls("taos_close"), 0)
end)

helper.test("pooled close() discards a connection that saw a query error", function()
    helper.reset()
    local conf = pool_conf(2)
    helper.on("taos_connect", function() return helper.ptr() end)
    helper.on("taos_query", function() return helper.res() end)
    helper.on("taos_errno", function() return 90001 end)
    helper.on("taos_errstr", function() return "syntax error" end)

    local d = taos:new()
    d:connect(conf)
    local r = d:query("bad sql")
    helper.assert_eq(r.code, 90001)
    d:close()
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("pooled close() discards a connection with a changed default database", function()
    helper.reset()
    local conf = pool_conf(3)
    helper.on("taos_connect", function() return helper.ptr() end)
    helper.on("taos_select_db", function() return 0 end)

    local d = taos:new()
    d:connect(conf)
    local ok = d:select_db("other_db")
    helper.assert_true(ok)
    d:close()
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("pooled close() closes instead of pooling after async work", function()
    helper.reset()
    local conf = pool_conf(4)
    helper.on("taos_connect", function() return helper.ptr() end)

    local d = taos:new()
    d:connect(conf)
    d:query_async("select 1", function() end)
    d:close()
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("pooled connect() failure stores nothing and closes nothing", function()
    helper.reset()
    local conf = pool_conf(5)
    helper.on("taos_connect", function() return nil end)

    local d = taos:new()
    local r = d:connect(conf)
    helper.assert_eq(r.code, -1)
    helper.assert_nil(d.conn)
    d:close()
    helper.assert_eq(#helper.calls("taos_close"), 0)
end)

helper.test("pooled select_db() failure marks the connection bad", function()
    helper.reset()
    local conf = pool_conf(6)
    helper.on("taos_connect", function() return helper.ptr() end)
    helper.on("taos_select_db", function() return -1 end)
    helper.on("taos_errstr", function() return "no such database" end)

    local d = taos:new()
    d:connect(conf)
    local ok, err = d:select_db("nope")
    helper.assert_nil(ok)
    helper.assert_eq(err, "no such database")
    d:close()
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("pooled close() closes the overflow when the per-key pool is full", function()
    helper.reset()
    local conf = pool_conf(7)
    helper.on("taos_connect", function() return helper.ptr() end)

    -- The driver pool keeps at most 16 idle handles per target.  Open 17
    -- connections at once, then close them all: the 16th fits, the 17th
    -- must release the C connection instead of storing it.
    local drivers = {}
    for i = 1, 17 do
        drivers[i] = taos:new()
        local c = drivers[i]:connect(conf)
        helper.assert_eq(c.code, 0)
    end
    for i = 1, 17 do
        drivers[i]:close()
    end

    helper.assert_eq(#helper.calls("taos_connect"), 17)
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("query() marks the connection bad when result conversion raised", function()
    helper.reset()
    local driver = taos:new()
    connect_ok(driver)
    helper.on("taos_query", function() return helper.res() end)
    -- totable() raises mid-conversion; query() re-raises and must mark the
    -- connection unusable so a later pooled close() will not reuse it.
    helper.on("taos_errno", function() error("boom") end)

    local ok, err = pcall(function() return driver:query("select 1") end)
    helper.assert_false(ok)
    helper.assert_true(tostring(err):find("boom", 1, true) ~= nil)
    helper.assert_true(driver._bad)

    driver:close()
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)

helper.test("pooled close() discards a connection when taos_query returns no result", function()
    helper.reset()
    local conf = pool_conf(9)
    helper.on("taos_connect", function() return helper.ptr() end)
    helper.on("taos_query", function() return nil end)

    local d = taos:new()
    d:connect(conf)
    helper.assert_nil(d:query("select 1"))

    d:close()
    helper.assert_eq(#helper.calls("taos_close"), 1)
end)
