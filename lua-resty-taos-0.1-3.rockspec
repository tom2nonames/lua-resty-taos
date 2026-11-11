rockspec_format = "3.0"
package = "lua-resty-taos"
version = "0.1-3"
source = {
   url = "git+https://github.com/lvhuan-dev-team/lua-resty-taos.git"
}
description = {
   detailed = "lua-resty-taos - Lua TDengine client driver for the ngx_lua based on the FFI",
   homepage = "https://github.com/lvhuan-dev-team/lua-resty-taos",
   license = "BSD License 2.0",
   labels = { "Taos","TDengine", "OpenResty", "FFI", "Nginx" }
}
build = {
   type = "builtin",
   modules = {
      ["resty.taos.async"] = "lib/resty/taos/async.lua",
      ["resty.taos.data"] = "lib/resty/taos/data.lua",
      ["resty.taos.library"] = "lib/resty/taos/library.lua",
      ["resty.taos.pool"] = "lib/resty/taos/pool.lua",
      ["resty.taos.result"] = "lib/resty/taos/result.lua",
      ["resty.taos.stmt"] = "lib/resty/taos/stmt.lua",
      ["resty.taos.stream"] = "lib/resty/taos/stream.lua",
      ["resty.taos.subscribe"] = "lib/resty/taos/subscribe.lua",
      ["resty.taos"] = "lib/resty/taos.lua"
   }
}