# lua-resty-taos

Nonblocking Lua TDengine driver library for ngx_lua or OpenResty

[中文文档](README.zh-CN.md)

# install
```bash
cd lua-resty-taos
luarocks build
```

# modules

## resty.taos — main driver

The top-level module.  Creates driver instances, manages the connection
and provides synchronous query, asynchronous query, prepared statements,
options and helpers.

```lua
local taos = require "resty.taos"

-- Create a driver instance (one per request/worker is the typical usage).
local driver = taos:new()

-- Connect.  conf fields: host, port, user, password, database (optional).
local conn = driver:connect({
    host = "127.0.0.1",
    port = 6030,
    user = "root",
    password = "taosdata",
    -- database = "demo",   -- optional default database
})
if conn.code ~= 0 then
    ngx.log(ngx.ERR, "connect failed: ", conn.error)
    return
end

-- Synchronous query.  Returns { code, affected, item }.
--   * item is an array of rows; each row is { <column> = <value>, ... }
--   * BIGINT values are returned as strings (64-bit precision);
--     TIMESTAMP values are returned as millisecond numbers.
local res = driver:query("select * from m1")
if res.code ~= 0 then
    ngx.log(ngx.ERR, "query error: ", res.error)
else
    ngx.say("affected rows: ", res.affected)
    for _, row in ipairs(res.item) do
        ngx.say(row.ts, " ", row.speed, " ", row.owner)
    end
end

-- Client / server versions.
ngx.log(ngx.INFO, driver:get_client_info())
ngx.log(ngx.INFO, driver:get_server_info())

-- Switch the default database.
local ok, err = driver:select_db("demo")

-- Validate a SQL statement (returns the C status code).
local code = driver:validate_sql("select 1")

-- Client-side options: locale / charset / timezone / cfgdir.
driver:options({ timezone = "UTC-8", charset = "UTF-8" })

-- Error helpers (work with or without an explicit handle).
ngx.log(ngx.WARN, driver:get_error_string())
ngx.log(ngx.WARN, "errno: ", driver:get_error_no())

-- Asynchronous query (see resty.taos.async).
local ok = driver:query_async("insert into t values (1)", function(t)
    ngx.log(ngx.INFO, "async done, affected: ", t.affected)
end)

-- Prepared statement (see resty.taos.stmt).
local stmt = driver:stmt()

-- Close the connection.  Always call this when the driver is no longer
-- needed so the underlying connection is released.
driver:close()
```

Methods: `new()`, `connect(conf)`, `close()`, `query(sql)`,
`query_async(sql, callback)`, `fetch_rows_async(res, callback)`,
`options(opts)`, `select_db(db)`, `validate_sql(sql)`, `stmt()`,
`get_client_info()`, `get_server_info()`, `get_error_string(res?)`,
`get_error_no(res?)`, `init()`, `cleanup()`.

### connection pooling (opt-in)

By default every `connect()` opens a new C connection and every `close()`
closes it.  For per-request workloads that is mostly pure overhead (the
reference stack spends 5–20 ms per request on connect+close, versus well
under a millisecond on a point query), so the driver can keep a small
per-worker idle pool instead.  Enable it with `pool = true`:

```lua
local driver = taos:new()
driver:connect({
    host = "127.0.0.1", port = 6030,
    user = "root", password = "taosdata",
    pool = true,                       -- reuse connections in this worker
})

-- ... work ...

driver:close()   -- returns the connection to the worker pool
```

The pool is keyed by host/port/user/database, keeps at most 16 idle
connections per key and expires them after 30 seconds (expired handles are
closed).  `close()` returns the handle to the pool instead of calling
`taos_close()`, so a later `connect()` with the same conf skips
`taos_init()`/`taos_connect()`.  A connection is closed for real — never
pooled — when a query returned an error, `select_db()` changed the default
database, or an async query was issued on the driver.  See section 8 of
the best practices for the full rules.

## resty.taos.result — result set

Wraps a C `TAOS_RES*` handle.  `query()` uses it internally; use it
directly when you need row-by-row access or the low-level fetch API.

```lua
local result = require "resty.taos.result"

-- Wrap a TAOS_RES* (e.g. from resty.taos.library).
local r = result:new(raw_res)
if r then
    -- Convert the whole result set to Lua tables at once.
    local t = r:totable()          -- { code, affected, item }
    for _, row in ipairs(t.item) do
        ngx.say(row.ts, " ", row.speed)
    end

    -- Or iterate row by row (column pointers need resty.taos.data to
    -- convert; see below).
    local fields = r:fetch_fields() -- { {name, type, len}, ... }
    while true do
        local row = r:fetch_row()
        if not row then break end   -- end of result set
        -- row[i] (0-based) is a C pointer to the i-th column value
    end

    -- Explicit release.  free() is idempotent; the result set is also
    -- reclaimed if the wrapper is garbage-collected.
    r:free()
end
```

Methods: `new(result)`, `totable()`, `fetch_row()`, `fetch_block()`,
`fetch_fields()`, `fetch_lengths()`, `num_fields()`, `field_count()`,
`affected_rows()`, `precision()`, `stop()`, `errstr()`, `errno()`,
`free()`.

## resty.taos.stmt — prepared statements

Parameterised statements for batch inserts / repeated execution.  Note:
the parameter binding uses the C `TAOS_BIND` structure, so
`bind_param()` expects an FFI-constructed binding (see
`resty.taos.library` for the struct layout).

```lua
local stmt = driver:stmt()   -- or require("resty.taos.stmt"):new(conn)

-- prepare(); the SQL length is optional (defaults to #sql).
local rc = stmt:prepare("insert into t values (?, ?)")

-- Bind parameters (TAOS_BIND cdata) and queue a batch...
-- stmt:bind_param(bind)
-- stmt:add_batch()
-- ...then execute.
local rc = stmt:execute()

-- For SELECT statements, obtain the result set handle.
local res = stmt:use_result()

stmt:close()   -- must be called explicitly
```

Methods: `new(conn)`, `prepare(sql, length?)`, `bind_param(bind)`,
`add_batch()`, `execute()`, `use_result()`, `close()`.

## resty.taos.async — asynchronous queries

Non-blocking query execution through the driver:

```lua
-- Fire and forget; the callback is invoked when the server replies.
local ok, err = driver:query_async("insert into t values (1)", function(t)
    if t.code == 0 then
        ngx.log(ngx.INFO, "inserted, affected: ", t.affected)
    else
        ngx.log(ngx.ERR, "async query failed: ", t.error)
    end
end)
if not ok then
    ngx.log(ngx.ERR, "query_async rejected: ", err)
end
```

For row fetching you can use `fetch_rows_async(res, callback)` with a
result handle obtained from `taos_query`.

Module API: `new(cwrap)`, `query(sql, callback)`, `fetch_rows(res,
callback)` (normally used through `driver:query_async()` /
`driver:fetch_rows_async()`).

The driver keeps each callback alive until it fires and caps the number of
pending operations at 64 per connection; see section 4 of the best
practices below.

## resty.taos.subscribe — topic subscription

Subscribe to a query result set and poll (or receive) the changes.
This is the API behind "watch a table for new rows".

```lua
local subscribe = require "resty.taos.subscribe"

local sub = subscribe:new(driver)

-- Synchronous (polling) subscription:
--   restart=true  -> start from the beginning
--   interval      -> polling interval in ms
local r = sub:subscribe(true, "topic1", "select * from therm1", nil, nil, 1000)
if r.code ~= 0 then
    ngx.log(ngx.ERR, "subscribe failed")
    return
end

-- Poll and consume new rows.
while not ngx.worker.exiting() do
    local t = sub:consume()          -- { code, affected, item }
    if t and t.item and #t.item > 0 then
        for _, row in ipairs(t.item) do
            ngx.log(ngx.INFO, "new row: ", row.ts, " ", row.degree)
        end
    end
    ngx.sleep(1)
end

sub:unsubscribe(false)   -- keep_progress: true = resume from last position
```

Callback (asynchronous) flavour — the callback receives the same
`{code, affected, item}` table, and errors are reported through it too:

```lua
local r = sub:subscribe(true, "topic1", "select * from therm1", function(t)
    if t.code == 0 then
        for _, row in ipairs(t.item or {}) do
            ngx.log(ngx.INFO, "cb row: ", row.ts, " ", row.degree)
        end
    else
        ngx.log(ngx.ERR, "subscription error: ", t.error)
    end
end, nil, 1000)
```

Methods: `new(cwrap)`, `subscribe(restart, topic, sql, callback?, param?,
interval)`, `consume()`, `unsubscribe(keep_progress?)`.

## resty.taos.stream — continuous queries (streams)

TDengine stream compute: a SQL with `interval()`/`sliding()` runs
continuously and invokes your handler with each new result batch.

```lua
local stream = require "resty.taos.stream"

local st = stream:new(driver)

-- stime: start time (0 = now).  handle: called with each result batch.
-- callback: optional completion callback.
local res = st:open(
    "select count(*) as cnt, avg(degree) as avg_d from thermometer interval(2s) sliding(2s)",
    0,
    function(item)
        ngx.log(ngx.INFO, "stream batch: cnt=", item.cnt,
                " avg=", item.avg_d)
    end,
    function() end
)
if res.code ~= 0 then
    ngx.log(ngx.ERR, "stream open failed: ", res.error)
    return
end

-- ... later
st:close()   -- stops the stream and releases the handle
```

Methods: `new(cwrap)`, `open(sql, stime, handle, callback?)`, `close()`.

## resty.taos.data — column type conversion

Internal module mapping TDengine column types to Lua values.  Used by
`totable()`/`query()`; you only need it when iterating raw rows yourself:

```lua
local data = require "resty.taos.data"

-- data[<type number>](pointer) converts one column value:
local v = data[5](ptr)        -- BIGINT   -> string (exact 64-bit)
local t = data[9](ptr)        -- TIMESTAMP-> number (milliseconds)
local f = data[6](ptr)        -- FLOAT    -> number (rounded to float32 precision)
local d = data[7](ptr)        -- DOUBLE   -> number (exact)
local s = data[8](ptr)        -- BINARY   -> string
local b = data[1](ptr)        -- BOOL     -> boolean
```

Type map: `0` NULL, `1` BOOL, `2` TINYINT, `3` SMALLINT, `4` INT,
`5` BIGINT (string), `6` FLOAT, `7` DOUBLE, `8` BINARY, `9` TIMESTAMP
(number), `10` NCHAR, `11` UTINYINT, `12` USMALLINT, `13` UINT,
`14` UBIGINT.

## resty.taos.library — FFI bindings

Declares the C API of the TDengine 2.4 client library (`libtaos`) via
`ffi.cdef` and returns the `ffi.load("taos")` handle.  Loading this module
registers every FFI type (`TAOS *`, `TAOS_RES *`, `TAOS_STMT *`,
`TAOS_SUB *`, `TAOS_STREAM *`, `TAOS_BIND`, ...).  If `libtaos` is not
installed, the module still loads and returns a placeholder that raises a
descriptive error when called — this is what lets the unit-test suite run
without the native library.

# best practices — connection lifecycle & memory management

Everything in this section was learned the hard way: the driver used to
leak memory in production (nginx RSS growing forever) and a naive
"finalizer everywhere" fix made things worse.  Follow these rules and
your worker memory stays flat.

## 1. One driver per request/worker, and always close() it

`connect()` allocates a C connection (`taos_connect`) that is released
**only** by an explicit `driver:close()`.  There is deliberately no
`ffi.gc` finalizer on the connection handle: with the TDengine 2.4 client
library, attaching ANY finalizer (C function or closure) to a TAOS*
handle makes tightly-looped operations segfault under LuaJIT (verified
with bare FFI).  So the release is on you.

```lua
-- Typical per-request pattern:
local driver = taos:new()

local ok = pcall(function()
    local conn = driver:connect(conf)
    if conn.code ~= 0 then
        error("connect failed: " .. conn.error)
    end
    -- ... work ...
end)

-- ALWAYS close, even on error:
driver:close()

-- Or use the request-phase hooks:
--   ngx.on_abort(function() driver:close() end)
--   (and close again in log_by_lua as a safety net)
```

If a driver is discarded without `close()`, the connection leaks for the
life of the worker.  This is the #1 cause of "nginx memory grows
forever" in projects that create a driver per request.

## 2. query() and consume() release their result sets for you

Both `driver:query()` and `sub:consume()` call `taos_free_result()`
internally, **even when row conversion raises** (pcall-guarded), so you
cannot leak result sets through the high-level API.

```lua
local res = driver:query("select * from m1")   -- result freed internally
local t = sub:consume()                        -- result freed internally
```

If you use `resty.taos.result` directly (e.g. wrapping a `TAOS_RES*`
from `taos_query` or `stmt:use_result()`), **you** own the result set:

```lua
local r = result:new(raw_res)
if r then
    local t = r:totable()
    -- ... use t ...
    r:free()          -- mandatory; free() is idempotent
end
```

## 3. Don't attach ffi.gc finalizers to TDengine handles

This cannot be stressed enough: with the TDengine 2.4 client under
LuaJIT, `ffi.gc(handle, anything)` on a TAOS*/TAOS_RES*/TAOS_SUB*/
TAOS_STREAM* handle measurably increases the segfault rate in loops
(verified: 100% crash rate in the consume loop with a finalizer vs ~50%
without, using bare FFI).  The driver therefore uses **explicit release +
pcall-guarded cleanup** everywhere instead of GC finalizers.  When
extending the library, keep it that way.

## 4. Async queries: callbacks are kept alive, then dropped (list is capped)

`driver:query_async()`/`fetch_rows_async()` keep the callback trampoline
alive on the driver until the callback fires (the C side may invoke it
after `query_async()` returns).  Once the callback fires, the wrapper is
detached from the keep-alive list; the callback cdata itself stays
referenced until the trampoline has returned and is then reclaimed by the
GC, so its machine code is never freed while C is still executing it.

A driver cannot know whether a reply will ever arrive, so the keep-alive
list is capped at **64 pending operations per connection**.  Past that
limit both functions return `nil, "too many pending async queries
(max 64)"` instead of growing without bound; wait for some callbacks to
fire before issuing more.

Do not call `close()` while async operations are still in flight: the
library then drops the trampolines and cannot prevent a late callback
from touching freed memory.  Wait for the callbacks you care about, or
do not issue async work on a short-lived driver.

## 5. Subscriptions and streams must be torn down explicitly

* `sub:subscribe(...)` allocates a subscription; call
  `sub:unsubscribe(keep_progress)` when done, or it lives until the
  worker exits.
* `st:open(...)` allocates a stream; call `st:close()` to stop it.
* The result set returned by `taos_consume()` is owned by the
  subscription machinery; `consume()` already releases what it can.
  (The official `demoSubscribe.c` confirms the caller must
  `taos_free_result()`; the driver does this for you.)

## 6. Leak checklist

| Symptom | Likely cause | Fix |
|---|---|---|
| RSS grows with every request | driver created per request, `close()` never called | close in `log_by_lua` / `ngx.on_abort` |
| RSS grows in a subscribe loop | (older driver) consume result not freed | use the current driver (auto-frees) |
| RSS grows with repeated `query_async` | older driver kept every wrapper forever | current driver detaches fired callbacks and caps pending ops at 64 |
| Worker segfaults in tight loops | (extension) an `ffi.gc` finalizer was added to a TAOS handle | remove it; use explicit release |
| Lua error mid-conversion leaks | result freed only on the happy path | pcall-guarded release (current driver) |

These paths are all covered by dedicated unit tests and are part of the
100% line coverage (see below).

## 7. Security: error text and the example stack

`taos_errstr()` returns the server's diagnostic text.  It can echo SQL
fragments, table/column names and server details, so treat it as internal
diagnostics: log it with `ngx.log(ngx.ERR, ...)` and return a stable error
code (for example `res.code`) to the client, not the raw string.

The `docker/` stack is a development/test aid, **not a deployment
template**:

* `docker/nginx.conf` exposes the `/version` and `/test` diagnostic
  endpoints and runs over plain HTTP on port 8080;
* it uses the TDengine demo credentials (`root` / `taosdata`);
* it must not be exposed to untrusted networks.

The example endpoints follow the guidance above: failures are reported as
numeric `code=` values, and the container's `error_log` runs at `warn`
(never `debug`).

## 8. Connection pooling is opt-in — prefer it for per-request workloads

`connect()` + `close()` costs 5–20 ms per request on the reference stack,
most of it inside `taos_close()`, while a point query takes a fraction of a
millisecond.  Set `pool = true` in the connection conf to reuse connections
inside the worker:

* the pool is keyed by host/port/user/database; each key keeps at most 16
  idle handles, expiring them after 30 s (expired handles are closed);
* `close()` puts a healthy handle back instead of calling `taos_close()`, so
  the next `connect()` with the same conf skips `taos_init()` and
  `taos_connect()`;
* a handle is closed for real when a query failed, `select_db()` changed the
  default database, or the driver ran an async query — those states do not
  match the pool key's assumptions;
* statements, subscriptions and streams stay per-driver objects: tear them
  down before `close()`, and don't share one pooled handle between drivers.

# unit tests
Two suites are provided.  Neither requires a TDengine server or the
native `libtaos` library: the C layer is replaced by a mock (`t/helper.lua`)
that records every call and lets each test script the return values.

## 1. LuaJIT unit tests (fast, no nginx)

```bash
# run the whole suite
luajit t/run.lua

# run a subset
luajit t/run.lua t.data_spec t.async_spec

# static analysis (optional)
luacheck lib t
```

### Line coverage (100% required)

The coverage runner executes the full unit-test suite under a LuaJIT
debug line hook and reports per-file line coverage of every module in
`lib/resty/taos*`.  Executable lines are detected from the bytecode
(`luajit -bL`), so table-constructor field lines and function-declaration
lines are not miscounted.  The suite must pass **and** every executable
line must be hit, otherwise the runner exits non-zero.

```bash
luajit t/run_coverage.lua
```

Notes:

* Run with the system (Homebrew) LuaJIT: its debug hook is stable, while
  the OpenResty-bundled LuaJIT segfaults intermittently under a line hook
  with FFI-heavy code.
* The bytecode listing step auto-detects a `-bL`-capable interpreter
  (`LUAJIT_BIN` override, then the OpenResty-bundled luajit, then the
  current interpreter).
* The runner forces the `pcall(require, "table.new")` fallback in every
  module (LuaJIT ships `table.new`, so that branch would otherwise be
  unreachable); this is coverage-only and does not affect the normal
  suites.

Memory-management paths (result-set release in `query()`/`consume()`,
the async keep-alive list cleanup after callbacks fire, the pcall-guarded
release on conversion errors, idempotent `free()`, `close()` clearing
async wrappers) are all exercised by dedicated tests and are part of the
100% line coverage.

## 2. test::nginx tests (real OpenResty worker)

The `t/*.t` files spawn a real nginx with the library loaded, so the
driver is exercised inside an actual worker (real `ngx.log`, FFI in the
worker, request/response handling).  The TDengine C library is still
mocked at the Lua level (`t/nginx_util.lua`), so no server is needed.

Prerequisites: an OpenResty `nginx` binary on `PATH` and the Perl module
`Test::Nginx::Socket`.

```bash
# either
PATH=/usr/local/openresty/nginx/sbin:$PATH ./t/run-nginx.sh

# or, if nginx is already on PATH
./t/run-nginx.sh

# run a single file
TEST_NGINX_BINARY=/usr/local/openresty/nginx/sbin/nginx prove -v t/001-driver.t
```

Every `--- no_error_log [error]` assertion verifies that no Lua error
leaked into the nginx error log (this is what caught the `ngx.ERROR`
log-level bug and the subscription error-branch crash).

# integration test samples
These need a running TDengine (see `docker-compose.yaml`, which builds
TDengine 2.4.0.12 from source):

```bash
docker-compose up --build

docker exec -it {id} /bin/bash

resty --errlog-level debug ./test.lua
```
