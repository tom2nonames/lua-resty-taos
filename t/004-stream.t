# Stream (continuous query) tests inside a real OpenResty worker with the
# C library mocked.

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

=== TEST 1: handler receives converted rows and does not free the result
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local stream = require("resty.taos.stream")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_open_stream", function() return util.ptr() end)
            util.on("taos_field_count", function() return 2 end)
            util.on("taos_fetch_fields", function()
                return util.fields({ "ts", 9, 8 }, { "speed", 4, 4 })
            end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local st = stream:new(d)
            local got
            local res = st:open("select * from t", 0, function(item)
                got = item
            end, function() end)

            -- Fire the HANDLEFUNC the way the C side would.
            local args = util.called("taos_open_stream")
            args[3](args[5], util.res(),
                util.row(util.int64_buf(1600000000000), util.int_buf(7)))

            ngx.say(res.code .. "|" .. got.ts .. "|" .. got.speed
                    .. "|" .. #util.calls("taos_free_result"))
        }
    }
--- request
GET /t
--- response_body
0|1600000000000|7|0
--- no_error_log
[error]

=== TEST 2: close passes the TAOS_STREAM handle and is idempotent
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local stream = require("resty.taos.stream")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_open_stream", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local st = stream:new(d)
            st:open("select 1", 0, function() end, nil)

            local ok = st:close()
            local h = util.called("taos_close_stream")[1]
            local ok2, err = st:close()

            ngx.say(tostring(ok) .. "|" .. tostring(h == util.ptr())
                    .. "|" .. tostring(ok2) .. "|" .. tostring(err))
        }
    }
--- request
GET /t
--- response_body
true|true|nil|no stream opened.
--- no_error_log
[error]

=== TEST 3: open failure reports code -1
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local stream = require("resty.taos.stream")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_open_stream", function() return nil end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local st = stream:new(d)
            local res = st:open("select 1", 0, function() end, nil)
            ngx.say(res.code)
        }
    }
--- request
GET /t
--- response_body
-1
--- no_error_log
[error]
