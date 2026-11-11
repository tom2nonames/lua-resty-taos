-- Tests for resty.taos.pool: the per-worker idle connection pool.

local helper = require("t.helper")
local pool = require("resty.taos.pool")

helper.suite("pool")

local function fixed_now(t)
    return function() return t end
end

helper.test("new() applies defaults and overrides", function()
    local p = pool:new()
    helper.assert_eq(p.max_idle, 16)
    helper.assert_eq(p.idle_timeout, 30000)
    helper.assert_eq(type(p.now), "function")
    helper.assert_nil(p.close)

    local clock = fixed_now(1000)
    local close = function() end
    local q = pool:new({ max_idle = 4, idle_timeout = 5, now = clock, close = close })
    helper.assert_eq(q.max_idle, 4)
    helper.assert_eq(q.idle_timeout, 5)
    helper.assert_true(q.now == clock)
    helper.assert_true(q.close == close)
end)

helper.test("acquire() on an unknown key returns nil", function()
    local p = pool:new({ now = fixed_now(0) })
    helper.assert_nil(p:acquire("never-seen"))
    helper.assert_eq(p:size("never-seen"), 0)
end)

helper.test("release() + acquire() round-trip, most recent first", function()
    local p = pool:new({ now = fixed_now(0) })
    helper.assert_true(p:release("k", "first"))
    helper.assert_true(p:release("k", "second"))
    helper.assert_eq(p:size("k"), 2)
    helper.assert_eq(p:acquire("k"), "second")
    helper.assert_eq(p:acquire("k"), "first")
    helper.assert_nil(p:acquire("k"))
    helper.assert_eq(p:size("k"), 0)
end)

helper.test("acquire() drops expired entries and closes them", function()
    local t = 0
    local closed = {}
    local p = pool:new({
        idle_timeout = 100,
        now = function() return t end,
        close = function(conn) closed[#closed + 1] = conn end,
    })
    p:release("k", "stale")
    t = 500
    helper.assert_nil(p:acquire("k"), "expired handle must not be returned")
    helper.assert_eq(closed[1], "stale")
    helper.assert_eq(p:size("k"), 0)
end)

helper.test("acquire() drops an expired entry even without a close callback", function()
    local t = 0
    local p = pool:new({ idle_timeout = 10, now = function() return t end })
    p:release("k", "stale")
    t = 20
    helper.assert_nil(p:acquire("k"))
end)

helper.test("release() enforces max_idle and closes the overflow", function()
    local closed = {}
    local p = pool:new({
        max_idle = 1,
        now = fixed_now(0),
        close = function(conn) closed[#closed + 1] = conn end,
    })
    helper.assert_true(p:release("k", "kept"))
    helper.assert_false(p:release("k", "overflow"))
    helper.assert_eq(closed[1], "overflow")
    helper.assert_eq(p:size("k"), 1)
end)

helper.test("release() with max_idle 0 closes without a close callback", function()
    local p = pool:new({ max_idle = 0, now = fixed_now(0) })
    helper.assert_false(p:release("k", "a"))
end)

helper.test("clear() closes every idle handle and empties the pool", function()
    local closed = {}
    local p = pool:new({
        now = fixed_now(0),
        close = function(conn) closed[#closed + 1] = conn end,
    })
    p:release("a", "x")
    p:release("b", "y")
    p:release("b", "z")
    p:clear()
    helper.assert_eq(#closed, 3)
    helper.assert_eq(p:size("a"), 0)
    helper.assert_eq(p:size("b"), 0)
    p:clear() -- empty pool: the loop body is not entered
end)

helper.test("clear() without a close callback forgets the entries", function()
    local p = pool:new({ now = fixed_now(0) })
    p:release("k", "x")
    p:clear()
    helper.assert_eq(p:size("k"), 0)
end)

helper.test("default clock works with and without ngx", function()
    -- With ngx available (the test stub) the default clock uses ngx.now().
    local p = pool:new()
    helper.assert_true(p:release("ngx-key", "c1"))
    helper.assert_eq(p:size("ngx-key"), 1)

    -- Without ngx it falls back to os.time().
    local saved = ngx
    local ok, err = pcall(function()
        ngx = nil
        local q = pool:new()
        helper.assert_true(q:release("os-key", "c2"))
        helper.assert_eq(q:size("os-key"), 1)
    end)
    ngx = saved
    helper.assert_true(ok, tostring(err))
end)

return true
