-- Coverage runner: executes the full unit-test suite under line coverage
-- and reports per-file percentages.  Exits non-zero when any test fails or
-- any required line is not covered.
--
-- Usage:
--   /usr/local/openresty/luajit/bin/luajit t/run_coverage.lua
--
-- The report requires 100% coverage of every executable line in
-- lib/resty/taos*.lua (conditional lines are reported but not required).

package.path = "./lib/?.lua;./t/?.lua;" .. package.path

-- Force the `pcall(require, "table.new")` fallback in every library
-- module: LuaJIT ships table.new, so the fallback branch (a coverage
-- requirement) is otherwise unreachable.  This must happen before any
-- library module is loaded.
package.preload["table.new"] = function()
    error("table.new disabled for coverage", 0)
end

local helper = require("t.helper")
local cov = require("t.coverage")

-- Collect from the very beginning (library modules are loaded lazily by
-- the specs).
cov.start()

helper.init()

local SPECS = {
    "t.library_spec",
    "t.data_spec",
    "t.taos_spec",
    "t.result_spec",
    "t.stmt_spec",
    "t.subscribe_spec",
    "t.stream_spec",
    "t.async_spec",
}

for _, spec in ipairs(SPECS) do
    local ok, err = pcall(require, spec)
    if not ok then
        io.stderr:write("[LOAD ERROR] " .. spec .. ": " .. tostring(err) .. "\n")
        os.exit(2)
    end
end

-- Run every registered test manually (helper.run() calls os.exit, which
-- would skip the coverage report).
local passed, failed = 0, 0
for _, t in ipairs(helper.tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("  [FAIL] %s :: %s\n         %s\n",
                               t.suite, t.name, tostring(err)))
    end
end

cov.stop()

io.write(string.format("\n%d/%d tests passed\n", passed, passed + failed))

local files = {
    "lib/resty/taos.lua",
    "lib/resty/taos/async.lua",
    "lib/resty/taos/data.lua",
    "lib/resty/taos/library.lua",
    "lib/resty/taos/result.lua",
    "lib/resty/taos/stmt.lua",
    "lib/resty/taos/stream.lua",
    "lib/resty/taos/subscribe.lua",
}
local cov_ok = cov.report_files(files)

os.exit((failed == 0 and cov_ok) and 0 or 1)
