-module(coding_agent_repl).
-export([start/0, start/1, loop/2]).
-export([rl/0]).

-define(HISTORY_FILE, ".tarha/history").

start() ->
    start([]).
start(_Args) ->
    try
        application:ensure_all_started(coding_agent),
        
        io:format("~n"),
        io:format("╔════════════════════════════════════════════════════════════╗~n"),
        io:format("║       Coding Agent REPL - Interactive Shell                ║~n"),
        io:format("║       Model: ~s~n", [get_model()]),
        io:format("╠════════════════════════════════════════════════════════════╣~n"),
        io:format("║ Commands:                                                  ║~n"),
        io:format("║   /help          - Show this help                         ║~n"),
        io:format("║   /status        - Show session/memory status            ║~n"),
        io:format("║   /history       - Show conversation history               ║~n"),
        io:format("║   /tools         - List available tools                    ║~n"),
        io:format("║   /models        - List available Ollama models           ║~n"),
        io:format("║   /model <name>  - Show model details                     ║~n"),
        io:format("║   /switch <name> - Switch to different model              ║~n"),
        io:format("║   /modules       - List agent modules                      ║~n"),
        io:format("║   /reload [mod]  - Hot reload module (all if no arg)      ║~n"),
        io:format("║   /checkpoint    - Create checkpoint                      ║~n"),
        io:format("║   /restore <id>  - Restore from checkpoint                ║~n"),
        io:format("║   /clear         - Clear session history                  ║~n"),
        io:format("║   /trim           - Force memory cleanup                    ║~n"),
        io:format("║   /quit, /exit   - Exit the REPL                          ║~n"),
        io:format("╚════════════════════════════════════════════════════════════╝~n"),
        io:format("~n"),
        
        {ok, {SessionId, _Pid}} = coding_agent_session:new(),
        io:format("Session started: ~s~n~n", [SessionId]),
        
        History = load_history(),
        
        io:format("Type your message and press Enter (/help for commands):~n~n"),
        loop(SessionId, History),
        ok
    catch
        Type:Error:Stacktrace ->
            io:format("~nError starting REPL: ~p:~p~n", [Type, Error]),
            io:format("Stack: ~p~n", [Stacktrace]),
            init:stop(1),
            ok
    end.

rl() ->
    start().

get_model() ->
    case application:get_env(coding_agent, model) of
        {ok, Model} when is_list(Model) -> Model;
        {ok, Model} when is_binary(Model) -> binary_to_list(Model);
        _ -> "glm-5:cloud"
    end.

flush_pending_output() ->
    io:format("", []),
    ok.

loop(SessionId, History) ->
    io:format("coder> ", []),
    flush_pending_output(),
    case file:read_line(standard_io) of
        eof ->
            io:format("~nGoodbye!~n"),
            save_history(History),
            ok;
        {error, Reason} ->
            io:format("Input error: ~p~n", [Reason]),
            save_history(History),
            ok;
        {ok, Line} ->
            Input = sanitize_input(Line),
            case Input of
                "" -> 
                    ?MODULE:loop(SessionId, History);
                _ -> 
                    case process_input(SessionId, History, Input) of
                        {continue, NewHistory} ->
                            ?MODULE:loop(SessionId, NewHistory);
                        {new_session, NewSessionId, NewHistory} ->
                            ?MODULE:loop(NewSessionId, NewHistory);
                        stop ->
                            ok
                    end
            end
    end.

sanitize_input(Line) ->
    try
        LineBin = case is_list(Line) of
            true -> iolist_to_binary(Line);
            false when is_binary(Line) -> Line;
            false -> iolist_to_binary([Line])
        end,
        % Remove control characters and normalize whitespace
        CleanBin = re:replace(LineBin, "[\\p{C}\\s]+", " ", [global, {return, binary}]),
        % Remove leading/trailing whitespace
        Stripped = binary:replace(CleanBin, <<" ">>, <<>>, [{global, true}]),
        % Convert back to list safely
        case unicode:characters_to_list(Stripped, utf8) of
            L when is_list(L) -> L;
            _ -> []
        end
    catch
        _:_ ->
            % Last resort: take only printable ASCII
            try
                [C || C <- lists:flatten(io_lib:format("~s", [Line])), 
                      C >= 32, C < 127]
            catch
                _:_ -> []
            end
    end.

safe_trim(String) ->
    try
        string:trim(String)
    catch
        _:_ ->
            L = case is_list(String) of
                true -> String;
                false -> io_lib:format("~s", [String])
            end,
            StrippedFront = lists:dropwhile(fun(C) -> C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r end, L),
            lists:reverse(lists:dropwhile(fun(C) -> C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r end, lists:reverse(StrippedFront)))
    end.

process_input(SessionId, History, Input) ->
    process_input_impl(SessionId, History, Input).

process_input_impl(_SessionId, History, "") ->
    {continue, History};
process_input_impl(SessionId, History, Input) when is_list(Input) ->
    % Check if it starts with /
    case Input of
        [$/ | Rest] ->
            % It's a command - safely process it
            SafeCmd = safe_trim(Rest),
            process_command(SessionId, History, SafeCmd);
        _ ->
            % It's a message to the agent
            SafeInput = safe_trim(Input),
            process_message(SessionId, History, SafeInput)
    end;
process_input_impl(SessionId, History, Input) ->
    % Convert binary to list first
    process_input_impl(SessionId, History, io_lib:format("~s", [Input])).

process_command(SessionId, History, "help" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~nCommands:~n"),
    io:format("  /help           - Show this help~n"),
    io:format("  /status         - Show session & memory status~n"),
    io:format("  /history        - Show conversation history~n"),
    io:format("  /tools          - List available tools~n"),
    io:format("  /models         - List available Ollama models~n"),
    io:format("  /model <name>   - Show model details~n"),
    io:format("  /switch <model> - Switch to a different model~n"),
    io:format("  /modules        - List agent modules~n"),
    io:format("  /reload [mod]  - Hot reload module (all if no arg)~n"),
    io:format("  /checkpoint     - Create checkpoint~n"),
    io:format("  /restore <id>  - Restore from checkpoint~n"),
    io:format("  /compact        - Compact session (summarize and archive old context)~n"),
    io:format("  /sessions       - List saved sessions~n"),
    io:format("  /load <id>      - Load a saved session~n"),
    io:format("  /save           - Save current session~n"),
    io:format("  /clear          - Clear session history~n"),
    io:format("  /trim           - Force memory cleanup~n"),
    io:format("  /crashes        - Show recent crashes~n"),
    io:format("  /reports        - List crash/fix reports~n"),
    io:format("  /fix <id>       - Attempt auto-fix~n"),
    io:format("  /dump <file>   - Dump context to file (.md/.json/.txt)~n"),
    {continue, History};
    
process_command(SessionId, History, "status" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~nSession Status:~n"),
    try coding_agent_session:stats(SessionId) of
        {ok, Stats} ->
            %% Session token stats
            SessionPrompt = maps:get(<<"session_prompt_tokens">>, Stats, 0),
            SessionCompletion = maps:get(<<"session_completion_tokens">>, Stats, 0),
            SessionEstimated = maps:get(<<"session_estimated_tokens">>, Stats, 0),
            SessionTotal = maps:get(<<"session_total_tokens">>, Stats, 0),
            ToolCalls = maps:get(<<"tool_calls">>, Stats, 0),
            MsgCount = maps:get(<<"message_count">>, Stats, 0),
            io:format("  Session Tokens:~n"),
            io:format("    Prompt:       ~p~n", [SessionPrompt]),
            io:format("    Completion:   ~p~n", [SessionCompletion]),
            io:format("    Estimated:    ~p~n", [SessionEstimated]),
            io:format("    Total:        ~p~n", [SessionTotal]),
            io:format("  Tool calls:    ~p~n", [ToolCalls]),
            io:format("  Messages:      ~p~n", [MsgCount]),
            
            %% Global token stats from Ollama client
            GlobalPrompt = maps:get(<<"global_prompt_tokens">>, Stats, 0),
            GlobalCompletion = maps:get(<<"global_completion_tokens">>, Stats, 0),
            GlobalEstimated = maps:get(<<"global_estimated_tokens">>, Stats, 0),
            io:format("~nGlobal Token Stats:~n"),
            io:format("    Total Prompt:     ~p~n", [GlobalPrompt]),
            io:format("    Total Completion: ~p~n", [GlobalCompletion]),
            io:format("    Total Estimated:  ~p~n", [GlobalEstimated]);
        {error, _} ->
            io:format("  (session error)~n")
    catch _:_ ->
        io:format("  (session not available)~n")
    end,
    io:format("~nMemory Status:~n"),
    try coding_agent_process_monitor:status() of
        {ok, MemStatus} ->
            io:format("  Total: ~p KB~n", [maps:get(total_memory, MemStatus) div 1024]),
            io:format("  Processes: ~p~n", [maps:get(process_count, MemStatus)]),
            io:format("  ETS tables: ~p~n", [length(ets:all())]);
        _ ->
            io:format("  (memory manager not available)~n")
    catch _:_ ->
        io:format("  (memory manager not available)~n")
    end,
    Ckpts = try coding_agent_self:list_checkpoints() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end,
    io:format("  Checkpoints: ~p~n~n", [length(Ckpts)]),
    {continue, History};
    
process_command(SessionId, History, "history" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    {ok, Messages} = coding_agent_session:history(SessionId),
    io:format("~nConversation History:~n"),
    lists:foreach(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"unknown">>),
        Content = maps:get(<<"content">>, Msg, <<"">>),
        Preview = case byte_size(Content) of
            N when N > 200 -> <<(binary:part(Content, 0, 200))/binary, "..."/utf8>>;
            _ -> Content
        end,
        io:format("  [~s] ~s~n", [Role, Preview])
    end, Messages),
    io:format("~n"),
    {continue, History};
    
process_command(SessionId, History, "tools" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Tools = coding_agent_tools:tools(),
    io:format("~nAvailable Tools (~p):~n", [length(Tools)]),
    lists:foreach(fun(Tool) ->
        Name = maps:get(<<"name">>, maps:get(<<"function">>, Tool, #{}), <<"unknown">>),
        io:format("  - ~s~n", [Name])
    end, Tools),
    io:format("~n"),
    {continue, History};

process_command(_SessionId, History, "models" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~nAvailable Ollama Models:~n"),
    case coding_agent_ollama:list_models() of
        {ok, Models} when is_list(Models) ->
            CurrentModel = get_model(),
            lists:foreach(fun(Model) ->
                Name = maps:get(name, Model, <<"unknown">>),
                NameStr = case is_binary(Name) of true -> binary_to_list(Name); false -> Name end,
                Size = maps:get(size, Model, 0),
                SizeMB = case is_integer(Size) of true -> Size div (1024 * 1024); false -> 0 end,
                Marker = case lists:prefix(CurrentModel, NameStr) of true -> " *"; false -> "" end,
                io:format("  ~s (~p MB)~s~n", [NameStr, SizeMB, Marker])
            end, Models),
            io:format("~n~p model(s) found.~n~n", [length(Models)]);
        {error, Reason} ->
            io:format("  Error listing models: ~p~n~n", [Reason])
    end,
    {continue, History};

process_command(_SessionId, History, "model " ++ ModelName) ->
    Name = safe_trim(ModelName),
    io:format("~nModel Details for: ~s~n", [Name]),
    case coding_agent_ollama:show_model(Name, #{}) of
        {ok, ModelInfo} ->
            Details = maps:get(<<"details">>, ModelInfo, #{}),
            Family = maps:get(<<"family">>, Details, <<"unknown">>),
            ParamSize = maps:get(<<"parameter_size">>, Details, <<"unknown">>),
            QuantLevel = maps:get(<<"quantization_level">>, Details, <<"unknown">>),
            Capabilities = maps:get(<<"capabilities">>, ModelInfo, []),
            Parameters = maps:get(<<"parameters">>, ModelInfo, undefined),
            License = maps:get(<<"license">>, ModelInfo, undefined),
            Modified = maps:get(<<"modified_at">>, ModelInfo, undefined),
            ModelInfoMap = maps:get(<<"model_info">>, ModelInfo, #{}),
            
            io:format("  Family: ~s~n", [Family]),
            io:format("  Parameter Size: ~s~n", [ParamSize]),
            io:format("  Quantization: ~s~n", [QuantLevel]),
            io:format("  Modified: ~s~n", [Modified]),
            case License of
                undefined -> ok;
                _ -> io:format("  License: ~s~n", [binary:part(License, 0, min(byte_size(License), 100))])
            end,
            case Capabilities of
                [] -> ok;
                _ -> io:format("  Capabilities: ~p~n", [Capabilities])
            end,
            case Parameters of
                undefined -> ok;
                _ -> 
                    ParamStr = binary:part(Parameters, 0, min(byte_size(Parameters), 200)),
                    io:format("  Parameters: ~s~n", [ParamStr])
            end,
            
            % Try to extract context length
            CtxLen = find_context_length(ModelInfoMap),
            io:format("  Context Length: ~p~n", [CtxLen]),
            
            io:format("~n"),
            {continue, History};
        {error, Reason} ->
            io:format("  Error getting model info: ~p~n~n", [Reason]),
            {continue, History}
    end;

process_command(SessionId, History, "switch " ++ ModelName) ->
    Name = safe_trim(ModelName),
    io:format("Switching to model: ~s...~n", [Name]),
    case coding_agent_ollama:switch_model(Name) of
        {ok, OldModel, NewModel} ->
            io:format("✓ Switched from ~s to ~s~n~n", [OldModel, NewModel]),
            io:format("Session cleared (new model context).~n~n");
        {error, Reason} ->
            io:format("✗ Failed to switch model: ~p~n~n", [Reason])
    end,
    {continue, History};
    
process_command(SessionId, History, "modules" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Modules = try coding_agent_self:get_modules() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end,
    io:format("~nAgent Modules:~n"),
    lists:foreach(fun(M) ->
        Name = maps:get(name, M),
        Loaded = maps:get(loaded, M, false),
        Path = maps:get(path, M, <<"">>),
        Status = case Loaded of true -> "[loaded]"; false -> "[unloaded]" end,
        io:format("  ~p ~s ~s~n", [Name, Status, Path])
    end, Modules),
    io:format("~n"),
    {continue, History};
    
process_command(SessionId, History, "reload" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case safe_trim(Rest) of
        "" ->
            io:format("Reloading all modules...~n"),
            try coding_agent_self:reload_all() of
                Results when is_list(Results) ->
                    Successes = [M || {M, #{success := true}} <- Results],
                    Failures = [{M, E} || {M, #{success := false, error := E}} <- Results],
                    io:format("✓ Reloaded ~p modules successfully~n", [length(Successes)]),
                    case Failures of
                        [] -> ok;
                        _ ->
                            io:format("✗ Failed to reload ~p modules:~n", [length(Failures)]),
                            lists:foreach(fun({M, E}) ->
                                io:format("    ~p: ~s~n", [M, E])
                            end, Failures)
                    end,
                    io:format("~n");
                Other ->
                    io:format("✗ Unexpected result: ~p~n~n", [Other])
            catch
                Type:Error:Stack ->
                    io:format("✗ Reload all crashed: ~p:~p~n", [Type, Error]),
                    report_crash(Type, Error, Stack),
                    {continue, History}
            end,
            {continue, History};
        ModuleName ->
            ModAtom = try list_to_existing_atom(ModuleName)
            catch error:badarg -> 
                io:format("Error: Unknown module ~p~n", [ModuleName]),
                {continue, History}
            end,
            case ModAtom of
                _ when is_atom(ModAtom) ->
                    io:format("Reloading ~p...~n", [ModAtom]),
                    try coding_agent_self:reload_module(ModAtom) of
                        #{success := true} ->
                            io:format("✓ Module ~p reloaded successfully~n~n", [ModAtom]);
                        #{success := false, error := Error} ->
                            io:format("✗ Failed to reload: ~s~n~n", [Error]);
                        Other ->
                            io:format("✗ Unexpected result: ~p~n~n", [Other])
                    catch
                        Type:Error:Stack ->
                            io:format("✗ Reload crashed: ~p:~p~n", [Type, Error]),
                            report_crash(Type, Error, Stack),
                            {continue, History}
                    end,
                    {continue, History};
                _ ->
                    {continue, History}
            end
    end;
    
process_command(SessionId, History, "checkpoint" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case coding_agent_self:create_checkpoint() of
        #{success := true, id := Id} ->
            io:format("✓ Checkpoint created: ~s~n~n", [Id]);
        #{success := false, error := Error} ->
            io:format("✗ Failed: ~s~n~n", [Error])
    end,
    {continue, History};
    
process_command(SessionId, History, "restore " ++ CkptId) ->
    Id = list_to_binary(safe_trim(CkptId)),
    case coding_agent_self:restore_checkpoint(Id) of
        #{success := true} ->
            io:format("✓ Restored from checkpoint ~s~n~n", [Id]);
        #{success := false, error := Error} ->
            io:format("✗ Failed: ~s~n~n", [Error])
    end,
    {continue, History};
    
process_command(SessionId, History, "clear" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    try coding_agent_session:clear(SessionId) of
        _ -> io:format("✓ Session history cleared~n~n")
    catch _:_ ->
        io:format("✗ Failed to clear session~n~n")
    end,
    {continue, History};
    
process_command(SessionId, History, "trim" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("Trimming memory...~n"),
    try coding_agent_process_monitor:trim() of
        _ -> ok
    catch _:_ ->
        io:format("Warning: memory trim failed~n")
    end,
    try coding_agent_process_monitor:status() of
        {ok, MemStatus} ->
            io:format("✓ Memory trimmed. Current: ~p KB~n~n", [maps:get(total_memory, MemStatus) div 1024]);
        _ ->
            io:format("✓ Memory trimmed~n~n")
    catch _:_ ->
        io:format("✓ Memory trimmed~n~n")
    end,
    {continue, History};

process_command(SessionId, History, "compact" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("Compacting session...~n"),
    try coding_agent_session:compact(SessionId) of
        {ok, #{archived_as := ArchiveId, summary_size := SummarySize}} ->
            io:format("✓ Session compacted.~n"),
            io:format("  Archived as: ~s~n", [ArchiveId]),
            io:format("  Summary size: ~p bytes~n~n", [SummarySize]);
        {error, Reason} ->
            io:format("✗ Compaction failed: ~p~n~n", [Reason])
    catch
        Type:Error ->
            io:format("✗ Compaction crashed: ~p:~p~n~n", [Type, Error])
    end,
    {continue, History};

process_command(SessionId, History, "crashes" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Crashes = try coding_agent_healer:get_crashes() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end,
    io:format("~nRecent Crashes:~n"),
    lists:foreach(fun({Id, Data}) ->
        Type = maps:get(type, Data, unknown),
        Time = maps:get(timestamp, Data, 0),
        Module = maps:get(module, Data, unknown),
        Reason = maps:get(reason, Data, unknown),
        io:format("  ~s:~n    Type: ~p~n    Module: ~p~n    Reason: ~p~n    Time: ~p~n", [Id, Type, Module, Reason, Time])
    end, lists:sublist(Crashes, 10)),
    io:format("~nUse /fix <id> to attempt auto-fix~n"),
    io:format("Use /reports to list crash report files~n~n"),
    {continue, History};

process_command(SessionId, History, "reports" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    ReportDir = ".coding_agent_reports",
    case filelib:is_dir(ReportDir) of
        false ->
            io:format("~nNo crash reports directory found.~n~n"),
            {continue, History};
        true ->
            Files = filelib:wildcard(filename:join(ReportDir, "*.md")),
            io:format("~nCrash & Fix Reports (~p files):~n", [length(Files)]),
            lists:foreach(fun(File) ->
                Basename = filename:basename(File, ".md"),
                io:format("  ~s~n", [Basename])
            end, lists:sort(Files)),
            io:format("~nView with: cat ~s/<file>.md~n~n", [ReportDir]),
            {continue, History}
    end;
    
process_command(SessionId, History, "fix " ++ CrashId) ->
    Id = list_to_binary(safe_trim(CrashId)),
    io:format("Attempting auto-fix for ~s...~n", [Id]),
    case coding_agent_healer:auto_fix(Id) of
        {ok, Result} ->
            io:format("✓ Fix applied: ~p~n~n", [Result]);
        {error, Reason} ->
            io:format("✗ Auto-fix failed: ~p~n~n", [Reason])
    end,
    {continue, History};
    
process_command(SessionId, History, "sessions" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~nSaved Sessions:~n~n"),
    case coding_agent_session:list_saved_sessions() of
        {ok, SessionIds} when is_list(SessionIds) ->
            case SessionIds of
                [] -> 
                    io:format("  (no saved sessions)~n~n"),
                    io:format("Use /save to save the current session.~n~n");
                _ ->
                    lists:foreach(fun(Sid) ->
                        SidStr = if is_binary(Sid) -> binary_to_list(Sid); true -> Sid end,
                        io:format("  ~s~n", [SidStr])
                    end, lists:sort(SessionIds)),
                    io:format("~n~p session(s) found.~n~n", [length(SessionIds)])
            end;
        {error, Reason} ->
            io:format("  Error listing sessions: ~p~n~n", [Reason])
    end,
    {continue, History};

process_command(SessionId, History, "load " ++ SessionIdArg) ->
    LoadId = list_to_binary(string:trim(SessionIdArg)),
    io:format("Loading session ~s...~n", [LoadId]),
    case coding_agent_session:load_session(LoadId) of
        {ok, {NewSessionId, _Pid}} ->
            io:format("✓ Session loaded: ~s~n", [NewSessionId]),
            io:format("Session ID: ~s~n~n", [NewSessionId]),
            loop(NewSessionId, []);
        {error, session_not_found} ->
            io:format("✗ Session not found: ~s~n", [LoadId]),
            io:format("Use /sessions to see available sessions.~n~n"),
            {continue, History};
        {error, Reason} ->
            io:format("✗ Failed to load session: ~p~n~n", [Reason]),
            {continue, History}
    end;

process_command(SessionId, History, "save" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("Saving session ~s...~n", [SessionId]),
    case coding_agent_session:save_session(SessionId) of
        {ok, SavedId} ->
            io:format("✓ Session saved: ~s~n~n", [SavedId]);
        {error, Reason} ->
            io:format("✗ Failed to save session: ~p~n~n", [Reason])
    end,
    {continue, History};

process_command(_SessionId, History, "quit" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    save_history(History),
    io:format("Goodbye!~n"),
    stop;
    
process_command(_SessionId, History, "exit" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    save_history(History),
    io:format("Goodbye!~n"),
    stop;

process_command(SessionId, History, "dump " ++ Args) ->
    [Filename | FormatRest] = string:split(string:trim(Args), " "),
    Format = case FormatRest of
        [F | _] -> string:trim(F);
        [] -> filename:extension(Filename)
    end,
    dump_context(SessionId, History, Filename, Format),
    {continue, History};

process_command(SessionId, History, "dump" ++ Rest) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~nUsage: /dump <filename> [format]~n"),
    io:format("  /dump context.md        - Dump full context to markdown~n"),
    io:format("  /dump context.json      - Dump full context to JSON~n"),
    io:format("  /dump context.txt       - Dump full context to text~n"),
    io:format("~n"),
    {continue, History};



process_command(SessionId, History, Unknown) ->
    io:format("Unknown command: /~s~nType /help for available commands.~n~n", [Unknown]),
    {continue, History}.

process_message(SessionId, History, Input) ->
    process_message(SessionId, History, Input, 0).

process_message(SessionId, History, Input, RetryCount) when RetryCount >= 3 ->
    io:format("~nMax retries exceeded. Please try again.~n"),
    {continue, History};
process_message(SessionId, History, Input, RetryCount) ->
    Message = list_to_binary(Input),
    NewHistory = [Input | History],
    
    io:format("~nThinking...~n"),
    try coding_agent_session:ask(SessionId, Message) of
        {ok, Response, _Thinking, _History} ->
            io:format("~n--- Response ---~n"),
            print_response(Response),
            io:format("~n"),
            {continue, NewHistory};
        {error, session_not_found} ->
            io:format("~nSession expired. Creating new session...~n"),
            {ok, {NewSessionId, _}} = coding_agent_session:new(),
            io:format("New session: ~s~n~n", [NewSessionId]),
            process_message(NewSessionId, NewHistory, Input, 0);
        {error, Reason} ->
            io:format("Error: ~p~n~n", [Reason]),
            report_error(Reason, SessionId),
            {continue, NewHistory}
    catch
        exit:{timeout, _} ->
            io:format("~nRequest timed out. Retrying (~p/3)...~n", [RetryCount + 1]),
            timer:sleep(1000 * (RetryCount + 1)),
            process_message(SessionId, History, Input, RetryCount + 1);
        error:undef:Stacktrace ->
            io:format("~n⚠ Undefined function error:~n"),
            lists:foreach(fun({M, F, A, Loc}) ->
                io:format("  ~p:~p/~p at ~p~n", [M, F, A, Loc])
            end, Stacktrace),
            io:format("~nPlease recompile and restart.~n"),
            {continue, History};
        Type:Error:Stacktrace ->
            io:format("~n⚠ Session crashed: ~p:~p~n", [Type, Error]),
            report_crash(Type, Error, Stacktrace, SessionId),
            io:format("Creating new session and continuing...~n"),
            try ets:delete(coding_agent_sessions, SessionId)
            catch _:_ -> ok
            end,
            {ok, {NewSessionId, _}} = coding_agent_session:new(),
            io:format("New session: ~s~n~n", [NewSessionId]),
            {new_session, NewSessionId, NewHistory}
    end.

report_error(Reason, SessionId) ->
    % Don't log HTTP/API errors to crash report - they're handled by retry
    case is_http_error(Reason) of
        true ->
            io:format("(API error, will retry automatically)~n");
        false ->
            io:format("Error: ~p~n", [Reason]),
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ ->
                    Stacktrace = try throw(fake) catch _:_:St -> St end,
                    coding_agent_healer:report_crash(repl_error, Reason, Stacktrace, #{session_id => SessionId}),
                    io:format("Error logged.~n")
            end
    end.

report_crash(Type, Error, Stacktrace, SessionId) ->
    try
        case whereis(coding_agent_healer) of
            undefined -> ok;
            _ ->
                coding_agent_healer:report_crash(repl_crash, {Type, Error}, Stacktrace, #{session_id => SessionId}),
                io:format("Crash logged.~n"),
                {_, CrashAnalysis} = coding_agent_healer:analyze_crash(Type, Stacktrace),
                case maps:get(suggested_fix, CrashAnalysis, #{}) of
                    #{hint := Hint} -> io:format("Suggestion: ~s~n", [Hint]);
                    _ -> ok
                end
        end
    catch
        _:_ -> 
            io:format("Could not log crash (healer unavailable).~n")
    end.

report_error(Reason) ->
    % Don't log HTTP/API errors to crash report - they're handled by retry
    case is_http_error(Reason) of
        true ->
            io:format("(API error, will retry automatically)~n");
        false ->
            io:format("Error: ~p~n", [Reason]),
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ ->
                    Stacktrace = try throw(fake) catch _:_:St -> St end,
                    coding_agent_healer:report_crash(repl_error, Reason, Stacktrace),
                    io:format("Error logged.~n")
            end
    end.

is_http_error({http_error, _, _}) -> true;
is_http_error({status, _, _}) -> true;
is_http_error(max_retries_exceeded) -> true;
is_http_error(timeout) -> true;
is_http_error(_) -> false.

report_crash(Type, Error, Stacktrace) ->
    case whereis(coding_agent_healer) of
        undefined -> ok;
        _ ->
            coding_agent_healer:report_crash(repl_crash, {Type, Error}, Stacktrace),
            io:format("Crash logged.~n"),
            {_, CrashAnalysis} = coding_agent_healer:analyze_crash(Type, Stacktrace),
            case maps:get(suggested_fix, CrashAnalysis, #{}) of
                #{hint := Hint} -> io:format("Suggestion: ~s~n", [Hint]);
                _ -> ok
            end
    end.

dump_context(SessionId, History, Filename, Format0) ->
    Format = case Format0 of
        ".md" -> markdown;
        ".json" -> json;
        ".txt" -> text;
        "md" -> markdown;
        "json" -> json;
        "txt" -> text;
        _ -> text
    end,
    
    io:format("Dumping context to ~s...~n", [Filename]),
    
    Context = gather_context(SessionId, History),
    
    Content = case Format of
        markdown -> format_context_markdown(Context);
        json -> format_context_json(Context);
        text -> format_context_text(Context)
    end,
    
    case file:write_file(Filename, Content) of
        ok ->
            io:format("✓ Context dumped to ~s~n", [Filename]);
        {error, Reason} ->
            io:format("✗ Failed to write file: ~p~n", [Reason])
    end.

gather_context(SessionId, History) ->
    #{
        session_id => SessionId,
        timestamp => erlang:system_time(millisecond),
        datetime => format_datetime(),
        conversation_history => get_conversation_history(SessionId),
        memory_status => get_memory_status(),
        loaded_modules => get_loaded_modules(),
        crash_history => get_crash_history(),
        checkpoints => get_checkpoints(),
        agent_config => get_agent_config()
    }.

get_conversation_history(SessionId) ->
    try coding_agent_session:history(SessionId) of
        {ok, Messages} -> Messages;
        _ -> []
    catch _:_ -> []
    end.

get_memory_status() ->
    try coding_agent_process_monitor:status() of
        {ok, Status} -> Status;
        _ -> #{}
    catch _:_ -> #{}
    end.

get_loaded_modules() ->
    try coding_agent_self:get_modules() of
        {ok, Modules} -> Modules;
        L when is_list(L) -> L;
        _ -> []
    catch _:_ -> []
    end.

get_crash_history() ->
    try coding_agent_healer:get_crashes() of
        {ok, Crashes} -> Crashes;
        L when is_list(L) -> L;
        _ -> []
    catch _:_ -> []
    end.

get_checkpoints() ->
    try coding_agent_self:list_checkpoints() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end.

get_agent_config() ->
    #{
        model => application:get_env(coding_agent, model, <<"glm-5:cloud">>),
        ollama_host => application:get_env(coding_agent, ollama_host, <<"http://localhost:11434">>)
    }.

format_datetime() ->
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:local_time(),
    io_lib:format("~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b", [Year, Month, Day, Hour, Min, Sec]).

format_context_markdown(Context) ->
    SessionId = maps:get(session_id, Context, <<"unknown">>),
    SessionIdStr = if is_binary(SessionId) -> binary_to_list(SessionId); true -> io_lib:format("~p", [SessionId]) end,
    Timestamp = maps:get(timestamp, Context, 0),
    DateTime = maps:get(datetime, Context, ""),
    
    History = maps:get(conversation_history, Context, []),
    Memory = maps:get(memory_status, Context, #{}),
    Modules = maps:get(loaded_modules, Context, []),
    Crashes = maps:get(crash_history, Context, []),
    Checkpoints = maps:get(checkpoints, Context, []),
    Config = maps:get(agent_config, Context, #{}),
    
    Model = maps:get(model, Config, <<"unknown">>),
    ModelStr = if is_binary(Model) -> binary_to_list(Model); true -> io_lib:format("~p", [Model]) end,
    Host = maps:get(ollama_host, Config, <<"unknown">>),
    HostStr = if is_binary(Host) -> binary_to_list(Host); true -> io_lib:format("~p", [Host]) end,
    
    iolist_to_binary([
        <<"# Agent Context Dump\n\n">>,
        io_lib:format("**Session:** ~s\n", [SessionIdStr]),
        io_lib:format("**Timestamp:** ~p (~s)\n\n", [Timestamp, DateTime]),
        
        <<"## Configuration\n\n">>,
        io_lib:format("- **Model:** ~s\n", [ModelStr]),
        io_lib:format("- **Ollama Host:** ~s\n\n", [HostStr]),
        
        <<"## Memory Status\n\n">>,
        format_memory_markdown(Memory),
        <<"\n">>,
        
        <<"## Conversation History\n\n">>,
        format_history_markdown(History),
        <<"\n">>,
        
        <<"## Loaded Modules\n\n">>,
        format_modules_markdown(Modules),
        <<"\n">>,
        
        <<"## Crash History\n\n">>,
        format_crashes_markdown(Crashes),
        <<"\n">>,
        
        <<"## Checkpoints\n\n">>,
        format_checkpoints_markdown(Checkpoints)
    ]).

format_memory_markdown(#{total_memory := Total, process_count := ProcCount}) ->
    io_lib:format("- Total Memory: ~p KB\n- Process Count: ~p\n- ETS Tables: ~p\n", 
        [Total div 1024, ProcCount, length(ets:all())]);
format_memory_markdown(#{<<"total_memory">> := Total, <<"process_count">> := ProcCount}) ->
    io_lib:format("- Total Memory: ~p KB\n- Process Count: ~p\n- ETS Tables: ~p\n", 
        [Total div 1024, ProcCount, length(ets:all())]);
format_memory_markdown(_) ->
    <<"- Memory status unavailable\n">>.

format_history_markdown([]) ->
    <<"> No conversation history\n">>;
format_history_markdown(Messages) ->
    lists:map(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"unknown">>),
        Content = maps:get(<<"content">>, Msg, <<"">>),
        RoleStr = if is_binary(Role) -> binary_to_list(Role); true -> io_lib:format("~p", [Role]) end,
        ContentPreview = case byte_size(Content) of
            N when N > 500 -> binary:part(Content, 0, 500);
            _ -> Content
        end,
        ContentStr = if is_binary(ContentPreview) -> ContentPreview; true -> io_lib:format("~p", [ContentPreview]) end,
        [io_lib:format("### ~s\n\n", [string:uppercase(RoleStr)]),
         ContentStr, "\n\n"]
    end, lists:sublist(Messages, 20)).

format_modules_markdown([]) ->
    <<"> No modules loaded\n">>;
format_modules_markdown(Modules) ->
    lists:map(fun(M) ->
        Name = maps:get(name, M, unknown),
        Loaded = maps:get(loaded, M, false),
        Path = maps:get(path, M, <<>>),
        Status = case Loaded of true -> "loaded"; false -> "unloaded" end,
        PathStr = if is_binary(Path) -> binary_to_list(Path); true -> io_lib:format("~p", [Path]) end,
        io_lib:format("- [~s] ~p at ~s\n", [Status, Name, PathStr])
    end, Modules).

format_crashes_markdown([]) ->
    <<"> No crashes recorded\n">>;
format_crashes_markdown(Crashes) ->
    lists:map(fun({Id, Data}) ->
        Type = maps:get(type, Data, unknown),
        Module = maps:get(module, Data, unknown),
        Reason = maps:get(reason, Data, unknown),
        io_lib:format("- **~s**: ~p in ~p - ~p\n", [Id, Type, Module, Reason])
    end, lists:sublist(Crashes, 10)).

format_checkpoints_markdown([]) ->
    <<"> No checkpoints\n">>;
format_checkpoints_markdown(Checkpoints) ->
    lists:map(fun(Ckpt) ->
        Id = maps:get(id, Ckpt, unknown),
        io_lib:format("- ~s\n", [Id])
    end, Checkpoints).

format_context_json(Context) ->
    jsx:encode(Context).

format_context_text(Context) ->
    SessionId = maps:get(session_id, Context, <<"unknown">>),
    Timestamp = maps:get(timestamp, Context, 0),
    
    History = maps:get(conversation_history, Context, []),
    Memory = maps:get(memory_status, Context, #{}),
    Modules = maps:get(loaded_modules, Context, []),
    Crashes = maps:get(crash_history, Context, []),
    
    iolist_to_binary([
        io_lib:format("Session: ~s\n", [SessionId]),
        io_lib:format("Timestamp: ~p\n\n", [Timestamp]),
        
        "=== Memory Status ===\n",
        format_memory_text(Memory),
        "\n",
        
        "=== Conversation History ===\n",
        format_history_text(History),
        "\n",
        
        "=== Loaded Modules ===\n",
        format_modules_text(Modules),
        "\n",
        
        "=== Recent Crashes ===\n",
        format_crashes_text(Crashes)
    ]).

format_memory_text(#{total_memory := Total, process_count := ProcCount}) ->
    io_lib:format("Total: ~p KB, Processes: ~p\n", [Total div 1024, ProcCount]);
format_memory_text(_) ->
    "Memory status unavailable\n".

format_history_text([]) ->
    "No history\n";
format_history_text(Messages) ->
    lists:map(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"unknown">>),
        Content = maps:get(<<"content">>, Msg, <<"">>),
        io_lib:format("[~s] ~s\n\n", [Role, Content])
    end, Messages).

format_modules_text([]) ->
    "No modules\n";
format_modules_text(Modules) ->
    lists:map(fun(M) ->
        Name = maps:get(name, M, unknown),
        Loaded = maps:get(loaded, M, false),
        io_lib:format("~s ~p\n", [case Loaded of true -> "✓"; false -> "✗" end, Name])
    end, Modules).

format_crashes_text([]) ->
    "No crashes\n";
format_crashes_text(Crashes) ->
    lists:map(fun({Id, Data}) ->
        Type = maps:get(type, Data, unknown),
        Module = maps:get(module, Data, unknown),
        io_lib:format("~s: ~p in ~p\n", [Id, Type, Module])
    end, Crashes).

% Helper to extract context length from model_info
find_context_length(ModelInfo) when is_map(ModelInfo) ->
    Keys = [<<"context_length">>, <<"num_ctx">>, <<"n_ctx">>],
    lists:foldl(fun(Key, Acc) ->
        case Acc of
            undefined -> maps:get(Key, ModelInfo, undefined);
            _ -> Acc
        end
    end, undefined, Keys);
find_context_length(_) ->
    undefined.

print_response(<<>>) ->
    ok;
print_response(Content) when is_binary(Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:foreach(fun(Line) ->
        io:format("  ~s~n", [Line])
    end, Lines);
print_response(Content) ->
    print_response(iolist_to_binary(Content)).

load_history() ->
    case file:read_file(?HISTORY_FILE) of
        {ok, Data} ->
            binary:split(Data, <<"\n">>, [global, trim_all]);
        _ ->
            []
    end.

save_history(History) ->
    Data = lists:join(<<"\n">>, lists:sublist(History, 100)),
    file:write_file(?HISTORY_FILE, Data).