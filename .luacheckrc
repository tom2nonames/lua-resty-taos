-- Luacheck configuration for lua-resty-taos.
-- Run with: luacheck lib t

-- `ngx` is injected by OpenResty at runtime.
globals = { "ngx" }

-- The table.new/table.clear shims are idiomatic lua-resty boilerplate.
std = "lua51"

-- Allow the unused-variable noise that comes from the boilerplate
-- (new_tab shims, unused ffi imports) without hiding real issues.
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
    "421", -- shadowing definition
    "611", -- line too long
    "431", -- shadowing upvalue argument
    "432", -- shadowing upvalue
    "562", -- unused varargs
}
