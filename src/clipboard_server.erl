%%%-------------------------------------------------------------------
%% @doc 剪贴板服务器：写/读系统剪贴板，并把写入内容持久化到 SQLite。
%%
%% 设计要点：
%%   - 使用外部命令 xclip / wl-copy / wl-paste，避免 wx 库在无图形
%%     环境下的 {wx, unknown_env} 问题。
%%   - 写入剪贴板后通过 gen_server:cast 异步落库，不阻塞调用方。
%%   - 历史查询委托给 clipboard_store。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_server).
-behaviour(gen_server).

-export([start_link/0, set_text/1, get_text/0,
         list_history/0, list_history/1,
         search_history/1, clear_history/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CALL_TIMEOUT, 10000).
-define(PORT_TIMEOUT, 5000).

%% ===================================================================
%% API
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc 将文本写入系统剪贴板，并异步写入历史库。
-spec set_text(string()) -> ok | {error, term()}.
set_text(Text) when is_list(Text) ->
    gen_server:call(?MODULE, {set_text, Text}, ?CALL_TIMEOUT).

%% @doc 读取系统剪贴板中的文本。
-spec get_text() -> {ok, string()} | {error, term()}.
get_text() ->
    gen_server:call(?MODULE, get_text, ?CALL_TIMEOUT).

%% @doc 列出全部历史（最新在前）。
list_history() -> clipboard_store:list_all().

%% @doc 列出最近 N 条历史。
list_history(N) when is_integer(N), N >= 0 -> clipboard_store:list_all(N).

%% @doc 模糊搜索历史，等价于 LIKE '%Pattern%'。
search_history(Pattern) when is_list(Pattern) -> clipboard_store:search(Pattern).

%% @doc 清空历史。
clear_history() -> clipboard_store:clear().

%% ===================================================================
%% gen_server 回调
%% ===================================================================

init([]) ->
    case find_tools() of
        {ok, WriteTool, ReadTool} ->
            {ok, #{write_tool => WriteTool, read_tool => ReadTool}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({set_text, Text}, _From, #{write_tool := Tool} = State) ->
    case do_set_text(Tool, Text) of
        ok ->
            %% 异步落库，不阻塞调用方
            gen_server:cast(clipboard_store, {insert, Text}),
            {reply, ok, State};
        Err ->
            {reply, Err, State}
    end;

handle_call(get_text, _From, #{read_tool := Tool} = State) ->
    {reply, do_get_text(Tool), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ===================================================================
%% 内部函数
%% ===================================================================

find_tools() ->
    case {os:find_executable("wl-copy"), os:find_executable("wl-paste")} of
        {false, _}        -> find_x11_tools();
        {_, false}        -> find_x11_tools();
        {WlCopy, WlPaste} -> {ok, WlCopy, WlPaste}
    end.

find_x11_tools() ->
    case os:find_executable("xclip") of
        false ->
            {error, {missing_tool, "请安装 xclip 或 wl-clipboard"}};
        Xclip ->
            {ok,
             Xclip ++ " -selection clipboard",
             Xclip ++ " -selection clipboard -o"}
    end.

%% 写入路径：xclip / wl-copy 会驻留以持有剪贴板所有权，
%% 关闭 stdin 后不会立即退出，因此发完数据关闭端口直接返回 ok。
do_set_text(Tool, Text) ->
    BinData = unicode:characters_to_binary(Text),
    Port = open_port({spawn, Tool}, [stream, binary, exit_status]),
    Port ! {self(), {command, BinData}},
    safe_port_close(Port),
    ok.

%% 读取路径：xclip -o / wl-paste 输出内容后正常退出，
%% 用 eof 作为主终止条件，兼容 exit_status。
do_get_text(Tool) ->
    Port = open_port({spawn, Tool}, [stream, binary, exit_status, eof]),
    collect_port_data(Port, <<>>).

collect_port_data(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port_data(Port, <<Acc/binary, Data/binary>>);
        {Port, eof} ->
            finalize_read(Acc);
        {Port, {exit_status, 0}} ->
            finalize_read(Acc);
        {Port, {exit_status, Status}} ->
            {error, {external_tool_failed, Status}}
    after ?PORT_TIMEOUT ->
        safe_port_close(Port),
        {error, timeout}
    end.

finalize_read(<<>>) -> {error, no_text_data};
finalize_read(Acc)  -> {ok, unicode:characters_to_list(Acc)}.

safe_port_close(Port) ->
    try port_close(Port) of
        _ -> ok
    catch
        _:_ -> ok
    end.