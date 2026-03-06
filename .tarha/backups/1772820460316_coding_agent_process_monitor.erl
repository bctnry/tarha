-module(coding_agent_process_monitor).
-behaviour(gen_server).
-export([start_link/0, status/0, trim/0, trim/1, gc/0, gc/1, set_limit/1, get_limit/0]).
-export([monitor_process/1, unmonitor_process/1, get_monitored/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    memory_limit = 1073741824, % 1GB default
    monitored_pids = #{},
    last_gc = 0,
    gc_interval = 60000 % 1 minute
}).

-define(MEMORY_TABLE, coding_agent_process_monitor).
-define(CRASH_DIR, ".tarha/crashes").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(?MEMORY_TABLE, [named_table, public, set]),
    filelib:ensure_dir(?CRASH_DIR ++ "/"),
    schedule_gc_check(),
    {ok, #state{}}.

handle_call(status, _From, State) ->
    Status = gather_memory_status(),
    {reply, {ok, Status}, State};

handle_call(trim, _From, State) ->
    Result = do_memory_trim(all),
    {reply, Result, State};

handle_call({trim, What}, _From, State) ->
    Result = do_memory_trim(What),
    {reply, Result, State};

handle_call(gc, _From, State) ->
    Result = do_gc(all),
    {reply, Result, State};

handle_call({gc, What}, _From, State) ->
    Result = do_gc(What),
    {reply, Result, State};

handle_call({set_limit, Bytes}, _From, State) ->
    {reply, ok, State#state{memory_limit = Bytes}};

handle_call(get_limit, _From, State) ->
    {reply, {ok, State#state.memory_limit}, State};

handle_call({monitor_process, Pid}, _From, State = #state{monitored_pids = Monitored}) ->
    Ref = erlang:monitor(process, Pid),
    NewMonitored = maps:put(Pid, Ref, Monitored),
    {reply, {ok, Ref}, State#state{monitored_pids = NewMonitored}};

handle_call({unmonitor_process, Pid}, _From, State = #state{monitored_pids = Monitored}) ->
    case maps:find(Pid, Monitored) of
        {ok, Ref} ->
            erlang:demonitor(Ref, [flush]),
            NewMonitored = maps:remove(Pid, Monitored),
            {reply, ok, State#state{monitored_pids = NewMonitored}};
        error ->
            {reply, {error, not_monitored}, State}
    end;

handle_call(get_monitored, _From, State = #state{monitored_pids = Monitored}) ->
    {reply, {ok, maps:keys(Monitored)}, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({memory_high, Pid, Size}, State) ->
    io:format("[memory] High memory detected: ~p using ~p bytes~n", [Pid, Size]),
    auto_cleanup(Pid, Size, State),
    {noreply, State};

handle_info({large_heap, Pid, Size}, State) ->
    io:format("[memory] Large heap detected: ~p using ~p bytes~n", [Pid, Size]),
    auto_cleanup(Pid, Size, State),
    {noreply, State};

handle_info(gc_check, State) ->
    CurrentMemory = erlang:memory(total),
    case CurrentMemory > State#state.memory_limit of
        true ->
            io:format("[memory] Memory limit exceeded: ~p > ~p, trimming~n", [CurrentMemory, State#state.memory_limit]),
            do_memory_trim(all);
        false ->
            ok
    end,
    schedule_gc_check(),
    {noreply, State#state{last_gc = erlang:system_time(millisecond)}};

handle_info({'DOWN', Ref, process, Pid, Reason}, State = #state{monitored_pids = Monitored}) ->
    case maps:find(Pid, Monitored) of
        {ok, Ref} ->
            NewMonitored = maps:remove(Pid, Monitored),
            case Reason of
                normal -> ok;
                _ ->
                    io:format("[memory] Monitored process ~p died: ~p~n", [Pid, Reason]),
                    store_crash_info(Pid, Reason)
            end,
            {noreply, State#state{monitored_pids = NewMonitored}};
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

status() ->
    gen_server:call(?MODULE, status).

trim() ->
    gen_server:call(?MODULE, trim).

trim(What) ->
    gen_server:call(?MODULE, {trim, What}).

gc() ->
    gen_server:call(?MODULE, gc).

gc(What) ->
    gen_server:call(?MODULE, {gc, What}).

set_limit(Bytes) ->
    gen_server:call(?MODULE, {set_limit, Bytes}).

get_limit() ->
    gen_server:call(?MODULE, get_limit).

monitor_process(Pid) ->
    gen_server:call(?MODULE, {monitor_process, Pid}).

unmonitor_process(Pid) ->
    gen_server:call(?MODULE, {unmonitor_process, Pid}).

get_monitored() ->
    gen_server:call(?MODULE, get_monitored).

schedule_gc_check() ->
    erlang:send_after(60000, self(), gc_check).

gather_memory_status() ->
    Processes = erlang:processes(),
    ProcInfo = lists:filtermap(fun(Pid) ->
        case erlang:process_info(Pid, [memory, message_queue_len, heap_size]) of
            [{memory, Mem}, {message_queue_len, QLen}, {heap_size, Heap}] ->
                {true, #{
                    pid => Pid,
                    memory => Mem,
                    queue_len => QLen,
                    heap_size => Heap,
                    name => process_to_name(Pid)
                }};
            _ -> false
        end
    end, Processes),

    SortedByMemory = lists:sort(fun(A, B) -> maps:get(memory, A) > maps:get(memory, B) end, ProcInfo),
    TopMemory = lists:sublist(SortedByMemory, 20),

    #{
        total_memory => erlang:memory(total),
        process_memory => erlang:memory(processes),
        binary_memory => erlang:memory(binary),
        ets_memory => erlang:memory(ets),
        atom_memory => erlang:memory(atom),
        code_memory => erlang:memory(code),
        process_count => length(Processes),
        ets_tables => length(ets:all()),
        top_processes => TopMemory
    }.

process_to_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} when is_atom(Name) -> Name;
        _ -> Pid
    end.

do_memory_trim(all) ->
    try
        trim_sessions(),
        trim_ets_tables(),
        trim_code(),
        trim_binary_heaps(),
        ok
    catch
        Type:Error:Stacktrace ->
            % Report crash to healer
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ -> 
                    catch coding_agent_healer:report_crash(
                        coding_agent_process_monitor, 
                        {Type, Error}, 
                        Stacktrace
                    )
            end,
            {error, {Type, Error}}
    end;
do_memory_trim(sessions) ->
    trim_sessions(),
    ok;
do_memory_trim(ets) ->
    trim_ets_tables(),
    ok;
do_memory_trim(binaries) ->
    trim_binary_heaps(),
    ok;
do_memory_trim(_) ->
    {error, invalid_trim_target}.

trim_sessions() ->
    MemBefore = erlang:memory(processes),
    clear_old_sessions(),
    clear_session_caches(),
    clear_session_messages(),
    MemAfter = erlang:memory(processes),
    io:format("[memory] Sessions trimmed: ~p -> ~p bytes~n", [MemBefore, MemAfter]).

clear_old_sessions() ->
    case ets:whereis(coding_agent_sessions) of
        undefined -> ok;
        Table ->
            try
                AllSessions = ets:tab2list(Table),
                Now = erlang:system_time(millisecond),
                OldThreshold = Now - 3600000,
                lists:foreach(fun({_Id, SessionData}) ->
                    case SessionData of
                        M when is_map(M) ->
                            case maps:get(last_activity, M, Now) of
                                LastActivity when LastActivity < OldThreshold ->
                                    case maps:get(pid, M, undefined) of
                                        undefined -> ok;
                                        Pid when is_pid(Pid) -> catch gen_server:stop(Pid)
                                    end;
                                _ -> ok
                            end;
                        _ -> ok
                    end
                end, AllSessions)
            catch
                _:_ -> ok
            end
    end.

clear_session_caches() ->
    Sessions = get_all_session_pids(),
    [catch gen_server:call(Pid, clear, 5000) || Pid <- Sessions].

clear_session_messages() ->
    Sessions = get_all_session_pids(),
    [catch flush_process_messages(Pid) || Pid <- Sessions].

flush_process_messages(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N > 100 ->
            % Too many messages - process might be stuck
            io:format("[memory] Process ~p has ~p queued messages, killing~n", [Pid, N]),
            exit(Pid, kill);
        _ ->
            ok
    end.

get_all_session_pids() ->
    case ets:whereis(coding_agent_sessions) of
        undefined -> [];
        Table ->
            try
                [maps:get(pid, Data, undefined) || {_, Data} <- ets:tab2list(Table)]
            catch
                _:_ -> []
            end
    end.

trim_ets_tables() ->
    AllTables = ets:all(),
    [try trim_one_ets_table(T) catch _:_ -> ok end || T <- AllTables].

trim_one_ets_table(Table) ->
    case ets:info(Table, size) of
        N when N > 10000 ->
            io:format("[memory] ETS table ~p has ~p entries~n", [Table, N]),
            % Keep most recent entries if possible
            case ets:info(Table, type) of
                ordered_set ->
                    % Ordered set - delete oldest
                    Sorted = ets:tab2list(Table),
                    case length(Sorted) > 1000 of
                        true ->
                            {ToKeep, _} = lists:split(1000, lists:reverse(Sorted)),
                            ets:delete_all_objects(Table),
                            [ets:insert(Table, E) || E <- ToKeep];
                        false ->
                            ok
                    end;
                _ ->
                    % Regular table - just clear if too large and not critical
                    case Table of
                        coding_agent_sessions -> ok;
                        coding_agent_crashes -> ok;
                        _ -> ets:delete_all_objects(Table)
                    end
            end;
        _ -> ok
    end.

trim_code() ->
    % Force full sweep GC and purge old code
    erlang:garbage_collect(),
    lists:foreach(fun(M) ->
        try
            code:soft_purge(M)
        catch
            _:_ -> ok  % Some modules can't be purged (system modules)
        end
    end, code:all_loaded()),
    ok.

trim_binary_heaps() ->
    % Force GC on processes with high binary usage
    Processes = erlang:processes(),
    [begin
        case erlang:process_info(Pid, binary) of
            {binary, Binaries} when length(Binaries) > 10 ->
                erlang:garbage_collect(Pid);
            _ -> ok
        end
    end || Pid <- Processes],
    ok.

do_gc(all) ->
    erlang:garbage_collect(),
    {ok, erlang:memory(total)};
do_gc(Pids) when is_list(Pids) ->
    [erlang:garbage_collect(Pid) || Pid <- Pids],
    {ok, erlang:memory(total)};
do_gc(Pid) when is_pid(Pid) ->
    erlang:garbage_collect(Pid),
    {ok, erlang:memory(total)};
do_gc(_) ->
    {error, invalid_gc_target}.

auto_cleanup(Pid, Size, State) ->
    case State#state.memory_limit of
        Limit when Size > Limit ->
            io:format("[memory] Auto-cleanup triggered for ~p~n", [Pid]),
            do_gc(Pid),
            TrimResult = do_memory_trim(all),
            % Notify healer if available
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ -> coding_agent_healer:analyze_crash({memory_high, Size}, [{Pid, auto_cleanup, []}])
            end,
            TrimResult;
        _ ->
            ok
    end.

store_crash_info(Pid, Reason) ->
    CrashId = generate_crash_id(),
    CrashInfo = #{
        id => CrashId,
        pid => Pid,
        reason => Reason,
        timestamp => erlang:system_time(millisecond)
    },
    ets:insert(?MEMORY_TABLE, {CrashId, CrashInfo}).

generate_crash_id() ->
    <<A:32, B:32>> = crypto:strong_rand_bytes(8),
    iolist_to_binary(io_lib:format("mem-crash-~8.16.0b-~8.16.0b", [A, B])).