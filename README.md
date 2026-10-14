# clipboard_server —— 剪贴板服务器

一个用 Erlang/OTP 编写的剪贴板服务器，监听系统剪贴板并把每次写入的内容持久化到本地 SQLite 数据库，并提供模糊搜索（grep 式）接口，方便前端构建历史查询功能。

---

## 📖 目录

- [功能特性](#-功能特性)
- [系统架构](#-系统架构)
- [文件结构](#-文件结构)
- [环境依赖](#-环境依赖)
- [构建与运行](#-构建与运行)
- [使用示例](#-使用示例)
- [数据存储位置](#-数据存储位置)
- [数据库结构](#-数据库结构)
- [NIF 接口说明](#-nif-接口说明)
- [Erlang API 参考](#-erlang-api-参考)
- [调试指南](#-调试指南)
- [常见问题排查](#-常见问题排查)
- [设计决策说明](#-设计决策说明)
- [扩展建议](#-扩展建议)

---

## ✨ 功能特性

- **读写系统剪贴板**：通过外部命令 `xclip`（X11）或 `wl-copy` / `wl-paste`（Wayland）操作剪贴板，不依赖 `wx` 库，无图形环境也能稳定运行。
- **持久化历史**：每次写入剪贴板后异步落库，重启不丢失。
- **模糊搜索**：支持 SQL `LIKE '%pattern%'` 语义的 grep 式过滤，可直接用于前端搜索框。
- **自研精简 SQLite NIF**：不引入任何第三方 Erlang SQLite 绑定，只实现项目所需的 8 个核心 C 函数，代码完全可控。
- **OTP 规范**：完全遵循 `application` / `supervisor` / `gen_server` 分层，进程崩溃可自动重启。
- **脏调度器**：所有数据库 NIF 运行在脏 I/O 调度器上，不阻塞 Erlang 主调度器。

---

## 🏗️ 系统架构

```
       调用方（前端 / Eshell / 其他 OTP 进程）
                     │
                     ▼
        ┌────────────────────────┐
        │   clipboard_server     │  ← 写/读系统剪贴板
        │   （gen_server）       │     并通过 cast 异步落库
        └───────────┬────────────┘
                    │ gen_server:cast({insert, Text})
                    ▼
        ┌────────────────────────┐
        │   clipboard_store      │  ← 串行化所有数据库操作
        │   （gen_server）       │     调用 NIF 执行 SQL
        └───────────┬────────────┘
                    │ clipboard_sqlite_nif:insert/3 等
                    ▼
        ┌────────────────────────┐
        │  clipboard_sqlite_nif  │  ← Erlang 壳层，加载 .so
        │   （-on_load 加载）    │
        └───────────┬────────────┘
                    │ NIF
                    ▼
        ┌────────────────────────┐
        │  clipboard_sqlite_nif.so│ ← 自研 C 代码 + SQLite amalgamation
        │  （ERL_NIF_DIRTY_*）   │
        └───────────┬────────────┘
                    │ SQLite C API
                    ▼
        ~/.local/share/clipboard_server/clipboard.db
```

监督树结构：

```
clipboard_server_sup (supervisor, one_for_one)
├── clipboard_store  (worker, permanent)   ← 先启动
└── clipboard_server (worker, permanent)   ← 后启动（依赖 store）
```

---

## 📁 文件结构

```
clipboard_server/
├── rebar.config                      # rebar3 配置，含 pre_hooks 触发 C 编译
├── README.md                         # 本文档
├── c_src/
│   ├── Makefile                      # 编译 NIF 到 priv/
│   ├── clipboard_sqlite_nif.c        # 自研 NIF 实现（8 个函数）
│   ├── sqlite3.c                     # SQLite amalgamation（需自行下载）
│   └── sqlite3.h                     # SQLite amalgamation（需自行下载）
├── priv/                             # 编译产物目录（自动创建）
│   └── clipboard_sqlite_nif.so       # 生成的 NIF 动态库
└── src/
    ├── clipboard_server.app.src      # 应用资源描述
    ├── clipboard_server_app.erl      # application 回调
    ├── clipboard_server_sup.erl      # 顶层监督者
    ├── clipboard_server.erl          # 剪贴板读写 + 历史查询转发
    ├── clipboard_store.erl           # 持久化层（gen_server）
    └── clipboard_sqlite_nif.erl      # NIF 的 Erlang 壳层
```

---

## 🧰 环境依赖

### 运行时依赖

| 依赖 | 用途 | 安装（Debian/Ubuntu） |
|---|---|---|
| Erlang/OTP | ≥ 26（本项目在 OTP 29 上测试） | 建议用 mise / kerl / asdf 管理 |
| rebar3 | 构建工具 | `mise use -g rebar` 或官网下载 |
| `xclip` | X11 环境剪贴板工具 | `sudo apt install xclip` |
| `wl-clipboard` | Wayland 环境剪贴板工具 | `sudo apt install wl-clipboard` |
| `sqlite3` CLI | 调试用（可选） | `sudo apt install sqlite3` |

**X11 与 Wayland 只需安装其中之一**，代码会自动探测。判断方式：`init/1` 里优先探测 `wl-copy` / `wl-paste`，找不到就回退到 `xclip`。

### 编译期依赖

- C 编译器（`gcc` 或 `clang`）
- `make`
- SQLite amalgamation 源码（见下一节）

---

## 🚀 构建与运行

### 1. 下载 SQLite amalgamation

SQLite 官方提供单文件发行版，放进 `c_src/`：

```bash
cd c_src
curl -LO https://www.sqlite.org/2024/sqlite-amalgamation-3460000.zip
unzip sqlite-amalgamation-3460000.zip
mv sqlite-amalgamation-3460000/sqlite3.c .
mv sqlite-amalgamation-3460000/sqlite3.h .
rm -rf sqlite-amalgamation-3460000*
```

这样 NIF 就**完全自包含**，不依赖系统安装的 SQLite。

### 2. 编译

```bash
rebar3 compile
```

`rebar.config` 里配置了 `pre_hooks`，会自动调用 `make -C c_src` 编译出 `priv/clipboard_sqlite_nif.so`。

若想单独调试 C 编译：

```bash
cd c_src
make debug      # 打印推导出的 include 路径
make            # 只编译 NIF
make clean      # 清理产物
```

### 3. 启动

```bash
rebar3 shell
```

会启动 `clipboard_server` 应用，自动拉起监督树。

---

## 💻 使用示例

在 `rebar3 shell` 的 Eshell 中：

```erlang
%% 写入剪贴板（同时异步落库）
clipboard_server:set_text("hello world").
clipboard_server:set_text("goodbye moon").
clipboard_server:set_text("hello erlang").

%% 读取当前剪贴板内容
clipboard_server:get_text().
%% => {ok, "hello erlang"}

%% 列出全部历史（最新在前）
clipboard_server:list_history().
%% => {ok, [#{id => 3, content => "hello erlang", created_at => 1760000000000},
%%          #{id => 2, content => "goodbye moon", created_at => ...},
%%          #{id => 1, content => "hello world", created_at => ...}]}

%% 只看最近 2 条
clipboard_server:list_history(2).

%% grep 式模糊过滤（等价于 LIKE '%hello%'）
clipboard_server:search_history("hello").
%% => {ok, [#{id => 3, ...}, #{id => 1, ...}]}

%% 通配符可用：% 匹配任意串，_ 匹配单个字符
clipboard_server:search_history("hello%erlang").

%% 清空历史
clipboard_server:clear_history().
```

---

## 💾 数据存储位置

### 默认路径

```
~/.local/share/clipboard_server/clipboard.db
```

对你当前用户而言，完整路径是：

```
/home/etcix/.local/share/clipboard_server/clipboard.db
```

### 路径解析优先级

数据库路径由 `clipboard_store:db_path/0` 决定，按以下顺序解析：

1. **环境变量 `CLIPBOARD_DATA_DIR`** —— 如果设置了，直接使用该目录下的 `clipboard.db`。
2. **环境变量 `XDG_DATA_HOME`** —— 未设置时回退到 `$HOME/.local/share`。
3. 最终路径为 `<Base>/clipboard_server/clipboard.db`。

### 在 Erlang shell 中查看实际路径

```erlang
%% 方式 1：直接从 store 的 State 里读（最准确）
sys:get_state(clipboard_store).
%% => #{db => #Ref<0...>, path => "/home/etcix/.local/share/clipboard_server/clipboard.db"}

%% 方式 2：查看环境变量
os:getenv("CLIPBOARD_DATA_DIR").
os:getenv("XDG_DATA_HOME").
os:getenv("HOME").
```

### 自定义存储位置

```bash
# 临时指定（单次运行）
CLIPBOARD_DATA_DIR=/tmp/clip_data rebar3 shell

# 永久生效（写入 shell 配置）
export CLIPBOARD_DATA_DIR="$HOME/data/clipboard"
```

### 目录创建

`clipboard_store:init/1` 会在打开数据库之前调用 `filelib:ensure_dir/1`，自动创建缺失的目录层级，无需手动 `mkdir`。

---

## 🗃️ 数据库结构

### 表定义

```sql
CREATE TABLE IF NOT EXISTS clipboard_history (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    content    TEXT    NOT NULL,
    created_at INTEGER NOT NULL       -- Unix 毫秒时间戳
);
```

### 字段说明

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER | 自增主键，每条记录唯一 |
| `content` | TEXT | 剪贴板文本内容，UTF-8 存储 |
| `created_at` | INTEGER | 写入时刻的 Unix 毫秒时间戳（`erlang:system_time(millisecond)`） |

### 用 sqlite3 CLI 查看

```bash
DB=/home/etcix/.local/share/clipboard_server/clipboard.db

# 查看表结构
sqlite3 "$DB" ".schema"

# 查看所有记录（毫秒时间戳转换成本地可读时间）
sqlite3 -header -column "$DB" \
  "SELECT id, content,
          datetime(created_at/1000, 'unixepoch', 'localtime') AS created
   FROM clipboard_history
   ORDER BY created_at DESC;"

# 用 LIKE 验证 search_history 的等价行为
sqlite3 "$DB" \
  "SELECT id, content FROM clipboard_history WHERE content LIKE '%hello%';"

# 统计记录条数
sqlite3 "$DB" "SELECT COUNT(*) FROM clipboard_history;"

# 手动清空
sqlite3 "$DB" "DELETE FROM clipboard_history;"
```

### 数据库文件维护

```bash
# 查看文件大小
ls -lh "$DB"

# 压缩（回收删除记录后残留的空洞）
sqlite3 "$DB" "VACUUM;"

# 备份
cp "$DB" "$DB.bak.$(date +%F)"
```

---

## 🔌 NIF 接口说明

所有 NIF 实现在 `c_src/clipboard_sqlite_nif.c`，通过 `src/clipboard_sqlite_nif.erl` 加载。全部声明为 `ERL_NIF_DIRTY_JOB_IO_BOUND`，运行在 I/O 脏调度器上。

| Erlang 函数 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `open/1` | `PathBin :: binary()` | `{ok, Ref}` \| `{error, Msg}` | 打开/创建数据库文件，返回资源引用 |
| `close/1` | `Db :: reference()` | `ok` \| `{error, Msg}` | 显式关闭连接（GC 也会自动关闭） |
| `exec/2` | `Db, SqlBin` | `ok` \| `{error, Msg}` | 执行无参数 SQL（DDL、PRAGMA 等） |
| `insert/3` | `Db, ContentBin, Ts` | `ok` \| `{error, Msg}` | 插入一行（内容 + 时间戳） |
| `list_all/1` | `Db` | `[{Id, Bin, Ts}]` \| `{error, Msg}` | 列出全部记录 |
| `list_limit/2` | `Db, N` | `[{Id, Bin, Ts}]` \| `{error, Msg}` | 列出最近 N 条 |
| `search/2` | `Db, PatternBin` | `[{Id, Bin, Ts}]` \| `{error, Msg}` | LIKE 模糊搜索 |
| `clear/1` | `Db` | `ok` \| `{error, Msg}` | 清空表 |

**返回值约定**：
- 内容一律返回 **二进制**，Erlang 侧负责转换成字符串（保证 UTF-8 正确）。
- 元组格式为 `{Id :: integer(), Content :: binary(), CreatedAt :: integer()}`。
- 出错时返回 `{error, Reason}`，`Reason` 是字符串（`string()` 类型）。

---

## 📚 Erlang API 参考

### `clipboard_server`

面向调用方的主要接口，封装了剪贴板读写和历史查询。

```erlang
%% 写入系统剪贴板，并把内容异步写入历史库
-spec set_text(string()) -> ok | {error, term()}.

%% 读取系统剪贴板当前文本
-spec get_text() -> {ok, string()} | {error, term()}.

%% 列出全部历史（最新在前）
-spec list_history() -> {ok, [map()]} | {error, term()}.

%% 列出最近 N 条历史
-spec list_history(non_neg_integer()) -> {ok, [map()]} | {error, term()}.

%% 模糊搜索历史
-spec search_history(string()) -> {ok, [map()]} | {error, term()}.

%% 清空历史
-spec clear_history() -> ok | {error, term()}.
```

### `clipboard_store`

持久化层，通常不直接调用，但调试时可用。

```erlang
-spec insert(string()) -> ok | {error, term()}.
-spec list_all() -> {ok, [map()]} | {error, term()}.
-spec list_all(non_neg_integer()) -> {ok, [map()]} | {error, term()}.
-spec search(string()) -> {ok, [map()]} | {error, term()}.
-spec clear() -> ok | {error, term()}.
```

### 返回的 map 结构

```erlang
#{id         => integer(),       %% 记录 ID
  content    => string(),        %% 剪贴板文本内容
  created_at => integer()}       %% Unix 毫秒时间戳
```

---

## 🐞 调试指南

### 1. 查看 gen_server 的 State

```erlang
%% 看 store 的 State（可确认数据库路径）
sys:get_state(clipboard_store).

%% 看 server 的 State（可确认当前用的剪贴板工具路径）
sys:get_state(clipboard_server).

%% 看进程完整状态（消息队列、链接进程等）
sys:get_status(clipboard_server).
```

### 2. 打开 gen_server 事件追踪

```erlang
%% 打开 store 的 trace，所有 call / cast / info 都会打印到终端
sys:trace(clipboard_store, true).

%% 触发一次
clipboard_server:set_text("trace test").
%% 终端会输出类似：
%% *DBG* clipboard_store got cast {insert,<<"trace test">>}
%% *DBG* clipboard_store new state #{db => ...}

%% 关闭
sys:trace(clipboard_store, false).
```

### 3. 确认 NIF 已加载

```erlang
%% 应返回 {module, clipboard_sqlite_nif}
code:which(clipboard_sqlite_nif).

%% 检查 .so 文件存在
filelib:is_file("priv/clipboard_sqlite_nif.so").
%% 或在 shell 里：
%% $ ls -la priv/
```

### 4. 启动 Observer（需图形环境）

```erlang
observer:start().
```

可视化查看监督树、进程状态、消息队列长度、内存占用。

### 5. 用 dbg 追踪调用链

```erlang
%% 追踪 store 和 server 的所有调用
dbg:tracer().
dbg:p(all, c).
dbg:tpl(clipboard_store, x).
dbg:tpl(clipboard_server, x).

%% 触发一次，观察调用链
clipboard_server:set_text("dbg test").

%% 停止
dbg:ctpl(), dbg:stop().
```

### 6. 绕过 server 直接测 store

用来快速区分问题是出在剪贴板层还是数据库层：

```erlang
clipboard_store:insert("direct insert").
clipboard_store:list_all().
clipboard_store:search("direct").
```

### 7. 加日志（推荐，长期方案）

在 `clipboard_store:init/1` 里加一行：

```erlang
logger:info("clipboard database opened at ~ts", [DbPath]),
```

启动时打开日志：

```bash
rebar3 shell --eval 'logger:set_primary_config(level, info).'
```

这样数据库路径一目了然。

---

## 🔧 常见问题排查

| 现象 | 可能原因 | 解决方式 |
|---|---|---|
| `erl_nif.h: No such file or directory` | Makefile 里 erts include 路径推导失败 | 使用 `code:root_dir()` + `erlang:system_info(version)` 组合推导，或 `make debug` 检查 |
| `nif_not_loaded` | `.so` 未编译或路径不对 | 检查 `priv/clipboard_sqlite_nif.so`，确认 `rebar3 compile` 成功 |
| `{noproc, {gen_server, call, [clipboard_store, ...]}}` | store 未启动或已崩溃 | 查看 shell 顶部 CRASH REPORT，检查 `init/1` 是否 `{stop, ...}` |
| `{error, "unable to open database file"}` | 数据目录不可写 | `ls -la ~/.local/share/clipboard_server/`，检查权限 |
| `{error, "database is locked"}` | 有另一进程持有锁 | `lsof ~/.local/share/clipboard_server/clipboard.db` |
| `{error, {missing_tool, ...}}` | 未安装 xclip 或 wl-clipboard | `sudo apt install xclip wl-clipboard` |
| `set_text` 返回 `{error, {external_tool_failed, N}}` | 外部剪贴板工具执行失败 | 手工运行相同命令看报错 |
| `search_history/1` 返回 `{error, ...}` | NIF 里 SQL 出错 | 用 `sqlite3` CLI 手工跑同 SQL 对比 |
| `.so` 编译后行为未变 | NIF 加载后无法热替换 | **必须重启 shell** |
| `'catch ...' is deprecated` 告警 | OTP 29 弃用了前置 catch | 用 `try ... catch ... end` 替代 |
| `{wx, unknown_env}` | 使用了 wx 库且无图形环境 | 本项目已弃用 wx，改用 xclip / wl-copy |
| 无头环境（SSH）无法读写剪贴板 | xclip 需要 X11 / Wayland 环境 | 本项目无法在纯文本终端使用剪贴板 |

---

## 🧠 设计决策说明

### 为什么不用 `wx` 库？

`wxClipboard` 依赖 `wxWidgets`，它需要可用的图形环境。在 SSH 或服务器环境里，`wx` 应用无法启动，会报 `{wx, unknown_env}`。改用 `xclip` / `wl-copy` 后，不依赖图形库，行为更稳定。

### 为什么用自研 NIF 而不用现成的 SQLite 绑定？

第三方绑定往往一次性提供大量 API，是个“黑盒”，且引入了额外的维护负担。本项目只需 8 个核心函数，自研 NIF 让代码完全可控、可审计、无意外依赖。代价是需要自己处理内存安全和跨平台编译。

### 为什么所有 NIF 都标脏调度器？

SQLite 操作涉及磁盘 I/O，可能超过 1 毫秒。如果放在普通调度器上，会阻塞 Erlang VM 的其他进程，导致延迟尖峰。脏 I/O 调度器是 OTP 21+ 引入的独立线程池，专为这类操作设计。

### 为什么写入剪贴板后不等待 `exit_status`？

`xclip` / `wl-copy` 会**驻留后台**持有剪贴板所有权，等待其他程序粘贴。它们不会因为 stdin 关闭而立刻退出。若在 `do_set_text/1` 里等 `exit_status`，会永远等不到并超时。因此发完数据、关闭 stdin，直接返回 `ok`。

### 为什么用资源对象管理数据库连接？

`enif_alloc_resource` 创建的资源对象由 Erlang GC 管理。当 Erlang 侧不再持有 `DbRef`，NIF 析构函数 `db_resource_dtor` 会被自动调用，关闭 `sqlite3*`。这避免了 C 侧连接泄漏。

### 为什么读返回二进制而不是字符串？

`content` 列可能包含 UTF-8 多字节字符（中文、emoji）。NIF 层用 `enif_make_binary` 返回原始字节，Erlang 侧用 `unicode:characters_to_list/1` 转成字符串。这保证了任意文本内容的正确性。

### 为什么搜索不转义 `%` 和 `_`？

`search_history/1` 直接把用户输入拼成 `%pattern%`。用户主动输入 `%` 或 `_` 时，会按 SQL 通配符语义解释（`%` 匹配任意串，`_` 匹配单字符）。这是有意为之，方便用户做更灵活的过滤。若需严格字面匹配，可修改 `nif_search` 转义这两个字符。

### 为什么数据库操作要串行化？

SQLite 连接默认不是线程安全的。所有 SQL 都通过 `clipboard_store` 这个 `gen_server` 串行执行，最简单的保护方式，也符合剪贴板场景的低并发特性。如需高并发，可在 `open/1` 后启用 WAL 模式并使用连接池。

---

## 🚧 扩展建议

### 1. 加 HTTP / JSON 前端

用 `cowboy` 暴露 REST 接口：

- `POST /api/clipboard` → `clipboard_server:set_text/1`
- `GET /api/history?q=xxx&limit=100` → `clipboard_server:search_history/1` 或 `list_history/1`
- `DELETE /api/history` → `clipboard_server:clear_history/0`

`{ok, [map()]}` 返回值可直接用 `jsx` / `jsone` 序列化为 JSON。

### 2. 加 CLI 工具

写一个 escript，调用上述 Erlang API：

```bash
clip list
clip search "hello"
clip clear
```

### 3. 全文搜索（FTS5）

SQLite 支持 FTS5 扩展。当 `content` 数据量大、需要分词或相关度排序时，可以：

- 新建 FTS5 虚拟表 `clipboard_history_fts`，内容与主表同步。
- 查询用 `MATCH` 替代 `LIKE`。
- 需要重启 NIF 编译时启用 `SQLITE_ENABLE_FTS5` 宏。

### 4. 剪贴板历史去重

在 `insert` 前先查一下最新一条是否相同，避免重复文本反复入库。

### 5. 支持图片剪贴板

增加一个 NIF 函数 `insert_blob/3`，把图片二进制存入单独的 BLOB 表；`clipboard_server` 侧探测剪贴板 MIME 类型决定走文本还是图片路径。

### 6. 配置热更新

把数据库路径、保留条数上限等参数从环境变量迁移到 `sys.config` / `runtime.exs`，通过 `application:set_env/3` 动态调整。

### 7. 打包成 release

```bash
rebar3 release
```

生成自带 Erlang 运行时的独立发行版，可以部署到未安装 Erlang 的机器上。注意把 SQLite amalgamation 一起打包。

### 8. 跨平台支持

当前只支持 Linux 的 X11 / Wayland。要支持 macOS / Windows：

- **macOS**：`find_tools/0` 里加 `pbcopy` / `pbpaste` 分支。它们不驻留，写入逻辑更简单。
- **Windows**：使用 PowerShell `Get-Clipboard` / `Set-Clipboard`，或调用 Win32 API。

---

## 📄 许可

本项目示例代码以 Apache-2.0 发布。SQLite amalgamation 遵循 SQLite 的公有领域许可。

---

## 🔗 参考

- [Erlang NIF 官方文档](https://www.erlang.org/doc/man/erl_nif.html)
- [SQLite C Interface](https://www.sqlite.org/c3ref/intro.html)
- [rebar3 官方文档](https://rebar3.org/)
- [OTP 脏调度器](https://www.erlang.org/doc/man/erl_nif.html#ERL_NIF_DIRTY_JOB_IO_BOUND)
- [xclip 项目](https://github.com/astrand/xclip)
- [wl-clipboard 项目](https://github.com/bugaevc/wl-clipboard)