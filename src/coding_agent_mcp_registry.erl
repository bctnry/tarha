-module(coding_agent_mcp_registry).
-behaviour(gen_server).

-export([start_link/0, stop/0]).
-export([start_server/1, stop_server/1, list_servers/0, get_server/1]).
-export([get_all_tools/0, get_tools/1, execute/2, find_tool_server/1]).
-export([update_server/4, clear_servers/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, coding_agent_mcp_servers).

-record(state, {
    servers :: #{binary() => map()}
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    gen_server:stop(?SERVER).

start_server(#{name := Name} = Config) when is_binary(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, _, ready}] ->
            {error, already_running};
        _ ->
            case coding_agent_mcp_sup:start_client(Config) of
                {ok, _Pid} -> {ok, Name};
                {error, Reason} -> {error, Reason}
            end
    end.

stop_server(Name) when is_binary(Name) ->
    try
        coding_agent_mcp_sup:stop_client(Name),
        ets:delete(?TABLE, Name),
        ok
    catch
        _:_ -> {error, not_found}
    end.

list_servers() ->
    case ets:whereis(?TABLE) of
        undefined -> [];
        _ -> ets:tab2list(?TABLE)
    end.

get_server(Name) when is_binary(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Info, Status}] -> {ok, Info#{status => Status}};
        [] -> {error, not_found}
    end.

get_all_tools() ->
    case ets:whereis(?TABLE) of
        undefined -> [];
        _ ->
            AllEntries = ets:tab2list(?TABLE),
            lists:flatmap(fun({Name, Info, Status}) ->
                case Status of
                    ready ->
                        Tools = maps:get(tools, Info, []),
                        Prefix = <<"mcp_", Name/binary, "_">>,
                        [{Prefix, Tool} || Tool <- Tools];
                    _ -> []
                end
            end, AllEntries)
    end.

get_tools(Name) when is_binary(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Info, ready}] ->
            Tools = maps:get(tools, Info, []),
            Prefix = <<"mcp_", Name/binary, "_">>,
            [{Prefix, Tool} || Tool <- Tools];
        [{_, _, Status}] -> {error, {server_not_ready, Status}};
        [] -> {error, server_not_found}
    end.

execute(FullToolName, Args) when is_binary(FullToolName) ->
    case find_tool_server(FullToolName) of
        {ok, ServerName, BaseToolName} ->
            case ets:lookup(?TABLE, ServerName) of
                [{ServerName, _, ready}] ->
                    coding_agent_mcp_client:call_tool(ServerName, BaseToolName, Args);
                [{_, _, Status}] ->
                    {error, {server_not_ready, Status}};
                [] ->
                    {error, server_not_found}
            end;
        {error, not_mcp_tool} ->
            {error, not_mcp_tool};
        Error ->
            Error
    end.

find_tool_server(FullToolName) when is_binary(FullToolName) ->
    case binary:match(FullToolName, <<"mcp_">>) of
        {0, 4} ->
            Rest = binary:part(FullToolName, 4, byte_size(FullToolName) - 4),
            case binary:split(Rest, <<"_">>) of
                [ServerName, BaseToolName] ->
                    {ok, ServerName, BaseToolName};
                _ ->
                    {error, invalid_mcp_tool_name}
            end;
        _ ->
            {error, not_mcp_tool}
    end.

update_server(Name, Tools, Resources, Status) ->
    gen_server:cast(?SERVER, {update, Name, Tools, Resources, Status}).

clear_servers() ->
    gen_server:call(?SERVER, clear).

init([]) ->
    ets:new(?TABLE, [named_table, public, set]),
    {ok, #state{servers = #{}}}.

handle_call(clear, _From, State) ->
    ets:delete_all_objects(?TABLE),
    {reply, ok, State#state{servers = #{}}};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({update, Name, Tools, Resources, Status}, State) ->
    Info = #{tools => Tools, resources => Resources},
    ets:insert(?TABLE, {Name, Info, Status}),
    {noreply, State#state{servers = maps:put(Name, Info#{status => Status}, State#state.servers)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    case ets:whereis(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.