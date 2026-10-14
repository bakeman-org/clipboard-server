%%%-------------------------------------------------------------------
%% @doc 剪贴板监视器：定时轮询，检测变化后落库 + pg 广播。
%%
%% 关键点：
%%   - 全程用二进制传递内容，不做 list <-> binary 转换，避免
%%     UTF-8 双重编码或解码失败。
%%   - 非文本剪贴板（截图、文件等）自动跳过，不落库不广播。
%%   - 归一化 = 去首尾空白 + 去零宽字符。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_watcher).
-behaviour(gen_server).

-export([start_link/0, get_last/0, get_stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_POLL_MS, 800).
-define(MAX_POLL_MS, 30000).
-define(GROUP, clipboard_events).

-record(state, {
    read_tool            :: string(),
    last_raw             :: binary(),
    last_norm            :: binary(),
    poll_ms              :: pos_integer(),
    consecutive_failures :: non_neg_integer(),
    total_polls          :: non_neg_integer(),
    total_changes        :: non_neg_integer(),
    total_skipped        :: non_neg_integer()
}).

%% ===================================================================
%% API
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_last() ->
    gen_server:call(?MODULE, get_last).

get_stats() ->
    gen_server:call(?MODULE, get_stats).

%% ===================================================================
%% gen_server
%% ===================================================================

init([]) ->
    case clipboard_tools:find_read_tool() of
        {ok, ReadTool} ->
            PollMs = application:get_env(
                       clipboard_server, watcher_poll_ms,
                       ?DEFAULT_POLL_MS),
            Initial = read_or_empty(ReadTool),
            InitialNorm = normalize(Initial),
            schedule_poll(PollMs),
            logger:info("clipboard watcher started: "
                        "tool=~ts poll=~pms baseline=~p bytes",
                        [ReadTool, PollMs, byte_size(Initial)]),
            {ok, #state{
                read_tool = ReadTool,
                last_raw = Initial,
                last_norm = InitialNorm,
                poll_ms = PollMs,
                consecutive_failures = 0,
                total_polls = 0,
                total_changes = 0,
                total_skipped = 0
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(get_last, _From, #state{last_raw = L} = State) ->
    {reply, L, State};

handle_call(get_stats, _From, State) ->
    {reply, #{
        poll_ms              => State#state.poll_ms,
        consecutive_failures => State#state.consecutive_failures,
        total_polls          => State#state.total_polls,
        total_changes        => State#state.total_changes,
        total_skipped        => State#state.total_skipped,
        baseline_bytes       => byte_size(State#state.last_raw)
    }, State};

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll, #state{read_tool = Tool} = State0) ->
    schedule_poll(current_interval(State0)),
    State1 = State0#state{total_polls = State0#state.total_polls + 1},
    case clipboard_tools:read_clipboard(Tool) of
        {ok, Content}   -> handle_content(Content, State1);
        {error, empty}  -> handle_content(<<>>, State1);
        {error, Reason} -> handle_read_error(Reason, State1)
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% 内容处理
%% ===================================================================

handle_content(<<>>, State) ->
    %% 空剪贴板：只更新基线
    {noreply, State#state{
        last_raw = <<>>,
        last_norm = <<>>,
        consecutive_failures = 0
    }};

handle_content(Content, #state{last_norm = LastNorm} = State) ->
    case is_valid_utf8(Content) of
        false ->
            %% 非文本（截图/文件等），跳过不落库
            logger:debug("clipboard: skip non-text payload (~p bytes)",
                         [byte_size(Content)]),
            {noreply, State#state{
                last_raw = Content,
                last_norm = <<>>,   %% 置空，下次遇到不同内容仍能识别为变化
                consecutive_failures = 0,
                total_skipped = State#state.total_skipped + 1
            }};
        true ->
            Norm = normalize(Content),
            case Norm of
                <<>> ->
                    {noreply, State#state{
                        last_raw = Content,
                        last_norm = Norm,
                        consecutive_failures = 0
                    }};
                LastNorm ->
                    {noreply, State#state{
                        last_raw = Content,
                        consecutive_failures = 0
                    }};
                _ ->
                    %% 真正的新文本：直接传二进制给 store
                    gen_server:cast(clipboard_store, {insert_bin, Content}),
                    broadcast(Content),
                    logger:debug("clipboard changed: ~p bytes",
                                 [byte_size(Content)]),
                    {noreply, State#state{
                        last_raw = Content,
                        last_norm = Norm,
                        consecutive_failures = 0,
                        total_changes = State#state.total_changes + 1
                    }}
            end
    end.

handle_read_error(Reason, State) ->
    Fails = State#state.consecutive_failures + 1,
    Level = case Fails of
        N when N < 3  -> debug;
        N when N < 10 -> warning;
        _             -> error
    end,
    logger:log(Level,
               "clipboard read failed (~p consecutive): ~p",
               [Fails, Reason]),
    {noreply, State#state{consecutive_failures = Fails}}.

%% ===================================================================
%% 内部
%% ===================================================================

%% 判断二进制是否是合法 UTF-8。用于区分文本 vs 图片/文件。
is_valid_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        B when is_binary(B) -> true;
        _                   -> false
    end.

schedule_poll(Ms) ->
    erlang:send_after(Ms, self(), poll).

current_interval(#state{consecutive_failures = 0, poll_ms = Base}) ->
    Base;
current_interval(#state{consecutive_failures = N, poll_ms = Base}) ->
    min(Base bsl min(N, 5), ?MAX_POLL_MS).

read_or_empty(Tool) ->
    case clipboard_tools:read_clipboard(Tool) of
        {ok, T} -> T;
        _       -> <<>>
    end.

%% 归一化：去首尾空白 + 去零宽字符
normalize(Bin) when is_binary(Bin) ->
    Trimmed = string:trim(Bin),
    re:replace(
        Trimmed,
        <<"[\x{200B}\x{200C}\x{200D}\x{FEFF}]"/utf8>>,
        <<>>,
        [global, {return, binary}]).

broadcast(BinData) ->
    Members = try pg:get_members(?GROUP)
              catch _:_ -> []
              end,
    lists:foreach(
        fun(Pid) when is_pid(Pid), Pid =/= self() ->
                Pid ! {clipboard_changed, BinData};
           (_) -> ok
        end,
        Members).