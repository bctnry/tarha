-module(coding_agent_session_store).
-export([start_link/0, save_session/2, load_session/1, delete_session/1, list_sessions/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-behaviour(gen_server).

-record(state, {dir :: string()}).
-define(SESSIONS_DIR, "sessions").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Dir = get_sessions_dir(),
    filelib:ensure_dir(Dir ++ "/"),
    {ok, #state{dir = Dir}}.

get_sessions_dir() ->
    case application:get_env(coding_agent, sessions_dir) of
        {ok, Dir} -> Dir;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> filename:join(Cwd, ?SESSIONS_DIR);
                _ -> ?SESSIONS_DIR
            end
    end.

handle_call({save, SessionId, Data}, _From, State = #state{dir = Dir}) ->
    Filename = session_file(Dir, SessionId),
    JsonData = jsx:encode(Data),
    case file:write_file(Filename, JsonData) of
        ok -> {reply, ok, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({load, SessionId}, _From, State = #state{dir = Dir}) ->
    Filename = session_file(Dir, SessionId),
    case file:read_file(Filename) of
        {ok, Content} ->
            case jsx:is_json(Content) of
                true ->
                    Data = jsx:decode(Content, [return_maps]),
                    {reply, {ok, Data}, State};
                false ->
                    {reply, {error, invalid_json}, State}
            end;
        {error, enoent} ->
            {reply, {error, not_found}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({delete, SessionId}, _From, State = #state{dir = Dir}) ->
    Filename = session_file(Dir, SessionId),
    case file:delete(Filename) of
        ok -> {reply, ok, State};
        {error, enoent} -> {reply, ok, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call(list, _From, State = #state{dir = Dir}) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            SessionIds = [iolist_to_binary(filename:rootname(F)) || F <- Files, filename:extension(F) =:= ".json"],
            {reply, {ok, SessionIds}, State};
        {error, enoent} ->
            {reply, {ok, []}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

session_file(Dir, SessionId) when is_binary(SessionId) ->
    filename:join(Dir, <<SessionId/binary, ".json">>);
session_file(Dir, SessionId) when is_list(SessionId) ->
    filename:join(Dir, SessionId ++ ".json").

%% Public API

save_session(SessionId, Data) when is_binary(SessionId); is_list(SessionId) ->
    gen_server:call(?MODULE, {save, SessionId, Data}).

load_session(SessionId) when is_binary(SessionId); is_list(SessionId) ->
    gen_server:call(?MODULE, {load, SessionId}).

delete_session(SessionId) when is_binary(SessionId); is_list(SessionId) ->
    gen_server:call(?MODULE, {delete, SessionId}).

list_sessions() ->
    gen_server:call(?MODULE, list).
