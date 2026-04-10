-module(coding_agent_healer).
-behaviour(gen_server).
-export([start_link/0, analyze_crash/2, auto_fix/1, get_crashes/0, clear_crashes/0, 
         report_crash/3, report_crash/4, get_recent_crashes/0, write_crash_report/1,
         list_crash_reports/0, read_crash_report/1, delete_crash_report/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {crashes = [], auto_heal = true, monitored = #{}}%{pid => module}
).
-define(CRASH_TABLE, coding_agent_crashes).
-define(CRASH_REPORT_DIR, ".tarha/reports").
-define(MAX_CRASHES, 100).
-define(WORKERS, [coding_agent_process_monitor, coding_agent_self, coding_agent_healer]).
-define(MONITOR_SESSIONS, true).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(?CRASH_TABLE, [named_table, public, ordered_set]),
    filelib:ensure_dir(?CRASH_REPORT_DIR ++ "/"),
    process_flag(trap_exit, true),
    % Monitor all worker processes
    Monitored = lists:foldl(fun(Mod, Acc) ->
        case whereis(Mod) of
            undefined -> Acc;
            Pid when is_pid(Pid) ->
                Ref = monitor(process, Pid),
                Acc#{Pid => {Mod, Ref}}
        end
    end, #{}, ?WORKERS),
    {ok, #state{monitored = Monitored}}.

handle_call({analyze_crash, Error, Stacktrace}, _From, State) ->
    Analysis = do_analyze_crash(Error, Stacktrace),
    CrashInfo = #{
        type => crash,
        reason => Error,
        stacktrace => Stacktrace,
        analysis => Analysis,
        timestamp => erlang:system_time(millisecond)
    },
    CrashId = store_crash(crash, Error, CrashInfo),
    {reply, {CrashId, Analysis}, State};

handle_call({auto_fix, CrashId}, _From, State) ->
    case ets:lookup(?CRASH_TABLE, CrashId) of
        [] -> {reply, {error, not_found}, State};
        [{CrashId, CrashData}] ->
            case State#state.auto_heal of
                true ->
                    Result = attempt_auto_fix(CrashData),
                    {reply, Result, State};
                false ->
                    {reply, {error, auto_heal_disabled}, State}
            end
    end;

handle_call(get_crashes, _From, State) ->
    Crashes = ets:tab2list(?CRASH_TABLE),
    {reply, {ok, Crashes}, State};

handle_call(clear_crashes, _From, State) ->
    ets:delete_all_objects(?CRASH_TABLE),
    {reply, ok, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({monitor, Pid, Tag, Info}, State) ->
    CrashInfo = #{
        type => Tag,
        pid => Pid,
        info => Info,
        timestamp => erlang:system_time(millisecond)
    },
    CrashId = store_crash(Tag, Info, CrashInfo),
    case State#state.auto_heal of
        true -> spawn_healer(CrashId);
        false -> ok
    end,
    {noreply, State};

handle_info({'DOWN', Ref, process, Pid, Reason}, State = #state{monitored = Monitored}) ->
    % A monitored process crashed
    case maps:get(Pid, Monitored, undefined) of
        {Module, Ref} ->
            % Known process crashed
            Stacktrace = try throw(capture) catch throw:capture:St -> St end,
            Analysis = do_analyze_crash(Reason, Stacktrace),
            CrashInfo = #{
                type => crash,
                module => Module,
                pid => Pid,
                reason => Reason,
                stacktrace => Stacktrace,
                analysis => Analysis,
                timestamp => erlang:system_time(millisecond)
            },
            CrashId = store_crash(crash, Reason, CrashInfo),
            io:format("[healer] Process ~p (~p) crashed: ~p~n", [Pid, Module, Reason]),
            
            % Store crash for analysis
            NewMonitored = maps:remove(Pid, Monitored),
            
            case State#state.auto_heal of
                true ->
                    case Reason of
                        normal -> ok;  % Normal exit, don't heal
                        _ -> 
                            io:format("[healer] Attempting auto-recovery for ~p...~n", [Module]),
                            spawn_healer(CrashId),
                            % Re-monitor when process restarts
                            timer:send_after(1000, {remonitor, Module})
                    end;
                false -> ok
            end,
            {noreply, State#state{monitored = NewMonitored}};
        undefined ->
            % Unknown process
            {noreply, State}
    end;

handle_info({remonitor, Module}, State = #state{monitored = Monitored}) ->
    % Try to re-monitor a restarted process
    case whereis(Module) of
        undefined -> 
            {noreply, State};
        Pid when is_pid(Pid) ->
            case maps:get(Pid, Monitored, undefined) of
                undefined ->
                    Ref = monitor(process, Pid),
                    NewMonitored = Monitored#{Pid => {Module, Ref}},
                    io:format("[healer] Re-monitored ~p (pid ~p)~n", [Module, Pid]),
                    {noreply, State#state{monitored = NewMonitored}};
                _ ->
                    {noreply, State}
            end
    end;

handle_info({'EXIT', Pid, Reason}, State) ->
    Stacktrace = try throw(capture) catch throw:capture:St -> St end,
    Analysis = do_analyze_crash(Reason, Stacktrace),
    CrashInfo = #{
        type => exit,
        pid => Pid,
        reason => Reason,
        stacktrace => Stacktrace,
        analysis => Analysis,
        timestamp => erlang:system_time(millisecond)
    },
    CrashId = store_crash(exit, Reason, CrashInfo),
    case State#state.auto_heal of
        true -> spawn_healer(CrashId);
        false -> ok
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

analyze_crash(Error, Stacktrace) ->
    gen_server:call(?MODULE, {analyze_crash, Error, Stacktrace}).

auto_fix(CrashId) ->
    gen_server:call(?MODULE, {auto_fix, CrashId}, 120000).

get_crashes() ->
    gen_server:call(?MODULE, get_crashes).

get_recent_crashes() ->
    case ets:whereis(?CRASH_TABLE) of
        undefined -> [];
        Table ->
            All = ets:tab2list(Table),
            lists:sublist(lists:reverse(lists:keysort(3, All)), 10)
    end.

clear_crashes() ->
    gen_server:call(?MODULE, clear_crashes).

report_crash(Module, Reason, Stacktrace) ->
    report_crash(Module, Reason, Stacktrace, #{}).

report_crash(Module, Reason, Stacktrace, Opts) ->
    % Run analysis
    Analysis = do_analyze_crash(Reason, Stacktrace),
    CrashInfo = #{
        type => crash,
        module => Module,
        reason => Reason,
        stacktrace => Stacktrace,
        analysis => Analysis,
        timestamp => erlang:system_time(millisecond),
        session_id => maps:get(session_id, Opts, undefined)
    },
    CrashId = store_crash(crash, Reason, CrashInfo),
    io:format("[healer] Crash reported: ~p in ~p~n", [Reason, Module]),
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> spawn_healer(CrashId)
    end,
    CrashId.

store_crash(_ErrorType, _Reason, CrashInfo) ->
    CrashId = generate_crash_id(),
    CrashData = CrashInfo#{
        id => CrashId,
        timestamp => maps:get(timestamp, CrashInfo, erlang:system_time(millisecond))
    },
    ets:insert(?CRASH_TABLE, {CrashId, CrashData}),
    cleanup_old_crashes(),
    spawn(fun() ->
        case write_crash_report(CrashId) of
            {ok, Filename} ->
                io:format("[healer] Crash report saved to ~s~n", [Filename]);
            {error, Reason} ->
                io:format("[healer] Failed to write crash report: ~p~n", [Reason])
        end
    end),
    CrashId.

generate_crash_id() ->
    <<A:32, B:32>> = crypto:strong_rand_bytes(8),
    iolist_to_binary(io_lib:format("crash-~8.16.0b-~8.16.0b", [A, B])).

%% List all persisted crash reports
list_crash_reports() ->
    case filelib:is_dir(?CRASH_REPORT_DIR) of
        false -> [];
        true ->
            Files = filelib:wildcard(filename:join(?CRASH_REPORT_DIR, "crash-*.md")),
            lists:map(fun(FilePath) ->
                Filename = filename:basename(FilePath, ".md"),
                #{id => list_to_binary(Filename), path => list_to_binary(FilePath)}
            end, Files)
    end.

%% Read a specific crash report
read_crash_report(CrashId) when is_binary(CrashId) ->
    read_crash_report(binary_to_list(CrashId));
read_crash_report(CrashId) when is_list(CrashId) ->
    Filename = filename:join(?CRASH_REPORT_DIR, CrashId ++ ".md"),
    case file:read_file(Filename) of
        {ok, Content} -> {ok, Content};
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

%% Delete a crash report
delete_crash_report(CrashId) when is_binary(CrashId) ->
    delete_crash_report(binary_to_list(CrashId));
delete_crash_report(CrashId) when is_list(CrashId) ->
    Filename = filename:join(?CRASH_REPORT_DIR, CrashId ++ ".md"),
    case file:delete(Filename) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> {error, Reason}
    end.

cleanup_old_crashes() ->
    case ets:info(?CRASH_TABLE, size) of
        N when N > ?MAX_CRASHES ->
            All = ets:tab2list(?CRASH_TABLE),
            Sorted = lists:keysort(3, All),
            {ToKeep, _ToDelete} = lists:split(?MAX_CRASHES, lists:reverse(Sorted)),
            ets:delete_all_objects(?CRASH_TABLE),
            [ets:insert(?CRASH_TABLE, E) || E <- ToKeep];
        _ -> ok
    end.

do_analyze_crash(Error, Stacktrace) ->
    ErrorStr = format_error(Error),
    StacktraceStr = format_stacktrace(Stacktrace),

    #{error_type => classify_error(Error),
      error_message => ErrorStr,
      stacktrace => StacktraceStr,
      affected_modules => extract_modules(Stacktrace),
      suggested_fix => suggest_fix(Error, Stacktrace)}.

format_error({Reason, Stacktrace}) ->
    io_lib:format("~p~n~p", [Reason, Stacktrace]);
format_error(Error) ->
    io_lib:format("~p", [Error]).

format_stacktrace(Stacktrace) ->
    io_lib:format("~p", [Stacktrace]).

classify_error({badarg, _}) -> badarg;
classify_error({badmatch, _}) -> badmatch;
classify_error({case_clause, _}) -> case_clause;
classify_error({if_clause, _}) -> if_clause;
classify_error({try_clause, _}) -> try_clause;
classify_error({function_clause, _}) -> function_clause;
classify_error({undef, _}) -> undefined_function;
classify_error({noproc, _}) -> process_not_found;
classify_error({timeout, _}) -> timeout;
classify_error({exit, Reason}) -> classify_exit_reason(Reason);
classify_error({error, Reason}) -> classify_error(Reason);
classify_error({throw, _}) -> throw_error;
classify_error(badarg) -> badarg;
classify_error(badmatch) -> badmatch;
classify_error(case_clause) -> case_clause;
classify_error(if_clause) -> if_clause;
classify_error(function_clause) -> function_clause;
classify_error(undef) -> undefined_function;
classify_error(noproc) -> process_not_found;
classify_error(timeout) -> timeout;
classify_error(error) -> error;
classify_error(Reason) when is_atom(Reason) -> Reason;
classify_error(_) -> unknown.

classify_exit_reason(normal) -> normal_exit;
classify_exit_reason(killed) -> killed;
classify_exit_reason({shutdown, _}) -> shutdown;
classify_exit_reason({noproc, _}) -> process_not_found;
classify_exit_reason({timeout, _}) -> timeout;
classify_exit_reason({badarg, _}) -> badarg;
classify_exit_reason({badmatch, _}) -> badmatch;
classify_exit_reason({case_clause, _}) -> case_clause;
classify_exit_reason({undef, _}) -> undefined_function;
classify_exit_reason(_) -> exit_signal.

extract_modules([]) -> [];
extract_modules([{M, _, _, _} | Rest]) ->
    [M | extract_modules(Rest)];
extract_modules([{M, _, _} | Rest]) ->
    [M | extract_modules(Rest)];
extract_modules([_ | Rest]) ->
    extract_modules(Rest).

suggest_fix(Error, Stacktrace) ->
    Type = classify_error(Error),
    Modules = extract_modules(Stacktrace),
    
    % Check if we can rollback
    RollbackAvailable = can_rollback(Modules),
    
    case Type of
        badarg ->
            suggest_with_rollback(check_arguments, Modules, 
                "Check function arguments - invalid type or value passed", RollbackAvailable);
        badmatch ->
            suggest_with_rollback(fix_pattern_match, Modules,
                "Pattern match failed - verify expected values match actual", RollbackAvailable);
        case_clause ->
            suggest_with_rollback(add_case_clause, Modules,
                "Missing case clause - add handling for unexpected value", RollbackAvailable);
        if_clause ->
            suggest_with_rollback(add_if_clause, Modules,
                "No if clause matched - add condition for missing case", RollbackAvailable);
        try_clause ->
            suggest_with_rollback(add_try_clause, Modules,
                "No try clause matched - add catch for exception", RollbackAvailable);
        function_clause ->
            suggest_with_rollback(fix_function_arity, Modules,
                "No matching function clause - check arity or add clause", RollbackAvailable);
        undefined_function ->
            % Try to find the function in other modules
            Found = find_function_in_modules(Error, Stacktrace),
            case Found of
                {ok, CorrectModule} ->
                    suggest_with_rollback(use_correct_module, Modules,
                        io_lib:format("Function exists in module ~p - use ~p instead", [CorrectModule, CorrectModule]), RollbackAvailable);
                not_found ->
                    suggest_with_rollback(export_or_define_function, Modules,
                        "Function not found - add -export or define function", RollbackAvailable)
            end;
        process_not_found ->
            suggest_with_rollback(check_process_start, Modules,
                "Process not found - ensure dependent process is started", RollbackAvailable);
        timeout ->
            suggest_with_rollback(increase_timeout_or_fix_hang, Modules,
                "Operation timed out - increase timeout or fix blocking code", RollbackAvailable);
        normal_exit ->
            suggest_with_rollback(investigate, Modules,
                "Process exited normally - this may be intentional", RollbackAvailable);
        killed ->
            suggest_with_rollback(investigate, Modules,
                "Process was killed - check for supervisor restart or explicit exit", RollbackAvailable);
        shutdown ->
            suggest_with_rollback(investigate, Modules,
                "Process shutdown - check application shutdown logic", RollbackAvailable);
        throw_error ->
            suggest_with_rollback(investigate, Modules,
                "Exception thrown - check error handling", RollbackAvailable);
        exit_signal ->
            suggest_with_rollback(investigate, Modules,
                "Process exited - check linked process or exit reason", RollbackAvailable);
        error ->
            suggest_with_rollback(investigate, Modules,
                "Error occurred - check error reason", RollbackAvailable);
        _ ->
            suggest_with_rollback(investigate, Modules,
                "Review stacktrace for error source", RollbackAvailable)
    end.

suggest_with_rollback(Action, Modules, Hint, true) ->
    #{action => Action, modules => Modules, hint => Hint, 
      rollback_available => true, rollback_hint => "Can auto-rollback to previous version"};
suggest_with_rollback(Action, Modules, Hint, false) ->
    #{action => Action, modules => Modules, hint => Hint,
      rollback_available => false, rollback_hint => "No previous version available"}.

can_rollback([]) -> false;
can_rollback([M | _]) ->
    case whereis(coding_agent_self) of
        undefined -> false;
        _ ->
            case coding_agent_self:get_versions(M) of
                [_ | _] -> true;
                _ -> false
            end
    end.

%% Find a function that exists in another module
%% Useful for suggesting correct module when undef error occurs
find_function_in_modules({undef, {WrongModule, FunctionName, Arity}}, _Stacktrace) ->
    %% Common modules to search
    CommonModules = [lists, string, binary, file, filename, os, io, 
                     proplists, maps, sets, dict, queue, array,
                     re, unicode, calendar, timer, erlang],
    Found = lists:filter(fun(Mod) ->
        erlang:function_exported(Mod, FunctionName, Arity)
    end, CommonModules -- [WrongModule]),
    case Found of
        [CorrectModule | _] -> {ok, CorrectModule};
        [] -> not_found
    end;
find_function_in_modules(_Error, _Stacktrace) ->
    not_found.

attempt_auto_fix(CrashData) ->
    #{analysis := Analysis} = CrashData,
    #{suggested_fix := Suggestion} = Analysis,

    case maps:get(action, Suggestion, none) of
        none ->
            {error, no_auto_fix_available};
        Action ->
            case try_apply_fix(Action, CrashData) of
                {ok, Result} ->
                    % Write fix report
                    write_fix_report(CrashData, Action, Result),
                    {ok, #{fix_applied => Action, result => Result}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

write_crash_report(CrashId) ->
    case ets:lookup(?CRASH_TABLE, CrashId) of
        [] -> {error, not_found};
        [{CrashId, CrashData}] ->
            filelib:ensure_dir(?CRASH_REPORT_DIR ++ "/"),
            _Timestamp = maps:get(timestamp, CrashData, erlang:system_time(millisecond)),
            _Analysis = maps:get(analysis, CrashData, #{}),
            
            ReportContent = generate_crash_report_content(CrashId, CrashData),
            Filename = filename:join(?CRASH_REPORT_DIR, binary_to_list(CrashId) ++ ".md"),
            
            case file:write_file(Filename, ReportContent) of
                ok -> 
                    io:format("[healer] Crash report written to ~s~n", [Filename]),
                    {ok, Filename};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

generate_crash_report_content(CrashId, CrashData) ->
    Timestamp = maps:get(timestamp, CrashData, 0),
    DateTimeStr = format_datetime_utc(Timestamp),
    ErrorType = maps:get(type, CrashData, unknown),
    Module = maps:get(module, CrashData, unknown),
    Reason = maps:get(reason, CrashData, unknown),
    Stacktrace = maps:get(stacktrace, CrashData, []),
    Analysis = maps:get(analysis, CrashData, #{}),
    SessionId = maps:get(session_id, CrashData, undefined),
    
    SuggestedFix = maps:get(suggested_fix, Analysis, #{}),
    AffectedModules = maps:get(affected_modules, Analysis, []),
    
    SessionSection = case SessionId of
        undefined -> <<"">>;
        <<"">> -> <<"">>;
        Sid -> io_lib:format("**Session ID:** ~s\n\n", [Sid])
    end,
    
    iolist_to_binary([
        <<"# Crash Report\n\n">>,
        io_lib:format("**Crash ID:** ~s\n\n", [CrashId]),
        io_lib:format("**Timestamp:** ~s (UTC)\n\n", [DateTimeStr]),
        SessionSection,
        io_lib:format("**Module:** ~p\n\n", [Module]),
        io_lib:format("**Error Type:** ~p\n\n", [ErrorType]),
        io_lib:format("**Error:**\n\n```\n~p\n```\n\n", [Reason]),
        <<"## Stacktrace\n\n```\n">>,
        format_stacktrace_for_report(Stacktrace),
        <<"```\n\n">>,
        <<"## Affected Modules\n\n">>,
        [[<<"- ">>, atom_to_binary(M, utf8), <<"\n">>] || M <- AffectedModules],
        <<"\n">>,
        <<"## Suggested Fix\n\n">>,
        io_lib:format("**Action:** ~p\n\n", [maps:get(action, SuggestedFix, none)]),
        io_lib:format("**Hint:** ~s\n\n", [maps:get(hint, SuggestedFix, "No hint available")]),
        <<"\n">>,
        <<"## Status\n\n">>,
        <<"- [ ] Investigated\n">>,
        <<"- [ ] Fixed\n">>,
        <<"- [ ] Verified\n">>
    ]).

format_datetime_utc(TimestampMs) when is_integer(TimestampMs), TimestampMs > 0 ->
    Seconds = TimestampMs div 1000,
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:system_time_to_universal_time(Seconds, second),
    iolib_to_binary(io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w UTC", 
        [Year, Month, Day, Hour, Min, Sec]));
format_datetime_utc(_) ->
    <<"unknown">>.

iolib_to_binary(IoList) ->
    iolist_to_binary(IoList).

format_stacktrace_for_report(Stacktrace) when is_list(Stacktrace) ->
    format_stacktrace_list(Stacktrace);
format_stacktrace_for_report(Stacktrace) ->
    io_lib:format("~p", [Stacktrace]).

format_stacktrace_list([]) -> <<"">>;
format_stacktrace_list([{M, F, A, Info} | Rest]) when is_list(A) ->
    Line = io_lib:format("  ~p:~p/~b at ~s:~p~n", [
        M, F, length(A),
        proplists:get_value(file, Info, "unknown"),
        proplists:get_value(line, Info, 0)
    ]),
    [Line | format_stacktrace_list(Rest)];
format_stacktrace_list([{M, F, A, Info} | Rest]) ->
    Line = io_lib:format("  ~p:~p/~p at ~s:~p~n", [
        M, F, A,
        proplists:get_value(file, Info, "unknown"),
        proplists:get_value(line, Info, 0)
    ]),
    [Line | format_stacktrace_list(Rest)];
format_stacktrace_list([{M, F, A} | Rest]) ->
    Line = io_lib:format("  ~p:~p/~p~n", [M, F, A]),
    [Line | format_stacktrace_list(Rest)];
format_stacktrace_list([_ | Rest]) ->
    format_stacktrace_list(Rest).

write_fix_report(CrashData, Action, Result) ->
    filelib:ensure_dir(?CRASH_REPORT_DIR ++ "/"),
    CrashId = maps:get(id, CrashData, <<"unknown">>),
    _Timestamp = erlang:system_time(millisecond),
    
    ReportContent = generate_fix_report_content(CrashId, Action, Result),
    Filename = filename:join(?CRASH_REPORT_DIR, "fix-" ++ binary_to_list(CrashId) ++ ".md"),
    
    case file:write_file(Filename, ReportContent) of
        ok -> 
            io:format("[healer] Fix report written to ~s~n", [Filename]),
            {ok, Filename};
        {error, Reason} ->
            {error, Reason}
    end.

generate_fix_report_content(CrashId, Action, Result) ->
    Timestamp = erlang:system_time(millisecond),
    
    iolist_to_binary([
        <<"# Fix Report\n\n">>,
        io_lib:format("**Crash ID:** ~s\n\n", [CrashId]),
        io_lib:format("**Fix Applied:** ~p\n\n", [Action]),
        io_lib:format("**Timestamp:** ~p\n\n", [Timestamp]),
        <<"## Result\n\n">>,
        <<"```\n">>,
        io_lib:format("~p", [Result]),
        <<"```\n\n">>,
        <<"## Verification Steps\n\n">>,
        <<"1. Run the affected code again\n">>,
        <<"2. Check that the crash no longer occurs\n">>,
        <<"3. If crash persists, run /fix again or investigate manually\n">>
    ]).

try_apply_fix(check_arguments, CrashData) ->
    % Try to add argument validation
    fix_badarg(CrashData);
try_apply_fix(fix_pattern_match, CrashData) ->
    % Try to add catch-all pattern
    fix_badmatch(CrashData);
try_apply_fix(add_case_clause, CrashData) ->
    fix_case_clause(CrashData);
try_apply_fix(add_if_clause, CrashData) ->
    fix_if_clause(CrashData);
try_apply_fix(add_try_clause, CrashData) ->
    fix_try_clause(CrashData);
try_apply_fix(fix_function_arity, CrashData) ->
    % Try to add missing function clause
    fix_function_clause(CrashData);
try_apply_fix(export_or_define_function, CrashData) ->
    fix_missing_function(CrashData);
try_apply_fix(check_process_start, _CrashData) ->
    {error, manual_fix_required};
try_apply_fix(increase_timeout_or_fix_hang, _CrashData) ->
    {error, manual_fix_required};
try_apply_fix(investigate, _CrashData) ->
    {error, manual_fix_required};
try_apply_fix(rollback_version, CrashData) ->
    % Attempt to rollback to previous version
    #{affected_modules := Modules} = maps:get(analysis, CrashData, #{affected_modules => []}),
    rollback_modules(Modules);
try_apply_fix(_, _CrashData) ->
    {error, manual_fix_required}.

rollback_modules([]) ->
    {error, no_modules_to_rollback};
rollback_modules([M | Rest]) ->
    case coding_agent_self:rollback(M) of
        #{success := true} ->
            {ok, #{rolled_back => M}};
        _ ->
            rollback_modules(Rest)
     end.

fix_missing_function(CrashData) ->
    #{analysis := Analysis} = CrashData,
    #{affected_modules := Modules} = Analysis,

    case Modules of
        [M | _] ->
            SourceFile = find_source_file(M),
            case file:read_file(SourceFile) of
                {ok, Content} ->
                    ExportSection = extract_exports(Content),
                    MissingFuncs = find_missing_exports(Content, ExportSection),
                    case MissingFuncs of
                        [] ->
                            {error, no_missing_exports_found};
                        _ ->
                            NewContent = add_to_exports(Content, MissingFuncs),
                            file:write_file(SourceFile, NewContent),
                            coding_agent_self:reload_module(M),
                            {ok, #{added_exports => MissingFuncs}}
                    end;
                {error, _} ->
                    {error, cannot_read_source}
            end;
        [] ->
            {error, no_affected_modules}
    end.

find_source_file(Module) ->
    case code:which(Module) of
        Beam when is_list(Beam) ->
            SrcFile = Beam ++ ".erl",
            case filelib:is_file(SrcFile) of
                true -> SrcFile;
                false ->
                    SrcDir = filename:dirname(Beam),
                    SrcFile2 = filename:join([SrcDir, "..", "src", atom_to_list(Module) ++ ".erl"]),
                    SrcFile2
            end;
        _ ->
            SrcDir = "src",
            filename:join(SrcDir, atom_to_list(Module) ++ ".erl")
    end.

%% Fix badarg - read the crash line and fix the pattern directly
fix_badarg(CrashData) ->
    #{stacktrace := Stacktrace} = CrashData,
    % Find the first stack frame with line info in our code
    case find_user_code_location(Stacktrace) of
        {ok, File, Line} ->
            case file:read_file(File) of
                {ok, Content} ->
                    Lines = binary:split(Content, <<"\n">>, [global]),
                    case lists:nth(Line, Lines) of
                        LineContent when is_binary(LineContent) ->
                            case fix_badarg_in_line(File, Line, LineContent, Lines) of
                                {ok, FixedContent} ->
                                    file:write_file(File, FixedContent),
                                    Module = filename_to_module(File),
                                    coding_agent_self:reload_module(Module),
                                    {ok, #{file => File, line => Line, action => fixed_badarg}};
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        _ ->
                            {error, cannot_extract_line}
                    end;
                {error, _} ->
                    {error, cannot_read_source}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

find_user_code_location([]) ->
    {error, no_user_code_in_stacktrace};
find_user_code_location([{_M, _F, _A, Info} | Rest]) ->
    File = proplists:get_value(file, Info, ""),
    Line = proplists:get_value(line, Info, 0),
    case is_user_code(File) of
        true when Line > 0 ->
            {ok, File, Line};
        _ ->
            find_user_code_location(Rest)
    end;
find_user_code_location([_ | Rest]) ->
    find_user_code_location(Rest).

is_user_code(File) ->
    % Check if file is in src/ directory (user code, not library)
    binary:match(iolist_to_binary(File), <<"src/">>) =/= nomatch orelse
    File =:= "coding_agent_repl.erl".

filename_to_module(File) ->
    BaseName = filename:basename(File, ".erl"),
    list_to_atom(BaseName).

fix_badarg_in_line(_File, LineNum, LineContent, AllLines) ->
    % Common badarg patterns:
    % 1. io_lib:format("~s", [[Integer]]) - Unicode codepoint passed to ~s
    % 2. binary_to_list(Incomplete) - incomplete binary
    % 3. list_to_binary(Invalid) - invalid list
    
    case find_badarg_pattern(LineContent) of
        {ok, {Pattern, Replacement}} ->
            FixedLine = binary:replace(LineContent, Pattern, Replacement),
            {Before, After} = lists:split(LineNum - 1, AllLines),
            {ok, iolist_to_binary(lists:join(<<"\n">>, Before ++ [FixedLine] ++ After))};
        {error, Reason} ->
            {error, Reason}
    end.

find_badarg_pattern(Line) ->
    % Pattern: io_lib:format with unicode integer list
    case binary:match(Line, <<"io_lib:format">>) of
        {_Pos, _} ->
            % Check for ~s with integer list argument
            case extract_format_args(Line) of
                {ok, FormatStr, Args} ->
                    case analyze_format_badarg(FormatStr, Args) of
                        {ok, Replacement} ->
                            {ok, {Line, Replacement}};
                        {error, _} ->
                            % Try other patterns
                            try_other_badarg_patterns(Line)
                    end;
                _ ->
                    try_other_badarg_patterns(Line)
            end;
        _ ->
            try_other_badarg_patterns(Line)
    end.

try_other_badarg_patterns(_Line) ->
    {error, unknown_badarg_pattern}.

analyze_format_badarg(FormatStr, Args) ->
    % Check if we're passing integer list to ~s
    case binary:match(FormatStr, <<"~s">>) of
        {_, _} ->
            % ~s used, check args for integer list pattern
            case Args of
                [[Int | _]] when is_integer(Int) ->
                    % Integer list like [10003] - need to use ~p or convert
                    % Replace ~s with ~p for safety
                    NewFormat = binary:replace(FormatStr, <<"~s">>, <<"~p">>),
                    {ok, iolist_to_binary([<<"io_lib:format">>, <<"(">>, NewFormat, <<", ">>, format_args_safe(Args), <<")">>])};
                _ ->
                    {error, not_unicode_codepoint}
            end;
        _ ->
            {error, no_tilde_s}
    end.

format_args_safe(Args) ->
    io_lib:format("~p", [Args]).

extract_format_args(Line) ->
    % Simplified extraction - find io_lib:format(..., ...)
    case binary:match(Line, <<"io_lib:format(">>) of
        {Start, _} ->
            <<_:Start/binary, Rest/binary>> = Line,
            case find_closing_paren(Rest, 1, <<>>) of
                {ok, Content} ->
                    % Content is "Format, Args)"
                    case binary:split(Content, <<", ">>) of
                        [Format, Args] ->
                            {ok, Format, Args};
                        _ ->
                            {error, cannot_parse}
                    end;
                error ->
                    {error, cannot_parse}
            end;
        _ ->
            {error, no_io_lib_format}
    end.

find_closing_paren(<<>>, _Depth, _Acc) -> error;
find_closing_paren(<<$), _Rest/binary>>, 1, Acc) -> {ok, Acc};
find_closing_paren(<<$), Rest/binary>>, Depth, Acc) -> 
    find_closing_paren(Rest, Depth - 1, <<Acc/binary, $)>>);
find_closing_paren(<<$(, Rest/binary>>, Depth, Acc) -> 
    find_closing_paren(Rest, Depth + 1, <<Acc/binary, $(>>);
find_closing_paren(<<C, Rest/binary>>, Depth, Acc) -> 
    find_closing_paren(Rest, Depth, <<Acc/binary, C>>).

%% Generic helper: read crash line and apply fix function
fix_at_crash_line(CrashData, FixFun) ->
    #{stacktrace := Stacktrace} = CrashData,
    case find_user_code_location(Stacktrace) of
        {ok, File, LineNum} ->
            case file:read_file(File) of
                {ok, Content} ->
                    Lines = binary:split(Content, <<"\n">>, [global]),
                    case lists:nth(LineNum, Lines) of
                        LineContent when is_binary(LineContent) ->
                            case FixFun(LineContent, LineNum, Lines) of
                                {ok, NewLines} when is_list(NewLines) ->
                                    NewContent = iolist_to_binary(lists:join(<<"\n">>, NewLines)),
                                    file:write_file(File, NewContent),
                                    Module = filename_to_module(File),
                                    coding_agent_self:reload_module(Module),
                                    {ok, #{file => File, line => LineNum, action => fixed}};
                                {ok, NewLine} when is_binary(NewLine) ->
                                    {Before, After} = lists:split(LineNum - 1, Lines),
                                    NewLines = Before ++ [NewLine] ++ After,
                                    NewContent = iolist_to_binary(lists:join(<<"\n">>, NewLines)),
                                    file:write_file(File, NewContent),
                                    Module = filename_to_module(File),
                                    coding_agent_self:reload_module(Module),
                                    {ok, #{file => File, line => LineNum, action => fixed}};
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        _ ->
                            {error, cannot_extract_line}
                    end;
                {error, _} ->
                    {error, cannot_read_source}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Fix badmatch - read crash line and fix pattern match
fix_badmatch(CrashData) ->
    fix_at_crash_line(CrashData, fun fix_badmatch_line/3).

fix_badmatch_line(Line, _LineNum, _Lines) ->
    case binary:match(Line, <<"=">>) of
        {Pos, _} when Pos > 0 ->
            <<Before:Pos/binary, _/binary>> = Line,
            Pattern = string:trim(Before, trailing),
            Indent = get_line_indent(Line),
            case string:find(Pattern, <<"{">>) of
                nomatch ->
                    {error, no_tuple_pattern};
                _ ->
                    case string:find(Pattern, <<"}">>) of
                        nomatch ->
                            {error, incomplete_tuple};
                        _ ->
                            Wildcard = <<Indent/binary, Pattern/binary, " = _">>,
                            {ok, Wildcard}
                    end
            end;
        _ ->
            {error, no_match_pattern}
    end.

%% Fix case_clause - add wildcard case
fix_case_clause(CrashData) ->
    fix_at_crash_line(CrashData, fun fix_case_clause_line/3).

fix_case_clause_line(Line, LineNum, Lines) ->
    case string:find(Line, <<"case">>) of
        nomatch ->
            case find_enclosing_construct(Lines, LineNum, <<"case">>, <<"end">>) of
                {ok, _CaseStart, CaseEnd} ->
                    Indent = get_line_indent(Line),
                    Wildcard = <<Indent/binary, "    _ -> ok">>,
                    {Before, After} = lists:split(CaseEnd - 1, Lines),
                    NewLines = Before ++ [Wildcard] ++ After,
                    {ok, NewLines};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            Indent = get_line_indent(Line),
            Wildcard = <<Indent/binary, "    _ -> ok">>,
            {ok, Wildcard}
    end.

%% Fix if_clause - add true clause
fix_if_clause(CrashData) ->
    fix_at_crash_line(CrashData, fun fix_if_clause_line/3).

fix_if_clause_line(Line, LineNum, Lines) ->
    case find_enclosing_construct(Lines, LineNum, <<"if">>, <<"end">>) of
        {ok, _IfStart, IfEnd} ->
            Indent = get_line_indent(Line),
            TrueClause = <<Indent/binary, "    true -> ok">>,
            {Before, After} = lists:split(IfEnd - 1, Lines),
            NewLines = Before ++ [TrueClause] ++ After,
            {ok, NewLines};
        {error, _} ->
            Indent = get_line_indent(Line),
            {ok, <<Indent/binary, "true -> ok">>}
    end.

%% Fix try_clause - add catch clause
fix_try_clause(CrashData) ->
    fix_at_crash_line(CrashData, fun fix_try_clause_line/3).

fix_try_clause_line(Line, LineNum, Lines) ->
    case find_enclosing_construct(Lines, LineNum, <<"try">>, <<"end">>) of
        {ok, _TryStart, TryEnd} ->
            Indent = get_line_indent(Line),
            CatchClause = <<Indent/binary, "catch">>,
            CatchAll = <<Indent/binary, "    _:_ -> ok">>,
            {Before, After} = lists:split(TryEnd - 1, Lines),
            NewLines = Before ++ [CatchClause, CatchAll] ++ After,
            {ok, NewLines};
        {error, _} ->
            {error, no_try_block}
    end.

%% Fix function_clause - add catch-all clause
fix_function_clause(CrashData) ->
    fix_at_crash_line(CrashData, fun fix_function_clause_line/3).

fix_function_clause_line(Line, _LineNum, _Lines) ->
    case binary:match(Line, <<"(">>) of
        {Pos, _} ->
            <<FuncName:Pos/binary, _/binary>> = Line,
            Indent = get_line_indent(Line),
            CatchAll = <<Indent/binary, FuncName/binary, "(_) -> ok">>,
            {ok, CatchAll};
        _ ->
            {error, no_function_name}
    end.

%% Helper functions

get_line_indent(Line) ->
    case binary:match(Line, <<"\t">>) of
        {0, _} ->
            <<$\t, Rest/binary>> = Line,
            <<$\t, (get_line_indent(Rest))/binary>>;
        _ ->
            case binary:match(Line, <<" ">>) of
                {0, _} ->
                    <<$\s, Rest/binary>> = Line,
                    <<$\s, (get_line_indent(Rest))/binary>>;
                _ ->
                    <<>>
            end
    end.

find_enclosing_construct(Lines, LineNum, StartKeyword, EndKeyword) ->
    % Search backwards for start, forwards for end
    case find_construct_start(Lines, LineNum, StartKeyword) of
        {ok, StartLine} ->
            case find_construct_end(Lines, LineNum, EndKeyword) of
                {ok, EndLine} ->
                    {ok, StartLine, EndLine};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

find_construct_start(_Lines, LineNum, _Keyword) when LineNum < 1 ->
    {error, not_found};
find_construct_start(Lines, LineNum, Keyword) ->
    Line = lists:nth(LineNum, Lines),
    case binary:match(Line, Keyword) of
        {_, _} ->
            {ok, LineNum};
        _ ->
            find_construct_start(Lines, LineNum - 1, Keyword)
    end.

find_construct_end(Lines, LineNum, _Keyword) when LineNum > length(Lines) ->
    {error, not_found};
find_construct_end(Lines, LineNum, Keyword) ->
    Line = lists:nth(LineNum, Lines),
    case binary:match(Line, Keyword) of
        {_, _} ->
            {ok, LineNum};
        _ ->
            find_construct_end(Lines, LineNum + 1, Keyword)
    end.

extract_exports(Content) ->
    case binary:match(Content, <<"-module(">>) of
        _ ->
            case binary:match(Content, <<"-export([">>) of
                {Start, _} ->
                    EndStart = binary:match(Content, <<"]).">>, [{scope, {Start, byte_size(Content) - Start}}]),
                    case EndStart of
                        {End, _} ->
                            binary:part(Content, Start, End + 3 - Start);
                        nomatch -> <<>>
                    end;
                nomatch -> <<>>
            end
    end.

find_missing_exports(_Content, _ExportSection) ->
    [].

add_to_exports(Content, []) -> Content;
add_to_exports(Content, [Func | Rest]) ->
    case binary:match(Content, <<"-export([">>) of
        {Start, _} ->
            InsertPos = Start + 10,
            Before = binary:part(Content, 0, InsertPos),
            After = binary:part(Content, InsertPos, byte_size(Content) - InsertPos),
            NewExport = iolist_to_binary([Func, ", "]),
            case After of
                <<"])>">> ->
                    iolist_to_binary([Before, NewExport, After]);
                _ ->
                    add_to_exports(iolist_to_binary([Before, NewExport, After]), Rest)
            end;
        nomatch ->
            case binary:match(Content, <<"-module(">>) of
                {ModEnd, _} ->
                    ModuleEnd = binary:match(Content, <<".">>, [{scope, {ModEnd, byte_size(Content) - ModEnd}}]),
                    case ModuleEnd of
                        {DotPos, _} ->
                            InsertAt = DotPos + 1,
                            Before = binary:part(Content, 0, InsertAt),
                            After = binary:part(Content, InsertAt, byte_size(Content) - InsertAt),
                            ExportLine = iolist_to_binary(["\n-export([", Func, "])."]),
                            add_to_exports(iolist_to_binary([Before, ExportLine, After]), Rest);
                        _ ->
                            Content
                    end;
                nomatch -> Content
            end
    end.

spawn_healer(CrashId) ->
    spawn(fun() ->
        timer:sleep(1000),
        io:format("[healer] Attempting auto-fix for crash ~p~n", [CrashId]),
        case auto_fix(CrashId) of
            {ok, Result} ->
                io:format("[healer] Auto-fix succeeded: ~p~n", [Result]);
            {error, Reason} ->
                io:format("[healer] Auto-fix failed: ~p~n", [Reason])
        end
    end).