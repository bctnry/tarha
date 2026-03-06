-module(coding_agent_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    BaseChildren = [
        #{id => coding_agent_process_monitor,
          start => {coding_agent_process_monitor, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent_process_monitor]},
        #{id => coding_agent_conv_memory,
          start => {coding_agent_conv_memory, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent_conv_memory]},
        #{id => coding_agent_skills,
          start => {coding_agent_skills, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent_skills]},
        #{id => coding_agent_session_store,
          start => {coding_agent_session_store, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent_session_store]},
        #{id => coding_agent_self,
          start => {coding_agent_self, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent_self]},
        #{id => coding_agent_healer,
          start => {coding_agent_healer, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent_healer]},
        #{id => coding_agent_session_sup,
          start => {coding_agent_session_sup, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [coding_agent_session_sup]},
        #{id => coding_agent,
          start => {coding_agent, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [coding_agent]}
    ],
    HTTPChild = case application:get_env(coding_agent, http_port) of
        {ok, _Port} ->
            [#{id => coding_agent_http,
              start => {coding_agent_http, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [coding_agent_http]}];
        _ -> []
    end,
    ZulipChild = case application:get_env(coding_agent, zulip_site) of
        {ok, _Site} ->
            [#{id => coding_agent_zulip,
              start => {coding_agent_zulip, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [coding_agent_zulip]}];
        _ -> []
    end,
    Children = BaseChildren ++ HTTPChild ++ ZulipChild,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, Children}}.