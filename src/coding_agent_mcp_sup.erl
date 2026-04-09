-module(coding_agent_mcp_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
-export([start_client/1, stop_client/1, list_clients/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 60},
    {ok, {SupFlags, []}}.

start_client(#{name := Name} = Config) ->
    ChildSpec = #{
        id => {mcp_client, Name},
        start => {coding_agent_mcp_client, start_link, [Config]},
        restart => transient,
        shutdown => 5000,
        type => worker
    },
    supervisor:start_child(?MODULE, ChildSpec).

stop_client(Name) when is_binary(Name) ->
    supervisor:terminate_child(?MODULE, {mcp_client, Name}),
    supervisor:delete_child(?MODULE, {mcp_client, Name}).

list_clients() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE), is_pid(Pid)].