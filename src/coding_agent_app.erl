-module(coding_agent_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ets:new(coding_agent_sessions, [named_table, public, set]),
    coding_agent_sup:start_link().

stop(_State) ->
    ok.