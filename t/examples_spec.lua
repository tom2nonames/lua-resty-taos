-- Static guards for the docker example stack.
--
-- S2 regression: the example stack must not ship with debug logging and
-- must never return raw driver error text (taos_errstr()) to an HTTP
-- client -- that text can echo SQL fragments and schema details.  These
-- checks fail if a future edit reintroduces either problem.

local helper = require("t.helper")

helper.suite("examples")

-- Resolve the project root from this file's location so the spec works
-- no matter which directory the runner is started from.
local function project_root()
    local src = debug.getinfo(1, "S").source:sub(2)
    local dir = src:match("^(.*)[/\\]t[/\\][^/\\]+$")
    if dir and dir ~= "" then
        return dir .. "/"
    end
    return ""
end

local root = project_root()

local function read_file(name)
    local f = assert(io.open(root .. name, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local conf = read_file("docker/nginx.conf")

helper.test("docker example does not log at debug level", function()
    local level = conf:match("error_log[^;]-%s(%a+)%s*;")
    helper.assert_not_nil(level, "error_log directive not found in docker/nginx.conf")
    helper.assert_true(level ~= "debug",
                       "docker/nginx.conf must not log at debug level (got " .. level .. ")")
end)

helper.test("docker example never returns raw driver error text", function()
    -- Returning `.error` through ngx.say/ngx.print leaks taos_errstr()
    -- content to the HTTP client; only numeric codes may be exposed.
    helper.assert_nil(conf:find("ngx%.say%([^)]*%.error"),
                      "ngx.say() must not echo a .error field")
    helper.assert_nil(conf:find("ngx%.print%([^)]*%.error"),
                      "ngx.print() must not echo a .error field")
    -- The sanitized detail helper reports "code=<n>" instead.
    helper.assert_not_nil(conf:find('"code="', 1, true),
                          "expected sanitized 'code=' error details in the example")
end)
