-module(coding_agent_telemetry).
-behaviour(gen_server).

-export([start_link/0, record/2, get_metrics/0, get_summary/0, get_events/2, enable/0, disable/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TELEMETRY_DIR, ".tarha/telemetry").
-define(MAX_EVENTS, 10000).

-record(event, {
    timestamp :: integer(),
    type :: atom(),
    session_id :: binary() | undefined,
    data :: map()
}).

-record(state, {
    enabled :: boolean(),
    events :: [#event{}],
    metrics :: #{atom() => integer() | float()},
    output_dir :: string()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

record(Type, Data) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> gen_server:cast(?MODULE, {record, Type, Data})
    end.

get_metrics() ->
    case whereis(?MODULE) of
        undefined -> #{};
        _Pid -> gen_server:call(?MODULE, get_metrics, 5000)
    end.

get_summary() ->
    case whereis(?MODULE) of
        undefined -> #{total_sessions => 0, total_tokens => 0, total_tool_calls => 0, total_errors => 0};
        _Pid -> gen_server:call(?MODULE, get_summary, 5000)
    end.

get_events(Type, Since) ->
    case whereis(?MODULE) of
        undefined -> [];
        _Pid -> gen_server:call(?MODULE, {get_events, Type, Since}, 5000)
    end.

enable() ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?MODULE, enable, 5000)
    end.

disable() ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        _Pid -> gen_server:call(?MODULE, disable, 5000)
    end.

init([]) ->
    OutputDir = filename:join(coding_agent_config:workspace(), ?TELEMETRY_DIR),
    filelib:ensure_dir(OutputDir ++ "/"),
    {ok, #state{enabled = true, events = [], metrics = #{total_api_calls => 0, total_tool_calls => 0, total_tokens => 0, total_errors => 0, avg_api_latency_ms => 0.0}, output_dir = OutputDir}}.

handle_cast({record, _Type, _Data}, State = #state{enabled = false}) ->
    {noreply, State};

handle_cast({record, Type, Data}, State = #state{enabled = true, events = Events, metrics = Metrics}) ->
    Event = #event{
        timestamp = erlang:system_time(millisecond),
        type = Type,
        session_id = maps:get(session_id, Data, undefined),
        data = Data
    },
    NewEvents = case length(Events) >= ?MAX_EVENTS of
        true -> lists:sublist(Events, ?MAX_EVENTS - 1) ++ [Event];
        false -> Events ++ [Event]
    end,
    NewMetrics = update_metrics(Type, Data, Metrics),
    ok = maybe_write_event(Event, State#state.output_dir),
    {noreply, State#state{events = NewEvents, metrics = NewMetrics}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_call(get_metrics, _From, State = #state{metrics = Metrics}) ->
    {reply, Metrics, State};

handle_call(get_summary, _From, State = #state{metrics = Metrics}) ->
    Summary = Metrics#{
        total_sessions => maps:get(total_sessions, Metrics, 0),
        tool_breakdown => maps:get(tool_breakdown, Metrics, #{}),
        model_breakdown => maps:get(model_breakdown, Metrics, #{})
    },
    {reply, Summary, State};

handle_call({get_events, Type, Since}, _From, State = #state{events = Events}) ->
    Filtered = lists:filter(fun(E) ->
        E#event.type =:= Type andalso E#event.timestamp >= Since
    end, Events),
    {reply, Filtered, State};

handle_call(enable, _From, State) ->
    {reply, ok, State#state{enabled = true}};

handle_call(disable, _From, State) ->
    {reply, ok, State#state{enabled = false}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

update_metrics(api_call, Data, Metrics) ->
    _Key = case maps:get(model, Data, undefined) of
        undefined -> total_api_calls;
        _Model -> model_api_calls
    end,
    Metrics#{
        total_api_calls => maps:get(total_api_calls, Metrics, 0) + 1,
        total_tokens => maps:get(total_tokens, Metrics, 0) + maps:get(prompt_tokens, Data, 0) + maps:get(completion_tokens, Data, 0),
        avg_api_latency_ms => case maps:get(duration_ms, Data, undefined) of
            undefined -> maps:get(avg_api_latency_ms, Metrics, 0.0);
            Dur -> (maps:get(avg_api_latency_ms, Metrics, 0.0) + Dur) / 2
        end
    };

update_metrics(tool_call, Data, Metrics) ->
    ToolName = maps:get(tool_name, Data, <<"unknown">>),
    ToolBreakdown = maps:get(tool_breakdown, Metrics, #{}),
    NewToolBreakdown = maps:update_with(ToolName, fun(V) -> V + 1 end, 1, ToolBreakdown),
    Metrics#{
        total_tool_calls => maps:get(total_tool_calls, Metrics, 0) + 1,
        tool_breakdown => NewToolBreakdown
    };

update_metrics(error, _Data, Metrics) ->
    Metrics#{
        total_errors => maps:get(total_errors, Metrics, 0) + 1
    };

update_metrics(session_start, _Data, Metrics) ->
    Metrics#{
        total_sessions => maps:get(total_sessions, Metrics, 0) + 1
    };

update_metrics(session_end, Data, Metrics) ->
    Metrics#{
        total_tokens => maps:get(total_tokens, Metrics, 0) + maps:get(total_tokens, Data, 0)
    };

update_metrics(compaction, _Data, Metrics) ->
    Metrics#{
        total_compactions => maps:get(total_compactions, Metrics, 0) + 1
    };

update_metrics(_, _Data, Metrics) ->
    Metrics.

maybe_write_event(Event, OutputDir) ->
    DateStr = format_date(Event#event.timestamp),
    File = filename:join(OutputDir, DateStr ++ ".jsonl"),
    Line = jsx:encode(#{
        timestamp => Event#event.timestamp,
        type => Event#event.type,
        session_id => case Event#event.session_id of undefined -> null; Id -> Id end,
        data => Event#event.data
    }),
    try
        file:write_file(File, <<Line/binary, "\n">>, [append])
    catch
        _:_ -> ok
    end.

format_date(TimestampMs) when is_integer(TimestampMs) ->
    Seconds = TimestampMs div 1000,
    {{Year, Month, Day}, _Time} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(io_lib:format("~4..0w-~2..0w-~2..0w", [Year, Month, Day]));
format_date(_) ->
    <<"unknown">>.