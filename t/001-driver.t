# Driver-level tests running inside a real OpenResty worker, with the
# TDengine C library mocked at the Lua level (see t/helper.lua).

use Test::Nginx::Socket 'no_plan';

use Cwd qw(abs_path);

our $ROOT = abs_path($0) =~ /^(.*)\/t\/[^\/]+$/ ? $1 : ".";

add_block_preprocessor(sub {
    my $block = shift;
    my $http = $block->http_config // "";
    $block->set_value("http_config", <<"EOC" . $http);
    lua_package_path "$ROOT/lib/?.lua;$ROOT/t/?.lua;;";
    init_by_lua_block { require("t.nginx_util").init() }
EOC
});

run_tests();

__DATA__

=== TEST 1: connect + query returns rows, JSON encoded
--- config
    location /t {
        content_by_lua_block {
            local cjson = require("cjson")
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            -- NOTE: util.mock_select() resets the mock, so it must run
            -- before any util.on() registration.
            util.mock_select({
                util.row(util.int64_buf(1600000000000), util.int_buf(42)),
            }, 1)
            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_query", function() return util.res() end)

            local d = taos:new()
            local conn = d:connect({
                host = "127.0.0.1", port = 6030,
                user = "root", password = "taosdata",
            })
            local r = d:query("select * from m1")
            ngx.say(cjson.encode(r))
        }
    }
--- request
GET /t
--- response_body_json_sort
--- response_body
{"affected":1,"code":0,"item":[{"speed":42,"ts":1600000000000}]}
--- no_error_log
[error]

=== TEST 2: connect failure keeps conn nil and reports the target
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return nil end)

            local d = taos:new()
            local conn = d:connect({
                host = "127.0.0.1", port = 6030,
                user = "root", password = "taosdata",
            })
            ngx.say(conn.code .. "|" .. tostring(d.conn) .. "|" .. conn.error)
        }
    }
--- request
GET /t
--- response_body
-1|nil|failed to connect server 127.0.0.1:6030
--- no_error_log
[error]

=== TEST 3: query error path reports code and message
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_query", function() return util.res() end)
            util.on("taos_errno", function() return 90001 end)
            util.on("taos_errstr", function() return "syntax error" end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })
            local r = d:query("bad sql")
            ngx.say(r.code .. "|" .. r.error .. "|" .. tostring(r.item))
        }
    }
--- request
GET /t
--- response_body
90001|syntax error|nil
--- no_error_log
[error]

=== TEST 4: options() forwards every configured option
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            local d = taos:new()
            local ok = d:options({
                locale = "en_US.UTF-8",
                charset = "UTF-8",
                timezone = "UTC-8",
            })
            ngx.say(tostring(ok) .. "|" .. #util.calls("taos_options"))
        }
    }
--- request
GET /t
--- response_body
true|3
--- no_error_log
[error]

=== TEST 5: close() closes once, then reports an error
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })
            local c1 = d:close()
            local c2 = d:close()
            ngx.say(c1.code .. "|" .. c2.code)
        }
    }
--- request
GET /t
--- response_body
0|-1
--- no_error_log
[error]

=== TEST 6: validate_sql, select_db and the stmt() factory
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_validate_sql", function() return 0 end)
            util.on("taos_select_db", function() return 0 end)
            util.on("taos_stmt_init", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })
            local v = d:validate_sql("select 1")
            local ok, err = d:select_db("demo")
            local s = d:stmt()
            local r = s:prepare("insert into t values (?, ?)")
            local len = util.called("taos_stmt_prepare")[3]
            ngx.say(v .. "|" .. tostring(ok) .. "|" .. tostring(err) .. "|" .. tostring(r) .. "|" .. len)
        }
    }
--- request
GET /t
--- response_body
0|true|nil|nil|27
--- no_error_log
[error]

=== TEST 7: pooled connect/close/connect reuses one C connection
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)

            local conf = {
                host = "127.0.0.1", port = 6030,
                user = "root", password = "taosdata",
                pool = true,
            }

            local d1 = taos:new()
            d1:connect(conf)
            local c1 = d1:close()

            local d2 = taos:new()
            local c2 = d2:connect(conf)
            d2:close()

            ngx.say(c2.code .. "|" .. #util.calls("taos_connect")
                    .. "|" .. #util.calls("taos_close") .. "|" .. c1.code)
        }
    }
--- request
GET /t
--- response_body
0|1|0|0
--- no_error_log
[error]
