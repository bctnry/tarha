-module(coding_agent_healer).
-behaviour(gen_server).
-export([start_link/0, analyze_crash/2, auto_fix/1, get_crashes/0, clear_crashes/0, 
         report_crash/3, report_crash/4, get_recent_crashes/0, write_crash_report/1,
         list_crash_reports/0, read_crash_report/1, delete_crash_report/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {crashes = [], auto_heal = true, monitored = #{}}%{pid => module}
).
-define(CRASH_TABLE, coding_agent_crashes).
-define(CRASH_DIR, ".tarha/crashes").
-define(CRASH_REPORT_DIR, ".tarha/reports").
-define(MAX_CRASHES, 100).
-define(WORKERS, [coding_agent_process_monitor, coding_agent_self, coding_agent_healer]).

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
classify_error({function_clause, _}) -> function_clause;
classify_error({undef, _}) -> undefined_function;
classify_error({noproc, _}) -> process_not_found;
classify_error({timeout, _}) -> timeout;
classify_error({exit, _}) -> exit_signal;
classify_error({error, Reason}) -> classify_error(Reason);
classify_error(error) -> error;
classify_error(Reason) when is_atom(Reason) -> Reason;
classify_error(_) -> unknown.

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
        function_clause ->
            suggest_with_rollback(fix_function_arity, Modules,
                "No matching function clause - check arity or add clause", RollbackAvailable);
        undefined_function ->
            suggest_with_rollback(export_or_define_function, Modules,
                "Function not found - add -export or define function", RollbackAvailable);
        process_not_found ->
            suggest_with_rollback(check_process_start, Modules,
                "Process not found - ensure dependent process is started", RollbackAvailable);
        timeout ->
            suggest_with_rollback(increase_timeout_or_fix_hang, Modules,
                "Operation timed out - increase timeout or fix blocking code", RollbackAvailable);
        exit_signal ->
            suggest_with_rollback(investigate, Modules,
                "Process exited - check linked process or exit reason", RollbackAvailable);
        error ->
            suggest_with_rollback(investigate, Modules,
                "Error occurred - manual investigation required", RollbackAvailable);
        _ ->
            suggest_with_rollback(investigate, Modules,
                "Unknown error type - manual investigation required", RollbackAvailable)
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
            Timestamp = maps:get(timestamp, CrashData, erlang:system_time(millisecond)),
            Analysis = maps:get(analysis, CrashData, #{}),
            
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
    Timestamp = erlang:system_time(millisecond),
    
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

try_apply_fix(check_arguments, _CrashData) ->
    {error, manual_fix_required};
try_apply_fix(fix_pattern_match, _CrashData) ->
    {error, manual_fix_required};
try_apply_fix(add_case_clause, CrashData) ->
    fix_case_clause(CrashData);
try_apply_fix(fix_function_arity, _CrashData) ->
    {error, manual_fix_required};
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

fix_case_clause(CrashData) ->
    #{stacktrace := Stacktrace} = CrashData,
    case Stacktrace of
        [{M, F, A, _Loc} | _] ->
            SourceFile = find_source_file(M),
            case file:read_file(SourceFile) of
                {ok, Content} ->
                    case find_case_clause_location(Content, F, A) of
                        {ok, CaseStart, CaseEnd} ->
                            NewContent = add_catch_all_case(Content, CaseStart, CaseEnd),
                            file:write_file(SourceFile, NewContent),
                            coding_agent_self:reload_module(M),
                            {ok, #{file => SourceFile, action => added_catch_all}};
                        {error, not_found} ->
                            {error, could_not_locate_case}
                    end;
                {error, _} ->
                    {error, cannot_read_source}
            end;
        _ ->
            {error, invalid_stacktrace}
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

find_case_clause_location(Content, _F, _A) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    find_case_start(Lines, 1, none).

find_case_start([], _, none) -> {error, not_found};
find_case_start([Line | Rest], LineNum, none) ->
    case binary:match(Line, <<"case ">>) of
        {_, _} ->
            case find_case_end(Rest, LineNum + 1, 1) of
                {ok, EndLine} -> {ok, LineNum, EndLine};
                error -> find_case_start(Rest, LineNum + 1, none)
            end;
        nomatch ->
            find_case_start(Rest, LineNum + 1, none)
    end.

find_case_end([], _, _) -> error;
find_case_end([Line | Rest], LineNum, Depth) ->
    HasEnd = binary:match(Line, <<"end">>) =/= nomatch,
    HasCase = binary:match(Line, <<"case ">>) =/= nomatch,
    NewDepth = Depth + (case HasCase of true -> 1; false -> 0 end) - (case HasEnd of true -> 1; false -> 0 end),
    case NewDepth of
        0 -> {ok, LineNum};
        _ -> find_case_end(Rest, LineNum + 1, NewDepth)
    end.

add_catch_all_case(Content, StartLine, EndLine) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    {Before, CaseBlock} = lists:split(StartLine - 1, Lines),
    {CaseLines, After} = lists:split(EndLine - StartLine + 1, CaseBlock),

    LastLine = lists:last(CaseLines),
    Indent = find_indent(LastLine),
    CatchAll = <<Indent/binary, "_ -> ok">>,
    
    case binary:match(LastLine, <<"end">>) of
        {0, _} ->
            NewCaseLines = lists:droplast(CaseLines) ++ [CatchAll, <<"end">>],
            iolist_to_binary(lists:join(<<"\n">>, Before ++ NewCaseLines ++ After));
        _ ->
            Content
    end.

find_indent(Line) ->
    case binary:match(Line, <<"end">>) of
        {Pos, _} when Pos > 0 ->
            binary:part(Line, {0, Pos});
        _ ->
            case binary:first(Line) of
                $\s -> <<$\s, (find_indent(binary:part(Line, {1, byte_size(Line) - 1}))/binary)>>;
                $\t -> <<$\t, (find_indent(binary:part(Line, {1, byte_size(Line) - 1}))/binary)>>;
                _ -> <<>>
            end
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