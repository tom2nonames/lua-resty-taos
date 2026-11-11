# lua-resty-taos

面向 OpenResty / ngx_lua 的 LuaJIT FFI 驱动,直接调用 TDengine **2.4** C
客户端库(`libtaos`)。

[English](README.MD)

驱动通过 LuaJIT FFI 直接与 `libtaos` 交互:没有 cosocket 层,没有 Lua
依赖,除原生客户端外不需要任何额外运行时。它提供:

* 同步 SQL 执行(`query`)与基于回调的异步查询(`query_async` /
  `fetch_rows_async`);
* 预编译语句、主题订阅与流式计算;
* 精确的列类型转换:64 位 BIGINT 以字符串返回、TIMESTAMP 以毫秒返回、
  无符号整数不丢符号、BINARY/NCHAR 按真实字节长度读取;
* 可选的每 worker 空闲连接池,让"每请求一个驱动"的工作负载不必为每次
  请求支付 connect/close 的开销。

**阻塞与非阻塞。** `query()` 会在服务端往返期间阻塞 nginx worker(局域网
内点查询通常远低于 1 ms,但仍然是阻塞的)。异步 API 基于回调:worker 不会
被阻塞,但没有协程集成 —— 请围绕回调设计处理流程。异步的容量与生命周期
限制见最佳实践第 4 节。

**兼容性。** 本驱动面向 TDengine **2.4** 的 C API,已在 2.4.0.12 客户端
与服务端上验证。TDengine 3.x 改变了该 API,本驱动不是 3.x 客户端。

**许可。** MIT —— 见 [LICENSE](LICENSE)。

# 安装

```bash
git clone <本仓库>
cd lua-resty-taos
luarocks build
```

前置条件:

* OpenResty(LuaJIT)。独立 LuaJIT 仅覆盖率运行器需要(见[测试](#测试));
* 已安装 TDengine 2.4 客户端库,使 `ffi.load("taos")` 能找到它
  (Linux 为 `libtaos.so.1`,macOS 为 `libtaos.dylib`)。

运行时没有任何 Lua 依赖。若缺少 `libtaos`,库仍可加载,但每次 C 调用都会
抛出描述性错误 —— 这也是单元测试无需原生库即可运行的原因。

# 模块一览

| 模块 | 用途 |
|---|---|
| `resty.taos` | 主驱动:连接、查询、异步查询、选项、语句 |
| `resty.taos.pool` | `pool = true` 使用的每 worker 空闲连接池 |
| `resty.taos.result` | `TAOS_RES*` 封装:逐行/块读取、转换、释放 |
| `resty.taos.stmt` | 预编译语句 |
| `resty.taos.async` | `query_async` / `fetch_rows_async` 背后的 trampoline |
| `resty.taos.subscribe` | 主题订阅与 `consume()` |
| `resty.taos.stream` | 连续查询(流式计算) |
| `resty.taos.data` | 列类型转换 |
| `resty.taos.library` | C API 的 `ffi.cdef` + `ffi.load("taos")` |

# 模块说明

## resty.taos — 主驱动模块

顶层模块。创建驱动实例、管理连接,并提供同步查询、异步查询、预编译语句、
连接选项与辅助函数。

```lua
local taos = require "resty.taos"

-- 典型用法:每个请求/worker 一个驱动实例。
local driver = taos:new()

-- 连接。返回 { code, conn, error }。
local conn = driver:connect({
    host = "127.0.0.1",
    port = 6030,
    user = "root",
    password = "taosdata",
    -- database = "demo",   -- 可选:默认数据库
    -- pool = true,         -- 可选:在本 worker 内复用连接
})
if conn.code ~= 0 then
    ngx.log(ngx.ERR, "连接失败: ", conn.error)
    return
end

-- 同步查询。返回 { code, affected, item, error }。
--   * item 是行数组,每行形如 { <列名> = <值>, ... }
--   * BIGINT 值以字符串返回(保留 64 位精度);
--     TIMESTAMP 值以毫秒数字返回。
local res = driver:query("select * from m1")
if res == nil then
    -- 完全没有结果句柄:C 调用失败,连接被标记为不可用
    -- (不会被归还到连接池)。
    ngx.log(ngx.ERR, "查询失败: ", driver:get_error_string())
elseif res.code ~= 0 then
    -- 服务端拒绝了该语句;res.error 是 taos_errstr() 的文本。
    ngx.log(ngx.ERR, "查询错误: ", res.error)
else
    ngx.say("受影响行数: ", res.affected)
    for _, row in ipairs(res.item) do
        ngx.say(row.ts, " ", row.speed, " ", row.owner)
    end
end

-- 客户端 / 服务端版本。
ngx.log(ngx.INFO, driver:get_client_info())
ngx.log(ngx.INFO, driver:get_server_info())

-- 切换默认数据库。
local ok, err = driver:select_db("demo")

-- 校验 SQL 语句(返回 C 状态码)。
local code = driver:validate_sql("select 1")

-- 客户端选项。支持键:locale、charset、timezone、cfgdir。
driver:options({ timezone = "UTC-8", charset = "UTF-8" })

-- 错误辅助函数(有无显式句柄均可)。
ngx.log(ngx.WARN, driver:get_error_string())
ngx.log(ngx.WARN, "errno: ", driver:get_error_no())

-- 异步查询(参见 resty.taos.async 与最佳实践第 4 节)。
local ok, err = driver:query_async("insert into t values (1)", function(t)
    if t.code == 0 then
        ngx.log(ngx.INFO, "异步完成, affected: ", t.affected)
    else
        ngx.log(ngx.ERR, "异步失败: ", t.error)
    end
end)
if not ok then
    ngx.log(ngx.ERR, "query_async 被拒绝: ", err)
end

-- 预编译语句(参见 resty.taos.stmt)。
local stmt = driver:stmt()

-- 务必 close:连接只在这里(或由连接池)释放。
driver:close()
```

连接配置(`connect(conf)`):

| 字段 | 类型 | 说明 |
|---|---|---|
| `host` | string | 服务端地址 |
| `port` | number | TDengine 原生端口,通常为 6030 |
| `user` | string | |
| `password` | string | |
| `database` | string(可选) | 默认数据库 |
| `pool` | boolean(可选) | 启用连接复用,见下文 |

`connect()` 返回 `{ code, conn, error }`:`taos_connect()` 成功时 `code =
0`;失败时 `code = -1`,并给出描述目标的 `error`(`conn` 此时是 NULL 句柄)。
`query()` 返回 `{ code, affected, item, error }`,只有在完全无法创建结果句柄
时才返回 `nil`。

方法清单:`new()`、`connect(conf)`、`close()`、`query(sql)`、
`query_async(sql, callback)`、`fetch_rows_async(res, callback)`、
`options(opts)`、`select_db(db)`、`validate_sql(sql)`、`stmt()`、
`get_client_info()`、`get_server_info()`、`get_error_string(res?)`、
`get_error_no(res?)`、`init()`、`cleanup()`。

`init()` 调用 `taos_init()`,由 `connect()` 内部调用;`cleanup()` 调用
`taos_cleanup()`,通常留给 worker 退出时执行。

### 连接池(可选启用)

默认每次 `connect()` 都会新建一条 C 连接,`close()` 则关闭它。对按请求
处理的工作负载,这部分几乎全是纯开销(参考环境下 connect+close 每次约
5–20 ms,而一次点查询远低于 1 ms)。驱动可为每个 worker 保留一个小型
空闲连接池,在 conf 中设置 `pool = true` 即可启用:

```lua
local driver = taos:new()
driver:connect({
    host = "127.0.0.1", port = 6030,
    user = "root", password = "taosdata",
    pool = true,                       -- 在本 worker 内复用连接
})

-- ... 业务处理 ...

driver:close()   -- 将连接归还到 worker 连接池
```

连接池以 host/port/user/database 为键,每个键最多保留 16 条空闲连接,
30 秒后过期(过期连接会被关闭)。`close()` 会把健康连接归还到池中而不是
调用 `taos_close()`,因此后续用相同 conf 的 `connect()` 会跳过
`taos_init()` 与 `taos_connect()`。以下情况会真正关闭连接、不归还:
查询失败、`select_db()` 改变了默认数据库、或在驱动上发起过异步查询。
完整规则见最佳实践第 7 节;连接池对象本身的 API 见下一节。

## resty.taos.pool — 每 worker 空闲连接池

`pool = true` 背后的空闲池。它由驱动在首次需要时惰性创建,并在该 worker
内被所有启用池化的驱动共享;通常你不需要直接接触它。只有自己管理句柄时
才需要直接使用。

```lua
local pool = require "resty.taos.pool"

local p = pool:new({
    max_idle     = 16,        -- 每个键的空闲句柄上限(默认 16)
    idle_timeout = 30000,     -- 毫秒(默认 30000)
    now          = nil,       -- 时钟覆盖函数,返回毫秒(默认 ngx/os)
    close        = function(handle) handle:close() end,  -- 释放回调
})

local key = "127.0.0.1:6030:root:demo"
local handle = p:acquire(key)     -- 最近归还的句柄;没有则为 nil
if handle == nil then
    handle = open_connection()
end

-- ... 使用 handle ...

p:release(key, handle)            -- 归还(该键已满时会直接关闭)
p:size(key)                       -- 该键当前持有的空闲句柄数
p:clear()                         -- 关闭所有空闲句柄并清空键
```

方法清单:`new(opts)`、`acquire(key)`、`release(key, handle)`、`size(key)`、
`clear()`。

行为说明:

* 每个 worker 一个池 —— nginx worker 内 Lua 是单线程执行的,普通 table
  就是安全的存储,无需加锁;
* `acquire()` 取最近归还的句柄(后进先出),并在取出过程中丢弃已过期的
  条目,对每个过期句柄调用 `close`;
* `release()` 在该键持有少于 `max_idle` 条空闲连接时保留句柄,否则调用
  `close(handle)` 并返回 `false`;
* 过期只在 `acquire()` 时检查 —— 没有后台定时器,因此空闲 worker 会一直
  持有句柄,直到下一次 `acquire()`;
* 不传 `close` 回调时,池只是"忘记"句柄;生产环境务必传入回调(单元测试
  故意不传,以便观察哪些句柄本应被释放)。

## resty.taos.result — 结果集

封装 C 层 `TAOS_RES*` 句柄。`query()` 内部使用它;当你需要逐行访问或底层
fetch API 时可以直接使用。

```lua
local result = require "resty.taos.result"
local data   = require "resty.taos.data"

-- 包装一个 TAOS_RES*(例如来自 resty.taos.library)。
local r = result:new(raw_res)
if r then
    -- 将整个结果集一次性转换为 Lua 表。
    local t = r:totable()          -- { code, affected, item }
    for _, row in ipairs(t.item or {}) do
        ngx.say(row.ts, " ", row.speed)
    end

    -- 或者逐行迭代。列指针需用 resty.taos.data 转换;BINARY/NCHAR
    -- 还需要 taos_fetch_lengths() 给出的逐列字节长度。
    local fields = r:fetch_fields()   -- { {name, type, len}, ... }
    while true do
        local row = r:fetch_row()
        if not row then break end     -- 结果集结束
        local lens = r:fetch_lengths() -- 每列字节长度(可能为 NULL)
        for i = 0, r:num_fields() - 1 do
            local field = fields[i + 1]
            -- lens 不可用时是 NULL cdata;必须显式与 nil 比较。
            local len = lens ~= nil and lens[i] or nil
            -- row[i](0 基)是指向第 i 列值的 C 指针。
            local value = data[field.type](row[i], len)
        end
    end

    -- 显式释放:TAOS_RES 句柄没有 GC finalizer,必须调用 free()
    -- (query()/consume() 会替你调用)。free() 是幂等的。
    r:free()
end
```

方法清单:`new(result)`、`totable()`、`fetch_row()`、`fetch_block()`、
`fetch_fields()`、`fetch_lengths()`、`num_fields()`、`field_count()`、
`affected_rows()`、`precision()`、`stop()`、`errstr()`、`errno()`、
`free()`。

`totable()` 会自行获取每行的字节长度并传给 BINARY/NCHAR 转换器,因此
`query()`/`consume()` 的结果即使面对定长列或含 NUL 字节的值也是精确的。

## resty.taos.stmt — 预编译语句

用于批量插入 / 重复执行的参数化语句。注意:参数绑定使用 C 层的
`TAOS_BIND` 结构,因此 `bind_param()` 需要传入 FFI 构造的绑定
(结构布局见 `resty.taos.library`)。

```lua
local stmt = driver:stmt()   -- 或 require("resty.taos.stmt"):new(conn)

-- prepare();SQL 长度可选(默认取 #sql)。
local rc = stmt:prepare("insert into t values (?, ?)")

-- 绑定参数(TAOS_BIND cdata)并加入批次...
-- stmt:bind_param(bind)
-- stmt:add_batch()
-- ...然后执行。
local rc = stmt:execute()

-- 对 SELECT 语句,获取结果集句柄。
local res = stmt:use_result()

stmt:close()   -- 必须显式调用
```

方法清单:`new(conn)`、`prepare(sql, length?)`、`bind_param(bind)`、
`add_batch()`、`execute()`、`use_result()`、`close()`。

## resty.taos.async — 异步查询

通过驱动进行非阻塞查询:

```lua
-- 发出即忘;服务端响应后回调被调用。
local ok, err = driver:query_async("insert into t values (1)", function(t)
    if t.code == 0 then
        ngx.log(ngx.INFO, "插入成功, affected: ", t.affected)
    else
        ngx.log(ngx.ERR, "异步查询失败: ", t.error)
    end
end)
if not ok then
    -- 回调缺失,或已达每连接上限(64)。
    ngx.log(ngx.ERR, "query_async 被拒绝: ", err)
end
```

如需拉取行数据,可对 `taos_query` 得到的结果句柄调用
`fetch_rows_async(res, callback)`(SELECT 的成功回调也会把原始句柄放在
`t.res` 中)。

模块 API:`new(cwrap)`、`query(sql, callback)`、`fetch_rows(res,
callback)`(通常经由 `driver:query_async()` / `driver:fetch_rows_async()`
使用)。

驱动会为每个回调 trampoline 保活直到触发,并在回调入口立即将其从保活
列表 detach(用户回调抛错也不会钉住它);每个连接的待处理操作上限为
**64 个**,超过后两个函数返回 `nil, "too many pending async queries (max
64)"`。生命周期规则与 `close()` 风险见最佳实践第 4 节。

## resty.taos.subscribe — 主题订阅

订阅某个查询结果集,并轮询(或接收)其变化。这是"监控表的新增行"类
场景的底层 API。

```lua
local subscribe = require "resty.taos.subscribe"

local sub = subscribe:new(driver)

-- 同步(轮询)订阅:
--   restart=true  -> 从头开始订阅
--   interval      -> 轮询间隔(毫秒)
local r = sub:subscribe(true, "topic1", "select * from therm1", nil, nil, 1000)
if r.code ~= 0 then
    ngx.log(ngx.ERR, "订阅失败")
    return
end

-- 轮询并消费新数据。consume() 会释放它包装的结果集。
while not ngx.worker.exiting() do
    local t = sub:consume()          -- { code, affected, item }
    if t and t.item and #t.item > 0 then
        for _, row in ipairs(t.item) do
            ngx.log(ngx.INFO, "新行: ", row.ts, " ", row.degree)
        end
    end
    ngx.sleep(1)
end

sub:unsubscribe(false)   -- keep_progress: true = 下次从上次位置继续
```

回调(异步)形式 —— 回调收到相同的 `{code, affected, item}` 表,错误也
通过它上报:

```lua
local r = sub:subscribe(true, "topic1", "select * from therm1", function(t)
    if t.code == 0 then
        for _, row in ipairs(t.item or {}) do
            ngx.log(ngx.INFO, "回调行: ", row.ts, " ", row.degree)
        end
    else
        ngx.log(ngx.ERR, "订阅错误: ", t.error)
    end
end, nil, 1000)
```

方法清单:`new(cwrap)`、`subscribe(restart, topic, sql, callback?,
param?, interval)`、`consume()`、`unsubscribe(keep_progress?)`。

## resty.taos.stream — 连续查询(流)

TDengine 流式计算:带 `interval()`/`sliding()` 的 SQL 持续运行,每产生
一批结果就调用你的处理函数。

```lua
local stream = require "resty.taos.stream"

local st = stream:new(driver)

-- stime: 起始时间(0 = 从现在开始)。handle: 每批结果回调。
-- callback: 可选的完成回调。
local res = st:open(
    "select count(*) as cnt, avg(degree) as avg_d from thermometer interval(2s) sliding(2s)",
    0,
    function(item)
        ngx.log(ngx.INFO, "流批次: cnt=", item.cnt,
                " avg=", item.avg_d)
    end,
    function() end
)
if res.code ~= 0 then
    ngx.log(ngx.ERR, "流打开失败: ", res.error)
    return
end

-- ...稍后
st:close()   -- 停止流并释放句柄
```

方法清单:`new(cwrap)`、`open(sql, stime, handle, callback?)`、`close()`。

## resty.taos.data — 列类型转换

内部模块,负责把 TDengine 列类型转换为 Lua 值。`totable()`/`query()`
内部使用;只有当你自己逐行迭代原始数据时才需要它:

```lua
local data = require "resty.taos.data"

-- data[<类型编号>](指针, 长度?) 转换单列的值。
local v = data[5](ptr)         -- BIGINT   -> 字符串(精确 64 位)
local t = data[9](ptr)         -- TIMESTAMP-> 数字(毫秒)
local f = data[6](ptr)         -- FLOAT    -> 数字(7 位有效数字)
local d = data[7](ptr)         -- DOUBLE   -> 数字(精确)
local s = data[8](ptr, len)    -- BINARY   -> 字符串(按长度读取)
local n = data[10](ptr, len)   -- NCHAR    -> 字符串(按长度读取)
local b = data[1](ptr)         -- BOOL     -> 布尔
```

类型映射:

| 编号 | TDengine 类型 | Lua 值 |
|---|---|---|
| 0 | NULL | `nil` |
| 1 | BOOL | 布尔 |
| 2 | TINYINT | 数字 |
| 3 | SMALLINT | 数字 |
| 4 | INT | 数字 |
| 5 | BIGINT | 字符串(精确 64 位) |
| 6 | FLOAT | 数字(按 7 位有效数字舍入) |
| 7 | DOUBLE | 数字(精确) |
| 8 | BINARY | 字符串(请传字节长度) |
| 9 | TIMESTAMP | 数字(毫秒) |
| 10 | NCHAR | 字符串(请传字节长度) |
| 11 | UTINYINT | 数字(无符号) |
| 12 | USMALLINT | 数字(无符号) |
| 13 | UINT | 数字(无符号) |
| 14 | UBIGINT | 数字(由十进制字符串解析;仅 2^53 以内精确) |

**BINARY / NCHAR 需要字节长度。** TDengine 通过 `taos_fetch_lengths()`
报告每个值的精确字节长度;定长 BINARY 列不保证以 NUL 结尾,其值也可能
合法地包含 NUL 字节。因此 `data[8]`/`data[10]` 接受可选的第二个参数:
传入时按该字节数精确读取(`ffi.string(ptr, len)`);不传时回退到历史上的
NUL 结尾读取,只对你能确定已终止的值安全。`totable()`(以及因此的
`query()`、`consume()`、流回调)始终传入报告的长度。详见最佳实践第 6 节。

## resty.taos.library — FFI 绑定

通过 `ffi.cdef` 声明 TDengine 2.4 客户端库(`libtaos`)的 C API,并返回
`ffi.load("taos")` 的句柄。加载该模块会注册全部 FFI 类型(`TAOS *`、
`TAOS_RES *`、`TAOS_STMT *`、`TAOS_SUB *`、`TAOS_STREAM *`、
`TAOS_BIND`,...)。若未安装 `libtaos`,模块仍可加载并返回一个占位对象,
调用时抛出描述性错误 —— 这正是单元测试无需原生库即可运行的原因。

# 最佳实践 — 连接生命周期、内存与安全

本节的每一条都是踩坑换来的:该驱动曾在上线后内存泄漏(nginx RSS 持续
增长),"到处加 finalizer"的粗暴修复反而让情况更糟,而不看长度的
BINARY/NCHAR 转换可能读越界定长列的边界。遵循以下规则,你的 worker
内存将保持平稳,读取也不会越界。

## 1. 每个请求/worker 一个驱动实例,并且务必 close()

`connect()` 分配的 C 连接(`taos_connect`)**只有**通过显式
`driver:close()` 才会释放(启用 `pool = true` 时则归还空闲池,由池在
过期时关闭)。连接句柄上刻意**没有** `ffi.gc` finalizer:在 TDengine 2.4
客户端下,给 TAOS* 句柄附加任何 finalizer(C 函数或闭包)都会让 LuaJIT
中的紧密循环操作段错误(已用裸 FFI 验证)。因此释放的责任在你。

```lua
-- 典型"每请求一个驱动"模式:
local driver = taos:new()

local ok = pcall(function()
    local conn = driver:connect(conf)
    if conn.code ~= 0 then
        error("连接失败: " .. conn.error)
    end
    -- ...业务...
end)

-- 无论是否出错,都要 close:
driver:close()

-- 或者使用请求阶段钩子:
--   ngx.on_abort(function() driver:close() end)
--   (并在 log_by_lua 中再 close 一次作为兜底)
```

如果驱动在被丢弃前没有调用 `close()`,连接会在 worker 的整个生命周期
内泄漏。这是"每请求建连"的项目中"nginx 内存持续增长"的头号原因。

## 2. 结果集:query()/consume() 代为释放;直接持有的句柄归你

`driver:query()` 和 `sub:consume()` 内部都会调用 `taos_free_result()`,
**即使在行转换抛出异常时也会释放**(pcall 保护),因此通过高层 API
你不会泄漏结果集。

```lua
local res = driver:query("select * from m1")   -- 结果集内部已释放
local t = sub:consume()                        -- 结果集内部已释放
```

如果直接使用 `resty.taos.result`(例如包装来自 `taos_query` 或
`stmt:use_result()` 的 `TAOS_RES*`),结果集**归你所有**,必须调用
`free()`。这里没有 GC 兜底:给 TDengine 句柄加 finalizer 是禁忌
(见规则 3),未释放的包装对象会泄漏 C 结果集。`free()` 是幂等的。

```lua
local r = result:new(raw_res)
if r then
    local t = r:totable()
    -- ...使用 t ...
    r:free()          -- 必须调用;free() 是幂等的
end
```

## 3. 不要给 TDengine 句柄附加 ffi.gc finalizer

这一点怎么强调都不为过:在 TDengine 2.4 客户端 + LuaJIT 下,给
TAOS*/TAOS_RES*/TAOS_SUB*/TAOS_STREAM* 句柄调用
`ffi.gc(handle, anything)` 会显著提高循环中的段错误概率(已验证:消费
循环中带 finalizer 崩溃率 100%,不带约 50%,裸 FFI 实测)。因此驱动在
所有地方都采用**显式释放 + pcall 保护的清理**,而不是 GC finalizer。
扩展本库时请保持这一原则。

## 4. 异步查询:保活列表有上限、trampoline 保活、不要在途 close

`driver:query_async()`/`fetch_rows_async()` 会保持回调 trampoline 存活
到回调触发(`query_async()` 返回后 C 侧仍可能调用它)。回调入口会立即
把包装对象从保活列表 detach,但 `self.handle`/`self.param` 会保持引用
直到 trampoline 返回 —— C 仍在执行回调机器码时它绝不会被提前释放,
用户回调抛错也不会把包装对象钉在列表里。

驱动无法知道服务端是否还会回复,因此每个连接的保活列表上限为
**64 个待处理操作**。超过后两个函数返回 `nil, "too many pending async
queries (max 64)"`,而不是无限增长;等部分回调触发后再发新请求。驱动会
复用空出的槽位,回调可以以任意顺序触发。

不要在异步操作仍在进行时调用 `close()`:此时库会丢弃 trampoline,无法
阻止迟到的回调访问已释放内存(驱动会记录 WARN)。请等待关心的回调完成,
或不要在短生命周期驱动上发起异步操作。

## 5. 订阅与流必须显式拆除

* `sub:subscribe(...)` 分配订阅;完成后调用 `sub:unsubscribe(keep_progress)`,
  否则它会存活到 worker 退出。
* `st:open(...)` 分配流;调用 `st:close()` 停止。
* `taos_consume()` 返回的结果集由订阅机制管理;`consume()` 已尽可能释放。
  (官方 `demoSubscribe.c` 确认调用方必须 `taos_free_result()`;驱动已
  替你完成。)

## 6. BINARY/NCHAR 必须按字节长度读取

TDengine 的 `taos_fetch_lengths()` 返回刚取出那一行中每一列的精确字节
长度。定长 BINARY 列不以 NUL 结尾,BINARY/NCHAR 值还可能包含内嵌 NUL,
因此不看长度的 `ffi.string(ptr)` 要么读越界,要么截断值。驱动的转换路径
会传入报告的长度:

* `result:totable()` 在每次 `fetch_row()` 后获取 `fetch_lengths()`,并把
  `lens[i]` 交给 BINARY/NCHAR 转换器 —— 这覆盖了 `query()`、`consume()`
  与流回调;
* 转换器仍接受缺省长度以保持向后兼容,但该回退只对你能确定以 NUL 结尾
  的值安全。

自己逐行迭代时也请这样做:

```lua
local data = require "resty.taos.data"
local lens = r:fetch_lengths()          -- int*(0 基);可能为 NULL
local row  = r:fetch_row()
local len  = lens ~= nil and lens[i] or nil
local v    = data[type](row[i], len)    -- i 为 0 基
```

## 7. 连接池是可选项 —— 按请求的工作负载建议启用

参考环境下 `connect()` + `close()` 每次请求约 5–20 ms,其中大部分耗在
`taos_close()` 内;而一次点查询只需零点几毫秒。在连接 conf 中设置
`pool = true`,即可在 worker 内复用连接:

```lua
driver:connect({ host = "127.0.0.1", port = 6030,
                 user = "root", password = "taosdata",
                 database = "demo", pool = true })
```

* 连接池以 host/port/user/database 为键(密码不在键中 —— 若你依赖
  密码隔离,请使用不同用户或不要启用池化);每个键最多保留 16 条空闲
  连接,30 秒后过期(过期连接会被关闭);
* `close()` 会把健康连接归还到池中而不是调用 `taos_close()`,因此下一次
  用相同 conf 的 `connect()` 会跳过 `taos_init()` 与 `taos_connect()`;
* 以下情况会真正关闭连接:查询失败、`select_db()` 改变了默认数据库、
  或驱动发起过异步查询 —— 这些状态不再符合连接池键的假设;
* 语句、订阅与流仍是每个驱动独立的对象:请在 `close()` 之前拆除,
  不要把同一条池化连接交给多个驱动共用,也不要跨 worker 共享(池按
  worker 设计)。

如果你自己管理句柄,池对象 `resty.taos.pool` 的 API 见上文。

## 8. 错误文本是内部诊断 —— 不要回传给客户端

`taos_errstr()` 返回服务端的诊断文本,可能包含 SQL 片段、表/列名和服务端
细节。应将其视为内部诊断信息:用 `ngx.log(ngx.ERR, ...)` 记录,而向客户端
返回稳定的错误码(例如 `res.code`),不要回传原始字符串。

```lua
local res = driver:query(sql)
if res == nil then
    return ngx.exit(500)
end
if res.code ~= 0 then
    ngx.log(ngx.ERR, "查询失败: ", res.error)   -- 仅内部记录
    ngx.say("query failed, code=", res.code)    -- 稳定、安全
    return
end
```

`docker/` 环境是开发/测试辅助,**不是部署模板**:

* `docker/nginx.conf` 暴露 `/version` 与 `/test` 诊断端点,并通过明文 HTTP
  在 8080 端口运行;
* 使用 TDengine 演示凭据(`root` / `taosdata`);
* 不可暴露到不可信网络。

示例端点遵循上述约定:失败以数字 `code=` 形式报告,容器 `error_log`
级别为 `warn`(绝不使用 `debug`)。完整的测试环境与安全说明见
[docker/readme.md](docker/readme.md)。

## 9. 泄漏排查清单

| 现象 | 可能原因 | 修复 |
|---|---|---|
| 每个请求 RSS 都增长 | 每请求创建驱动但从未 `close()` | 在 `log_by_lua` / `ngx.on_abort` 中关闭 |
| 订阅循环中 RSS 增长 | (旧版驱动)consume 结果未释放 | 使用当前驱动(自动释放) |
| 反复 `query_async` 后 RSS 增长 | (旧版驱动)永久保留每个包装对象;或回调从未触发 | 当前驱动在回调后 detach,且待处理上限 64 |
| 空闲连接数不下降 | (自管连接池)`close` 回调缺失或从未 `clear()` | 传 close 回调;退出时 `pool:clear()` |
| 紧密循环中 worker 段错误 | (扩展代码)给 TDengine 句柄加了 ffi.gc finalizer | 移除,改用显式释放 |
| 转换中途 Lua 报错导致泄漏 | 结果集只在正常路径释放 | pcall 保护释放(当前驱动) |

以上路径均有专门单元测试,并计入 100% 行覆盖率(见下文)。

# 测试

提供两套测试,外加真实服务器集成环境。两套测试都不需要 TDengine 服务器
或原生 `libtaos`:C 层由 mock(`t/helper.lua`)替代,它记录每次调用,并
允许每个测试编排返回值。

## 1. LuaJIT 单元测试(快速,无需 nginx)

```bash
# 运行整套测试
luajit t/run.lua

# 运行部分测试
luajit t/run.lua t.data_spec t.async_spec

# 静态分析(可选)
luacheck lib t
```

## 2. 行覆盖率(要求 100%)

覆盖率运行器在 LuaJIT 调试行钩子下执行完整单元测试套件,并报告
`lib/resty/taos*` 下每个模块的分文件行覆盖率。可执行行通过字节码
(`luajit -bL`)判定,因此表构造字段行、函数声明行不会被误计入。
测试必须全部通过**且**每一条可执行行都被命中,否则运行器以非零码退出。

```bash
luajit t/run_coverage.lua
```

说明:

* 请使用系统(Homebrew)LuaJIT 运行:它的调试钩子是稳定的,而
  OpenResty 自带的 LuaJIT 在行钩子 + FFI 密集代码下会间歇性段错误。
* 字节码列出一环会自动探测支持 `-bL` 的解释器(`LUAJIT_BIN`
  环境变量优先,其次 OpenResty 自带 luajit,最后当前解释器)。
* 运行器会强制每个模块走 `pcall(require, "table.new")` 的回退分支
  (LuaJIT 自带 `table.new`,该分支原本不可达);这仅影响覆盖率,
  不影响正常测试套件。

内存管理路径(`query()`/`consume()` 中的结果集释放、回调触发后的
异步保活列表清理、抛错回调的 detach、转换出错时经 pcall 保护的释放、
幂等的 `free()`、`close()` 清空异步包装对象、池化连接过期)均有专门测试,
并计入 100% 行覆盖率。

## 3. test::nginx 测试(真实 OpenResty worker)

`t/*.t` 文件会拉起一个真实的 nginx 并加载本库,因此在真实 worker 中
驱动被充分执行(真实 `ngx.log`、worker 内 FFI、请求/响应处理)。
TDengine C 库仍在 Lua 层被 mock(`t/nginx_util.lua`),因此无需服务器。

前置条件:可用的 OpenResty `nginx` 二进制,以及 Perl 模块
`Test::Nginx::Socket`。

```bash
# 方式一
PATH=/usr/local/openresty/nginx/sbin:$PATH ./t/run-nginx.sh

# 方式二(nginx 已在 PATH 中)
./t/run-nginx.sh

# 运行单个文件
TEST_NGINX_BINARY=/usr/local/openresty/nginx/sbin/nginx prove -v t/001-driver.t
```

如果系统 Perl 缺少 `Test::Nginx::Socket`,可装入本地目录并用
`PERL5LIB` 指向它:

```bash
cpanm --local-lib="$HOME/.perl5-local" --notest Test::Nginx::Socket
PERL5LIB="$HOME/.perl5-local/lib/perl5" ./t/run-nginx.sh
```

每条 `--- no_error_log [error]` 断言都会验证没有 Lua 错误泄漏到 nginx
错误日志(正是它捕获了 `ngx.ERROR` 日志级别 bug 和订阅错误分支崩溃)。

## 4. 真实服务器集成(docker)

`docker-compose.yaml` 构建真实环境:TDengine 2.4.0.12(从源码编译)加上
本驱动所在的 OpenResty,通过 HTTP 暴露 `/version` 与 `/test`。

```bash
docker compose up --build -d

curl http://127.0.0.1:8080/version
curl http://127.0.0.1:8080/test

# 在容器内运行项目的集成脚本
docker compose exec taos resty --errlog-level debug \
    /usr/local/lvhuan/lua-resty-taos/test.lua
```

详细说明、验证结果,以及 2.4 客户端在 x86 模拟环境下的已知随机段错误,
见 [docker/readme.md](docker/readme.md)。该环境必须以 `linux/amd64` 运行,
因为 TDengine 2.4 只提供 x86_64 二进制。
