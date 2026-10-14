%%%-------------------------------------------------------------------
%% @doc 剪贴板工具探测与读写封装（被 server 和 watcher 共用）。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_tools).

-export([find_tools/0, find_write_tool/0, find_read_tool/0,
         read_clipboard/1, write_clipboard/2]).

-define(PORT_TIMEOUT, 5000).

%% 优先 Wayland，回退 X11
find_tools() ->
    case {os:find_executable("wl-copy"), os:find_executable("wl-paste")} of
        {false, _} -> find_x11_tools();
        {_, false} -> find_x11_tools();
        {W, R}     -> {ok, W, R}
    end.

find_write_tool() ->
    case find_tools() of
        {ok, W, _} -> {ok, W};
        Err        -> Err
    end.

find_read_tool() ->
    case find_tools() of
        {ok, _, R} -> {ok, R};
        Err        -> Err
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

%% @doc 读剪贴板，返回 {ok, binary()} | {error, term()}。
%% 空剪贴板返回 {error, empty}，调用方按需处理。
read_clipboard(Tool) ->
    Port = open_port({spawn, Tool}, [stream, binary, exit_status, eof]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, eof} ->
            safe_close(Port), finalize(Acc);
        {Port, {exit_status, 0}} ->
            safe_close(Port), finalize(Acc);
        {Port, {exit_status, S}} ->
            safe_close(Port), {error, {exit_status, S}}
    after ?PORT_TIMEOUT ->
        safe_close(Port),
        {error, timeout}
    end.

finalize(<<>>) -> {error, empty};
finalize(Acc)  -> {ok, Acc}.

%% @doc 写剪贴板。发完数据即关闭 stdin 返回；
%% xclip/wl-copy 会驻留后台持有剪贴板所有权，不会立即退出。
write_clipboard(Tool, Text) ->
    Bin = unicode:characters_to_binary(Text),
    Port = open_port({spawn, Tool}, [stream, binary, exit_status]),
    Port ! {self(), {command, Bin}},
    safe_close(Port),
    ok.

safe_close(Port) ->
    try port_close(Port) of _ -> ok catch _:_ -> ok end.