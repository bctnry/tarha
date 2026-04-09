-module(coding_agent_lifeline).
-behaviour(gen_server).

%% Public API
-export([start_link/0, status/0, get_crash_count/0, reset_crash_count/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(REPORT_DIR, ".tarha/reports").
-define(INITIAL_BACKOFF_MS, 5000).
-define(MAX_BACKOFF_MS, 60000).
-define(MAX_RESTARTS, 10).
-define(RESTART_WINDOW_MS, 300000).
-define(STABLE_MS, 60000).

-record(state, {
    sup_pid :: pid() | undefined,
    sup_ref :: reference() | undefined,
    backoff = ?INITIAL_BACKOFF_MS :: integer(),
    crash_timestamps = [] :: [integer()],
    restart_count = 0 :: integer(),
    giving_up = false :: boolean()
}).

%%===================================================================
%% Public API
%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

status() ->
    gen_server:call(?MODULE, status).

get_crash_count() ->
    gen_server:call(?MODULE, get_crash_count).

reset_crash_count() ->
    gen_server:call(?MODULE, reset_crash_count).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    filelib:ensure_dir(?REPORT_DIR ++ "/"),
    {ok, start_supervisor(#state{})}.

handle_call(status, _From, State) ->
    Info = #{
        sup_pid => State#state.sup_pid,
        giving_up => State#state.giving_up,
        restart_count => State#state.restart_count,
        backoff => State#state.backoff,
        recent_crashes => length(State#state.crash_timestamps)
    },
    {reply, {ok, Info}, State};

handle_call(get_crash_count, _From, State) ->
    {reply, State#state.restart_count, State};

handle_call(reset_crash_count, _From, State) ->
    {reply, ok, State#state{crash_timestamps = [], restart_count = 0,
                            backoff = ?INITIAL_BACKOFF_MS, giving_up = false}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, Reason}, #state{sup_ref = Ref, sup_pid = Pid} = State) ->
    io:format("[lifeline] Main supervisor DOWN: ~p~n", [Reason]),
    write_crash_report(Reason, Pid, State),
    Now = erlang:system_time(millisecond),
    RecentCrashes = prune_crashes(Now, State#state.crash_timestamps),
    NewCrashes = [Now | RecentCrashes],
    case State#state.giving_up of
        true ->
            io:format("[lifeline] Already gave up — not restarting~n"),
            {noreply, State#state{sup_pid = undefined, sup_ref = undefined}};
        false ->
            case length(NewCrashes) >= ?MAX_RESTARTS of
                true ->
                    io:format("[lifeline] Max restarts (~p in ~p ms) exceeded — giving up~n",
                              [?MAX_RESTARTS, ?RESTART_WINDOW_MS]),
                    write_give_up_report(Now, NewCrashes),
                    {noreply, State#state{sup_pid = undefined, sup_ref = undefined,
                                          crash_timestamps = NewCrashes, giving_up = true}};
                false ->
                    Backoff = State#state.backoff,
                    io:format("[lifeline] Restarting supervisor in ~p ms (attempt ~p)~n",
                              [Backoff, length(NewCrashes)]),
                    erlang:send_after(Backoff, self(), restart_supervisor),
                    NewBackoff = min(Backoff * 2, ?MAX_BACKOFF_MS),
                    {noreply, State#state{sup_pid = undefined, sup_ref = undefined,
                                          crash_timestamps = NewCrashes,
                                          backoff = NewBackoff,
                                          restart_count = State#state.restart_count + 1}}
            end
    end;

handle_info(restart_supervisor, State) ->
    case State#state.giving_up of
        true ->
            {noreply, State};
        false ->
            NewState = start_supervisor(State),
            {noreply, NewState}
    end;

handle_info(check_stable, #state{sup_pid = Pid} = State) when is_pid(Pid) ->
    case erlang:is_process_alive(Pid) of
        true ->
            erlang:send_after(?STABLE_MS, self(), check_stable),
            {noreply, State#state{backoff = ?INITIAL_BACKOFF_MS}};
        false ->
            {noreply, State}
    end;

handle_info(check_stable, State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #state{sup_pid = Pid} = State) ->
    io:format("[lifeline] Received EXIT from supervisor: ~p~n", [Reason]),
    handle_info({'DOWN', State#state.sup_ref, process, Pid, Reason}, State);

handle_info({'EXIT', _Pid, normal}, State) ->
    {noreply, State};

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.sup_ref of
        undefined -> ok;
        Ref -> erlang:demonitor(Ref, [flush])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal
%%===================================================================

start_supervisor(State) ->
    case coding_agent_sup:start_link() of
        {ok, Pid} ->
            Ref = erlang:monitor(process, Pid),
            io:format("[lifeline] Main supervisor started: ~p~n", [Pid]),
            erlang:send_after(?STABLE_MS, self(), check_stable),
            State#state{sup_pid = Pid, sup_ref = Ref, backoff = ?INITIAL_BACKOFF_MS};
        {error, Reason} ->
            io:format("[lifeline] Failed to start supervisor: ~p~n", [Reason]),
            write_crash_report(Reason, no_pid, State),
            erlang:send_after(?INITIAL_BACKOFF_MS, self(), restart_supervisor),
            State
    end.

prune_crashes(Now, Timestamps) ->
    Cutoff = Now - ?RESTART_WINDOW_MS,
    [T || T <- Timestamps, T > Cutoff].

generate_lifeline_id() ->
    <<A:32, B:32>> = crypto:strong_rand_bytes(8),
    iolist_to_binary(io_lib:format("lifeline-~8.16.0b-~8.16.0b", [A, B])).

format_datetime_utc(TimestampMs) when is_integer(TimestampMs) ->
    Seconds = TimestampMs div 1000,
    {{Year, Month, Day}, {Hour, Min, Sec}} =
        calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w UTC",
        [Year, Month, Day, Hour, Min, Sec]));
format_datetime_utc(_) ->
    <<"unknown">>.

format_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format_reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

format_stacktrace([]) -> <<"">>;
format_stacktrace([{M, F, A, Info} | Rest]) when is_list(A) ->
    Line = io_lib:format("  ~p:~p/~b at ~s:~p~n", [
        M, F, length(A),
        proplists:get_value(file, Info, "unknown"),
        proplists:get_value(line, Info, 0)
    ]),
    [Line | format_stacktrace(Rest)];
format_stacktrace([{M, F, A} | Rest]) when is_integer(A) ->
    Line = io_lib:format("  ~p:~p/~p~n", [M, F, A]),
    [Line | format_stacktrace(Rest)];
format_stacktrace([_ | Rest]) -> format_stacktrace(Rest);
format_stacktrace(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

write_crash_report(Reason, Pid, State) ->
    CrashId = generate_lifeline_id(),
    DateTimeStr = format_datetime_utc(erlang:system_time(millisecond)),
    ReasonStr = format_reason(Reason),
    StacktraceStr = case Reason of
        {_, Stacktrace} when is_list(Stacktrace) ->
            iolist_to_binary(format_stacktrace(Stacktrace));
        _ ->
            <<"No stacktrace available (supervisor exit)">>
    end,
    PidStr = case Pid of
        no_pid -> <<"N/A (supervisor failed to start)">>;
        _ -> iolist_to_binary(io_lib:format("~p", [Pid]))
    end,
    Report = iolist_to_binary([
        <<"# Lifeline Crash Report\n\n">>,
        io_lib:format("**Crash ID:** ~s\n\n", [CrashId]),
        io_lib:format("**Timestamp:** ~s\n\n", [DateTimeStr]),
        io_lib:format("**Supervisor PID:** ~s\n\n", [PidStr]),
        io_lib:format("**Exit Reason:**\n\n```\n~s\n```\n\n", [ReasonStr]),
        <<"## Stacktrace\n\n```\n">>,
        StacktraceStr,
        <<"\n```\n\n">>,
        <<"## Context\n\n">>,
        io_lib:format("**Restart count:** ~p\n\n", [State#state.restart_count + 1]),
        io_lib:format("**Backoff at crash:** ~p ms\n\n", [State#state.backoff]),
        io_lib:format("**Recent crashes in window:** ~p\n\n", [length(State#state.crash_timestamps) + 1]),
        <<"## Status\n\n">>,
        <<"- [ ] Investigated\n">>,
        <<"- [ ] Root-caused\n">>,
        <<"- [ ] Fixed\n">>,
        <<"- [ ] Verified\n">>
    ]),
    filelib:ensure_dir(?REPORT_DIR ++ "/"),
    Filename = filename:join(?REPORT_DIR, binary_to_list(CrashId) ++ ".md"),
    case file:write_file(Filename, Report) of
        ok -> io:format("[lifeline] Crash report written to ~s~n", [Filename]);
        {error, Err} -> io:format("[lifeline] Failed to write crash report: ~p~n", [Err])
    end.

write_give_up_report(Timestamp, CrashTimestamps) ->
    CrashId = generate_lifeline_id(),
    DateTimeStr = format_datetime_utc(Timestamp),
    Report = iolist_to_binary([
        <<"# Lifeline Give-Up Report\n\n">>,
        io_lib:format("**Crash ID:** ~s\n\n", [CrashId]),
        io_lib:format("**Timestamp:** ~s\n\n", [DateTimeStr]),
        <<"The lifeline has stopped attempting restarts after exceeding the threshold.\n\n">>,
        io_lib:format("**Max restarts:** ~p in ~p ms\n\n", [?MAX_RESTARTS, ?RESTART_WINDOW_MS]),
        io_lib:format("**Crash timestamps:**\n\n```\n~p\n```\n\n", [CrashTimestamps]),
        <<"## Next Steps\n\n">>,
        <<"1. Investigate the crash reports in this directory\n">>,
        <<"2. Fix the root cause\n">>,
        <<"3. Reset the lifeline with `coding_agent_lifeline:reset_crash_count()`\n">>,
        <<"4. Restart the application\n">>
    ]),
    Filename = filename:join(?REPORT_DIR, binary_to_list(CrashId) ++ ".md"),
    file:write_file(Filename, Report).