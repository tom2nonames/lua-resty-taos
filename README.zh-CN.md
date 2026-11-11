# lua-resty-taos

面向 ngx_lua / OpenResty 的非阻塞 Lua TDengine 驱动库

中文文档 · [English](README.MD)

# 安装
```bash
cd lua-resty-taos
luarocks build
```

# 模块说明

## resty.taos — 主驱动模块

顶层模块。创建驱动实例、管理连接,并提供同步查询、异步查询、预编译语句、连接选项与辅助函数。

```lua
local taos = require "resty.taos"

-- 创建驱动实例(典型用法:每个请求/worker 一个实例)。
local driver = taos:new()

-- 连接。conf 字段:host、port、user、password、database(可选)。
local conn = driver:connect({
    host = "127.0.0.1",
    port = 6030,
    user = "root",
    password = "taosdata",
    -- database = "demo",   -- 可选:默认数据库
})
if conn.code ~= 0 then
    ngx.log(ngx.ERR, "连接失败: ", conn.error)
    return
end

-- 同步查询。返回 { code, affected, item }。
--   * item 是行数组,每行形如 { <列名> = <值>, ... }
--   * BIGINT 值以字符串返回(保留 64 位精度);
--     TIMESTAMP 值以毫秒数字返回。
local res = driver:query("select * from m1")
if res.code ~= 0 then
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

-- 客户端选项:locale / charset / timezone / cfgdir。
driver:options({ timezone = "UTC-8", charset = "UTF-8" })

-- 错误辅助函数(有无显式句柄均可)。
ngx.log(ngx.WARN, driver:get_error_string())
ngx.log(ngx.WARN, "errno: ", driver:get_error_no())

-- 异步查询(参见 resty.taos.async)。
local ok = driver:query_async("insert into t values (1)", function(t)
    ngx.log(ngx.INFO, "异步完成, affected: ", t.affected)
end)

-- 预编译语句(参见 resty.taos.stmt)。
local stmt = driver:stmt()

-- 关闭连接。驱动不再使用时务必调用,以释放底层连接。
driver:close()
```

方法清单:`new()`、`connect(conf)`、`close()`、`query(sql)`、
`query_async(sql, callback)`、`fetch_rows_async(res, callback)`、
`options(opts)`、`select_db(db)`、`validate_sql(sql)`、`stmt()`、
`get_client_info()`、`get_server_info()`、`get_error_string(res?)`、
`get_error_no(res?)`、`init()`、`cleanup()`。

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
查询返回错误、`select_db()` 改变了默认数据库、或在驱动上发起过异步查询。
完整规则见最佳实践第 8 节。

## resty.taos.result — 结果集

封装 C 层 `TAOS_RES*` 句柄。`query()` 内部使用它;当你需要逐行访问或底层
fetch API 时可以直接使用。

```lua
local result = require "resty.taos.result"

-- 包装一个 TAOS_RES*(例如来自 resty.taos.library)。
local r = result:new(raw_res)
if r then
    -- 将整个结果集一次性转换为 Lua 表。
    local t = r:totable()          -- { code, affected, item }
    for _, row in ipairs(t.item) do
        ngx.say(row.ts, " ", row.speed)
    end

    -- 或者逐行迭代(列指针需用 resty.taos.data 转换,见下文)。
    local fields = r:fetch_fields() -- { {name, type, len}, ... }
    while true do
        local row = r:fetch_row()
        if not row then break end   -- 结果集结束
        -- row[i](0 基)是指向第 i 列值的 C 指针
    end

    -- 显式释放。free() 是幂等的;即使不调用,结果集也会在
    -- 包装对象被垃圾回收时一并释放。
    r:free()
end
```

方法清单:`new(result)`、`totable()`、`fetch_row()`、`fetch_block()`、
`fetch_fields()`、`fetch_lengths()`、`num_fields()`、`field_count()`、
`affected_rows()`、`precision()`、`stop()`、`errstr()`、`errno()`、
`free()`。

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
    ngx.log(ngx.ERR, "query_async 被拒绝: ", err)
end
```

如需拉取行数据,可对 `taos_query` 得到的结果句柄调用
`fetch_rows_async(res, callback)`。

模块 API:`new(cwrap)`、`query(sql, callback)`、`fetch_rows(res,
callback)`(通常经由 `driver:query_async()` / `driver:fetch_rows_async()`
使用)。

驱动会为每个回调保活直到触发,并把每个连接的待处理操作上限设为 64;
详见下方最佳实践第 4 节。

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

-- 轮询并消费新数据。
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

-- data[<类型编号>](指针) 转换单列的值:
local v = data[5](ptr)        -- BIGINT   -> 字符串(精确 64 位)
local t = data[9](ptr)        -- TIMESTAMP-> 数字(毫秒)
local f = data[6](ptr)        -- FLOAT    -> 数字(按 float32 精度舍入)
local d = data[7](ptr)        -- DOUBLE   -> 数字(精确)
local s = data[8](ptr)        -- BINARY   -> 字符串
local b = data[1](ptr)        -- BOOL     -> 布尔
```

类型映射:`0` NULL、`1` BOOL、`2` TINYINT、`3` SMALLINT、`4` INT、
`5` BIGINT(字符串)、`6` FLOAT、`7` DOUBLE、`8` BINARY、`9` TIMESTAMP
(数字)、`10` NCHAR、`11` UTINYINT、`12` USMALLINT、`13` UINT、
`14` UBIGINT。

## resty.taos.library — FFI 绑定

通过 `ffi.cdef` 声明 TDengine 2.4 客户端库(`libtaos`)的 C API,并返回
`ffi.load("taos")` 的句柄。加载该模块会注册全部 FFI 类型(`TAOS *`、
`TAOS_RES *`、`TAOS_STMT *`、`TAOS_SUB *`、`TAOS_STREAM *`、
`TAOS_BIND`,...)。若未安装 `libtaos`,模块仍可加载并返回一个占位对象,
调用时抛出描述性错误——这正是单元测试无需原生库即可运行的原因。

# 最佳实践 — 连接生命周期与内存管理

本节的每一条都是踩坑换来的:该驱动曾在上线后内存泄漏(nginx RSS 持续
增长),而"到处加 finalizer"的粗暴修复反而让情况更糟。遵循以下规则,
你的 worker 内存将保持平稳。

## 1. 每个请求/worker 一个驱动实例,并且务必 close()

`connect()` 分配的 C 连接(`taos_connect`)**只有**通过显式
`driver:close()` 才会释放。连接句柄上刻意**没有** `ffi.gc` finalizer:
在 TDengine 2.4 客户端下,给 TAOS* 句柄附加任何 finalizer(C 函数或
闭包)都会让 LuaJIT 中的紧密循环操作段错误(已用裸 FFI 验证)。
因此释放的责任在你。

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

## 2. query() 和 consume() 会替你释放结果集

`driver:query()` 和 `sub:consume()` 内部都会调用 `taos_free_result()`,
**即使在行转换抛出异常时也会释放**(pcall 保护),因此通过高层 API
你不会泄漏结果集。

```lua
local res = driver:query("select * from m1")   -- 结果集内部已释放
local t = sub:consume()                        -- 结果集内部已释放
```

如果直接使用 `resty.taos.result`(例如包装来自 `taos_query` 或
`stmt:use_result()` 的 `TAOS_RES*`),结果集**归你所有**:

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

## 4. 异步查询:回调保活,触发后丢弃(列表有上限)

`driver:query_async()`/`fetch_rows_async()` 会保持回调 trampoline 存活
到回调触发(`query_async()` 返回后 C 侧仍可能调用它)。回调一旦触发,
包装对象会从驱动的保活列表中移除;回调 cdata 本身会保持引用直到
trampoline 返回,之后由 GC 回收,因此 C 仍在执行其机器码时不会被提前释放。

驱动无法知道服务端是否还会回复,因此每个连接的保活列表上限为
**64 个待处理操作**。超过后两个函数返回 `nil, "too many pending async
queries (max 64)"`,而不是无限增长;等部分回调触发后再发新请求。

不要在异步操作仍在进行时调用 `close()`:此时库会丢弃 trampoline,
无法阻止迟到的回调访问已释放内存。请等待关心的回调完成,或不要在
短生命周期驱动上发起异步操作。

## 5. 订阅与流必须显式拆除

* `sub:subscribe(...)` 分配订阅;完成后调用 `sub:unsubscribe(keep_progress)`,
  否则它会存活到 worker 退出。
* `st:open(...)` 分配流;调用 `st:close()` 停止。
* `taos_consume()` 返回的结果集由订阅机制管理;`consume()` 已尽可能释放。
  (官方 `demoSubscribe.c` 确认调用方必须 `taos_free_result()`;驱动已
  替你完成。)

## 6. 泄漏排查清单

| 现象 | 可能原因 | 修复 |
|---|---|---|
| 每个请求 RSS 都增长 | 每请求创建驱动但从未 `close()` | 在 `log_by_lua` / `ngx.on_abort` 中关闭 |
| 订阅循环中 RSS 增长 | (旧版驱动)consume 结果未释放 | 使用当前驱动(自动释放) |
| 反复 `query_async` 后 RSS 增长 | 旧版驱动永久保留每个包装对象 | 当前驱动在回调后移除,且待处理上限 64 |
| 紧密循环中 worker 段错误 | (扩展代码)给 TAOS 句柄加了 ffi.gc finalizer | 移除,改用显式释放 |
| 转换中途 Lua 报错导致泄漏 | 结果集只在正常路径释放 | pcall 保护释放(当前驱动) |

以上路径均有专门单元测试,并计入 100% 行覆盖率(见下文)。

## 7. 安全:错误文本与示例环境

`taos_errstr()` 返回服务端的诊断文本,可能包含 SQL 片段、表/列名和服务端
细节。应将其视为内部诊断信息:用 `ngx.log(ngx.ERR, ...)` 记录,而向客户端
返回稳定的错误码(例如 `res.code`),不要回传原始字符串。

`docker/` 环境是开发/测试辅助,**不是部署模板**:

* `docker/nginx.conf` 暴露 `/version` 与 `/test` 诊断端点,并通过明文 HTTP
  在 8080 端口运行;
* 使用 TDengine 演示凭据(`root` / `taosdata`);
* 不可暴露到不可信网络。

示例端点遵循上述约定:失败以数字 `code=` 形式报告,容器 `error_log`
级别为 `warn`(绝不使用 `debug`)。

## 8. 连接池是可选项 —— 按请求的工作负载建议启用

参考环境下 `connect()` + `close()` 每次请求约 5–20 ms,其中大部分耗在
`taos_close()` 内;而一次点查询只需零点几毫秒。在连接 conf 中设置
`pool = true`,即可在 worker 内复用连接:

* 连接池以 host/port/user/database 为键;每个键最多保留 16 条空闲连接,
  30 秒后过期(过期连接会被关闭);
* `close()` 会把健康连接归还到池中而不是调用 `taos_close()`,因此下一次
  用相同 conf 的 `connect()` 会跳过 `taos_init()` 与 `taos_connect()`;
* 以下情况会真正关闭连接:查询失败、`select_db()` 改变了默认数据库、
  或驱动发起过异步查询 —— 这些状态不再符合连接池键的假设;
* 语句、订阅与流仍是每个驱动独立的对象:请在 `close()` 之前拆除,
  不要把同一条池化连接交给多个驱动共用。

# 单元测试

提供两套测试。两者都不需要 TDengine 服务器或原生 `libtaos` 库:C 层由
mock(`t/helper.lua`)替代,它记录每次调用,并允许每个测试编排返回值。

## 1. LuaJIT 单元测试(快速,无需 nginx)

```bash
# 运行整套测试
luajit t/run.lua

# 运行部分测试
luajit t/run.lua t.data_spec t.async_spec

# 静态分析(可选)
luacheck lib t
```

### 行覆盖率(要求 100%)

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
异步保活列表清理、转换出错时经 pcall 保护的释放、幂等的 `free()`、
`close()` 清空异步包装对象)均有专门测试,并计入 100% 行覆盖率。

## 2. test::nginx 测试(真实 OpenResty worker)

`t/*.t` 文件会拉起一个真实的 nginx 并加载本库,因此在真实 worker 中
驱动被充分执行(真实 `ngx.log`、worker 内 FFI、请求/响应处理)。
TDengine C 库仍在 Lua 层被 mock(`t/nginx_util.lua`),因此无需服务器。

前置条件:`PATH` 中有 OpenResty `nginx` 二进制,且已安装 Perl 模块
`Test::Nginx::Socket`。

```bash
# 方式一
PATH=/usr/local/openresty/nginx/sbin:$PATH ./t/run-nginx.sh

# 方式二(nginx 已在 PATH 中)
./t/run-nginx.sh

# 运行单个文件
TEST_NGINX_BINARY=/usr/local/openresty/nginx/sbin/nginx prove -v t/001-driver.t
```

每条 `--- no_error_log [error]` 断言都会验证没有 Lua 错误泄漏到 nginx
错误日志(正是它捕获了 `ngx.ERROR` 日志级别 bug 和订阅错误分支崩溃)。

# 集成测试示例

这些需要运行中的 TDengine(参见 `docker-compose.yaml`,其中从源码构建
TDengine 2.4.0.12):

```bash
docker-compose up --build

docker exec -it {id} /bin/bash

resty --errlog-level debug ./test.lua
```
