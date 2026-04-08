-module(coding_agent_session_sup).
-behaviour(supervisor).

-export([start_link/0, start_session/1, stop_session/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_session(Id) ->
    supervisor:start_child(?MODULE, [Id]).

stop_session(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    %% Ensure ETS table exists (survives app restart)
    case ets:whereis(coding_agent_sessions) of
        undefined -> ets:new(coding_agent_sessions, [named_table, public, set]);
        _ -> ok
    end,
    SessionSpec = #{
        id => coding_agent_session,
        start => {coding_agent_session, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [coding_agent_session]
    },
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 60}, [SessionSpec]}}.
