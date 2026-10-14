%%%-------------------------------------------------------------------
%% @doc 剪贴板历史存储 —— 基于自研 SQLite NIF 的持久化层。
%%
%% 表结构：
%%   clipboard_history(id INTEGER PRIMARY KEY AUTOINCREMENT,
%%                     content TEXT NOT NULL,
%%                     created_at INTEGER NOT NULL)
%%
%% 数据库文件默认位于 $XDG_DATA_HOME/clipboard_server/clipboard.db，
%% 可用环境变量 CLIPBOARD_DATA_DIR 覆盖。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_store).
-behaviour(gen_server).

-export([start_link/0,
         insert/1,
         list_all/0, list_all/1,
         search/1,
         clear/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CALL_TIMEOUT, 10000).

%% ===================================================================
%% API
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 同步插入一条记录。
-spec insert(string()) -> ok | {error, term()}.
insert(Text) when is_list(Text) ->
    gen_server:call(?MODULE, {insert, Text}, ?CALL_TIMEOUT).

%% @doc 列出全部历史（最新在前）。
-spec list_all() -> {ok, [map()]} | {error, term()}.
list_all() -> list_all(0).

%% @doc 列出最近 Limit 条历史，Limit = 0 表示全部。
-spec list_all(non_neg_integer()) -> {ok, [map()]} | {error, term()}.
list_all(Limit) when is_integer(Limit), Limit >= 0 ->
    gen_server:call(?MODULE, {list_all, Limit}, ?CALL_TIMEOUT).

%% @doc 模糊搜索历史，等价于 SQL LIKE '%Pattern%'。
-spec search(string()) -> {ok, [map()]} | {error, term()}.
search(Pattern) when is_list(Pattern) ->
    gen_server:call(?MODULE, {search, Pattern}, ?CALL_TIMEOUT).

%% @doc 清空全部历史。
-spec clear() -> ok | {error, term()}.
clear() ->
    gen_server:call(?MODULE, clear, ?CALL_TIMEOUT).

%% ===================================================================
%% gen_server 回调
%% ===================================================================

init([]) ->
    DbPath = db_path(),
    logger:info("clipboard database opened at ~ts", [DbPath]),
    case clipboard_sqlite_nif:open(list_to_binary(DbPath)) of
        {ok, Db} ->
            ok = ensure_schema(Db),
            {ok, #{db => Db, path => DbPath}};
        {error, Reason} ->
            {stop, {db_open_failed, Reason}}
    end.

handle_call({insert, Text}, _From, #{db := Db} = State) ->
    Now = erlang:system_time(millisecond),
    Result = clipboard_sqlite_nif:insert(
        Db, unicode:characters_to_binary(Text), Now),
    {reply, Result, State};

handle_call({list_all, 0}, _From, #{db := Db} = State) ->
    {reply, wrap(clipboard_sqlite_nif:list_all(Db)), State};

handle_call({list_all, Limit}, _From, #{db := Db} = State) ->
    {reply, wrap(clipboard_sqlite_nif:list_limit(Db, Limit)), State};

handle_call({search, Pattern}, _From, #{db := Db} = State) ->
    Bin = unicode:characters_to_binary(Pattern),
    {reply, wrap(clipboard_sqlite_nif:search(Db, Bin)), State};

handle_call(clear, _From, #{db := Db} = State) ->
    {reply, clipboard_sqlite_nif:clear(Db), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% 异步落库接口（供 clipboard_server 使用）
handle_cast({insert, Text}, #{db := Db} = State) ->
    Now = erlang:system_time(millisecond),
    _ = clipboard_sqlite_nif:insert(
        Db, unicode:characters_to_binary(Text), Now),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{db := Db}) ->
    _ = clipboard_sqlite_nif:close(Db),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% 内部函数
%% ===================================================================

db_path() ->
    Dir = case os:getenv("CLIPBOARD_DATA_DIR") of
        false ->
            Base = case os:getenv("XDG_DATA_HOME") of
                false ->
                    case os:getenv("HOME") of
                        false -> ".";
                        Home  -> filename:join(Home, ".local/share")
                    end;
                D -> D
            end,
            filename:join(Base, "clipboard_server");
        D -> D
    end,
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    filename:join(Dir, "clipboard.db").

ensure_schema(Db) ->
    Sql = <<"CREATE TABLE IF NOT EXISTS clipboard_history ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "content TEXT NOT NULL, "
            "created_at INTEGER NOT NULL)">>,
    case clipboard_sqlite_nif:exec(Db, Sql) of
        ok -> ok;
        {error, Reason} -> error({schema_error, Reason})
    end.

%% 把 NIF 返回的 [{Id, ContentBin, Ts}] 转成 [{Id, ContentString, Ts}]
%% 的 map 列表。若 NIF 已返回 {error, _}，原样返回。
wrap(Rows) when is_list(Rows) ->
    {ok, [row_to_map(R) || R <- Rows]};
wrap(Other) ->
    Other.

row_to_map({Id, ContentBin, CreatedAt}) ->
    #{id         => Id,
      content    => unicode:characters_to_list(ContentBin),
      created_at => CreatedAt}.