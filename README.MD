# lua-resty-taos

A LuaJIT FFI driver for the TDengine **2.4** C client library (`libtaos`),
built for OpenResty / ngx_lua.

[中文文档](README.zh-CN.md)

The driver talks to `libtaos` directly through LuaJIT FFI: no cosocket layer,
no Lua dependencies, and no extra runtime beyond the native client. It
provides:

* synchronous SQL execution (`query`) and callback-based asynchronous
  queries (`query_async` / `fetch_rows_async`);
* prepared statements, topic subscriptions and stream compute;
* exact column conversion: 64-bit BIGINT as strings, timestamps as
  milliseconds, unsigned integers preserved, and byte-length-aware
  BINARY/NCHAR values;
* an opt-in per-worker idle connection pool, so per-request workloads do not
  pay for a connect/close round-trip on every request.

**Blocking vs. nonblocking.** `query()` blocks the nginx worker for the
duration of the server round-trip (well under a millisecond for a point
query on a LAN, but still blocking). The asynchronous API is callback-based:
the worker is not blocked, but there is no coroutine integration — design
your handler around the callback. See best practice 4 for the async limits.

**Compatibility.** This driver targets the TDengine **2.4** C API and is
tested against the 2.4.0.12 client and server. The C API changed in
TDengine 3.x; this is not a TDengine 3.x client.

**License.** MIT — see [LICENSE](LICENSE).

# install

```bash
git clone <this repository>
cd lua-resty-taos
luarocks build
```

Requirements:

* OpenResty (LuaJIT). A standalone LuaJIT is only needed for the coverage
  runner (see [testing](#testing));
* the TDengine 2.4 client library installed so that `ffi.load("taos")`
  finds it (`libtaos.so.1` on Linux, `libtaos.dylib` on macOS).

There are no Lua dependencies. If `libtaos` is missing the library still
loads; every C call then raises a descriptive error. That is what lets the
unit tests run without the native library.

# modules at a glance

| Module | Purpose |
|---|---|
| `resty.taos` | main driver: connect, query, async query, options, statements |
| `resty.taos.pool` | per-worker idle connection pool used by `pool = true` |
| `resty.taos.result` | `TAOS_RES*` wrapper: row/block fetch, conversion, free |
| `resty.taos.stmt` | prepared statements |
| `resty.taos.async` | trampolines behind `query_async` / `fetch_rows_async` |
| `resty.taos.subscribe` | topic subscription and `consume()` |
| `resty.taos.stream` | continuous queries (stream compute) |
| `resty.taos.data` | column type conversion |
| `resty.taos.library` | `ffi.cdef` + `ffi.load("taos")` for the C API |

# modules

## resty.taos — main driver

The top-level module. Creates driver instances, manages the connection and
provides synchronous query, asynchronous query, prepared statements, options
and helpers.

```lua
local taos = require "resty.taos"

-- One driver instance per request/worker is the typical usage.
local driver = taos:new()

-- Connect.  Returns { code, conn, error }.
local conn = driver:connect({
    host = "127.0.0.1",
    port = 6030,
    user = "root",
    password = "taosdata",
    -- database = "demo",   -- optional default database
    -- pool = true,         -- opt-in per-worker connection reuse
})
if conn.code ~= 0 then
    ngx.log(ngx.ERR, "connect failed: ", conn.error)
    return
end

-- Synchronous query.  Returns { code, affected, item, error }.
--   * item is an array of rows; each row is { <column> = <value>, ... }
--   * BIGINT values are returned as strings (64-bit precision);
--     TIMESTAMP values are returned as millisecond numbers.
local res = driver:query("select * from m1")
if res == nil then
    -- No result handle at all: the C call failed and the connection is
    -- flagged unusable (it is never returned to the pool).
    ngx.log(ngx.ERR, "query failed: ", driver:get_error_string())
elseif res.code ~= 0 then
    -- The server rejected the statement; res.error is taos_errstr().
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

-- Client-side options.  Supported keys: locale, charset, timezone, cfgdir.
driver:options({ timezone = "UTC-8", charset = "UTF-8" })

-- Error helpers (work with or without an explicit handle).
ngx.log(ngx.WARN, driver:get_error_string())
ngx.log(ngx.WARN, "errno: ", driver:get_error_no())

-- Asynchronous query (see resty.taos.async and best practice 4).
local ok, err = driver:query_async("insert into t values (1)", function(t)
    if t.code == 0 then
        ngx.log(ngx.INFO, "async done, affected: ", t.affected)
    else
        ngx.log(ngx.ERR, "async failed: ", t.error)
    end
end)
if not ok then
    ngx.log(ngx.ERR, "query_async rejected: ", err)
end

-- Prepared statement (see resty.taos.stmt).
local stmt = driver:stmt()

-- Always close: the connection is released only here (or by the pool).
driver:close()
```

Connection configuration (`connect(conf)`):

| Field | Type | Notes |
|---|---|---|
| `host` | string | server address |
| `port` | number | native TDengine port, normally 6030 |
| `user` | string | |
| `password` | string | |
| `database` | string (optional) | default database |
| `pool` | boolean (optional) | opt-in connection reuse, see below |

`connect()` returns `{ code, conn, error }`: `code = 0` on success, `code =
-1` with a descriptive `error` when `taos_connect()` fails (`conn` then holds
a NULL handle). `query()` returns `{ code, affected, item, error }`, or `nil`
when no result handle could be created at all.

Methods: `new()`, `connect(conf)`, `close()`, `query(sql)`,
`query_async(sql, callback)`, `fetch_rows_async(res, callback)`,
`options(opts)`, `select_db(db)`, `validate_sql(sql)`, `stmt()`,
`get_client_info()`, `get_server_info()`, `get_error_string(res?)`,
`get_error_no(res?)`, `init()`, `cleanup()`.

`init()` calls `taos_init()` and is invoked by `connect()`; `cleanup()` calls
`taos_cleanup()` and is normally left to worker shutdown.

### connection pooling (opt-in)

By default every `connect()` opens a new C connection and every `close()`
closes it. For per-request workloads that is mostly pure overhead (the
reference stack spends 5–20 ms per request in connect+close, versus well
under a millisecond on a point query), so the driver can keep a small
per-worker idle pool instead:

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
closed). `close()` returns the handle to the pool instead of calling
`taos_close()`, so a later `connect()` with the same conf skips
`taos_init()`/`taos_connect()`. A connection is closed for real — never
pooled — when a query failed, `select_db()` changed the default database, or
an async query was issued on the driver. Full rules are in best practice 7;
the pool object itself is documented below.

## resty.taos.pool — per-worker idle connection pool

The idle pool behind `pool = true`. It is created lazily by the driver and
shared by every pooled driver in the worker; you normally do not need to
touch it. Use it directly only if you manage your own handles.

```lua
local pool = require "resty.taos.pool"

local p = pool:new({
    max_idle     = 16,        -- idle handles per key (default 16)
    idle_timeout = 30000,     -- milliseconds (default 30000)
    now          = nil,       -- clock override, returns ms (default ngx/os)
    close        = function(handle) handle:close() end,  -- release callback
})

local key = "127.0.0.1:6030:root:demo"
local handle = p:acquire(key)     -- most recently released handle, or nil
if handle == nil then
    handle = open_connection()
end

-- ... use handle ...

p:release(key, handle)            -- put it back (closes it if the key is full)
p:size(key)                       -- idle handles currently held for key
p:clear()                         -- close every idle handle and forget keys
```

Methods: `new(opts)`, `acquire(key)`, `release(key, handle)`, `size(key)`,
`clear()`.

Behaviour:

* one pool per worker — an nginx worker runs Lua single-threaded, so a plain
  table is a safe store and no locks are needed;
* `acquire()` pops the most recently released handle (LIFO) and drops
  expired entries on the way, calling `close` on each;
* `release()` keeps the handle when the key holds fewer than `max_idle`
  entries, otherwise it calls `close(handle)` and returns `false`;
* expiry is checked when a handle is acquired — there is no background
  timer, so an idle worker keeps its handles until the next `acquire()`;
* without a `close` callback the pool simply forgets handles; production
  always passes one (the unit tests omit it to observe what would be
  released).

## resty.taos.result — result sets

Wraps a C `TAOS_RES*` handle. `query()` uses it internally; use it directly
when you need row-by-row access or the low-level fetch API.

```lua
local result = require "resty.taos.result"
local data   = require "resty.taos.data"

-- Wrap a TAOS_RES* (e.g. from resty.taos.library).
local r = result:new(raw_res)
if r then
    -- Convert the whole result set to Lua tables at once.
    local t = r:totable()          -- { code, affected, item }
    for _, row in ipairs(t.item or {}) do
        ngx.say(row.ts, " ", row.speed)
    end

    -- Or iterate row by row.  Column pointers must be converted with
    -- resty.taos.data; BINARY/NCHAR values also need the per-row byte
    -- lengths from taos_fetch_lengths().
    local fields = r:fetch_fields()   -- { {name, type, len}, ... }
    while true do
        local row = r:fetch_row()
        if not row then break end     -- end of result set
        local lens = r:fetch_lengths() -- byte length per column (may be NULL)
        for i = 0, r:num_fields() - 1 do
            local field = fields[i + 1]
            -- lens is NULL-cdata when unavailable; compare against nil.
            local len = lens ~= nil and lens[i] or nil
            -- row[i] (0-based) is a C pointer to the i-th column value.
            local value = data[field.type](row[i], len)
        end
    end

    -- Explicit release: TAOS_RES handles have NO GC finalizer, so free()
    -- must be called (query()/consume() do it for you).  free() is
    -- idempotent.
    r:free()
end
```

Methods: `new(result)`, `totable()`, `fetch_row()`, `fetch_block()`,
`fetch_fields()`, `fetch_lengths()`, `num_fields()`, `field_count()`,
`affected_rows()`, `precision()`, `stop()`, `errstr()`, `errno()`,
`free()`.

`totable()` fetches the per-row byte lengths itself and passes them to the
BINARY/NCHAR converters, so `query()`/`consume()` results are exact even for
fixed-length columns and values containing NUL bytes.

## resty.taos.stmt — prepared statements

Parameterised statements for batch inserts / repeated execution. Note: the
parameter binding uses the C `TAOS_BIND` structure, so `bind_param()` expects
an FFI-constructed binding (see `resty.taos.library` for the struct layout).

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
    -- Missing callback, or the per-connection cap (64) is reached.
    ngx.log(ngx.ERR, "query_async rejected: ", err)
end
```

For row fetching you can use `fetch_rows_async(res, callback)` with a result
handle obtained from `taos_query` (the success table of a SELECT callback
also exposes the raw handle as `t.res`).

Module API: `new(cwrap)`, `query(sql, callback)`, `fetch_rows(res,
callback)` (normally used through `driver:query_async()` /
`driver:fetch_rows_async()`).

The driver keeps each callback trampoline alive until it fires, detaches it
immediately at callback entry (so a raising user callback cannot pin it),
and caps the number of pending operations at **64 per connection**. Past the
cap both functions return `nil, "too many pending async queries (max 64)"`.
See best practice 4 for the lifetime rules and the `close()` hazard.

## resty.taos.subscribe — topic subscription

Subscribe to a query result set and poll (or receive) the changes. This is
the API behind "watch a table for new rows".

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

-- Poll and consume new rows.  consume() frees the result set it wraps.
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

Internal module mapping TDengine column types to Lua values. Used by
`totable()`/`query()`; you only need it when iterating raw rows yourself:

```lua
local data = require "resty.taos.data"

-- data[<type>](pointer, length?) converts one column value.
local v = data[5](ptr)         -- BIGINT   -> string (exact 64-bit)
local t = data[9](ptr)         -- TIMESTAMP-> number (milliseconds)
local f = data[6](ptr)         -- FLOAT    -> number (7 significant digits)
local d = data[7](ptr)         -- DOUBLE   -> number (exact)
local s = data[8](ptr, len)    -- BINARY   -> string (length-aware)
local n = data[10](ptr, len)   -- NCHAR    -> string (length-aware)
local b = data[1](ptr)         -- BOOL     -> boolean
```

Type map:

| Code | TDengine type | Lua value |
|---|---|---|
| 0 | NULL | `nil` |
| 1 | BOOL | boolean |
| 2 | TINYINT | number |
| 3 | SMALLINT | number |
| 4 | INT | number |
| 5 | BIGINT | string (exact 64-bit) |
| 6 | FLOAT | number (rounded to 7 significant digits) |
| 7 | DOUBLE | number (exact) |
| 8 | BINARY | string (pass the byte length) |
| 9 | TIMESTAMP | number (milliseconds) |
| 10 | NCHAR | string (pass the byte length) |
| 11 | UTINYINT | number (unsigned) |
| 12 | USMALLINT | number (unsigned) |
| 13 | UINT | number (unsigned) |
| 14 | UBIGINT | number (parsed from the decimal string; exact only up to 2^53) |

**BINARY / NCHAR need a byte length.** TDengine reports the exact byte
length of each value through `taos_fetch_lengths()`; a fixed-length BINARY
column is not guaranteed to be NUL-terminated and its value may legitimately
contain NUL bytes. `data[8]`/`data[10]` therefore accept an optional second
argument: when given, they take exactly that many bytes
(`ffi.string(ptr, len)`); without it they fall back to the historical
NUL-terminated read, which is only safe for values you know are terminated.
`totable()` (and therefore `query()`, `consume()`, the stream handler) always
passes the reported lengths. See best practice 6.

## resty.taos.library — FFI bindings

Declares the C API of the TDengine 2.4 client library (`libtaos`) via
`ffi.cdef` and returns the `ffi.load("taos")` handle. Loading this module
registers every FFI type (`TAOS *`, `TAOS_RES *`, `TAOS_STMT *`,
`TAOS_SUB *`, `TAOS_STREAM *`, `TAOS_BIND`, ...). If `libtaos` is not
installed, the module still loads and returns a placeholder that raises a
descriptive error when called — this is what lets the unit-test suite run
without the native library.

# best practices — connection lifecycle, memory and security

Everything in this section was learned the hard way: the driver used to leak
memory in production (nginx RSS growing forever), a naive "finalizer
everywhere" fix made things worse, and a length-blind BINARY/NCHAR
conversion could read past the end of a fixed-length column. Follow these
rules and your worker memory stays flat and your reads stay in bounds.

## 1. One driver per request/worker — and always close()

`connect()` allocates a C connection (`taos_connect`) that is released
**only** by an explicit `driver:close()` (or, with `pool = true`, handed back
to the idle pool, where it is closed on expiry). There is deliberately no
`ffi.gc` finalizer on the connection handle: with the TDengine 2.4 client
library, attaching ANY finalizer (C function or closure) to a TAOS* handle
makes tightly-looped operations segfault under LuaJIT (verified with bare
FFI). So the release is on you.

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
life of the worker — this is the #1 cause of "nginx memory grows forever" in
projects that create a driver per request.

## 2. Result sets: query()/consume() free; direct handles are yours

`driver:query()` and `sub:consume()` call `taos_free_result()` internally,
**even when row conversion raises** (pcall-guarded), so you cannot leak
result sets through the high-level API.

```lua
local res = driver:query("select * from m1")   -- result freed internally
local t = sub:consume()                        -- result freed internally
```

If you use `resty.taos.result` directly (e.g. wrapping a `TAOS_RES*` from
`taos_query` or `stmt:use_result()`), **you** own the result set and must
call `free()`. There is no GC fallback: attaching a finalizer to TDengine
handles is off-limits (see rule 3), so an unfreed wrapper leaks the C result
set. `free()` is idempotent.

```lua
local r = result:new(raw_res)
if r then
    local t = r:totable()
    -- ... use t ...
    r:free()          -- mandatory; free() is idempotent
end
```

## 3. Never attach ffi.gc finalizers to TDengine handles

This cannot be stressed enough: with the TDengine 2.4 client under LuaJIT,
`ffi.gc(handle, anything)` on a TAOS*/TAOS_RES*/TAOS_SUB*/TAOS_STREAM*
handle measurably increases the segfault rate in loops (verified: 100%
crash rate in the consume loop with a finalizer vs ~50% without, using bare
FFI). The driver therefore uses **explicit release + pcall-guarded cleanup**
everywhere instead of GC finalizers. When extending the library, keep it
that way.

## 4. Async queries: capped keep-alive list, live trampolines, no close in flight

`driver:query_async()`/`fetch_rows_async()` keep the callback trampoline
alive on the driver until the callback fires (the C side may invoke it after
`query_async()` returns). At callback entry the wrapper is detached from the
keep-alive list, but `self.handle`/`self.param` stay referenced until the
trampoline has returned — the callback machine code is never freed while C
is still executing it, and a raising user callback cannot pin the wrapper.

A driver cannot know whether a reply will ever arrive, so the keep-alive
list is capped at **64 pending operations per connection**. Past that limit
both functions return `nil, "too many pending async queries (max 64)"`
instead of growing without bound; wait for some callbacks to fire before
issuing more. The driver reuses freed slots, so callbacks may fire in any
order.

Do not call `close()` while async operations are still in flight: the
library then drops the trampolines and cannot prevent a late callback from
touching freed memory. It logs a WARN when it notices; wait for the
callbacks you care about, or do not issue async work on a short-lived
driver.

## 5. Subscriptions and streams must be torn down explicitly

* `sub:subscribe(...)` allocates a subscription; call
  `sub:unsubscribe(keep_progress)` when done, or it lives until the worker
  exits.
* `st:open(...)` allocates a stream; call `st:close()` to stop it.
* The result set returned by `taos_consume()` is owned by the subscription
  machinery; `consume()` already releases what it can. (The official
  `demoSubscribe.c` confirms the caller must `taos_free_result()`; the
  driver does this for you.)

## 6. BINARY/NCHAR values need their byte length

TDengine's `taos_fetch_lengths()` returns the exact byte length of every
column in the row just fetched. Fixed-length BINARY columns are not
NUL-terminated, and BINARY/NCHAR values may contain embedded NULs, so a
length-blind `ffi.string(ptr)` can either overrun the buffer or truncate the
value. The driver's conversion path passes the reported length:

* `result:totable()` fetches `fetch_lengths()` after every `fetch_row()` and
  hands `lens[i]` to the BINARY/NCHAR converters — this covers `query()`,
  `consume()`, and the stream handler;
* the converters still accept a missing length for backwards compatibility,
  but that fallback is only safe for NUL-terminated values you control.

When iterating raw rows yourself, do the same:

```lua
local data = require "resty.taos.data"
local lens = r:fetch_lengths()          -- int* (0-based); may be NULL
local row  = r:fetch_row()
local len  = lens ~= nil and lens[i] or nil
local v    = data[type](row[i], len)    -- i is 0-based
```

## 7. Connection pooling is opt-in — prefer it for per-request workloads

`connect()` + `close()` costs 5–20 ms per request on the reference stack,
most of it inside `taos_close()`, while a point query takes a fraction of a
millisecond. Set `pool = true` in the connection conf to reuse connections
inside the worker:

```lua
driver:connect({ host = "127.0.0.1", port = 6030,
                 user = "root", password = "taosdata",
                 database = "demo", pool = true })
```

* the pool is keyed by host/port/user/database (the password is not part of
  the key — use distinct users or do not enable pooling if you rely on
  per-password isolation); each key keeps at most 16 idle handles, expiring
  them after 30 s (expired handles are closed);
* `close()` puts a healthy handle back instead of calling `taos_close()`, so
  the next `connect()` with the same conf skips `taos_init()` and
  `taos_connect()`;
* a handle is closed for real when a query failed, `select_db()` changed the
  default database, or the driver ran an async query — those states do not
  match the pool key's assumptions;
* statements, subscriptions and streams stay per-driver objects: tear them
  down before `close()`, and don't share one pooled handle between drivers
  or across workers (the pool is per worker by design).

The pool object itself (`resty.taos.pool`) is documented above if you manage
handles yourself.

## 8. Error text is internal diagnostics — do not return it to clients

`taos_errstr()` returns the server's diagnostic text. It can echo SQL
fragments, table/column names and server details, so treat it as internal
diagnostics: log it with `ngx.log(ngx.ERR, ...)` and return a stable error
code (for example `res.code`) to the client, not the raw string.

```lua
local res = driver:query(sql)
if res == nil then
    return ngx.exit(500)
end
if res.code ~= 0 then
    ngx.log(ngx.ERR, "query failed: ", res.error)   -- internal only
    ngx.say("query failed, code=", res.code)        -- stable, safe
    return
end
```

The `docker/` stack is a development/test aid, **not a deployment
template**:

* `docker/nginx.conf` exposes the `/version` and `/test` diagnostic
  endpoints and runs over plain HTTP on port 8080;
* it uses the TDengine demo credentials (`root` / `taosdata`);
* it must not be exposed to untrusted networks.

The example endpoints follow the guidance above: failures are reported as
numeric `code=` values, and the container's `error_log` runs at `warn`
(never `debug`). See [docker/readme.md](docker/readme.md) for the full test
stack and its security notes.

## 9. Leak checklist

| Symptom | Likely cause | Fix |
|---|---|---|
| RSS grows with every request | driver created per request, `close()` never called | close in `log_by_lua` / `ngx.on_abort` |
| RSS grows in a subscribe loop | (older driver) consume result not freed | use the current driver (auto-frees) |
| RSS grows with repeated `query_async` | (older driver) kept every wrapper forever; or callbacks never fire | current driver detaches fired callbacks and caps pending ops at 64 |
| Idle handles never shrink | (custom pool use) `close` callback missing or pool never cleared | pass a close callback; `pool:clear()` on shutdown |
| Worker segfaults in tight loops | (extension) an `ffi.gc` finalizer was added to a TAOS handle | remove it; use explicit release |
| Lua error mid-conversion leaks | result freed only on the happy path | pcall-guarded release (current driver) |

These paths are all covered by dedicated unit tests and are part of the 100%
line coverage (see below).

# testing

Two suites are provided, plus a real-server integration stack. Neither test
suite requires a TDengine server or the native `libtaos`: the C layer is
replaced by a mock (`t/helper.lua`) that records every call and lets each
test script the return values.

## 1. LuaJIT unit tests (fast, no nginx)

```bash
# run the whole suite
luajit t/run.lua

# run a subset
luajit t/run.lua t.data_spec t.async_spec

# static analysis (optional)
luacheck lib t
```

## 2. Line coverage (100% required)

The coverage runner executes the full unit-test suite under a LuaJIT debug
line hook and reports per-file line coverage of every module in
`lib/resty/taos*`. Executable lines are detected from the bytecode
(`luajit -bL`), so table-constructor field lines and function-declaration
lines are not miscounted. The suite must pass **and** every executable line
must be hit, otherwise the runner exits non-zero.

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
  unreachable); this is coverage-only and does not affect the normal suites.

Memory-management paths (result-set release in `query()`/`consume()`, the
async keep-alive list cleanup after callbacks fire, detaching a raising
callback, the pcall-guarded release on conversion errors, idempotent
`free()`, `close()` clearing async wrappers, pooled-connection expiry) are
all exercised by dedicated tests and are part of the 100% line coverage.

## 3. test::nginx tests (real OpenResty worker)

The `t/*.t` files spawn a real nginx with the library loaded, so the driver
is exercised inside an actual worker (real `ngx.log`, FFI in the worker,
request/response handling). The TDengine C library is still mocked at the Lua
level (`t/nginx_util.lua`), so no server is needed.

Prerequisites: an OpenResty `nginx` binary and the Perl module
`Test::Nginx::Socket`.

```bash
# either
PATH=/usr/local/openresty/nginx/sbin:$PATH ./t/run-nginx.sh

# or, if nginx is already on PATH
./t/run-nginx.sh

# run a single file
TEST_NGINX_BINARY=/usr/local/openresty/nginx/sbin/nginx prove -v t/001-driver.t
```

If the system Perl lacks `Test::Nginx::Socket`, install it into a local lib
and point `PERL5LIB` at it:

```bash
cpanm --local-lib="$HOME/.perl5-local" --notest Test::Nginx::Socket
PERL5LIB="$HOME/.perl5-local/lib/perl5" ./t/run-nginx.sh
```

Every `--- no_error_log [error]` assertion verifies that no Lua error leaked
into the nginx error log (this is what caught the `ngx.ERROR` log-level bug
and the subscription error-branch crash).

## 4. Real server integration (docker)

`docker-compose.yaml` builds a real environment: TDengine 2.4.0.12 (compiled
from source) plus OpenResty with this driver, exposing `/version` and `/test`
over HTTP.

```bash
docker compose up --build -d

curl http://127.0.0.1:8080/version
curl http://127.0.0.1:8080/test

# run the project's integration script inside the container
docker compose exec taos resty --errlog-level debug \
    /usr/local/lvhuan/lua-resty-taos/test.lua
```

Details, verified results, and the known emulation-related segfaults of the
2.4 client under x86 emulation are documented in
[docker/readme.md](docker/readme.md). The stack runs as `linux/amd64` because
TDengine 2.4 ships x86_64 binaries only.
