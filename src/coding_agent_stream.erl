-module(coding_agent_stream).
-behaviour(gen_server).
-export([start_link/1, stream/3, stream/4, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([set_callback/2]).

-record(state, {
    model :: binary(),
    session :: pid() | undefined,
    request_id :: reference() | undefined,
    buffer :: binary(),
    thinking_buffer :: binary(),
    callback :: fun() | undefined,
    cancelled :: boolean()
}).

start_link(Model) ->
    gen_server:start_link(?MODULE, [Model], []).

stream(Pid, Messages, Tools) ->
    stream(Pid, Messages, Tools, fun(_, _) -> ok end).

stream(Pid, Messages, Tools, Callback) when is_function(Callback, 2) ->
    gen_server:call(Pid, {stream, Messages, Tools, Callback}, 30000).

cancel(Pid) ->
    gen_server:cast(Pid, cancel).

set_callback(Pid, Callback) when is_function(Callback, 2) ->
    gen_server:cast(Pid, {set_callback, Callback}).

init([Model]) ->
    ModelBin = if is_list(Model) -> list_to_binary(Model); true -> Model end,
    {ok, #state{
        model = ModelBin,
        buffer = <<>>,
        thinking_buffer = <<>>,
        cancelled = false
    }}.

handle_call({stream, Messages, Tools, Callback}, _From, State = #state{model = Model}) ->
    RequestId = make_ref(),
    case coding_agent_ollama:chat_stream_with_tools(Model, Messages, Tools, self(), RequestId) of
        {ok, _Pid} ->
            {noreply, State#state{
                request_id = RequestId,
                callback = Callback,
                buffer = <<>>,
                thinking_buffer = <<>>,
                cancelled = false
            }, 30000};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({set_callback, Callback}, State) ->
    {noreply, State#state{callback = Callback}};

handle_cast(cancel, State) ->
    {noreply, State#state{cancelled = true}}.

handle_info({stream_chunk, RequestId, Chunk, #{thinking := Thinking, content := Content}}, 
            State = #state{request_id = RequestId, callback = Callback, cancelled = Cancelled,
                          buffer = Buffer, thinking_buffer = ThinkBuffer}) ->
    case Cancelled of
        true -> {noreply, State};
        false ->
            NewBuffer = case Content of
                <<>> -> Buffer;
                _ -> <<Buffer/binary, Content/binary>>
            end,
            NewThinkBuffer = case Thinking of
                <<>> -> ThinkBuffer;
                _ -> <<ThinkBuffer/binary, Thinking/binary>>
            end,
            case Callback of
                undefined -> ok;
                Fun when is_function(Fun, 3) ->
                    try Fun(Content, Thinking, #{buffer => NewBuffer, thinking => NewThinkBuffer})
                    catch _:_ -> ok
                    end
            end,
            {noreply, State#state{buffer = NewBuffer, thinking_buffer = NewThinkBuffer}}
    end;

handle_info({stream_complete, RequestId, Response}, State = #state{request_id = RequestId}) ->
    FinalResponse = Response#{
        <<"content">> => State#state.buffer,
        <<"thinking">> => State#state.thinking_buffer
    },
    {stop, normal, {ok, FinalResponse}, State#state{request_id = undefined}};

handle_info({stream_error, RequestId, Reason}, State = #state{request_id = RequestId}) ->
    {stop, normal, {error, Reason}, State#state{request_id = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.