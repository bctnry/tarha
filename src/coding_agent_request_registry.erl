%%%-------------------------------------------------------------------
%%% @doc Request Registry - tracks ongoing LLM requests for cancellation
%%% 
%%% This module tracks active HTTP requests to the Ollama API and allows
%%% them to be cancelled/halted. Each session can have one active request.
%%% 
%%% Additionally, it tracks cancellation flags for stopping long-running
%%% tool call chains. A session's agent loop will check this flag before
%%% each iteration and stop if cancelled.
%%% @end
%%%-------------------------------------------------------------------
-module(coding_agent_request_registry).
-behaviour(gen_server).

-export([start_link/0, register/2, unregister/1, get_request/1, halt/1, halt_all/0, get_active/0]).
-export([set_cancelling/1, clear_cancelling/1, is_cancelling/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, coding_agent_active_requests).
-define(CANCEL_TABLE, coding_agent_cancellation_flags).

-record(state, {}).

%% @doc Start the registry
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register an active request for a session
%% Returns ok if registered, {error, already_exists} if session already has a request
-spec register(binary(), reference()) -> ok | {error, term()}.
register(SessionId, RequestRef) when is_binary(SessionId), is_reference(RequestRef) ->
    %% Get the actual calling process pid
    CallerPid = self(),
    gen_server:call(?SERVER, {register, SessionId, RequestRef, CallerPid}).

%% @doc Unregister a request (called when request completes)
-spec unregister(binary()) -> ok.
unregister(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?SERVER, {unregister, SessionId}).

%% @doc Get the request reference for a session
-spec get_request(binary()) -> {ok, reference()} | {error, not_found}.
get_request(SessionId) when is_binary(SessionId) ->
    case ets:lookup(?TABLE, SessionId) of
        [{_, Ref, _Pid}] -> {ok, Ref};
        [] -> {error, not_found}
    end.

%% @doc Halt/cancel the active request for a session
-spec halt(binary()) -> ok | {error, not_found}.
halt(SessionId) when is_binary(SessionId) ->
    gen_server:call(?SERVER, {halt, SessionId}).

%% @doc Halt all active requests
-spec halt_all() -> ok.
halt_all() ->
    gen_server:call(?SERVER, halt_all).

%% @doc Get list of all active requests
-spec get_active() -> [{binary(), reference(), pid()}].
get_active() ->
    gen_server:call(?SERVER, get_active).

%% @doc Set the cancellation flag for a session's agent loop
%% This tells the agent loop to stop after completing current tool execution
-spec set_cancelling(binary()) -> ok.
set_cancelling(SessionId) when is_binary(SessionId) ->
    gen_server:call(?SERVER, {set_cancelling, SessionId}).

%% @doc Clear the cancellation flag for a session (called when loop exits)
-spec clear_cancelling(binary()) -> ok.
clear_cancelling(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?SERVER, {clear_cancelling, SessionId}).

%% @doc Check if a session's agent loop should stop
-spec is_cancelling(binary()) -> boolean().
is_cancelling(SessionId) when is_binary(SessionId) ->
    case ets:lookup(?CANCEL_TABLE, SessionId) of
        [{_, true}] -> true;
        _ -> false
    end.

%% Gen server callbacks

init([]) ->
    ets:new(?TABLE, [named_table, public, set]),
    ets:new(?CANCEL_TABLE, [named_table, public, set]),
    {ok, #state{}}.

handle_call({register, SessionId, RequestRef, CallerPid}, _From, State) ->
    %% Store the request with the caller's pid for notification
    case ets:lookup(?TABLE, SessionId) of
        [] ->
            ets:insert(?TABLE, {SessionId, RequestRef, CallerPid}),
            {reply, ok, State};
        [_] ->
            {reply, {error, already_exists}, State}
    end;

handle_call({halt, SessionId}, _From, State) ->
    case ets:lookup(?TABLE, SessionId) of
        [{SessionId, Ref, Pid}] ->
            %% Cancel the hackney request
            hackney_manager:cancel_request(Ref),
            %% Notify the session process
            Pid ! {request_halted, SessionId, Ref},
            ets:delete(?TABLE, SessionId),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call(halt_all, _From, State) ->
    Active = ets:tab2list(?TABLE),
    lists:foreach(fun({SessionId, Ref, Pid}) ->
        hackney_manager:cancel_request(Ref),
        Pid ! {request_halted, SessionId, Ref}
    end, Active),
    ets:delete_all_objects(?TABLE),
    {reply, ok, State};

handle_call(get_active, _From, State) ->
    Active = [{S, R, P} || {S, R, P} <- ets:tab2list(?TABLE)],
    {reply, Active, State}.

handle_cast({unregister, SessionId}, State) ->
    ets:delete(?TABLE, SessionId),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.