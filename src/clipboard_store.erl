%%%-------------------------------------------------------------------
%% @doc 剪贴板历史存储 —— 基于自研 SQLite NIF 的持久化层。
%%
%% 关键点：
%%   - 全程使用二进制，不做 list <-> binary 转换。
%%   - 插入前对最后一条做"归一化比较"去重。
%%   - search 同时支持 list / binary 输入，最终转成二进制传入 NIF。
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

-spec insert(binary() | string()) -> ok | {error, term()}.
insert(Text) ->
    gen_server:call(?MODULE, {insert, Text}, ?CALL_TIMEOUT).

-spec list_all() -> {ok, [map()]} | {error, term()}.
list_all() -> list_all(0).

-spec list_all(non_neg_integer()) -> {ok, [map()]} | {error, term()}.
list_all(Limit) when is_integer(Limit), Limit >= 0 ->
    gen_server:call(?MODULE, {list_all, Limit}, ?CALL_TIMEOUT).

%% @doc 模糊搜索。参数可为二进制或字符串。
-spec search(binary() | string()) -> {ok, [map()]} | {error, term()}.
search(Pattern) when is_binary(Pattern) ->
    gen_server:call(?MODULE, {search, Pattern}, ?CALL_TIMEOUT);
search(Pattern) when is_list(Pattern) ->
    search(unicode:characters_to_binary(Pattern)).

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
    case to_binary(Text) of
        {ok, Bin} -> {reply, insert_if_new(Db, Bin), State};
        error     -> {reply, {error, bad_content}, State}
    end;

handle_call({list_all, 0}, _From, #{db := Db} = State) ->
    {reply, wrap(clipboard_sqlite_nif:list_all(Db)), State};

handle_call({list_all, Limit}, _From, #{db := Db} = State) ->
    {reply, wrap(clipboard_sqlite_nif:list_limit(Db, Limit)), State};

handle_call({search, Bin}, _From, #{db := Db} = State) when is_binary(Bin) ->
    {reply, wrap(clipboard_sqlite_nif:search(Db, Bin)), State};

handle_call(clear, _From, #{db := Db} = State) ->
    {reply, clipboard_sqlite_nif:clear(Db), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% 异步落库：watcher 传二进制
handle_cast({insert_bin, Bin}, #{db := Db} = State) when is_binary(Bin) ->
    _ = insert_if_new(Db, Bin),
    {noreply, State};

handle_cast({insert, Text}, #{db := Db} = State) ->
    case to_binary(Text) of
        {ok, Bin} -> _ = insert_if_new(Db, Bin);
        error     -> ok
    end,
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

%% 统一把输入转成二进制；非法输入返回 error
to_binary(B) when is_binary(B) -> {ok, B};
to_binary(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> {ok, B};
        _                   -> error
    end;
to_binary(_) -> error.

insert_if_new(_, <<>>) ->
    %% 空内容不入库
    ok;
insert_if_new(Db, Bin) ->
    case is_duplicate(Db, Bin) of
        true ->
            logger:debug("clipboard_store: skip duplicate (~p bytes)",
                         [byte_size(Bin)]),
            ok;
        false ->
            Now = erlang:system_time(millisecond),
            case clipboard_sqlite_nif:insert(Db, Bin, Now) of
                ok ->
                    logger:debug("clipboard_store: inserted ~p bytes",
                                 [byte_size(Bin)]),
                    ok;
                {error, Reason} = Err ->
                    logger:error("clipboard_store: insert failed: ~p",
                                 [Reason]),
                    Err
            end
    end.

is_duplicate(Db, Bin) ->
    Normalized = normalize(Bin),
    case clipboard_sqlite_nif:list_limit(Db, 1) of
        [{_, LastBin, _}] ->
            normalize(LastBin) =:= Normalized;
        _ ->
            false
    end.

normalize(Bin) when is_binary(Bin) ->
    Trimmed = string:trim(Bin),
    re:replace(
        Trimmed,
        <<"[\x{200B}\x{200C}\x{200D}\x{FEFF}]"/utf8>>,
        <<>>,
        [global, {return, binary}]).

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

wrap(Rows) when is_list(Rows) ->
    {ok, [row_to_map(R) || R <- Rows]};
wrap(Other) ->
    Other.

row_to_map({Id, ContentBin, CreatedAt}) ->
    %% 已经确定是合法 UTF-8（NIF 存的就是原始文本）
    #{id         => Id,
      content    => unicode:characters_to_list(ContentBin),
      created_at => CreatedAt}.