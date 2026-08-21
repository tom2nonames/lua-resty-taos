# Subscription tests (taos_subscribe / taos_consume / taos_unsubscribe)
# inside a real OpenResty worker with the C library mocked.

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

=== TEST 1: subscribe callback receives converted rows
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local subscribe = require("resty.taos.subscribe")

            -- NOTE: util.mock_select() resets the mock, so it must run
            -- before any util.on() registration.
            util.mock_select({
                util.row(util.int64_buf(1600000000000), util.int_buf(42)),
            }, 1)
            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_subscribe", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local sub = subscribe:new(d)
            local got
            local res = sub:subscribe(true, "topic1", "select * from t", function(t)
                got = t
            end, nil, 1000)

            -- Fire the C subscription callback ourselves.
            local args = util.called("taos_subscribe")
            args[5](util.ptr(), util.res(), args[6], 0)

            ngx.say(res.code .. "|" .. got.code .. "|" .. got.item[1].speed)
        }
    }
--- request
GET /t
--- response_body
0|0|42
--- no_error_log
[error]

=== TEST 2: error callback does not crash and reports the error
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local subscribe = require("resty.taos.subscribe")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_subscribe", function() return util.ptr() end)
            util.on("taos_errstr", function() return "subscribe failed" end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local sub = subscribe:new(d)
            local got
            sub:subscribe(true, "topic1", "select 1", function(t)
                got = t
            end, nil, 0)

            -- Regression: the error branch used to reference `result`
            -- before its declaration (crash), and logged with ngx.ERROR
            -- which is -1, not a log level (another crash).  Both must be
            -- gone now: the callback must run, and the error must be
            -- logged at the ERR level (asserted via --- error_log below).
            local args = util.called("taos_subscribe")
            args[5](util.ptr(), util.res(), args[6], -1)

            ngx.say(got.code .. "|" .. got.error)
        }
    }
--- request
GET /t
--- response_body
-1|subscribe failed
--- error_log
callback error, code: -1, error: subscribe failed

=== TEST 3: subscribe without a callback passes a NULL callback
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local subscribe = require("resty.taos.subscribe")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_subscribe", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local sub = subscribe:new(d)
            local res = sub:subscribe(false, "topic1", "select 1", nil, nil, 0)

            ngx.say(res.code .. "|" .. tostring(util.called("taos_subscribe")[5]))
        }
    }
--- request
GET /t
--- response_body
0|nil
--- no_error_log
[error]

=== TEST 4: consume() converts the polled result set
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local subscribe = require("resty.taos.subscribe")

            -- NOTE: util.mock_select() resets the mock, so it must run
            -- before any util.on() registration.
            util.mock_select({
                util.row(util.int64_buf(1600000000000), util.int_buf(7)),
            }, 1)
            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_subscribe", function() return util.ptr() end)
            util.on("taos_consume", function() return util.res() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local sub = subscribe:new(d)
            sub:subscribe(false, "topic1", "select * from t", nil, nil, 0)

            local t = sub:consume()
            ngx.say(t.code .. "|" .. t.item[1].speed)
        }
    }
--- request
GET /t
--- response_body
0|7
--- no_error_log
[error]

=== TEST 5: unsubscribe forwards the keep flag
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")
            local subscribe = require("resty.taos.subscribe")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_subscribe", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local sub = subscribe:new(d)
            sub:subscribe(true, "topic1", "select 1", function() end, nil, 0)

            local ok = sub:unsubscribe(true)
            local keep = util.called("taos_unsubscribe")[2]
            ngx.say(tostring(ok) .. "|" .. keep)
        }
    }
--- request
GET /t
--- response_body
true|1
--- no_error_log
[error]
