# Async query tests (taos_query_a / taos_fetch_rows_a) inside a real
# OpenResty worker with the C library mocked.

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

=== TEST 1: query_async callback fires with affected rows
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_affected_rows", function() return 2 end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local got
            local ok = d:query_async("insert into t values (1)", function(t)
                got = t
            end)

            -- The C side would fire this later; fire it ourselves from the
            -- captured TAOS_QUERY_CALLBACK cdata.
            local args = util.called("taos_query_a")
            args[3](args[4], util.res(), 0)

            ngx.say(tostring(ok) .. "|" .. got.code .. "|" .. got.affected)
        }
    }
--- request
GET /t
--- response_body
true|0|2
--- no_error_log
[error]

=== TEST 2: query_async error callback receives the error
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_errstr", function() return "query failed" end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local got
            d:query_async("bad sql", function(t)
                got = t
            end)

            local args = util.called("taos_query_a")
            args[3](args[4], util.res(), -1)

            ngx.say(got.code .. "|" .. got.error)
        }
    }
--- request
GET /t
--- response_body
-1|query failed
--- no_error_log
[error]

=== TEST 3: driver keeps async callbacks alive after query_async returns
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            d:query_async("select 1", function() end)
            d:fetch_rows_async(util.res(), function() end)

            -- Regression: the driver must retain the async wrappers so the
            -- C callback trampolines are not garbage-collected before the
            -- (still pending) callbacks fire.
            ngx.say(#d.asyncs)
        }
    }
--- request
GET /t
--- response_body
2
--- no_error_log
[error]

=== TEST 4: fetch_rows_async forwards the row count
--- config
    location /t {
        content_by_lua_block {
            local util = require("t.nginx_util")
            local taos = require("resty.taos")

            util.on("taos_connect", function() return util.ptr() end)

            local d = taos:new()
            d:connect({ host = "127.0.0.1", port = 6030, user = "root", password = "x" })

            local got
            d:fetch_rows_async(util.res(), function(t)
                got = t
            end)

            local args = util.called("taos_fetch_rows_a")
            args[2](args[3], util.res(), 5)

            ngx.say(got.num_of_rows)
        }
    }
--- request
GET /t
--- response_body
5
--- no_error_log
[error]
