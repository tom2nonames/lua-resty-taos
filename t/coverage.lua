-- Line-coverage collector and reporter for the lua-resty-taos unit tests.
--
-- Self-contained: the collector is a plain LuaJIT debug line hook; the
-- "which lines are executable" question is answered by luacov's pure-Lua
-- LineScanner when available (OpenResty ships it), falling back to a
-- built-in heuristic.  No C modules are required.
--
-- Usage (see t/run_coverage.lua):
--   local cov = require("t.coverage")
--   cov.start()                 -- begin collecting
--   ... run the code under test ...
--   cov.stop()                  -- stop collecting
--   cov.report_files({ "lib/resty/taos.lua", "lib/resty/taos/..." })
--   os.exit(cov.failures == 0 and 0 or 1)

local M = {}

local hits = {}          -- file -> { [line] = hit_count }
local active = false

local function hook()
    local info = debug.getinfo(2, "Sl")
    if not info or not info.source then
        return
    end
    local src = info.source
    if src:sub(1, 1) == "=" then
        return -- inline (non-file) chunks are not part of the library
    end
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    -- normalize "./lib/..." -> "lib/..."
    if src:sub(1, 2) == "./" then
        src = src:sub(3)
    end
    local line = info.currentline
    if not line or line <= 0 then
        return
    end
    local f = hits[src]
    if not f then
        f = {}
        hits[src] = f
    end
    f[line] = (f[line] or 0) + 1
end

function M.start()
    if not active then
        active = true
        debug.sethook(hook, "l")
    end
end

function M.stop()
    debug.sethook()
    active = false
end

function M.reset()
    hits = {}
end

---------------------------------------------------------------------------
-- Executable-line detection (bytecode-accurate)
---------------------------------------------------------------------------

-- Returns the bytecode-active line map for a library source file, parsed
-- from `luajit -bL` (bytecode listing with lineinfo: each instruction is
-- prefixed with its source line, e.g. "0005    [17]    UGET ...").  This
-- is the precise set of lines that can execute -- a table-constructor
-- field line or a function *declaration* line produces no instruction of
-- its own and is correctly excluded.
-- Picks a luajit binary that supports `-bL` (bytecode listing with
-- lineinfo, which newer LuaJIT builds removed; the OpenResty-bundled
-- build still has it).  The coverage hook itself is stable only on the
-- newer builds, so the two jobs may use different interpreters.
local function pick_bL_luajit()
    -- Collect candidates without holes: ipairs() stops at the first nil
    -- element, and os.getenv may return nil.
    local candidates = {}
    local function add(c)
        if c and c ~= "" then
            candidates[#candidates + 1] = c
        end
    end
    add(os.getenv("LUAJIT_BIN"))
    add("/usr/local/openresty/luajit/bin/luajit")
    add(arg and arg[-1] ~= "" and arg[-1] or nil)

    for _, c in ipairs(candidates) do
        if c then
            -- "-b" prints its option help to stdout; "-L" is present only
            -- on builds that support lineinfo listing.
            local p = io.popen(string.format("%s -b 2>&1", c))
            if p then
                local ok = false
                for line in p:lines() do
                    if line:find("%-L") then
                        ok = true
                        break
                    end
                end
                p:close()
                if ok then
                    return c
                end
            end
        end
    end
    return "luajit" -- last resort; executable lines will be empty
end

local bL_luajit = pick_bL_luajit()
M.bL_luajit = bL_luajit

local function executable_lines(path)
    local exec = {}
    -- "-bL <input>" (no output arg) lists the bytecode with lineinfo on
    -- stdout; each instruction is prefixed with its source line, e.g.
    -- "0005    [17]    UGET ...".
    local p = io.popen(string.format("%s -bL %q 2>/dev/null", bL_luajit, path))
    if not p then
        return exec
    end
    for line in p:lines() do
        local n = line:match("%[(%d+)%]")
        if n then
            exec[tonumber(n)] = "exec"
        end
    end
    p:close()
    return exec
end

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------

M.failures = 0
M.files = {}
M.total_lines = 0
M.hit_lines = 0

-- Reports coverage for the given list of source files.  Every
-- "exec"-classified line must have been hit; "cond" lines are reported
-- but not required.  Returns true when all files are at 100%.
function M.report_files(paths)
    io.write("\n===== unit-test line coverage =====\n")
    local all_ok = true
    for _, path in ipairs(paths) do
        local exec = executable_lines(path)
        local file_hits = hits[path] or {}
        local missed = {}
        local cond_missed = {}
        local exec_count, hit_count = 0, 0

        for line, kind in pairs(exec) do
            if kind == "exec" then
                exec_count = exec_count + 1
                if (file_hits[line] or 0) > 0 then
                    hit_count = hit_count + 1
                else
                    missed[#missed + 1] = line
                end
            else -- cond
                if (file_hits[line] or 0) == 0 then
                    cond_missed[#cond_missed + 1] = line
                end
            end
        end

        table.sort(missed)
        table.sort(cond_missed)

        local pct = exec_count > 0 and math.floor(hit_count / exec_count * 1000) / 10 or 100
        local ok = #missed == 0
        if not ok then
            all_ok = false
            M.failures = M.failures + 1
        end

        io.write(string.format("  %-40s %6.1f%%  (%d/%d lines)\n",
                               path, pct, hit_count, exec_count))
        if #missed > 0 then
            io.write("    MISSED:\n")
            local lines = {}
            local f = io.open(path, "r")
            if f then
                for line in f:lines() do
                    lines[#lines + 1] = line
                end
                f:close()
            end
            for _, ln in ipairs(missed) do
                io.write(string.format("      %4d  %s\n", ln, lines[ln] or ""))
            end
        end
        if #cond_missed > 0 then
            io.write("    conditional (not required):")
            local shown = {}
            for _, ln in ipairs(cond_missed) do
                shown[#shown + 1] = tostring(ln)
            end
            io.write(" " .. table.concat(shown, ", ") .. "\n")
        end

        M.files[#M.files + 1] = path
        M.total_lines = M.total_lines + exec_count
        M.hit_lines = M.hit_lines + hit_count
    end

    local total_pct = M.total_lines > 0
        and math.floor(M.hit_lines / M.total_lines * 1000) / 10 or 100
    io.write(string.format("  TOTAL                                  %6.1f%%  (%d/%d lines)\n",
                           total_pct, M.hit_lines, M.total_lines))
    io.write("===============================================\n")
    return all_ok
end

return M
