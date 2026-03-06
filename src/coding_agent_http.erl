-module(coding_agent_http).
-export([start_link/0, start_link/1, stop/0]).
-export([init/2]).

-define(DEFAULT_PORT, 8080).
-define(DEFAULT_HOST, "localhost").

-define(CORS_HEADERS, #{
    <<"access-control-allow-origin">> => <<"*">>,
    <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
    <<"access-control-allow-headers">> => <<"Content-Type, Authorization">>
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
            {"/session", ?MODULE, #{action => session}},
            {"/session/:id", ?MODULE, #{action => session_info}},
            {"/session/:id/save", ?MODULE, #{action => session_save}},
            {"/session/:id/load", ?MODULE, #{action => session_load}},
            {"/sessions", ?MODULE, #{action => sessions_list}},
            {"/memory", ?MODULE, #{action => memory}},
            {"/memory/history", ?MODULE, #{action => memory_history}},
            {"/memory/consolidate", ?MODULE, #{action => memory_consolidate}},
            {"/skills", ?MODULE, #{action => skills}},
            {"/skills/:name", ?MODULE, #{action => skill_detail}},
            {"/tools", ?MODULE, #{action => tools}}
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
                    Req2 = cowboy_req:reply(500, Headers, 
                        jsx:encode(#{error => internal_error, details => io_lib:format("~p", [Error])}), Req),
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
            #{method => <<"POST">>, path => <<"/session">>, description => <<"Create session">>},
            #{method => <<"GET">>, path => <<"/session/:id">>, description => <<"Get session info">>},
            #{method => <<"POST">>, path => <<"/session/:id/save">>, description => <<"Save session to disk">>},
            #{method => <<"POST">>, path => <<"/session/:id/load">>, description => <<"Load session from disk">>},
            #{method => <<"GET">>, path => <<"/sessions">>, description => <<"List saved sessions">>},
            #{method => <<"GET">>, path => <<"/memory">>, description => <<"Get long-term memory">>},
            #{method => <<"POST">>, path => <<"/memory">>, description => <<"Update long-term memory">>},
            #{method => <<"GET">>, path => <<"/memory/history">>, description => <<"Get conversation history log">>},
            #{method => <<"POST">>, path => <<"/memory/consolidate">>, description => <<"Trigger memory consolidation">>},
            #{method => <<"GET">>, path => <<"/skills">>, description => <<"List available skills">>},
            #{method => <<"GET">>, path => <<"/skills/:name">>, description => <<"Get skill content">>},
            #{method => <<"GET">>, path => <<"/tools">>, description => <<"List available tools">>}
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

handle_action(<<"GET">>, sessions_list, _Req) ->
    case coding_agent_session:list_saved_sessions() of
        {ok, SessionIds} -> {ok, #{sessions => SessionIds, count => length(SessionIds)}};
        {error, Reason} -> {error, 500, io_lib:format("Error: ~p", [Reason])}
    end;

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
    case coding_agent_session:stats(SessionId) of
        {ok, Stats} -> {ok, Stats};
        {error, not_found} -> {error, 404, session_not_found};
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