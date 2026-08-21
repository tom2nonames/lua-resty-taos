# Smoke tests for the test::nginx setup itself:
#   * the library loads inside a real OpenResty worker
#   * the mock (t/helper.lua) can be installed and scripted
#   * responses are compared correctly

use Test::Nginx::Socket 'no_plan';

use Cwd qw(abs_path);

# Project root = one level above t/.
our $ROOT = abs_path($0) =~ /^(.*)\/t\/[^\/]+$/ ? $1 : ".";

# Every block gets the lua package path and the mock installation for free
# (http_config lands in the http{} block, where lua_package_path and
# init_by_lua_block are allowed).
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

=== TEST 1: module version loads in the worker
--- config
    location /t {
        content_by_lua_block {
            ngx.say(require("resty.taos")._VERSION)
        }
    }
--- request
GET /t
--- response_body
0.1
--- no_error_log
[error]

=== TEST 2: mock connect + query returns rows (plain string output)
--- config
    location /t {
        content_by_lua_block {
            local ffi = require("ffi")
            local util = require("t.nginx_util")

            util.mock_select({
                util.row(util.int64_buf(1600000000000), util.int_buf(42)),
            }, 1)
            util.on("taos_connect", function() return util.ptr() end)
            util.on("taos_query", function() return util.res() end)

            local taos = require("resty.taos")
            local d = taos:new()
            local conn = d:connect({
                host = "127.0.0.1", port = 6030,
                user = "root", password = "taosdata",
            })
            local r = d:query("select * from m1")
            ngx.say(conn.code .. "|" .. r.code .. "|" .. r.item[1].ts .. "|" .. r.item[1].speed)
        }
    }
--- request
GET /t
--- response_body
0|0|1600000000000|42
--- no_error_log
[error]
