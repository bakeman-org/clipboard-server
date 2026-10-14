%%%-------------------------------------------------------------------
%% @doc clipboard_server 顶层监督者。
%%
%% 子进程启动顺序（重要）：
%%   1. clipboard_store    —— 持久化层，watcher 和 server 都会向它发消息
%%   2. clipboard_server   —— 剪贴板读写 API 层
%%   3. clipboard_watcher  —— 轮询监视器，依赖 store
%%   4. clipboard_http     —— REST API + 前端，依赖前三个
%%
%% 任一进程崩溃都会被 one_for_one 策略单独重启，不影响其他子进程。
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_server_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% ===================================================================
%% supervisor 回调
%% ===================================================================

init([]) ->
    SupFlags = #{strategy  => one_for_one,
                 intensity => 1,
                 period    => 5},
    ChildSpecs = [
        #{id       => clipboard_store,
          start    => {clipboard_store, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [clipboard_store]},
        #{id       => clipboard_server,
          start    => {clipboard_server, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [clipboard_server]},
        #{id       => clipboard_watcher,
          start    => {clipboard_watcher, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [clipboard_watcher]},
        #{id       => clipboard_http,
          start    => {clipboard_http, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [clipboard_http]}
    ],
    {ok, {SupFlags, ChildSpecs}}.