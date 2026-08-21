-- Tests for resty.taos.stmt: prepared statements.

local helper = require("t.helper")
local stmt = require("resty.taos.stmt")

helper.suite("stmt")

local fake_stmt = helper.ptr()

helper.test("new() requires a connection", function()
    local s, err = stmt:new(nil)
    helper.assert_nil(s)
    helper.assert_eq(err, "not connected.")
end)

helper.test("new() initializes a statement on the connection", function()
    helper.reset()
    helper.on("taos_stmt_init", function(conn) return fake_stmt end)

    local conn = helper.ptr()
    local s = stmt:new(conn)

    helper.assert_not_nil(s)
    helper.assert_eq(#helper.calls("taos_stmt_init"), 1)
    helper.assert_eq(helper.called("taos_stmt_init")[1], conn)
end)

helper.test("prepare() derives the SQL length when omitted", function()
    helper.reset()
    helper.on("taos_stmt_init", function() return fake_stmt end)
    local s = stmt:new(helper.ptr())

    local sql = "insert into t values (?, ?)"
    local rc = s:prepare(sql)

    helper.assert_eq(rc, nil) -- mock default
    local args = helper.called("taos_stmt_prepare")
    helper.assert_not_nil(args)
    helper.assert_eq(args[1], fake_stmt)
    helper.assert_eq(args[2], sql)
    -- Regression: the length used to be a mandatory, typo-named parameter;
    -- when omitted it must now default to #sql.
    helper.assert_eq(args[3], #sql)
end)

helper.test("prepare() honours an explicit length", function()
    helper.reset()
    helper.on("taos_stmt_init", function() return fake_stmt end)
    local s = stmt:new(helper.ptr())

    s:prepare("insert into t values (?, ?)", 10)
    helper.assert_eq(helper.called("taos_stmt_prepare")[3], 10)
end)

helper.test("bind/add_batch/execute/use_result forward to the C library", function()
    helper.reset()
    helper.on("taos_stmt_init", function() return fake_stmt end)
    local s = stmt:new(helper.ptr())

    s:bind_param({ buffer_type = 4 })
    helper.assert_eq(helper.called("taos_stmt_bind_param")[1], fake_stmt)

    s:add_batch()
    helper.assert_eq(helper.called("taos_stmt_add_batch")[1], fake_stmt)

    s:execute()
    helper.assert_eq(helper.called("taos_stmt_execute")[1], fake_stmt)

    helper.on("taos_stmt_use_result", function() return helper.res() end)
    local res = s:use_result()
    helper.assert_not_nil(res)
    helper.assert_eq(helper.called("taos_stmt_use_result")[1], fake_stmt)
end)

helper.test("close() releases the statement", function()
    helper.reset()
    helper.on("taos_stmt_init", function() return fake_stmt end)
    local s = stmt:new(helper.ptr())

    s:close()
    helper.assert_eq(#helper.calls("taos_stmt_close"), 1)
    helper.assert_eq(helper.called("taos_stmt_close")[1], fake_stmt)
end)
