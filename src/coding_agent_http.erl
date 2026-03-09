-module(coding_agent_http).
-export([start_link/0, start_link/1, stop/0]).
-export([init/2]).

-define(DEFAULT_PORT, 8080).
-define(DEFAULT_HOST, "localhost").

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-methods">> => <<"GET, POST, PUT, DELETE, OPTIONS">>,
    <<"access-control-allow-headers">> => <<"Content-Type, Authorization, Accept, X-Requested-With, Origin, Cache-Control">>,
    <<"access-control-expose-headers">> => <<"Content-Type, Content-Length, X-Request-Id">>,
    <<"access-control-max-age">> => <<"86400">>
}).

start_link() ->
    start_link([]).

start_link(Options) ->
    Port = proplists:get_value(port, Options, ?DEFAULT_PORT),
    Host = proplists:get_value(host, Options, ?DEFAULT_HOST),
    
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/", ?MODULE, #{action => index}},
            {"/health", ?MODULE, #{action => health}},
            {"/status", ?MODULE, #{action => status}},
            {"/chat", ?MODULE, #{action => chat}},
            {"/chat/stream", ?MODULE, #{action => chat_stream}},
            {"/session", ?MODULE, #{action => session}},
            {"/session/:id", ?MODULE, #{action => session_info}},
            {"/session/:id/halt", ?MODULE, #{action => session_halt}},
            {"/session/:id/busy", ?MODULE, #{action => session_busy}},
            {"/session/:id/save", ?MODULE, #{action => session_save}},
            {"/session/:id/load", ?MODULE, #{action => session_load}},
            {"/session/:id/delete", ?MODULE, #{action => session_delete}},
            {"/sessions", ?MODULE, #{action => sessions_list}},
            {"/sessions/active", ?MODULE, #{action => active_sessions}},
            {"/memory", ?MODULE, #{action => memory}},
            {"/memory/history", ?MODULE, #{action => memory_history}},
            {"/memory/consolidate", ?MODULE, #{action => memory_consolidate}},
            {"/skills", ?MODULE, #{action => skills}},
            {"/skills/:name", ?MODULE, #{action => skill_detail}},
            {"/tools", ?MODULE, #{action => tools}},
            {"/models", ?MODULE, #{action => models}},
            {"/model", ?MODULE, #{action => model}},
            {"/model/:name", ?MODULE, #{action => model_show}}
        ]}
    ]),
    
    case cowboy:start_clear(http, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, _Ref} ->
            io:format("[http] Server started on http://~s:~p~n", [Host, Port]),
            {ok, #{port => Port, host => Host}};
        {error, Reason} ->
            io:format("[http] Failed to start on port ~p: ~p~n", [Port, Reason]),
            {error, Reason}
    end.

stop() ->
    cowboy:stop_listener(http).

init(Req, State) ->
    Action = maps:get(action, State, index),
    Method = cowboy_req:method(Req),
    
    case Method of
        <<"OPTIONS">> ->
            Req2 = cowboy_req:reply(204, ?CORS_HEADERS, <<>>, Req),
            {ok, Req2, State};
        _ ->
            try handle_action(Method, Action, Req) of
                {stream, Req2} ->
                    %% Streaming response - already handled
                    {ok, Req2, State};
                {ok, Response} ->
                    Headers = maps:merge(?CORS_HEADERS, #{<<"content-type">> => <<"application/json">>}),
                    Req2 = cowboy_req:reply(200, Headers, jsx:encode(Response), Req),
                    {ok, Req2, State};
                {error, Code, Reason} ->
                    Headers = maps:merge(?CORS_HEADERS, #{<<"content-type">> => <<"application/json">>}),
                    Req2 = cowboy_req:reply(Code, Headers, jsx:encode(#{error => Reason}), Req),
                    {ok, Req2, State}
            catch
                Type:Error:Stacktrace ->
                    io:format("[http] Error ~p:~p~n~p~n", [Type, Error, Stacktrace]),
                    Headers = maps:merge(?CORS_HEADERS, #{<<"content-type">> => <<"application/json">>}),
                    ErrorBinary = try iolist_to_binary(io_lib:format("~p", [Error]))
                                    catch _:_ -> <<"[error serializing]">> end,
                    ErrorBinary2 = case byte_size(ErrorBinary) of
                                      Size when Size > 500 -> <<(binary_part(ErrorBinary, 0, 500))/binary, "... (truncated)">>;
                                      _ -> ErrorBinary
                                  end,
                    Req2 = cowboy_req:reply(500, Headers, 
                        jsx:encode(#{error => internal_error, details => ErrorBinary2}), Req),
                    {ok, Req2, State}
            end
    end.

%% API endpoints

handle_action(<<"GET">>, index, _Req) ->
    {ok, #{
        name => <<"coding_agent">>,
        version => <<"0.5.0">>,
        endpoints => [
            #{method => <<"GET">>, path => <<"/">>, description => <<"API info">>},
            #{method => <<"GET">>, path => <<"/health">>, description => <<"Health check">>},
            #{method => <<"GET">>, path => <<"/status">>, description => <<"Agent status">>},
            #{method => <<"POST">>, path => <<"/chat">>, description => <<"Send message to agent">>},
            #{method => <<"POST">>, path => <<"/chat/stream">>, description => <<"Stream response with thinking">>},
            #{method => <<"POST">>, path => <<"/session">>, description => <<"Create session">>},
            #{method => <<"GET">>, path => <<"/session/:id">>, description => <<"Get session info">>},
            #{method => <<"POST">>, path => <<"/session/:id/halt">>, description => <<"Halt active LLM request">>},
            #{method => <<"GET">>, path => <<"/session/:id/busy">>, description => <<"Check if session is busy">>},
            #{method => <<"POST">>, path => <<"/session/:id/save">>, description => <<"Save session to disk">>},
            #{method => <<"POST">>, path => <<"/session/:id/load">>, description => <<"Load session from disk">>},
            #{method => <<"GET">>, path => <<"/sessions">>, description => <<"List saved sessions">>},
            #{method => <<"GET">>, path => <<"/sessions/active">>, description => <<"List active sessions">>},
            #{method => <<"GET">>, path => <<"/memory">>, description => <<"Get long-term memory">>},
            #{method => <<"POST">>, path => <<"/memory">>, description => <<"Update long-term memory">>},
            #{method => <<"GET">>, path => <<"/memory/history">>, description => <<"Get conversation history log">>},
            #{method => <<"POST">>, path => <<"/memory/consolidate">>, description => <<"Trigger memory consolidation">>},
            #{method => <<"GET">>, path => <<"/skills">>, description => <<"List available skills">>},
            #{method => <<"GET">>, path => <<"/skills/:name">>, description => <<"Get skill content">>},
            #{method => <<"GET">>, path => <<"/tools">>, description => <<"List available tools">>},
            #{method => <<"GET">>, path => <<"/models">>, description => <<"List available Ollama models">>},
            #{method => <<"POST">>, path => <<"/model">>, description => <<"Switch current Ollama model">>},
            #{method => <<"GET">>, path => <<"/model/:name">>, description => <<"Show model details">>}
        ]
    }};

handle_action(<<"GET">>, health, _Req) ->
    {ok, #{
        status => healthy,
        memory => erlang:memory(total),
        processes => erlang:system_info(process_count),
        uptime => erlang:system_time(millisecond)
    }};

handle_action(<<"GET">>, status, _Req) ->
    {ok, #{
        memory => get_memory_status(),
        sessions => get_session_count(),
        tools => length(coding_agent_tools:tools())
    }};

handle_action(<<"POST">>, chat, Req) ->
    {ok, Body, _} = cowboy_req:read_body(Req),
    case jsx:is_json(Body) of
        true ->
            Data = jsx:decode(Body, [return_maps]),
            Message = maps:get(<<"message">>, Data, <<>>),
            SessionId = maps:get(<<"session_id">>, Data, undefined),
            send_message(Message, SessionId);
        false ->
            {error, 400, invalid_json}
    end;

handle_action(<<"POST">>, chat_stream, Req) ->
    {ok, Body, _} = cowboy_req:read_body(Req),
    case jsx:is_json(Body) of
        true ->
            Data = jsx:decode(Body, [return_maps]),
            Message = maps:get(<<"message">>, Data, <<>>),
            SessionId = maps:get(<<"session_id">>, Data, undefined),
            start_stream_response(Req, Message, SessionId);
        false ->
            {error, 400, invalid_json}
    end;

handle_action(<<"POST">>, session, Req) ->
    {ok, Body, _} = cowboy_req:read_body(Req),
    case jsx:is_json(Body) of
        true ->
            Data = jsx:decode(Body, [return_maps]),
            Action = maps:get(<<"action">>, Data, <<"create">>),
            handle_session_action(Action, Data);
        false ->
            {error, 400, invalid_json}
    end;

handle_action(<<"GET">>, session_info, Req) ->
    SessionId = cowboy_req:binding(id, Req),
    get_session_status(SessionId);

handle_action(<<"POST">>, session_save, Req) ->
    SessionId = cowboy_req:binding(id, Req),
    case coding_agent_session:save_session(SessionId) of
        {ok, Id} -> {ok, #{session_id => Id, status => saved}};
        {error, session_not_found} -> {error, 404, session_not_found};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

handle_action(<<"POST">>, session_load, Req) ->
    SessionId = cowboy_req:binding(id, Req),
    case coding_agent_session:load_session(SessionId) of
        {ok, {Id, _Pid}} -> {ok, #{session_id => Id, status => loaded}};
        {error, session_not_found} -> {error, 404, session_not_found};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

handle_action(<<"POST">>, session_delete, Req) ->
    SessionId = cowboy_req:binding(id, Req),
    case coding_agent_session:delete_saved_session(SessionId) of
        ok -> {ok, #{session_id => SessionId, status => deleted}};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

handle_action(<<"GET">>, sessions_list, _Req) ->
    case coding_agent_session:list_saved_sessions() of
        {ok, SessionIds} ->
            %% Load each session's summary info
            Sessions = lists:filtermap(fun(SessionId) ->
                SessionIdBin = if is_binary(SessionId) -> SessionId; true -> iolist_to_binary(SessionId) end,
                case coding_agent_session_store:load_session(SessionIdBin) of
                    {ok, Data} ->
                        %% Extract summary info
                        Summary = #{
                            id => SessionIdBin,
                            model => maps:get(<<"model">>, Data, <<"unknown">>),
                            messages => length(maps:get(<<"messages">>, Data, [])),
                            prompt_tokens => maps:get(<<"prompt_tokens">>, Data, 0),
                            completion_tokens => maps:get(<<"completion_tokens">>, Data, 0),
                            total_tokens => maps:get(<<"total_tokens">>, Data, 0),
                            tool_calls => maps:get(<<"tool_calls">>, Data, 0),
                            working_dir => maps:get(<<"working_dir">>, Data, <<"">>),
                            status => <<"saved">>
                        },
                        {true, Summary};
                    {error, _} -> false
                end
            end, SessionIds),
            {ok, #{sessions => Sessions, count => length(Sessions)}};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

handle_action(<<"GET">>, active_sessions, _Req) ->
    Sessions = coding_agent_session:sessions(),
    SessionList = lists:map(fun({Id, Pid}) ->
        case coding_agent_session:stats(Id) of
            {ok, Stats} -> Stats#{pid => pid_to_list(Pid)};
            {error, _} -> #{id => Id, pid => pid_to_list(Pid)}
        end
    end, Sessions),
    {ok, #{sessions => SessionList, count => length(SessionList)}};

handle_action(<<"GET">>, tools, _Req) ->
    Tools = coding_agent_tools:tools(),
    {ok, #{
        count => length(Tools),
        tools => [format_tool(T) || T <- Tools]
    }};

handle_action(<<"GET">>, memory, _Req) ->
    case whereis(coding_agent_conv_memory) of
        undefined -> {ok, #{memory => <<>>, status => not_running}};
        _ ->
            {ok, Memory} = coding_agent_conv_memory:get_memory(),
            {ok, #{memory => Memory, status => running}}
    end;

handle_action(<<"POST">>, memory, Req) ->
    {ok, Body, _} = cowboy_req:read_body(Req),
    case jsx:is_json(Body) of
        true ->
            Data = jsx:decode(Body, [return_maps]),
            Content = maps:get(<<"content">>, Data, <<>>),
            case whereis(coding_agent_conv_memory) of
                undefined -> {error, 503, memory_not_running};
                _ ->
                    coding_agent_conv_memory:update_memory(Content),
                    {ok, #{status => updated}}
            end;
        false ->
            {error, 400, invalid_json}
    end;

handle_action(<<"GET">>, memory_history, _Req) ->
    case whereis(coding_agent_conv_memory) of
        undefined -> {ok, #{history => <<>>, status => not_running}};
        _ ->
            {ok, History} = coding_agent_conv_memory:get_history(),
            {ok, #{history => History, status => running}}
    end;

handle_action(<<"POST">>, memory_consolidate, _Req) ->
    case whereis(coding_agent_conv_memory) of
        undefined -> {error, 503, memory_not_running};
        _ ->
            case coding_agent_conv_memory:consolidate() of
                {ok, Result} -> {ok, #{status => ok, result => Result}};
                {error, Reason} -> {error, 500, io_lib:format("~p", [Reason])}
            end
    end;

handle_action(<<"GET">>, skills, _Req) ->
    case whereis(coding_agent_skills) of
        undefined -> {ok, #{skills => [], status => not_running}};
        _ ->
            case coding_agent_skills:list_skills() of
                {ok, Skills} -> {ok, #{skills => Skills, status => running}};
                _ -> {ok, #{skills => [], status => error}}
            end
    end;

handle_action(<<"GET">>, skill_detail, Req) ->
    SkillName = cowboy_req:binding(name, Req),
    case whereis(coding_agent_skills) of
        undefined -> {error, 503, skills_not_running};
        _ ->
            case coding_agent_skills:load_skill(SkillName) of
                {ok, <<>>} -> {error, 404, skill_not_found};
                {ok, Content} -> {ok, #{name => SkillName, content => Content}};
                _ -> {error, 500, skill_load_error}
            end
    end;

handle_action(<<"GET">>, models, _Req) ->
    case coding_agent_ollama:list_models() of
        {ok, Models} -> {ok, #{models => Models, count => length(Models)}};
        {error, Reason} -> {error, 500, io_lib:format("~p", [Reason])}
    end;

handle_action(<<"POST">>, model, Req) ->
    {ok, Body, _} = cowboy_req:read_body(Req),
    case jsx:is_json(Body) of
        true ->
            Data = jsx:decode(Body, [return_maps]),
            Model = maps:get(<<"model">>, Data, undefined),
            case Model of
                undefined -> {error, 400, missing_model};
                _ ->
                    case coding_agent_ollama:switch_model(Model) of
                        {ok, OldModel, NewModel} -> 
                            {ok, #{status => switched, old_model => OldModel, new_model => NewModel}};
                        {error, Reason} -> 
                            {error, 500, io_lib:format("~p", [Reason])}
                    end
            end;
        false ->
            {error, 400, invalid_json}
    end;

handle_action(<<"GET">>, model_show, Req) ->
    ModelName = cowboy_req:binding(name, Req),
    case coding_agent_ollama:show_model(ModelName, #{}) of
        {ok, ModelInfo} ->
            {ok, #{
                model => ModelName,
                details => maps:get(<<"details">>, ModelInfo, #{}),
                capabilities => maps:get(<<"capabilities">>, ModelInfo, []),
                parameters => maps:get(<<"parameters">>, ModelInfo, undefined),
                license => maps:get(<<"license">>, ModelInfo, undefined),
                modified_at => maps:get(<<"modified_at">>, ModelInfo, undefined),
                template => maps:get(<<"template">>, ModelInfo, undefined),
                model_info => maps:get(<<"model_info">>, ModelInfo, #{})
            }};
        {error, Reason} ->
            {error, 500, io_lib:format("~p", [Reason])}
    end;

%% Halt the current LLM request for a session
handle_action(<<"POST">>, session_halt, Req) ->
    SessionId = cowboy_req:binding(id, Req),
    case coding_agent_session:halt(SessionId) of
        ok -> {ok, #{session_id => SessionId, status => halted}};
        {error, no_active_request} -> {ok, #{session_id => SessionId, status => idle, message => <<"No active request to halt">>}};
        {error, session_not_found} -> {error, 404, session_not_found};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

%% Check if session is busy processing a request
handle_action(<<"GET">>, session_busy, Req) ->
    SessionId = cowboy_req:binding(id, Req),
    case coding_agent_session:is_busy(SessionId) of
        {ok, Busy} -> {ok, #{session_id => SessionId, busy => Busy}};
        {error, session_not_found} -> {error, 404, session_not_found};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

handle_action(_, _, _Req) ->
    {error, 404, not_found}.

%% Helper functions

get_memory_status() ->
    case ets:info(coding_agent_sessions) of
        undefined -> #{status => not_running};
        _ -> #{
            sessions => get_session_count()
        }
    end.

get_session_count() ->
    case whereis(coding_agent_sessions) of
        undefined -> 0;
        _ ->
            case ets:info(coding_agent_sessions, size) of
                N when is_integer(N) -> N;
                _ -> 0
            end
    end.

get_session_status(SessionId) when is_binary(SessionId) ->
    %% First check if it's an active session
    case coding_agent_session:stats(SessionId) of
        {ok, Stats} -> 
            {ok, Stats#{status => <<"active">>}};
        {error, not_found} ->
            %% Not active, check if it's a saved session
            case coding_agent_session_store:load_session(SessionId) of
                {ok, Data} ->
                    %% Extract summary info from saved session
                    Summary = #{
                        id => SessionId,
                        model => maps:get(<<"model">>, Data, <<"unknown">>),
                        message_count => length(maps:get(<<"messages">>, Data, [])),
                        messages => maps:get(<<"messages">>, Data, []),
                        prompt_tokens => maps:get(<<"prompt_tokens">>, Data, 0),
                        completion_tokens => maps:get(<<"completion_tokens">>, Data, 0),
                        total_tokens => maps:get(<<"total_tokens">>, Data, 0),
                        tool_calls => maps:get(<<"tool_calls">>, Data, 0),
                        working_dir => maps:get(<<"working_dir">>, Data, <<>>),
                        status => <<"saved">>
                    },
                    {ok, Summary};
                {error, _} ->
                    {error, 404, session_not_found}
            end;
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end.

send_message(Message, undefined) ->
    {ok, {SessionId, _Pid}} = coding_agent_session:new(),
    send_message(Message, SessionId);
send_message(Message, SessionId) when is_binary(SessionId) ->
    case coding_agent_session:ask(SessionId, Message) of
        {ok, Response, Thinking, _History} ->
            {ok, #{
                session_id => SessionId,
                response => Response,
                thinking => Thinking
            }};
        {error, session_not_found} ->
            {ok, {NewSessionId, _Pid}} = coding_agent_session:new(),
            send_message(Message, NewSessionId);
        {error, Reason} ->
            {error, 500, io_lib:format("Session error: ~p", [Reason])}
    end.

handle_session_action(<<"create">>, _Data) ->
    case coding_agent_session:new() of
        {ok, {SessionId, _Pid}} ->
            {ok, #{session_id => SessionId}};
        {error, Reason} ->
            {error, 500, io_lib:format("Failed to create session: ~p", [Reason])}
    end;
handle_session_action(<<"clear">>, Data) ->
    SessionId = maps:get(<<"session_id">>, Data, undefined),
    case SessionId of
        undefined -> {error, 400, missing_session_id};
        _ ->
            coding_agent_session:clear(SessionId),
            {ok, #{status => cleared}}
    end;
handle_session_action(_, _) ->
    {error, 400, unknown_action}.

format_tool(Tool) ->
    #{
        name => maps:get(<<"name">>, maps:get(<<"function">>, Tool, #{}), <<"unknown">>),
        description => maps:get(<<"description">>, maps:get(<<"function">>, Tool, #{}), <<"">>)
    }.

%% Streaming chat endpoint - returns Server-Sent Events

start_stream_response(Req, Message, SessionId) ->
    %% Get or create session
    {ok, {FinalSessionId, _Pid}} = case SessionId of
        undefined -> coding_agent_session:new();
        _ -> case ets:lookup(coding_agent_sessions, SessionId) of
            [{_, ExistingPid}] -> {ok, {SessionId, ExistingPid}};
            [] -> coding_agent_session:new()
        end
    end,
    
    %% Set up SSE headers
    SSEHeaders = maps:merge(?CORS_HEADERS, #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>
    }),
    
    %% Initialize streaming response
    Req2 = cowboy_req:stream_reply(200, SSEHeaders, Req),
    
    %% Send initial session ID
    cowboy_req:stream_body(
        iolist_to_binary([<<"data: ">>, jsx:encode(#{type => <<"session">>, session_id => FinalSessionId}), <<"\n\n">>]),
        nofin, Req2),
    
    %% Run the query and stream events
    cowboy_req:stream_body(
        iolist_to_binary([<<"data: ">>, jsx:encode(#{type => <<"status">>, status => <<"thinking">>}), <<"\n\n">>]),
        nofin, Req2),
    
    %% Call session (blocking, but returns full result)
    Result = coding_agent_session:ask(FinalSessionId, Message),
    
    case Result of
        {ok, Response, Thinking, _History} ->
            %% Stream thinking if present
            case Thinking of
                <<>> -> ok;
                _ ->
                    cowboy_req:stream_body(
                        iolist_to_binary([<<"data: ">>, jsx:encode(#{type => <<"thinking">>, content => Thinking}), <<"\n\n">>]),
                        nofin, Req2)
            end,
            %% Stream response
            cowboy_req:stream_body(
                iolist_to_binary([<<"data: ">>, jsx:encode(#{type => <<"response">>, content => Response}), <<"\n\n">>]),
                nofin, Req2),
            %% Send done event
            cowboy_req:stream_body(
                iolist_to_binary([<<"data: ">>, jsx:encode(#{type => <<"done">>}), <<"\n\n">>]),
                fin, Req2);
        {error, Reason} ->
            cowboy_req:stream_body(
                iolist_to_binary([<<"data: ">>, jsx:encode(#{type => <<"error">>, error => io_lib:format("~p", [Reason])}), <<"\n\n">>]),
                fin, Req2)
    end,
    
    {stream, Req2}.