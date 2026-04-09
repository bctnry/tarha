-module(coding_agent_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    coding_agent_config:init_config(),
    coding_agent_lifeline_sup:start_link().

stop(_State) ->
    ok.
