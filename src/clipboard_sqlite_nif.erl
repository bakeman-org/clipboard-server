%%%-------------------------------------------------------------------
%% @doc SQLite3 NIF 的 Erlang 壳层。
%%
%% 所有实际逻辑在 c_src/clipboard_sqlite_nif.c 中。
%% 本模块只负责加载 NIF，并声明与 C 侧一致的类型签名。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_sqlite_nif).

-export([open/1, close/1, exec/2, insert/3,
         list_all/1, list_limit/2, search/2, clear/1]).

-on_load(init/0).

%% ===================================================================
%% NIF 加载
%% ===================================================================

init() ->
    SoName = case code:priv_dir(clipboard_server) of
        {error, _} ->
            %% 开发模式回退：rebar3 shell 未加载应用时
            case filelib:is_file("priv/clipboard_sqlite_nif.so") of
                true  -> "priv/clipboard_sqlite_nif";
                false -> "_build/default/lib/clipboard_server/priv/clipboard_sqlite_nif"
            end;
        Dir ->
            filename:join(Dir, "clipboard_sqlite_nif")
    end,
    erlang:load_nif(SoName, 0).

%% ===================================================================
%% NIF 存根（仅在 NIF 加载失败时被调用）
%% ===================================================================

-spec open(binary()) -> {ok, reference()} | {error, string()}.
open(_Path) -> erlang:nif_error(nif_not_loaded).

-spec close(reference()) -> ok | {error, string()}.
close(_Db) -> erlang:nif_error(nif_not_loaded).

-spec exec(reference(), binary()) -> ok | {error, string()}.
exec(_Db, _Sql) -> erlang:nif_error(nif_not_loaded).

-spec insert(reference(), binary(), integer()) -> ok | {error, string()}.
insert(_Db, _Content, _Timestamp) -> erlang:nif_error(nif_not_loaded).

-spec list_all(reference()) -> [{integer(), binary(), integer()}] | {error, string()}.
list_all(_Db) -> erlang:nif_error(nif_not_loaded).

-spec list_limit(reference(), non_neg_integer()) ->
    [{integer(), binary(), integer()}] | {error, string()}.
list_limit(_Db, _Limit) -> erlang:nif_error(nif_not_loaded).

-spec search(reference(), binary()) ->
    [{integer(), binary(), integer()}] | {error, string()}.
search(_Db, _Pattern) -> erlang:nif_error(nif_not_loaded).

-spec clear(reference()) -> ok | {error, string()}.
clear(_Db) -> erlang:nif_error(nif_not_loaded).