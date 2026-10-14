-module(clipboard_server).
-behaviour(gen_server).

-export([start_link/0, set_text/1, get_text/0,
         list_history/0, list_history/1,
         search_history/1, clear_history/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(CALL_TIMEOUT, 10000).

%% ===================================================================
%% API
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec set_text(binary() | string()) -> ok | {error, term()}.
set_text(Text) when is_binary(Text) ->
    gen_server:call(?MODULE, {set_text, Text}, ?CALL_TIMEOUT);
set_text(Text) when is_list(Text) ->
    gen_server:call(?MODULE, {set_text, Text}, ?CALL_TIMEOUT).

-spec get_text() -> {ok, string()} | {error, term()}.
get_text() ->
    gen_server:call(?MODULE, get_text, ?CALL_TIMEOUT).

list_history() -> clipboard_store:list_all().
list_history(N) when is_integer(N), N >= 0 -> clipboard_store:list_all(N).

%% @doc 模糊搜索，接受二进制或字符串。
search_history(P) when is_binary(P) -> clipboard_store:search(P);
search_history(P) when is_list(P)   -> clipboard_store:search(P).

clear_history() -> clipboard_store:clear().

%% ===================================================================
%% gen_server
%% ===================================================================

init([]) ->
    case clipboard_tools:find_write_tool() of
        {ok, WriteTool} ->
            {ok, #{write_tool => WriteTool}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({set_text, Text}, _From, #{write_tool := Tool} = State) ->
    {reply, clipboard_tools:write_clipboard(Tool, Text), State};

handle_call(get_text, _From, _State) ->
    case clipboard_tools:find_read_tool() of
        {ok, Tool} ->
            case clipboard_tools:read_clipboard(Tool) of
                {ok, Bin} ->
                    case unicode:characters_to_list(Bin) of
                        L when is_list(L) -> {reply, {ok, L}, []};
                        _                 -> {reply, {error, non_text_clipboard}, []}
                    end;
                {error, empty} -> {reply, {error, no_text_data}, []};
                {error, R}     -> {reply, {error, R}, []}
            end;
        Err -> {reply, Err, []}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.