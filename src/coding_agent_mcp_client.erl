-module(coding_agent_mcp_client).
-behaviour(gen_server).

-export([start_link/1, stop/1, call_tool/3, list_tools/1, list_resources/1, read_resource/2, get_info/1, ping/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(MCP_PROTOCOL_VERSION, <<"2025-03-26">>).
-define(INIT_TIMEOUT, 30000).
-define(CALL_TIMEOUT, 60000).
-define(LIST_TIMEOUT, 15000).
-define(PING_TIMEOUT, 10000).

-record(state, {
    name :: binary(),
    transport :: stdio | http,
    command :: string() | undefined,
    args :: [string()],
    env :: [{string(), string()}],
    url :: string() | undefined,
    headers :: [{binary(), binary()}],
    port :: port() | undefined,
    req_id :: integer(),
    pending :: #{integer() => {pid(), term()}},
    capabilities :: map(),
    server_info :: map(),
    instructions :: binary(),
    tools :: [map()],
    resources :: [map()],
    status :: disconnected | initializing | ready | error,
    error_reason :: term()
}).

start_link(#{name := Name} = Config) ->
    gen_server:start_link({via, coding_agent_mcp_registry, {client, Name}}, ?MODULE, Config, []).

stop(Name) ->
    gen_server:stop({via, coding_agent_mcp_registry, {client, Name}}).

call_tool(Name, ToolName, Args) ->
    gen_server:call({via, coding_agent_mcp_registry, {client, Name}}, {call_tool, ToolName, Args}, ?CALL_TIMEOUT).

list_tools(Name) ->
    gen_server:call({via, coding_agent_mcp_registry, {client, Name}}, list_tools, ?LIST_TIMEOUT).

list_resources(Name) ->
    gen_server:call({via, coding_agent_mcp_registry, {client, Name}}, list_resources, ?LIST_TIMEOUT).

read_resource(Name, Uri) ->
    gen_server:call({via, coding_agent_mcp_registry, {client, Name}}, {read_resource, Uri}, ?CALL_TIMEOUT).

get_info(Name) ->
    gen_server:call({via, coding_agent_mcp_registry, {client, Name}}, get_info, 5000).

ping(Name) ->
    gen_server:call({via, coding_agent_mcp_registry, {client, Name}}, ping, ?PING_TIMEOUT).

init(#{name := Name, transport := Transport} = Config) ->
    process_flag(trap_exit, true),
    Command = maps:get(command, Config, undefined),
    Args = maps:get(args, Config, []),
    Env = maps:get(env, Config, []),
    Url = maps:get(url, Config, undefined),
    Headers = maps:get(headers, Config, []),
    State = #state{
        name = Name,
        transport = Transport,
        command = Command,
        args = Args,
        env = Env,
        url = Url,
        headers = Headers,
        req_id = 0,
        pending = #{},
        tools = [],
        resources = [],
        status = disconnected,
        capabilities = #{},
        server_info = #{},
        instructions = <<>>
    },
    case Transport of
        stdio -> do_stdio_connect(State);
        http -> do_http_initialize(State)
    end.

do_stdio_connect(State = #state{command = Command, args = Args, env = Env}) ->
    Cmd = case Args of
        [] -> Command;
        _ -> Command ++ " " ++ string:join(Args, " ")
    end,
    EnvList = case Env of
        [] -> [];
        _ -> [{env, [{Var, Val} || {Var, Val} <- Env]}]
    end,
    PortOpts = [{line, 65536}, use_stdio, exit_status, stderr_to_std_err] ++ EnvList,
    try
        Port = erlang:open_port({spawn, Cmd}, PortOpts),
        NewState = State#state{port = Port, status = initializing},
        case send_initialize(NewState) of
            {ok, InitResult} ->
                Capabilities = maps:get(<<"capabilities">>, InitResult, #{}),
                ServerInfo = maps:get(<<"serverInfo">>, InitResult, #{}),
                Instructions = maps:get(<<"instructions">>, InitResult, <<>>),
                send_notification(NewState, <<"notifications/initialized">>, #{}),
                {ok, Tools} = do_list_tools(NewState),
                Resources = case maps:get(<<"resources">>, Capabilities, undefined) of
                    undefined -> [];
                    _ ->
                        case do_list_resources(NewState) of
                            {ok, Res} -> Res;
                            _ -> []
                        end
                end,
                ReadyState = NewState#state{
                    status = ready,
                    capabilities = Capabilities,
                    server_info = ServerInfo,
                    instructions = Instructions,
                    tools = Tools,
                    resources = Resources
                },
                notify_registry(ReadyState),
                {ok, ReadyState};
            {error, Reason} ->
                {stop, {init_failed, Reason}}
        end
    catch
        _:Err ->
            {stop, {connect_failed, Err}}
    end.

do_http_initialize(State = #state{url = Url}) ->
    try
        InitReq = #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"method">> => <<"initialize">>,
            <<"params">> => #{
                <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
                <<"capabilities">> => #{<<"roots">> => #{<<"listChanged">> => true}},
                <<"clientInfo">> => #{<<"name">> => <<"tarha">>, <<"version">> => <<"0.3.0">>}
            }
        },
        Body = jsx:encode(InitReq),
        Headers = [{<<"Content-Type">>, <<"application/json">>} | State#state.headers],
        case hackney:post(Url, Headers, Body, [with_body, {recv_timeout, ?INIT_TIMEOUT}]) of
            {ok, 200, _, RespBody} ->
                Resp = jsx:decode(RespBody, [return_maps]),
                Result = maps:get(<<"result">>, Resp, #{}),
                Capabilities = maps:get(<<"capabilities">>, Result, #{}),
                ServerInfo = maps:get(<<"serverInfo">>, Result, #{}),
                Instructions = maps:get(<<"instructions">>, Result, <<>>),
                Tools = case maps:get(<<"tools">>, Capabilities, undefined) of
                    undefined -> [];
                    _ -> do_http_list_tools(State#state{req_id = 2})
                end,
                ReadyState = State#state{
                    status = ready,
                    req_id = 2,
                    capabilities = Capabilities,
                    server_info = ServerInfo,
                    instructions = Instructions,
                    tools = Tools,
                    resources = []
                },
                notify_registry(ReadyState),
                {ok, ReadyState};
            {ok, Status, _, RespBody} ->
                {stop, {http_init_failed, Status, RespBody}};
            {error, Reason} ->
                {stop, {http_connect_failed, Reason}}
        end
    catch
        _:Err2 ->
            {stop, {http_init_error, Err2}}
    end.

do_http_list_tools(#state{url = Url, headers = Hdrs, req_id = ReqId}) ->
    Req = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => ReqId,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{}
    },
    Headers = [{<<"Content-Type">>, <<"application/json">>} | Hdrs],
    case hackney:post(Url, Headers, jsx:encode(Req), [with_body, {recv_timeout, ?LIST_TIMEOUT}]) of
        {ok, 200, _, RespBody} ->
            Resp = jsx:decode(RespBody, [return_maps]),
            Result = maps:get(<<"result">>, Resp, #{}),
            {ok, maps:get(<<"tools">>, Result, [])};
        _ ->
            {ok, []}
    end.

handle_call({call_tool, ToolName, Args}, From, State = #state{status = ready, transport = stdio}) ->
    Id = State#state.req_id + 1,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{<<"name">> => ToolName, <<"arguments">> => Args}
    },
    send_stdio(State#state.port, Msg),
    {noreply, State#state{req_id = Id, pending = maps:put(Id, From, State#state.pending)}};

handle_call({call_tool, ToolName, Args}, _From, State = #state{status = ready, transport = http}) ->
    Result = do_http_call_tool(State, ToolName, Args),
    {reply, Result, State};

handle_call(list_tools, _From, State) ->
    {reply, {ok, State#state.tools}, State};

handle_call(list_resources, _From, State) ->
    {reply, {ok, State#state.resources}, State};

handle_call({read_resource, Uri}, _From, State = #state{transport = stdio, status = ready}) ->
    Id = State#state.req_id + 1,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"resources/read">>,
        <<"params">> => #{<<"uri">> => Uri}
    },
    send_stdio(State#state.port, Msg),
    Result = receive_stdio_response(State#state.port, Id, ?CALL_TIMEOUT),
    {reply, Result, State#state{req_id = Id}};

handle_call({read_resource, Uri}, _From, State = #state{transport = http, status = ready}) ->
    Id = State#state.req_id + 1,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"resources/read">>,
        <<"params">> => #{<<"uri">> => Uri}
    },
    Headers = [{<<"Content-Type">>, <<"application/json">>} | State#state.headers],
    Result = case hackney:post(State#state.url, Headers, jsx:encode(Msg), [with_body, {recv_timeout, ?CALL_TIMEOUT}]) of
        {ok, 200, _, RespBody} ->
            Resp = jsx:decode(RespBody, [return_maps]),
            {ok, maps:get(<<"result">>, Resp, #{})};
        {ok, Status, _, _} ->
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end,
    {reply, Result, State#state{req_id = Id}};

handle_call(get_info, _From, State) ->
    Info = #{
        name => State#state.name,
        transport => State#state.transport,
        status => State#state.status,
        capabilities => State#state.capabilities,
        server_info => State#state.server_info,
        tool_count => length(State#state.tools),
        resource_count => length(State#state.resources),
        instructions => State#state.instructions
    },
    {reply, {ok, Info}, State};

handle_call(ping, _From, State = #state{status = ready, transport = stdio}) ->
    send_notification(State, <<"notifications/ping">>, #{}),
    {reply, ok, State};

handle_call(ping, _From, State = #state{status = ready, transport = http}) ->
    {reply, ok, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, {eol, Line}}}, State = #state{port = Port, pending = Pending}) ->
    case catch jsx:decode(list_to_binary(Line), [return_maps]) of
        #{<<"id">> := Id, <<"result">> := Result} ->
            case maps:get(Id, Pending, undefined) of
                undefined -> ok;
                From ->
                    TarhaResult = mcp_tool_result_to_tarha(Result),
                    gen_server:reply(From, TarhaResult)
            end,
            {noreply, State#state{pending = maps:remove(Id, Pending)}};
        #{<<"id">> := Id, <<"error">> := Error} ->
            case maps:get(Id, Pending, undefined) of
                undefined -> ok;
                From ->
                    gen_server:reply(From, {error, Error})
            end,
            {noreply, State#state{pending = maps:remove(Id, Pending)}};
        #{<<"method">> := <<"notifications/tools/list_changed">>} ->
            {ok, Tools} = do_list_tools(State),
            NewState = State#state{tools = Tools},
            notify_registry(NewState),
            {noreply, NewState};
        #{<<"method">> := <<"notifications/resources/list_changed">>} ->
            case do_list_resources(State) of
                {ok, Resources} ->
                    {noreply, State#state{resources = Resources}};
                _ ->
                    {noreply, State}
            end;
        #{<<"method">> := <<"notifications/resources/updated">>} ->
            {noreply, State};
        #{<<"method">> := <<"notifications/ping">>} ->
            {noreply, State};
        _ ->
            {noreply, State}
    end;

handle_info({Port, {data, {_Flag, _Data}}}, State = #state{port = Port}) ->
    {noreply, State};

handle_info({Port, {exit_status, Status}}, State = #state{port = Port}) ->
    case Status of
        0 -> ok;
        _ -> io:format("[mcp] Server ~s exited with status ~p~n", [State#state.name, Status])
    end,
    {noreply, State#state{status = error, error_reason = {exit_status, Status}}};

handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    io:format("[mcp] Server ~s port exited: ~p~n", [State#state.name, Reason]),
    {noreply, State#state{status = error, error_reason = Reason}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port}) when is_port(Port) ->
    catch port_close(Port),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

send_initialize(State = #state{port = Port}) ->
    Id = 1,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
            <<"capabilities">> => #{<<"roots">> => #{<<"listChanged">> => true}},
            <<"clientInfo">> => #{<<"name">> => <<"tarha">>, <<"version">> => <<"0.3.0">>}
        }
    },
    send_stdio(Port, Msg),
    receive_stdio_response(Port, Id, ?INIT_TIMEOUT).

do_list_tools(State = #state{port = Port}) ->
    Id = State#state.req_id + 2,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{}
    },
    send_stdio(Port, Msg),
    case receive_stdio_response(Port, Id, ?LIST_TIMEOUT) of
        {ok, Result} -> {ok, maps:get(<<"tools">>, Result, [])};
        Error -> Error
    end.

do_list_resources(State = #state{port = Port}) ->
    Id = State#state.req_id + 3,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"resources/list">>,
        <<"params">> => #{}
    },
    send_stdio(Port, Msg),
    case receive_stdio_response(Port, Id, ?LIST_TIMEOUT) of
        {ok, Result} -> {ok, maps:get(<<"resources">>, Result, [])};
        Error -> Error
    end.

do_http_call_tool(#state{url = Url, headers = Hdrs, req_id = ReqId}, ToolName, Args) ->
    Id = ReqId + 1,
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{<<"name">> => ToolName, <<"arguments">> => Args}
    },
    Headers = [{<<"Content-Type">>, <<"application/json">>} | Hdrs],
    case hackney:post(Url, Headers, jsx:encode(Msg), [with_body, {recv_timeout, ?CALL_TIMEOUT}]) of
        {ok, 200, _, RespBody} ->
            Resp = jsx:decode(RespBody, [return_maps]),
            case maps:get(<<"error">>, Resp, undefined) of
                undefined ->
                    mcp_tool_result_to_tarha(maps:get(<<"result">>, Resp, #{}));
                Error ->
                    {error, Error}
            end;
        {ok, Status, _, _} ->
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

send_stdio(Port, Msg) ->
    Data = iolist_to_binary([jsx:encode(Msg), $\n]),
    Port ! {self(), {command, Data}}.

send_notification(State = #state{port = Port}, Method, Params) ->
    Msg = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    },
    send_stdio(Port, Msg).

receive_stdio_response(Port, Id, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    receive_loop(Port, Id, Deadline).

receive_loop(Port, Id, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true -> {error, timeout};
        false ->
            Remaining = Deadline - Now,
            receive
                {Port, {data, {eol, Line}}} ->
                    case catch jsx:decode(list_to_binary(Line), [return_maps]) of
                        #{<<"id">> := Id, <<"result">> := Result} ->
                            {ok, Result};
                        #{<<"id">> := Id, <<"error">> := Error} ->
                            {error, Error};
                        _ ->
                            receive_loop(Port, Id, Deadline)
                    end;
                {Port, {exit_status, Status}} ->
                    {error, {server_exit, Status}};
                {Port, {data, _}} ->
                    receive_loop(Port, Id, Deadline)
            after Remaining ->
                {error, timeout}
            end
    end.

mcp_tool_result_to_tarha(McpResult) ->
    Content = maps:get(<<"content">>, McpResult, []),
    IsError = maps:get(<<"isError">>, McpResult, false),
    TextParts = [maps:get(<<"text">>, C, <<>>) || C <- Content, maps:get(<<"type">>, C, <<>>) == <<"text">>],
    ImageParts = [maps:get(<<"data">>, C, <<>>) || C <- Content, maps:get(<<"type">>, C, <<>>) == <<"image">>],
    Combined = iolist_to_binary(lists:join(<<"\n">>, TextParts ++ ImageParts)),
    case IsError of
        true -> {error, Combined};
        false -> {ok, Combined}
    end.

notify_registry(#state{name = Name, tools = Tools, resources = Resources, status = Status}) ->
    case whereis(coding_agent_mcp_registry) of
        undefined -> ok;
        _ -> coding_agent_mcp_registry:update_server(Name, Tools, Resources, Status)
    end.