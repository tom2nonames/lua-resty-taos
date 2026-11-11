-- Test runner for lua-resty-taos.
--
-- Usage:
--   luajit t/run.lua [spec ...]
--
-- With no arguments it runs every spec in the default list below.
-- Individual specs can be passed as module names (e.g. `t.taos_spec`) to
-- run a subset.  The process exits non-zero when any test fails.

-- Make the library and test directories resolvable.  The runner lives in
-- t/, so the project root is one level up; both relative and absolute
-- invocations are supported.
local here = arg[0]:match("^(.*[/\\])") or "./"
local root = here:match("(.*[/\\])t[/\\]$") or ""
package.path = root .. "lib/?.lua;" .. root .. "?.lua;" .. package.path

local helper = require("t.helper")

helper.init()

local DEFAULT_SPECS = {
    "t.library_spec",
    "t.data_spec",
    "t.taos_spec",
    "t.result_spec",
    "t.stmt_spec",
    "t.subscribe_spec",
    "t.stream_spec",
    "t.async_spec",
    "t.examples_spec",
}

local specs = {}
if #arg == 0 then
    specs = DEFAULT_SPECS
else
    for _, name in ipairs(arg) do
        if not name:find("^t%.") then
            name = "t." .. name
        end
        specs[#specs + 1] = name
    end
end

for _, spec in ipairs(specs) do
    local ok, err = pcall(require, spec)
    if not ok then
        io.stderr:write(string.format("[LOAD ERROR] %s: %s\n", spec, tostring(err)))
        os.exit(2)
    end
end

helper.run()
