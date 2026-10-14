%%%-------------------------------------------------------------------
%% @doc HTTP 层：启动 Cowboy listener 并挂载 REST 路由。
%%
%% 端口默认 8080，可通过 application:set_env(clipboard_server,
%% http_port, Port) 或 sys.config 覆盖。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_http).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(LISTENER, clipboard_http_listener).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Port = application:get_env(clipboard_server, http_port, 8080),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/",                    clipboard_http_handler, #{action => index}},
            {"/api/history",         clipboard_http_handler, #{action => history}},
            {"/api/history/search",  clipboard_http_handler, #{action => search}},
            {"/api/clipboard",       clipboard_http_handler, #{action => clipboard}},
            {"/api/clear",           clipboard_http_handler, #{action => clear}}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(
        ?LISTENER,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    logger:info("clipboard HTTP server listening on http://0.0.0.0:~p/", [Port]),
    {ok, #{port => Port}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = cowboy:stop_listener(?LISTENER),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.