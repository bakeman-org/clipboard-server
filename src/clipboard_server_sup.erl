-module(clipboard_server_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

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
        #{id       => clipboard_http,
          start    => {clipboard_http, start_link, []},
          restart  => permanent,
          shutdown => 5000,
          type     => worker,
          modules  => [clipboard_http]}
    ],
    {ok, {SupFlags, ChildSpecs}}.