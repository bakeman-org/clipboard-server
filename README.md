# clipboard_server —— Linux 剪贴板监视与历史服务

一个用 Erlang/OTP 编写的剪贴板服务：**持续监听系统剪贴板**，把每次变化的内容持久化到本地 SQLite 数据库，并提供 REST API 和 Web 前端，方便随时检索、过滤、复制历史记录。

---

## 📖 目录

- [功能特性](#-功能特性)
- [系统架构](#-系统架构)
- [文件结构](#-文件结构)
- [环境依赖](#-环境依赖)
- [构建与运行](#-构建与运行)
- [Erlang API](#-erlang-api)
- [数据存储](#-数据存储)
- [HTTP API](#-http-api)
- [前端使用与测试](#-前端使用与测试)
- [调试与排查](#-调试与排查)
- [设计说明](#-设计说明)
- [扩展建议](#-扩展建议)

---

## ✨ 功能特性

| 能力 | 说明 |
|---|---|
| **自动监视** | 后台轮询系统剪贴板（默认 800ms），用户复制任何文本都会自动记录 |
| **读写剪贴板** | 通过 `xclip`（X11）或 `wl-copy` / `wl-paste`（Wayland）操作 |
| **持久化** | 全部历史写入本地 SQLite 数据库，重启不丢失 |
| **智能去重** | 归一化后比较最后一条，忽略首尾空白、换行、零宽字符导致的假重复 |
| **非文本跳过** | 截图、图片、文件等非 UTF-8 剪贴板内容自动忽略，不写入历史 |
| **模糊搜索** | SQL `LIKE '%pattern%'` 语义，支持 `%`（任意串）和 `_`（单字符）通配符 |
| **REST API** | 标准 JSON 接口，任何前端/脚本都能查询和写入 |
| **Web 前端** | 内置单文件 HTML 页面，带示例 pill、搜索高亮、自动刷新、一键复制 |
| **失败容错** | 读取失败自动指数退避；`pg` 组不可用时静默降级，watcher 不崩 |
| **完全自包含** | 自研精简 SQLite NIF，只依赖 Erlang 和系统剪贴板工具 |

---

## 🏗️ 系统架构

```
            系统剪贴板 (X11 / Wayland)
                     │
       ┌─────────────┴─────────────┐
       │                           │
       ▼ 读                        ▼ 写
┌────────────────┐         ┌────────────────┐
│clipboard_      │         │clipboard_      │
│watcher         │         │server          │
│(每 800ms 轮询) │         │(读写 API)      │
└───────┬────────┘         └───────┬────────┘
        │ cast({insert_bin, Bin})  │
        ▼                          │
┌───────────────────────────────────────┐
│           clipboard_store             │
│      (gen_server, 串行化 SQL)         │
│   去重检查 → NIF 调用 → SQLite        │
└────────────────┬──────────────────────┘
                 │ NIF
                 ▼
        clipboard_sqlite_nif.so
        (C + SQLite amalgamation)
                 │
                 ▼
   ~/.local/share/clipboard_server/clipboard.db

                 ▲ REST
                 │
      ┌──────────┴──────────┐
      │  clipboard_http     │  ← Cowboy HTTP 服务
      │  (REST + 静态页面)  │
      └─────────────────────┘
                 ▲
                 │ HTTP
          浏览器 / curl / 脚本
```

**监督树**（`one_for_one`）：

```
clipboard_server_sup
├── clipboard_store      先启动，其他进程依赖它
├── clipboard_server     剪贴板读写
├── clipboard_watcher    监视器
└── clipboard_http       HTTP 服务
```

启动顺序很重要：store 必须最先起，因为 watcher 会向它 cast 消息。

---

## 📁 文件结构

```
clipboard_server/
├── rebar.config                  rebar3 配置（含 C 编译 pre_hook）
├── README.md                     本文档
├── config/
│   └── sys.config                运行配置（端口、轮询间隔）
├── c_src/
│   ├── Makefile                  编译 NIF 到 priv/
│   ├── clipboard_sqlite_nif.c    自研 NIF（8 个函数）
│   ├── sqlite3.c                 SQLite amalgamation
│   └── sqlite3.h                 SQLite amalgamation
├── priv/
│   ├── clipboard_sqlite_nif.so   生成的 NIF 动态库
│   └── index.html                前端页面
└── src/
    ├── clipboard_server.app.src
    ├── clipboard_server_app.erl
    ├── clipboard_server_sup.erl
    ├── clipboard_tools.erl       工具探测 + 读写封装
    ├── clipboard_server.erl      剪贴板读写 + 历史查询转发
    ├── clipboard_store.erl       持久化层（去重、NIF 调用）
    ├── clipboard_watcher.erl     轮询监视器
    ├── clipboard_http.erl        Cowboy listener 启动
    ├── clipboard_http_handler.erl REST 路由
    └── clipboard_sqlite_nif.erl  NIF 的 Erlang 壳层
```

---

## 🧰 环境依赖

### 运行时

| 依赖 | 说明 |
|---|---|
| Erlang/OTP | ≥ 26（本项目在 OTP 29 测试通过） |
| rebar3 | ≥ 3.20 |
| `xclip` **或** `wl-clipboard` | 二者装其一即可，代码自动探测 |
| `sqlite3` CLI | 可选，调试用 |

Debian/Ubuntu 一键：

```bash
sudo apt install xclip wl-clipboard sqlite3
```

macOS 用户注意：当前实现只支持 Linux。macOS 需要自行在 `clipboard_tools.erl` 里加 `pbcopy` / `pbpaste` 分支。

### 编译期

- gcc 或 clang
- make
- SQLite amalgamation 源码（见下文）

---

## 🚀 构建与运行

### 1. 获取 SQLite amalgamation

```bash
cd c_src
curl -LO https://www.sqlite.org/2024/sqlite-amalgamation-3460000.zip
unzip sqlite-amalgamation-3460000.zip
mv sqlite-amalgamation-3460000/sqlite3.c .
mv sqlite-amalgamation-3460000/sqlite3.h .
rm -rf sqlite-amalgamation-3460000*
```

### 2. 编译

```bash
rebar3 compile
```

rebar3 会自动调用 `make -C c_src` 编译 NIF 到 `priv/`。

手动只编 NIF：

```bash
make -C c_src debug   # 打印推导出来的 erts include 路径
make -C c_src         # 只编译 NIF
make -C c_src clean   # 清理
```

### 3. 启动

```bash
rebar3 shell
```

启动日志应包含：

```
clipboard database opened at /home/<user>/.local/share/clipboard_server/clipboard.db
clipboard watcher started: tool=/usr/bin/xclip ... poll=800ms baseline=0 bytes
clipboard HTTP server listening on http://0.0.0.0:8080/
```

### 4. 打开前端

浏览器访问 [http://localhost:8080](http://localhost:8080) 即可。

---

## 📚 Erlang API

在 `rebar3 shell` 里直接调用。

### 剪贴板读写

```erlang
%% 写入系统剪贴板（watcher 会在下一轮把它捕获并落库）
clipboard_server:set_text("hello").
clipboard_server:set_text(<<"也支持二进制"/utf8>>).

%% 读取当前剪贴板
clipboard_server:get_text().
%% => {ok, "当前文本"}
%% => {error, no_text_data}     剪贴板为空
%% => {error, non_text_clipboard} 剪贴板里不是文本（如图片）
```

### 历史查询

```erlang
%% 全部历史，最新在前
clipboard_server:list_history().
%% => {ok, [#{id => 3, content => "...", created_at => 1760000000000}, ...]}

%% 最近 N 条
clipboard_server:list_history(5).

%% 模糊搜索（支持二进制和 list）
clipboard_server:search_history("历史").
clipboard_server:search_history(<<"%历史">>).

%% 清空
clipboard_server:clear_history().
```

### 监视器状态

```erlang
%% 最近一次检测到的剪贴板内容（原始二进制）
clipboard_watcher:get_last().
%% => <<"...">>

%% 运行统计
clipboard_watcher:get_stats().
%% => #{poll_ms              => 800,
%%      consecutive_failures => 0,
%%      total_polls          => 1234,
%%      total_changes        => 42,
%%      total_skipped        => 3,
%%      baseline_bytes       => 8}
```

### 订阅变化事件（pg 组）

在任意 Erlang 进程里：

```erlang
pg:join(clipboard_events, self()).

%% 每当剪贴板有新的文本内容，就会收到消息：
receive
    {clipboard_changed, BinData} -> io:format("变化: ~p~n", [BinData])
end.
```

这一层是未来接 SSE / WebSocket 实时推送的入口。

---

## 💾 数据存储

### 路径

默认：

```
~/.local/share/clipboard_server/clipboard.db
```

解析优先级：

1. 环境变量 `CLIPBOARD_DATA_DIR`（若设置则直接用）
2. `$XDG_DATA_HOME/clipboard_server/clipboard.db`
3. `$HOME/.local/share/clipboard_server/clipboard.db`

### 在 shell 里查看实际路径

```erlang
sys:get_state(clipboard_store).
%% => #{db => #Ref<...>, path => "/home/etcix/.local/share/clipboard_server/clipboard.db"}
```

### 表结构

```sql
CREATE TABLE IF NOT EXISTS clipboard_history (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    content    TEXT    NOT NULL,
    created_at INTEGER NOT NULL   -- Unix 毫秒时间戳
);
```

### 用 sqlite3 直接查

```bash
DB=~/.local/share/clipboard_server/clipboard.db

# 表结构
sqlite3 "$DB" ".schema"

# 全部记录（毫秒时间戳转本地时间）
sqlite3 -header -column "$DB" \
  "SELECT id, content,
          datetime(created_at/1000, 'unixepoch', 'localtime') AS ts
   FROM clipboard_history ORDER BY created_at DESC;"

# 检查某条的原始字节
sqlite3 "$DB" "SELECT id, hex(content) FROM clipboard_history LIMIT 5;"

# 模糊查询（等价于 search_history）
sqlite3 "$DB" "SELECT id, content FROM clipboard_history WHERE content LIKE '%历史%';"

# 统计
sqlite3 "$DB" "SELECT COUNT(*) FROM clipboard_history;"

# 清空
sqlite3 "$DB" "DELETE FROM clipboard_history; VACUUM;"
```

### 自定义位置

```bash
# 临时
CLIPBOARD_DATA_DIR=/tmp/clip_data rebar3 shell

# 永久（shell 配置里）
export CLIPBOARD_DATA_DIR="$HOME/data/clipboard"
```

---

## 🌐 HTTP API

服务默认监听 `0.0.0.0:8080`。所有响应均为 JSON，统一格式：

```json
{ "ok": true, "data": [...] }
{ "ok": true }
{ "ok": false, "error": "错误说明" }
```

### 端点总览

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/` | 前端页面（`priv/index.html`） |
| `GET` | `/api/history` | 列出历史（支持 `?limit=N`） |
| `GET` | `/api/history/search` | 模糊搜索（`?q=pattern`） |
| `GET` | `/api/clipboard` | 读取当前系统剪贴板 |
| `POST` | `/api/clipboard` | 写入剪贴板，body `{"text":"..."}` |
| `DELETE` | `/api/clear` | 清空全部历史 |
| `OPTIONS` | `*` | CORS 预检 |

### `GET /api/history`

列出全部历史，最新在前。

**查询参数**

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `limit` | integer | 0 | 返回最近 N 条，0 表示全部 |

**示例**

```bash
# 全部
curl -s http://localhost:8080/api/history | jq

# 最近 5 条
curl -s 'http://localhost:8080/api/history?limit=5' | jq
```

**响应**

```json
{
  "ok": true,
  "data": [
    {"id": 42, "content": "hello world", "created_at": 1760000000000},
    {"id": 41, "content": "剪贴板历史",   "created_at": 1759999900000}
  ]
}
```

### `GET /api/history/search`

对 `content` 做 SQL `LIKE '%q%'` 过滤。**`q` 支持 `%` 和 `_` 通配符**。

**查询参数**

| 参数 | 类型 | 说明 |
|---|---|---|
| `q` | string | 搜索关键字，必填 |

**示例**

```bash
# 包含 hello 的记录
curl -s 'http://localhost:8080/api/history/search?q=hello' | jq

# 以「历史」结尾（% 是通配符，URL 里编码为 %25）
curl -s 'http://localhost:8080/api/history/search?q=%25历史' | jq

# 以「剪」开头
curl -s 'http://localhost:8080/api/history/search?q=剪%25' | jq

# 「剪」+ 任意 3 个字符
curl -s 'http://localhost:8080/api/history/search?q=剪___' | jq

# 匹配所有非空记录
curl -s 'http://localhost:8080/api/history/search?q=%25' | jq
```

**响应**：与 `/api/history` 相同。

### `GET /api/clipboard`

读取当前系统剪贴板。

**示例**

```bash
curl -s http://localhost:8080/api/clipboard | jq
```

**响应**

```json
{ "ok": true, "text": "当前剪贴板的内容" }
{ "ok": false, "error": "no_text_data" }
```

### `POST /api/clipboard`

写入系统剪贴板。写入后由 watcher 异步落库，前端刷新即可看到。

**请求体**

```json
{ "text": "要写入的内容" }
```

**示例**

```bash
curl -s -X POST http://localhost:8080/api/clipboard \
     -H 'content-type: application/json' \
     -d '{"text":"from curl"}' | jq
```

**响应**

```json
{ "ok": true }
```

### `DELETE /api/clear`

清空全部历史。

```bash
curl -s -X DELETE http://localhost:8080/api/clear | jq
```

**响应**

```json
{ "ok": true }
```

### 端口配置

默认 `8080`。修改方式：

**方式 1：`config/sys.config`**

```erlang
[
  {clipboard_server, [
      {http_port, 9000},
      {watcher_poll_ms, 800}
  ]}
].
```

**方式 2：shell 里动态设置（临时）**

```erlang
application:set_env(clipboard_server, http_port, 9000).
```

改完后重启应用生效。

---

## 🖥️ 前端使用与测试

前端是一个单文件 `priv/index.html`，无框架、无外部依赖，由 Erlang 直接返回。打开 [http://localhost:8080](http://localhost:8080) 即可。

### 界面结构

```
┌──────────────────────────────────────────────────────┐
│  📋 剪贴板历史                                        │
│  ┌────────────────────────────────┐  ┌────┐ ┌────┐  │
│  │ 输入关键字过滤…                 │  │刷新│ │清空│  │
│  └────────────────────────────────┘  └────┘ └────┘  │
│  示例: hello  %历史  剪%  剪___  http%com  error  %  清空 │
├──────────────────────────────────────────────────────┤
│  共 N 条记录                                          │
│  ┌──────────────────────────────────────────────┐    │
│  │ 内容...                     #3 · 12:34:56   │    │
│  │                                     [复制]    │    │
│  └──────────────────────────────────────────────┘    │
│  ...                                                  │
└──────────────────────────────────────────────────────┘
```

### 功能测试

#### 测试 1：自动捕获系统剪贴板

**步骤**

1. 打开任意编辑器（浏览器、记事本、终端都可以），复制一段中文文本，例如 `测试中文内容`。
2. 回到浏览器，**不要点刷新**，等 2~3 秒。
3. 前端每 2 秒自动刷新一次，新记录会自动出现在列表顶部。

**预期**

- 列表顶部出现刚才复制的内容。
- 时间戳是刚刚复制的时刻。
- 内容显示为**正常的中文**，不是乱码。

**排查**

如果没看到新记录：

```erlang
%% 在 shell 里检查 watcher 是否活着
whereis(clipboard_watcher).
clipboard_watcher:get_stats().
%% total_changes 应该增加
```

#### 测试 2：相同内容不重复落库

**步骤**

1. 复制 `dup test`。
2. 等 2 秒。
3. 再复制一次 `dup test`。
4. 等 2 秒。

**预期**

列表里**只有一条** `dup test`。

后台日志（debug 级别）会显示：

```
clipboard_store compare: ... equal=true
clipboard_store: skip duplicate (8 bytes)
```

**打开 debug 日志**

```erlang
logger:set_primary_config(level, debug).
```

#### 测试 3：带换行、空格的内容视为相同

**步骤**

1. 复制 `hello`（不带换行）。
2. 等 2 秒。
3. 复制 `hello\n`（末尾换行）—— 手动在编辑器里敲一个回车再复制。
4. 等 2 秒。
5. 复制 `hello `（末尾空格）。
6. 等 2 秒。

**预期**

列表里只有一条 `hello`。归一化逻辑会忽略首尾空白和零宽字符。

#### 测试 4：截图粘贴不崩溃

**步骤**

1. 用系统截图工具（GNOME Screenshot、Flameshot、Spectacle 等）截一张图。
2. 选择"复制到剪贴板"。
3. 等 2 秒。
4. 观察前端列表和 shell 日志。

**预期**

- 前端列表**没有新记录**（图片内容被跳过）。
- shell 不崩溃，`clipboard_watcher:get_stats()` 的 `total_skipped` 加 1。
- 随后再复制一段文本，能正常落库。

**排查**

```erlang
clipboard_watcher:get_stats().
%% => #{total_skipped => 1, ...}
```

#### 测试 5：grep 示例 pill 点击

前端搜索框下方有一排示例 pill，每个都演示一种通配符用法：

| Pill | 匹配规则 | 演示场景 |
|---|---|---|
| `hello` | 包含 `hello` | 普通子串搜索 |
| `%历史` | 以「历史」结尾 | `%` 后缀匹配 |
| `剪%` | 以「剪」开头 | `%` 前缀匹配 |
| `剪___` | 「剪」+ 任意 3 字符 | `_` 单字符匹配 |
| `http%com` | `http` 与 `com` 之间任意内容 | 匹配 URL |
| `error` | 包含 `error` | 日志搜索 |
| `%` | 所有非空记录 | 通配一切 |
| `清空` | 空查询 | 显示全部 |

**步骤**

1. 先准备数据：复制几段内容，比如 `hello world`、`剪贴板历史`、`https://example.com`、`error: timeout`。
2. 依次点击每个 pill，观察过滤结果和 `匹配 "xxx" 的记录：N 条` 提示。
3. hover 每个 pill 会显示 tooltip 说明用途。

**预期**

- 点击 pill 后，搜索框内容自动替换为对应查询，列表即时过滤。
- `清空` pill 显示全部记录。
- 匹配的关键字在列表里有黄色高亮。

#### 测试 6：手动搜索

**步骤**

1. 在搜索框输入 `历史`，观察列表过滤。
2. 输入 `%历史`，观察结果是否只保留以"历史"结尾的。
3. 输入 `剪___`，观察是否匹配 4 个字符、以"剪"开头的内容。
4. 输入不存在的关键字 `zzz_not_exist`，列表应显示"暂无记录"。

**预期**

- 输入有 200ms 防抖，打字时不频繁请求。
- 高亮正确显示匹配部分。

#### 测试 7：一键复制回剪贴板

**步骤**

1. 找到任意一条历史。
2. 点击右侧「复制」按钮。
3. 打开任意编辑器，粘贴（Ctrl+V）。

**预期**

- 页面底部弹出 toast "已写回剪贴板"。
- 粘贴出来的就是这条内容。
- 因为内容不变，**不会新增一条历史**（去重生效）。

#### 测试 8：清空历史

**步骤**

1. 点击右上角红色「清空」按钮。
2. 确认对话框点"确定"。

**预期**

- 弹出 toast "已清空"。
- 列表显示"暂无记录"。
- 用 `sqlite3` 命令行查一下，表为空。

#### 测试 9：跨浏览器刷新持久化

**步骤**

1. 复制几段内容。
2. 关闭浏览器标签页。
3. 在 shell 里 `q().` 退出，再 `rebar3 shell` 重启。
4. 重新打开 `http://localhost:8080`。

**预期**

所有历史仍然存在（数据在 SQLite 里）。

#### 测试 10：HTTP API 和前端一致性

在终端里：

```bash
# 用 curl 写入
curl -s -X POST http://localhost:8080/api/clipboard \
     -H 'content-type: application/json' \
     -d '{"text":"from curl"}' | jq

# 等 2 秒，然后查看
curl -s http://localhost:8080/api/history?limit=3 | jq
```

**预期**

- curl 写入的内容，2 秒内出现在历史里。
- 浏览器刷新后也能看到。

### 前端调试技巧

打开浏览器开发者工具（F12）：

- **Console**：查看 JS 错误。
- **Network**：查看每个 `/api/*` 请求的响应，定位 400/500 问题。
- **Application → Local Storage**：暂无使用，可自行扩展。

如果页面显示"加载失败：HTTP 500"，切到 Network 看具体哪个请求失败，然后去 shell 日志里查对应的 CRASH REPORT。

---

## 🐞 调试与排查

### 常用 shell 命令

```erlang
%% 应用是否在运行
application:which_applications().

%% 进程是否存活
whereis(clipboard_store).
whereis(clipboard_server).
whereis(clipboard_watcher).
whereis(clipboard_http).

%% 监督树状态
supervisor:which_children(clipboard_server_sup).

%% 查看 State
sys:get_state(clipboard_store).
sys:get_state(clipboard_watcher).

%% 打开 trace，观察内部消息
sys:trace(clipboard_store, true).
clipboard_server:set_text("trace test").
sys:trace(clipboard_store, false).
```

### 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `{noproc, ...}` | 进程已崩溃且 supervisor 放弃重启 | 重启 shell；查前面的 CRASH REPORT |
| `nif_not_loaded` | `.so` 未编译或路径不对 | `ls priv/`，重跑 `rebar3 compile` |
| 前端"加载失败：HTTP 500" | 后端某处异常 | 查 shell 里最近的 CRASH REPORT |
| 搜中文 500 | `binary_to_list` 导致的双重编码 | 确保 HTTP handler 传二进制而非 list |
| 截图后服务崩溃 | 非 UTF-8 内容被当文本处理 | 确保 watcher 里做了 `is_valid_utf8` 判断 |
| 中文乱码 | 历史遗留数据是旧代码写的 | `clipboard_server:clear_history()` 后重试 |
| `xclip: command not found` | 未安装剪贴板工具 | `sudo apt install xclip wl-clipboard` |
| 端口 8080 被占 | 其他服务占用 | 改 `config/sys.config` 里的 `http_port` |

### 打开 debug 日志

```erlang
logger:set_primary_config(level, debug).
```

能看到：

- 每次剪贴板变化的字节数
- 去重比较的详细信息
- NIF 的插入/查询日志

### 用 sqlite3 直接验证数据

怀疑某条数据有异常时，用 `hex()` 看原始字节：

```bash
DB=~/.local/share/clipboard_server/clipboard.db
sqlite3 "$DB" "SELECT id, quote(content), hex(content) 
               FROM clipboard_history ORDER BY id DESC LIMIT 5;"
```

`quote()` 会把换行、空格等不可见字符转义显示。`hex()` 直接给出十六进制字节，末尾多一个 `0A` 就是多了一个换行符。

---

## 🧠 设计说明

### 为什么不用 `wx` 库？

`wxClipboard` 依赖 `wxWidgets` 图形库，在 SSH 或服务器环境里会报 `{wx, unknown_env}`。`xclip` / `wl-copy` 不依赖图形栈，稳定得多。

### 为什么自研 SQLite NIF？

第三方绑定往往是"黑盒"，且引入大量不需要的 API。自研 NIF 只实现 8 个核心函数，代码完全可控、可审计。代价是需自己保证内存安全。

### 为什么用脏调度器？

SQLite 磁盘 I/O 可能超过 1ms。若运行在普通调度器上，会阻塞 Erlang VM 的其他进程。所有 NIF 都声明为 `ERL_NIF_DIRTY_JOB_IO_BOUND`，由 OTP 的 I/O 线程池执行。

### 为什么 watcher 每 800ms 轮询？

Linux 剪贴板**没有**统一的"内容变化"通知机制。`wl-paste --watch` 只支持 Wayland；X11 没有可靠的事件接口。轮询是唯一跨环境通用的方案。800ms 的间隔对 CPU 几乎无感，响应也够快。

### 为什么要归一化去重？

用户从不同来源复制同一段文本，字节层面可能不同：末尾带不带换行、有没有零宽空格、有没有首尾空白。归一化后比较能避免这些"视觉上相同"的重复。

### 为什么要区分文本 vs 非文本？

截图、复制的图片、从文件管理器复制的文件路径等，在剪贴板里都是二进制数据。直接把二进制塞进 SQLite 的 TEXT 字段，会导致 UTF-8 解码失败、前端乱码、甚至服务崩溃。用 `unicode:characters_to_binary/3` 做合法性检查，非法就直接跳过。

### 为什么全程用二进制？

Erlang 的字符串是 codepoint 列表，二进制是字节数组。**跨边界（C NIF、HTTP、SQLite）时用二进制**能避免一系列编码陷阱：`binary_to_list` 把字节展开成 codepoint、`characters_to_binary` 又把 codepoint 编码成多字节 UTF-8，一来一回就是双重编码。二进制全程保持字节原样，各层只需在**出口**（前端、API 响应）做一次 UTF-8 编码。

### 为什么搜索不转义 `%` 和 `_`？

有意的：允许用户主动使用通配符做更灵活的过滤。如果用户只想字面匹配，可以改成在 `nif_search` 里对 `%` 和 `_` 做转义。

### 为什么落库入口要统一到 watcher？

如果 `set_text/1` 也直接落库，就会和 watcher 的捕获逻辑重复。统一让 watcher 从剪贴板读出来再落库，保证：

- API 写入和手动复制走同一条路径。
- 去重逻辑只在一个地方。
- 未来加"剪贴板历史监听"扩展时不用改两处。

代价：API 写入后需要等一个轮询周期才落库（最多 800ms）。对剪贴板历史场景完全够用。

---

## 🚧 扩展建议

1. **实时推送**：用 `pg` 组 + Cowboy SSE 或 WebSocket，前端不再需要轮询。
2. **分页**：`/api/history?offset=N&limit=M`。
3. **删除单条**：`DELETE /api/history/:id`。
4. **剪贴板历史去重策略**：可改成"任意位置重复都不插入"（用唯一索引），或"只保留最近 N 条"（定期清理）。
5. **FTS5 全文搜索**：数据量大时改用 SQLite FTS5，支持分词和相关度排序。
6. **图片剪贴板**：新增 BLOB 表和 `/api/clipboard/image` 端点。
7. **macOS 支持**：在 `clipboard_tools.erl` 里加 `pbcopy` / `pbpaste` 分支。
8. **鉴权**：加 `X-API-Token` 头校验，保护写接口。
9. **发布为 release**：`rebar3 release` 打包成独立运行的系统，可部署到未装 Erlang 的机器。
10. **前端框架化**：如果功能膨胀，`index.html` 可迁移到 Svelte / React + Vite，产物放回 `priv/`。

---

## 📄 许可

本项目示例代码以 Apache-2.0 发布。SQLite amalgamation 遵循 SQLite 的公有领域许可。