-module(coding_agent_repl).
-export([start/0, start/1]).
-export([rl/0]).

-define(HISTORY_FILE, ".coding_agent_history").

start() ->
    start([]).
start(_Args) ->
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
    io:format("║   /modules       - List agent modules                      ║~n"),
    io:format("║   /reload <mod>  - Hot reload a module                    ║~n"),
    io:format("║   /checkpoint    - Create checkpoint                      ║~n"),
    io:format("║   /restore <id>  - Restore from checkpoint                ║~n"),
    io:format("║   /clear         - Clear session history                  ║~n"),
    io:format("║   /trim          - Force memory cleanup                    ║~n"),
    io:format("║   /quit, /exit   - Exit the REPL                          ║~n"),
    io:format("╚════════════════════════════════════════════════════════════╝~n"),
    io:format("~n"),
    
    {ok, {SessionId, _Pid}} = coding_agent_session:new(),
    io:format("Session started: ~s~n~n", [SessionId]),
    
    History = load_history(),
    
    io:format("Type your message and press Enter (/help for commands):~n~n"),
    loop(SessionId, History),
    ok.

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
    try file:read_line(standard_io) of
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
                    loop(SessionId, History);
                _ -> 
                    case process_input(SessionId, History, Input) of
                        {continue, NewHistory} ->
                            loop(SessionId, NewHistory);
                        stop ->
                            ok
                    end
            end
    catch
        Type:Error:Stacktrace ->
            io:format("~n⚠ Crash caught: ~p:~p~n", [Type, Error]),
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ -> coding_agent_healer:analyze_crash(Type, Stacktrace)
            end,
            io:format("Session preserved. Continuing...~n~n"),
            loop(SessionId, History)
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

process_command(SessionId, History, "help" ++ _) ->
    io:format("~nCommands:~n"),
    io:format("  /help           - Show this help~n"),
    io:format("  /status         - Show session & memory status~n"),
    io:format("  /history        - Show conversation history~n"),
    io:format("  /tools          - List available tools~n"),
    io:format("  /modules        - List agent modules~n"),
    io:format("  /reload <mod>  - Hot reload a module~n"),
    io:format("  /checkpoint     - Create checkpoint~n"),
    io:format("  /restore <id>  - Restore from checkpoint~n"),
    io:format("  /clear          - Clear session history~n"),
    io:format("  /trim           - Force memory cleanup~n"),
    io:format("  /crashes        - Show recent crashes~n"),
    io:format("  /reports        - List crash/fix reports~n"),
    io:format("  /fix <id>       - Attempt auto-fix~n"),
    io:format("  /dump <file>   - Dump context to file (.md/.json/.txt)~n"),
    io:format("  /quit           - Exit the REPL~n~n"),
    {continue, History};
    
process_command(SessionId, History, "status" ++ _) ->
    io:format("~nSession Status:~n"),
    try coding_agent_session:stats(SessionId) of
        {ok, Stats} ->
            io:format("  Total tokens (est): ~p~n", [maps:get(<<"total_tokens_estimate">>, Stats, 0)]),
            io:format("  Tool calls: ~p~n", [maps:get(<<"tool_calls">>, Stats, 0)]),
            io:format("  Message count: ~p~n", [maps:get(<<"message_count">>, Stats, 0)]);
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
    
process_command(SessionId, History, "history" ++ _) ->
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
    
process_command(SessionId, History, "tools" ++ _) ->
    Tools = coding_agent_tools:tools(),
    io:format("~nAvailable Tools (~p):~n", [length(Tools)]),
    lists:foreach(fun(Tool) ->
        Name = maps:get(<<"name">>, maps:get(<<"function">>, Tool, #{}), <<"unknown">>),
        io:format("  - ~s~n", [Name])
    end, Tools),
    io:format("~n"),
    {continue, History};
    
process_command(SessionId, History, "modules" ++ _) ->
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
    
process_command(SessionId, History, "reload " ++ ModuleName) ->
    ModAtom = try list_to_existing_atom(safe_trim(ModuleName))
    catch error:badarg -> 
        io:format("Error: Unknown module ~p~n", [ModuleName]),
        {continue, History}
    end,
    case ModAtom of
        _ when is_atom(ModAtom) ->
            io:format("Reloading ~p...~n", [ModAtom]),
            case coding_agent_self:reload_module(ModAtom) of
                #{success := true} ->
                    io:format("✓ Module ~p reloaded successfully~n~n", [ModAtom]);
                #{success := false, error := Error} ->
                    io:format("✗ Failed to reload: ~s~n~n", [Error])
            end,
            {continue, History};
        _ ->
            {continue, History}
    end;
    
process_command(SessionId, History, "checkpoint" ++ _) ->
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
    
process_command(SessionId, History, "clear" ++ _) ->
    try coding_agent_session:clear(SessionId) of
        _ -> io:format("✓ Session history cleared~n~n")
    catch _:_ ->
        io:format("✗ Failed to clear session~n~n")
    end,
    {continue, History};
    
process_command(SessionId, History, "trim" ++ _) ->
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
    
process_command(SessionId, History, "crashes" ++ _) ->
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

process_command(SessionId, History, "reports" ++ _) ->
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
    
process_command(_SessionId, History, "quit" ++ _) ->
    save_history(History),
    io:format("Goodbye!~n"),
    stop;
    
process_command(_SessionId, History, "exit" ++ _) ->
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

process_command(SessionId, History, "dump" ++ _) ->
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
    Message = list_to_binary(Input),
    NewHistory = [Input | History],
    
    io:format("~nThinking...~n"),
    try coding_agent_session:ask(SessionId, Message) of
        {ok, Response, Thinking, _History} ->
            io:format("~n--- Thinking ---~n~s~n--- Response ---~n", [Thinking]),
            print_response(Response),
            io:format("~n"),
            {continue, NewHistory};
        {error, Reason} ->
            io:format("Error: ~p~n~n", [Reason]),
            {continue, NewHistory}
    catch
        Type:Error:Stacktrace ->
            io:format("~n⚠ Session crashed: ~p:~p~n", [Type, Error]),
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ -> 
                    {_, CrashAnalysis} = coding_agent_healer:analyze_crash(Type, Stacktrace),
                    io:format("Crash logged. ~n"),
                    case maps:get(suggested_fix, CrashAnalysis, #{}) of
                        #{hint := Hint} ->
                            io:format("Suggestion: ~s~n", [Hint]);
                        _ -> ok
                    end
            end,
            io:format("Creating new session and continuing...~n"),
            {ok, {NewSessionId, _}} = coding_agent_session:new(),
            io:format("New session: ~s~n~n", [NewSessionId]),
            {continue, NewHistory}
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