-module(coding_agent_repl).
-export([start/0, start/1, loop/3]).
-export([rl/0]).
-export([load_mcp_servers/0]).

%% Mode: build | plan | meticulous
%% In build mode, agent acts normally
%% In plan mode, agent discusses and refines plans
%% In meticulous mode, agent breaks plans into steps and executes one by one

-define(HISTORY_FILE, ".tarha/history").

%% Plan mode state stored in process dictionary
-define(MODE_KEY, {coding_agent_repl, mode}).
-define(PLAN_KEY, {coding_agent_repl, current_plan}).
-define(STEPS_KEY, {coding_agent_repl, meticulous_steps}).
-define(STEP_INDEX_KEY, {coding_agent_repl, current_step}).
-define(PLAN_DIR, ".tarha/plans").

start() ->
    start([]).
start(_Args) ->
    try
        application:ensure_all_started(coding_agent),
        
        % Auto-load MCP servers from config
        spawn(fun() -> timer:sleep(500), (catch coding_agent_repl:load_mcp_servers()) end),
        
        % Initialize mode to build
        put(?MODE_KEY, build),
        put(?PLAN_KEY, <<"">>),
        put(?STEPS_KEY, []),
        put(?STEP_INDEX_KEY, 0),
        
        io:format("~n"),
        A = coding_agent_ansi,
        io:format("~ts~n", [A:bright_cyan("╔════════════════════════════════════════════════════════════╗")]),
        io:format("~ts~n", [A:bright_cyan("║ ") ++ A:bold(A:bright_cyan("Coding Agent REPL - Interactive Shell")) ++ A:bright_cyan("                ║")]),
        io:format("~ts~n", [A:bright_cyan("║       ") ++ A:bright_yellow("Model:") ++ " " ++ A:bright_green(get_model())]),
        io:format("~ts~n", [A:bright_cyan("╠════════════════════════════════════════════════════════════╣")]),
        io:format("~ts~n", [A:bright_cyan("║ ") ++ A:bright_yellow("Commands:") ++ A:bright_cyan("                                                  ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/help") ++ A:dim("          - Show this help") ++ A:bright_cyan("                         ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/status") ++ A:dim("        - Show session/memory status") ++ A:bright_cyan("            ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/history") ++ A:dim("       - Show conversation history") ++ A:bright_cyan("               ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/tools") ++ A:dim("         - List available tools") ++ A:bright_cyan("                    ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/models") ++ A:dim("        - List available Ollama models") ++ A:bright_cyan("           ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/model <name>") ++ A:dim("  - Show model details") ++ A:bright_cyan("                     ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/switch <name>") ++ A:dim(" - Switch to different model") ++ A:bright_cyan("              ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/context [size]") ++ A:dim("- Show/set context size") ++ A:bright_cyan("                 ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/modules") ++ A:dim("       - List agent modules") ++ A:bright_cyan("                      ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/reload [mod]") ++ A:dim("  - Hot reload module (all if no arg)") ++ A:bright_cyan("      ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/checkpoint") ++ A:dim("    - Create checkpoint") ++ A:bright_cyan("                      ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/restore <id>") ++ A:dim("  - Restore from checkpoint") ++ A:bright_cyan("                ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/clear") ++ A:dim("         - Clear session history") ++ A:bright_cyan("                  ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/trim") ++ A:dim("           - Force memory cleanup") ++ A:bright_cyan("                    ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/plan") ++ A:dim("          - Enter plan mode") ++ A:bright_cyan("                        ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/build") ++ A:dim("         - Exit plan mode, enter build mode") ++ A:bright_cyan("       ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/showplan") ++ A:dim("      - Show current plan") ++ A:bright_cyan("                      ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/editplan") ++ A:dim("      - Edit plan in editor") ++ A:bright_cyan("                    ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/quit, /exit") ++ A:dim("   - Exit the REPL") ++ A:bright_cyan("                          ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/mcp") ++ A:dim("            - List MCP servers") ++ A:bright_cyan("                         ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/mcp-add <n>") ++ A:dim("  - Add MCP server") ++ A:bright_cyan("                             ║")]),
        io:format("~ts~n", [A:bright_cyan("║   ") ++ A:bright_white("/mcp-tools") ++ A:dim("      - List MCP tools") ++ A:bright_cyan("                            ║")]),
        io:format("~ts~n", [A:bright_cyan("╚════════════════════════════════════════════════════════════╝")]),
        io:format("~n"),
        
        {ok, {SessionId, _Pid}} = coding_agent_session:new(),
        io:format("Session started: ~ts~n~n", [coding_agent_ansi:bright_magenta(SessionId)]),
        
        History = load_history(),
        
        io:format("~s~n~n", [coding_agent_ansi:dim("Type your message and press Enter (/help for commands)")]),
        loop(SessionId, History, build),
        ok
    catch
        Type:Error:Stacktrace ->
            io:format("~n~s ~p:~p~n", [coding_agent_ansi:bright_red("Error starting REPL:"), Type, Error]),
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

get_current_mode() ->
    case get(?MODE_KEY) of
        undefined -> build;
        Mode -> Mode
    end.

set_current_mode(Mode) ->
    put(?MODE_KEY, Mode).

get_current_plan() ->
    case get(?PLAN_KEY) of
        undefined -> <<"">>;
        Plan -> Plan
    end.

set_current_plan(Plan) ->
    put(?PLAN_KEY, Plan).

get_meticulous_steps() ->
    case get(?STEPS_KEY) of
        undefined -> [];
        Steps -> Steps
    end.

set_meticulous_steps(Steps) ->
    put(?STEPS_KEY, Steps).

get_current_step_index() ->
    case get(?STEP_INDEX_KEY) of
        undefined -> 0;
        Idx -> Idx
    end.

set_current_step_index(Idx) ->
    put(?STEP_INDEX_KEY, Idx).

save_steps_to_files() ->
    Steps = get_meticulous_steps(),
    PlanDir = ?PLAN_DIR,
    filelib:ensure_dir(PlanDir ++ "/"),
    lists:foreach(fun({Idx, Step}) ->
        Title = maps:get(title, Step, <<"untitled">>),
        SafeName = make_safe_filename(Title),
        Filename = iolist_to_binary([
            PlanDir, "/", integer_to_binary(Idx + 1), "_", SafeName, ".md"
        ]),
        Content = iolist_to_binary([
            <<"# Step ">>, integer_to_binary(Idx + 1), <<": ">>, Title, <<"\n\n">>,
            <<"## Description\n">>, maps:get(description, Step, <<"">>), <<"\n\n">>,
            <<"## Files\n">>, maps:get(files, Step, <<"">>), <<"\n\n">>,
            <<"## Status\n">>, case Idx < get_current_step_index() of
                true -> <<"completed">>;
                false -> case Idx =:= get_current_step_index() of
                    true -> <<"in_progress">>;
                    false -> <<"pending">>
                end
            end, <<"\n">>
        ]),
        file:write_file(Filename, Content)
    end, lists:zip(lists:seq(0, length(Steps) - 1), Steps)).

make_safe_filename(Title) ->
    re:replace(Title, <<"[^a-zA-Z0-9_-]">>, <<"_">>, [global, {return, binary}]).

parse_steps_from_response(Response) when is_binary(Response) ->
    StepStart = <<"<<<STEP">>,
    StepEnd = <<"<<<ENDSTEP">>,
    case binary:match(Response, StepStart) of
        nomatch -> [];
        _ ->
            Parts = binary:split(Response, StepStart, [global]),
            Steps = lists:filtermap(fun(Part) ->
                case binary:match(Part, StepEnd) of
                    nomatch -> false;
                    _ ->
                        [Body | _] = binary:split(Part, StepEnd),
                        Title = case re:run(Body, <<"Title:\\s*(.+?)\\n">>, [{capture, [1], binary}]) of
                            {match, [T]} -> T;
                            _ -> <<"untitled">>
                        end,
                        Desc = case re:run(Body, <<"Description:\\s*(.+?)(?:\\nFiles:|$)">>, [{capture, [1], binary}, dotall]) of
                            {match, [D]} -> D;
                            _ -> Body
                        end,
                        Files = case re:run(Body, <<"Files:\\s*(.+?)(?:\\n|$)">>, [{capture, [1], binary}]) of
                            {match, [F]} -> F;
                            _ -> <<"">>
                        end,
                        {true, #{title => string:trim(Title), description => string:trim(Desc), files => string:trim(Files)}}
                end
            end, Parts),
            Steps
    end.

get_mode_prompt(build) ->
    coding_agent_ansi:bright_cyan("coder") ++ "> ";
get_mode_prompt(plan) ->
    coding_agent_ansi:bright_magenta("plan") ++ "> ";
get_mode_prompt(meticulous) ->
    coding_agent_ansi:bright_yellow("meticulous") ++ "> ".

get_mode_indicator(build) ->
    coding_agent_ansi:bright_cyan("[BUILD]");
get_mode_indicator(plan) ->
    coding_agent_ansi:bright_magenta("[PLAN]");
get_mode_indicator(meticulous) ->
    coding_agent_ansi:bright_yellow("[METICULOUS]").

loop(SessionId, History, Mode) ->
    Prompt = get_mode_prompt(Mode),
    io:format("~ts", [Prompt]),
    flush_pending_output(),
    case file:read_line(standard_io) of
        eof ->
            io:format("~n~s~n", [coding_agent_ansi:bright_cyan("Goodbye!")]),
            save_history(History),
            ok;
        {error, Reason} ->
            io:format("~ts ~p~n", [coding_agent_ansi:bright_red("Input error:"), Reason]),
            save_history(History),
            ok;
        {ok, Line} ->
            Input = sanitize_input(Line),
            case Input of
                "" -> 
                    ?MODULE:loop(SessionId, History, Mode);
                _ -> 
                    case process_input(SessionId, History, Input, Mode) of
                        {continue, NewHistory, NewMode} ->
                            ?MODULE:loop(SessionId, NewHistory, NewMode);
                        {new_session, NewSessionId, NewHistory, NewMode} ->
                            ?MODULE:loop(NewSessionId, NewHistory, NewMode);
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
        CleanBin = re:replace(LineBin, "[\\p{C}]+", "", [global, {return, binary}]),
        % Remove leading/trailing whitespace
        Stripped = re:replace(CleanBin, "^\\s+|\\s+$", "", [global, {return, binary}]),
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

process_input(SessionId, History, Input, Mode) ->
    try process_input_impl(SessionId, History, Input, Mode) of
        Result -> Result
    catch
        Type:Error:Stacktrace ->
            io:format("~n~s ~p:~p~n", [coding_agent_ansi:bright_red("** Command crashed:"), Type, Error]),
            report_crash(Type, Error, Stacktrace, SessionId),
            io:format("~n"),
            {continue, History, Mode}
    end.

process_input_impl(_SessionId, History, "", Mode) ->
    {continue, History, Mode};
process_input_impl(SessionId, History, Input, Mode) when is_list(Input) ->
    % Check if it starts with /
    case Input of
        [$/ | Rest] ->
            % It's a command - safely process it
            SafeCmd = safe_trim(Rest),
            process_command(SessionId, History, SafeCmd, Mode);
        _ ->
            % It's a message to the agent
            SafeInput = safe_trim(Input),
            process_message(SessionId, History, SafeInput, Mode)
    end;
process_input_impl(SessionId, History, Input, Mode) ->
    % Convert binary to list first
    process_input_impl(SessionId, History, io_lib:format("~s", [Input]), Mode).

process_command(SessionId, History, "help" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Commands:")]),
    io:format("  " ++ coding_agent_ansi:bright_white("/help") ++ coding_agent_ansi:dim("           - Show this help") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/status") ++ coding_agent_ansi:dim("         - Show session & memory status") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/history") ++ coding_agent_ansi:dim("        - Show conversation history") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/tools") ++ coding_agent_ansi:dim("          - List available tools") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/models") ++ coding_agent_ansi:dim("         - List available Ollama models") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/model <name>") ++ coding_agent_ansi:dim("   - Show model details") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/switch <model>") ++ coding_agent_ansi:dim(" - Switch to a different model") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/context [size]") ++ coding_agent_ansi:dim(" - Show/set max context size") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/modules") ++ coding_agent_ansi:dim("        - List agent modules") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/reload [mod]") ++ coding_agent_ansi:dim("  - Hot reload module (all if no arg)") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/checkpoint") ++ coding_agent_ansi:dim("     - Create checkpoint") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/restore <id>") ++ coding_agent_ansi:dim("  - Restore from checkpoint") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/compact") ++ coding_agent_ansi:dim("        - Compact session (summarize and archive old context)") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/sessions") ++ coding_agent_ansi:dim("       - List saved sessions (with metadata)") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/resume") ++ coding_agent_ansi:dim("        - Resume most recent session") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/load <id>") ++ coding_agent_ansi:dim("      - Load a saved session") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/save") ++ coding_agent_ansi:dim("           - Save current session") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/clear") ++ coding_agent_ansi:dim("          - Clear session history") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/trim") ++ coding_agent_ansi:dim("           - Force memory cleanup") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/cancel") ++ coding_agent_ansi:dim("         - Cancel in-progress operation") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/crashes") ++ coding_agent_ansi:dim("        - Show recent crashes") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/reports") ++ coding_agent_ansi:dim("        - List crash/fix reports") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/fix <id>") ++ coding_agent_ansi:dim("       - Attempt auto-fix") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/dump <file>") ++ coding_agent_ansi:dim("   - Dump context to file (.md/.json/.txt)") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/plan") ++ coding_agent_ansi:dim("           - Enter plan mode (discuss and refine plans)") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/build") ++ coding_agent_ansi:dim("          - Exit plan mode, enter build mode (execute)") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/showplan") ++ coding_agent_ansi:dim("       - Show current plan") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/editplan") ++ coding_agent_ansi:dim("       - Edit plan in external editor") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/clearplan") ++ coding_agent_ansi:dim("      - Clear current plan") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/meticulous") ++ coding_agent_ansi:dim("   - Step-by-step planning mode") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/steps") ++ coding_agent_ansi:dim("          - View implementation steps") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/confirm") ++ coding_agent_ansi:dim("        - Confirm plan for execution") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/exec") ++ coding_agent_ansi:dim("           - Execute next step") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/mcp") ++ coding_agent_ansi:dim("            - List MCP servers and status") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/mcp-add <cfg>") ++ coding_agent_ansi:dim("    - Add MCP server from config") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/mcp-remove <n>") ++ coding_agent_ansi:dim(" - Remove MCP server") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/mcp-tools") ++ coding_agent_ansi:dim("        - List MCP tools") ++ "~n"),
    io:format("  " ++ coding_agent_ansi:bright_white("/quit, /exit") ++ coding_agent_ansi:dim("    - Exit REPL") ++ "~n"),
    io:format("~n" ++ coding_agent_ansi:bright_yellow("Current mode:") ++ " ~s~n", [get_mode_indicator(Mode)]),
    {continue, History, Mode};
    
process_command(SessionId, History, "status" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Session Status:")]),
    try coding_agent_session:stats(SessionId) of
        {ok, Stats} ->
            %% Session token stats
            SessionPrompt = maps:get(<<"session_prompt_tokens">>, Stats, 0),
            SessionCompletion = maps:get(<<"session_completion_tokens">>, Stats, 0),
            SessionEstimated = maps:get(<<"session_estimated_tokens">>, Stats, 0),
            SessionTotal = maps:get(<<"session_total_tokens">>, Stats, 0),
            ContextLength = maps:get(<<"context_length">>, Stats, 0),
            ContextUsage = maps:get(<<"context_usage_percent">>, Stats, 0.0),
            ToolCalls = maps:get(<<"tool_calls">>, Stats, 0),
            MsgCount = maps:get(<<"message_count">>, Stats, 0),
            Model = maps:get(<<"model">>, Stats, <<"unknown">>),
            io:format("  Model:          ~s~n", [Model]),
            io:format("  Context Limit:  ~p tokens~n", [ContextLength]),
            io:format("  Context Usage:  ~p tokens (~.1f%)~n", [SessionTotal, ContextUsage]),
            io:format("  Available:      ~p tokens~n", [ContextLength - SessionTotal]),
            io:format("  Session Tokens:~n"),
            io:format("    Prompt:       ~p~n", [SessionPrompt]),
            io:format("    Completion:   ~p~n", [SessionCompletion]),
            io:format("    Estimated:    ~p~n", [SessionEstimated]),
            io:format("  Tool calls:     ~p~n", [ToolCalls]),
            io:format("  Messages:       ~p~n", [MsgCount]),
            
            %% Global token stats from Ollama client
            GlobalPrompt = maps:get(<<"global_prompt_tokens">>, Stats, 0),
            GlobalCompletion = maps:get(<<"global_completion_tokens">>, Stats, 0),
            GlobalEstimated = maps:get(<<"global_estimated_tokens">>, Stats, 0),
            io:format("~ts~n", [coding_agent_ansi:bright_yellow("Global Token Stats:")]),
            io:format("    Total Prompt:     ~p~n", [GlobalPrompt]),
            io:format("    Total Completion: ~p~n", [GlobalCompletion]),
            io:format("    Total Estimated:  ~p~n", [GlobalEstimated]);
        {error, _} ->
            io:format(coding_agent_ansi:dim("  (session error)") ++ "~n")
    catch _:_ ->
        io:format(coding_agent_ansi:dim("  (session not available)") ++ "~n")
    end,
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Memory Status:")]),
    try coding_agent_process_monitor:status() of
        {ok, MemStatus} ->
            io:format("  Total: ~p KB~n", [maps:get(total_memory, MemStatus) div 1024]),
            io:format("  Processes: ~p~n", [maps:get(process_count, MemStatus)]),
            io:format("  ETS tables: ~p~n", [length(ets:all())]);
        _ ->
            io:format(coding_agent_ansi:dim("  (memory manager not available)") ++ "~n")
    catch _:_ ->
        io:format(coding_agent_ansi:dim("  (memory manager not available)") ++ "~n")
    end,
    Ckpts = try coding_agent_self:list_checkpoints() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end,
    io:format("  Checkpoints: ~p~n~n", [length(Ckpts)]),
    io:format("  Current Mode: ~s~n", [get_mode_indicator(Mode)]),
    CurrentPlan = get_current_plan(),
    case byte_size(CurrentPlan) of
        0 -> io:format("  Current Plan: (none)~n~n");
        _ -> 
            PlanPreview = case byte_size(CurrentPlan) > 100 of
                true -> binary:part(CurrentPlan, 0, 100);
                false -> CurrentPlan
            end,
            io:format("  Current Plan: ~s...~n~n", [PlanPreview])
    end,
    {continue, History, Mode};
    
process_command(SessionId, History, "history" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    {ok, Messages} = coding_agent_session:history(SessionId),
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Conversation History:")]),
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
    {continue, History, Mode};
    
process_command(SessionId, History, "tools" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Tools = coding_agent_tools:tools(),
    io:format("~s (~p):~n", [coding_agent_ansi:bright_yellow("Available Tools"), length(Tools)]),
    lists:foreach(fun(Tool) ->
        Name = maps:get(<<"name">>, maps:get(<<"function">>, Tool, #{}), <<"unknown">>),
        io:format("  - ~s~n", [Name])
    end, Tools),
    io:format("~n"),
    {continue, History, Mode};

process_command(SessionId, History, "cancel", Mode) ->
    case coding_agent_request_registry:halt(SessionId) of
        ok ->
            io:format("~n" ++ coding_agent_ansi:bright_green("✓ Request cancelled.") ++ "~n~n");
        {error, not_found} ->
            io:format("~n" ++ coding_agent_ansi:dim("No active request to cancel.") ++ "~n~n")
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "models" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Available Ollama Models:")]),
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
            io:format("  " ++ coding_agent_ansi:bright_red("Error listing models:") ++ " ~p~n~n", [Reason])
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "model " ++ ModelName, Mode) ->
    Name = safe_trim(ModelName),
    io:format("~ts ~ts~n", [coding_agent_ansi:bright_yellow("Model Details for:"), coding_agent_ansi:bright_green(Name)]),
    case coding_agent_ollama:show_model(Name, #{}) of
        {ok, ModelInfo} ->
            % Print all top-level fields
            print_model_field(ModelInfo, <<"name">>, "Name"),
            print_model_field(ModelInfo, <<"remote_model">>, "Remote Model"),
            print_model_field(ModelInfo, <<"remote_host">>, "Remote Host"),
            print_model_field(ModelInfo, <<"modified_at">>, "Modified"),
            print_model_field(ModelInfo, <<"license">>, "License"),
            
            % Print capabilities
            Capabilities = maps:get(<<"capabilities">>, ModelInfo, []),
            case Capabilities of
                [] -> ok;
                _ -> io:format("  Capabilities: ~p~n", [Capabilities])
            end,
            
            % Print details
            Details = maps:get(<<"details">>, ModelInfo, #{}),
            case Details of
                #{} when map_size(Details) > 0 ->
                    io:format("~n  Details:~n"),
                    print_map_indented(Details, "    ");
                _ -> ok
            end,
            
            % Print modelfile if present
            Modelfile = maps:get(<<"modelfile">>, ModelInfo, undefined),
            case Modelfile of
                undefined -> ok;
                MF when byte_size(MF) > 0 ->
                    Lines = binary:split(MF, <<"\n">>, [global]),
                    io:format("~n  Modelfile:~n"),
                    lists:foreach(fun(L) -> io:format("    ~s~n", [L]) end, Lines);
                _ -> ok
            end,
            
            % Print model_info if present
            ModelInfoMap = maps:get(<<"model_info">>, ModelInfo, #{}),
            case ModelInfoMap of
                #{} when map_size(ModelInfoMap) > 0 ->
                    io:format("~n  Model Info:~n"),
                    print_map_indented(ModelInfoMap, "    ");
                _ -> ok
            end,
            
            % Print parameters if present
            Parameters = maps:get(<<"parameters">>, ModelInfo, undefined),
            case Parameters of
                undefined -> ok;
                _ ->
                    ParamStr = binary:part(Parameters, 0, min(byte_size(Parameters), 500)),
                    io:format("~n  Parameters: ~s~n", [ParamStr])
            end,
            
            % Context length from all possible locations
            CtxLen = find_context_length(ModelInfo),
            io:format("~n  Context Length: ~p~n", [CtxLen]),
            
            io:format("~n"),
            {continue, History, Mode};
        {error, Reason} ->
            io:format("  " ++ coding_agent_ansi:bright_red("Error getting model info:") ++ " ~p~n~n", [Reason]),
            {continue, History, Mode}
    end;

process_command(SessionId, History, "switch " ++ ModelName, Mode) ->
    Name = safe_trim(ModelName),
    io:format(coding_agent_ansi:dim("Switching to model:") ++ " ~s...~n", [Name]),
    case coding_agent_ollama:switch_model(Name) of
        {ok, OldModel, NewModel} ->
            io:format(coding_agent_ansi:bright_green("✓ Switched from") ++ " ~s " ++ coding_agent_ansi:bright_green("to") ++ " ~s~n~n", [OldModel, NewModel]),
            io:format("Session cleared (new model context).~n~n");
        {error, Reason} ->
            io:format("✗ Failed to switch model: ~p~n~n", [Reason])
    end,
    {continue, History, Mode};

process_command(SessionId, History, "context", Mode) ->
    % Show current context size (no arguments)
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Context Size:")]),
    try coding_agent_session:get_context_length(SessionId) of
        {ok, #{context_length := CtxLen, current_tokens := CurrentTokens, usage_percent := UsagePct}} ->
            io:format("  Max Context:    ~p tokens~n", [CtxLen]),
            io:format("  Current Usage: ~p tokens (~.1f%)~n", [CurrentTokens, UsagePct]),
            io:format("  Available:     ~p tokens~n", [CtxLen - CurrentTokens]),
            io:format("~n"),
            io:format("  Usage: /context <size>  - Set new max context size~n~n");
        {error, Reason} ->
            io:format("  " ++ coding_agent_ansi:bright_red("Error:") ++ " ~p~n~n", [Reason])
    catch _:Error ->
        io:format("  " ++ coding_agent_ansi:bright_red("Error:") ++ " ~p~n~n", [Error])
    end,
    {continue, History, Mode};
process_command(SessionId, History, "context " ++ SizeStr, Mode) ->
    % Set context size
    case string:to_integer(safe_trim(SizeStr)) of
        {Size, []} when Size > 0 ->
            io:format(coding_agent_ansi:dim("Setting context size to") ++ " ~p tokens...~n", [Size]),
            case coding_agent_session:set_context_length(SessionId, Size) of
                {ok, #{old_length := OldLen, new_length := NewLen}} ->
                    io:format(coding_agent_ansi:bright_green("✓ Context size changed:") ++ " ~p -> ~p tokens~n~n", [OldLen, NewLen]);
                {error, Reason} ->
                    io:format(coding_agent_ansi:bright_red("✗ Failed to set context size:") ++ " ~p~n~n", [Reason])
            end;
        _ ->
            io:format(coding_agent_ansi:bright_red("✗ Invalid size:") ++ " '~s'. Must be a positive integer.~n~n", [safe_trim(SizeStr)])
    end,
    {continue, History, Mode};
    
process_command(SessionId, History, "modules" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Modules = try coding_agent_self:get_modules() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end,
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Agent Modules:")]),
    lists:foreach(fun(M) ->
        Name = maps:get(name, M),
        Loaded = maps:get(loaded, M, false),
        Path = maps:get(path, M, <<"">>),
        Status = case Loaded of true -> "[loaded]"; false -> "[unloaded]" end,
        io:format("  ~p ~s ~s~n", [Name, Status, Path])
    end, Modules),
    io:format("~n"),
    {continue, History, Mode};
    
process_command(SessionId, History, "reload" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case safe_trim(Rest) of
        "" ->
            io:format(coding_agent_ansi:dim("Reloading all modules...") ++ "~n"),
            try coding_agent_self:reload_all() of
                Results when is_list(Results) ->
                    Successes = [M || {M, #{success := true}} <- Results],
                    Failures = [{M, E} || {M, #{success := false, error := E}} <- Results],
                    io:format(coding_agent_ansi:bright_green("✓ Reloaded") ++ " ~p modules successfully~n", [length(Successes)]),
                    case Failures of
                        [] -> ok;
                        _ ->
                            io:format(coding_agent_ansi:bright_red("✗ Failed to reload") ++ " ~p modules:~n", [length(Failures)]),
                            lists:foreach(fun({M, E}) ->
                                io:format("    ~p: ~s~n", [M, E])
                            end, Failures)
                    end,
                    io:format("~n");
                Other ->
                    io:format(coding_agent_ansi:bright_red("✗ Unexpected result:") ++ " ~p~n~n", [Other])
            catch
                Type:Error:Stack ->
                    io:format(coding_agent_ansi:bright_red("✗ Reload all crashed:") ++ " ~p:~p~n", [Type, Error]),
                    report_crash(Type, Error, Stack),
                    {continue, History, Mode}
            end,
            {continue, History, Mode};
        ModuleName ->
            ModAtom = try list_to_existing_atom(ModuleName)
            catch error:badarg -> 
                io:format(coding_agent_ansi:bright_red("Error:") ++ " Unknown module ~p~n", [ModuleName]),
                {continue, History, Mode}
            end,
            case ModAtom of
                _ when is_atom(ModAtom) ->
                    io:format(coding_agent_ansi:dim("Reloading") ++ " ~p...~n", [ModAtom]),
                    try coding_agent_self:reload_module(ModAtom) of
                        #{success := true} ->
                            io:format(coding_agent_ansi:bright_green("✓ Module") ++ " ~p reloaded successfully~n~n", [ModAtom]);
                        #{success := false, error := Error} ->
                            io:format(coding_agent_ansi:bright_red("✗ Failed to reload:") ++ " ~s~n~n", [Error]);
                        Other ->
                            io:format(coding_agent_ansi:bright_red("✗ Unexpected result:") ++ " ~p~n~n", [Other])
                    catch
                        Type:Error:Stack ->
                            io:format(coding_agent_ansi:bright_red("✗ Reload crashed:") ++ " ~p:~p~n", [Type, Error]),
                            report_crash(Type, Error, Stack),
                            {continue, History, Mode}
                    end,
                    {continue, History, Mode};
                _ ->
                    {continue, History, Mode}
            end
    end;
    
process_command(SessionId, History, "checkpoint" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case coding_agent_self:create_checkpoint() of
        #{success := true, id := Id} ->
            io:format(coding_agent_ansi:bright_green("✓ Checkpoint created:") ++ " ~s~n~n", [Id]);
        #{success := false, error := Error} ->
            io:format(coding_agent_ansi:bright_red("✗ Failed:") ++ " ~s~n~n", [Error])
    end,
    {continue, History, Mode};
    
process_command(SessionId, History, "restore " ++ CkptId, Mode) ->
    Id = list_to_binary(safe_trim(CkptId)),
    case coding_agent_self:restore_checkpoint(Id) of
        #{success := true} ->
            io:format(coding_agent_ansi:bright_green("✓ Restored from checkpoint") ++ " ~s~n~n", [Id]);
        #{success := false, error := Error} ->
            io:format(coding_agent_ansi:bright_red("✗ Failed:") ++ " ~s~n~n", [Error])
    end,
    {continue, History, Mode};
    
process_command(SessionId, History, "clear" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    try coding_agent_session:clear(SessionId) of
        _ -> io:format(coding_agent_ansi:bright_green("✓ Session history cleared") ++ "~n~n")
    catch _:_ ->
        io:format(coding_agent_ansi:bright_red("✗ Failed to clear session") ++ "~n~n")
    end,
    {continue, History, Mode};
    
process_command(SessionId, History, "trim" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format(coding_agent_ansi:dim("Trimming memory...") ++ "~n"),
    try coding_agent_process_monitor:trim() of
        _ -> ok
    catch _:_ ->
        io:format(coding_agent_ansi:bright_yellow("Warning:") ++ " memory trim failed~n")
    end,
    try coding_agent_process_monitor:status() of
        {ok, MemStatus} ->
            io:format(coding_agent_ansi:bright_green("✓ Memory trimmed.") ++ " Current: ~p KB~n~n", [maps:get(total_memory, MemStatus) div 1024]);
        _ ->
            io:format(coding_agent_ansi:bright_green("✓ Memory trimmed") ++ "~n~n")
    catch _:_ ->
        io:format(coding_agent_ansi:bright_green("✓ Memory trimmed") ++ "~n~n")
    end,
    {continue, History, Mode};

process_command(SessionId, History, "compact" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format(coding_agent_ansi:dim("Compacting session...") ++ "~n"),
    try coding_agent_session:compact(SessionId) of
        {ok, #{archived_as := ArchiveId, summary_size := SummarySize}} ->
            io:format(coding_agent_ansi:bright_green("✓ Session compacted.") ++ "~n"),
            io:format("  " ++ coding_agent_ansi:bright_white("Archived as:") ++ " ~s~n", [ArchiveId]),
            io:format("  " ++ coding_agent_ansi:bright_white("Summary size:") ++ " ~p bytes~n~n", [SummarySize]);
        {error, Reason} ->
            io:format(coding_agent_ansi:bright_red("✗ Compaction failed:") ++ " ~p~n~n", [Reason])
    catch
        Type:Error ->
            io:format(coding_agent_ansi:bright_red("✗ Compaction crashed:") ++ " ~p:~p~n~n", [Type, Error])
    end,
    {continue, History, Mode};

process_command(SessionId, History, "crashes" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Crashes = try coding_agent_healer:get_crashes() of
        L when is_list(L) -> L;
        {ok, L} -> L;
        _ -> []
    catch _:_ -> []
    end,
    io:format("~ts~n", [coding_agent_ansi:bright_yellow("Recent Crashes:")]),
    lists:foreach(fun({Id, Data}) ->
        Type = maps:get(type, Data, unknown),
        Time = maps:get(timestamp, Data, 0),
        Module = maps:get(module, Data, unknown),
        Reason = maps:get(reason, Data, unknown),
        io:format("  ~s:~n    Type: ~p~n    Module: ~p~n    Reason: ~p~n    Time: ~p~n", [Id, Type, Module, Reason, Time])
    end, lists:sublist(Crashes, 10)),
    io:format("~nUse /fix <id> to attempt auto-fix~n"),
    io:format("Use /reports to list crash report files~n~n"),
    {continue, History, Mode};

process_command(SessionId, History, "reports" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    ReportDir = ".coding_agent_reports",
    case filelib:is_dir(ReportDir) of
        false ->
            io:format("~nNo crash reports directory found.~n~n"),
            {continue, History, Mode};
        true ->
            Files = filelib:wildcard(filename:join(ReportDir, "*.md")),
            io:format("~nCrash & Fix Reports (~p files):~n", [length(Files)]),
            lists:foreach(fun(File) ->
                Basename = filename:basename(File, ".md"),
                io:format("  ~s~n", [Basename])
            end, lists:sort(Files)),
            io:format("~nView with: cat ~s/<file>.md~n~n", [ReportDir]),
            {continue, History, Mode}
    end;
    
process_command(SessionId, History, "fix " ++ CrashId, Mode) ->
    Id = list_to_binary(safe_trim(CrashId)),
    io:format("Attempting auto-fix for ~s...~n", [Id]),
    case coding_agent_healer:auto_fix(Id) of
        {ok, Result} ->
            io:format("✓ Fix applied: ~p~n~n", [Result]);
        {error, Reason} ->
            io:format("✗ Auto-fix failed: ~p~n~n", [Reason])
    end,
    {continue, History, Mode};
    
process_command(SessionId, History, "sessions" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~n~ts~n", [coding_agent_ansi:bright_cyan("Saved Sessions:")]),
    case coding_agent_session_store:list_sessions_with_metadata() of
        Sessions when is_list(Sessions) ->
            case Sessions of
                [] ->
                    io:format("  (no saved sessions)~n~n"),
                    io:format("Use /save to save the current session.~n~n");
                _ ->
                    lists:foreach(fun(S) ->
                        Id = maps:get(id, S, <<"unknown">>),
                        IdStr = if is_binary(Id) -> binary_to_list(Id); true -> Id end,
                        Summary = maps:get(summary, S, <<"">>),
                        Model = maps:get(model, S, <<"">>),
                        MsgCount = maps:get(message_count, S, 0),
                        Tokens = maps:get(estimated_tokens, S, 0),
                        ModelStr = if is_binary(Model) -> binary_to_list(Model); true -> "unknown" end,
                        SummaryStr = if is_binary(Summary) -> binary_to_list(Summary); true -> Summary end,
                        io:format("  ~ts  (~p msg, ~p tokens, ~s)  \"~s\"~n",
                                  [coding_agent_ansi:bright_white(IdStr), MsgCount, Tokens, ModelStr, SummaryStr])
                    end, Sessions),
                    io:format("~n~p session(s) found.~n", [length(Sessions)]),
                    io:format("Use ~ts to load, ~ts to resume latest.~n~n",
                              [coding_agent_ansi:bright_white("/load <id>"), coding_agent_ansi:bright_white("/resume")])
            end;
        {error, Reason} ->
            io:format("  Error listing sessions: ~p~n~n", [Reason])
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "resume" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case coding_agent_session_store:list_sessions_with_metadata() of
        Sessions when is_list(Sessions), length(Sessions) > 0 ->
            Sorted = lists:sort(fun(A, B) ->
                TA = maps:get(updated_at, A, {{1970,1,1},{0,0,0}}),
                TB = maps:get(updated_at, B, {{1970,1,1},{0,0,0}}),
                TA >= TB
            end, Sessions),
            MostRecent = hd(Sorted),
            LoadId = maps:get(id, MostRecent, <<"">>),
            Summary = maps:get(summary, MostRecent, <<"">>),
            io:format("~n~ts Resuming session ~s: ~s~n~n",
                      [coding_agent_ansi:bright_green("✓"), LoadId, Summary]),
            case coding_agent_session:load_session(LoadId) of
                {ok, {NewSessionId, _Pid}} ->
                    loop(NewSessionId, [], Mode);
                {error, Reason} ->
                    io:format("~ts Failed to resume: ~p~n~n", [coding_agent_ansi:bright_red("✗"), Reason]),
                    {continue, History, Mode}
            end;
        _ ->
            io:format("~n~ts No saved sessions found. Start a new session.~n~n",
                      [coding_agent_ansi:bright_yellow("!")]),
            {continue, History, Mode}
    end;

process_command(SessionId, History, "load " ++ SessionIdArg, Mode) ->
    LoadId = list_to_binary(string:trim(SessionIdArg)),
    io:format("Loading session ~s...~n", [LoadId]),
    case coding_agent_session:load_session(LoadId) of
        {ok, {NewSessionId, _Pid}} ->
            io:format("✓ Session loaded: ~s~n", [NewSessionId]),
            io:format("Session ID: ~s~n~n", [NewSessionId]),
            loop(NewSessionId, [], Mode);
        {error, session_not_found} ->
            io:format("✗ Session not found: ~s~n", [LoadId]),
            io:format("Use /sessions to see available sessions.~n~n"),
            {continue, History, Mode};
        {error, Reason} ->
            io:format("✗ Failed to load session: ~p~n~n", [Reason]),
            {continue, History, Mode}
    end;

process_command(SessionId, History, "save" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("Saving session ~s...~n", [SessionId]),
    case coding_agent_session:save_session(SessionId) of
        {ok, SavedId} ->
            io:format("✓ Session saved: ~s~n~n", [SavedId]);
        {error, Reason} ->
            io:format("✗ Failed to save session: ~p~n~n", [Reason])
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "quit" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    save_history(History),
    io:format("Goodbye!~n"),
    stop;
    
process_command(_SessionId, History, "exit" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    save_history(History),
    io:format("Goodbye!~n"),
    stop;

process_command(SessionId, History, "dump " ++ Args, Mode) ->
    [Filename | FormatRest] = string:split(string:trim(Args), " "),
    Format = case FormatRest of
        [F | _] -> string:trim(F);
        [] -> filename:extension(Filename)
    end,
    dump_context(SessionId, History, Filename, Format),
    {continue, History, Mode};

process_command(SessionId, History, "dump" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~nUsage: /dump <filename> [format]~n"),
    io:format("  /dump context.md        - Dump full context to markdown~n"),
    io:format("  /dump context.json      - Dump full context to JSON~n"),
    io:format("  /dump context.txt       - Dump full context to text~n"),
    io:format("~n"),
    {continue, History, Mode};



%% Plan mode commands
process_command(SessionId, History, "plan" ++ Rest, _Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~n╔════════════════════════════════════════════════════════════╗~n"),
    io:format("║                    ENTERING PLAN MODE                       ║~n"),
    io:format("╠════════════════════════════════════════════════════════════╣~n"),
    io:format("║ In plan mode, you can:                                      ║~n"),
    io:format("║   - Discuss and refine implementation plans                 ║~n"),
    io:format("║   - Think through problems step by step                    ║~n"),
    io:format("║   - Create detailed implementation plans                    ║~n"),
    io:format("║   - Ask clarifying questions                               ║~n"),
    io:format("║                                                             ║~n"),
    io:format("║ Commands:                                                   ║~n"),
    io:format("║   /build       - Exit plan mode, start implementing         ║~n"),
    io:format("║   /showplan    - Show current plan                          ║~n"),
    io:format("║   /editplan    - Edit plan in external editor               ║~n"),
    io:format("║   /clearplan   - Clear current plan                         ║~n"),
    io:format("║   /meticulous   - Enter meticulous step-by-step mode        ║~n"),
    io:format("╚════════════════════════════════════════════════════════════╝~n~n"),
    set_current_mode(plan),
    {continue, History, plan};

process_command(SessionId, History, "build" ++ Rest, _Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    CurrentPlan = get_current_plan(),
    set_current_mode(build),
    io:format("~n╔════════════════════════════════════════════════════════════╗~n"),
    io:format("║                    ENTERING BUILD MODE                      ║~n"),
    io:format("╠════════════════════════════════════════════════════════════╣~n"),
    case byte_size(CurrentPlan) of
        0 ->
            io:format("║ No plan has been created yet.                               ║~n"),
            io:format("║ You can still proceed with implementation.                  ║~n"),
            io:format("║ Use /plan to create a plan first next time.                 ║~n");
        _ ->
            io:format("║ Current plan:~n"),
            PlanLines = binary:split(CurrentPlan, <<"\n">>, [global]),
            PlanPreview = lists:sublist(PlanLines, 5),
            lists:foreach(fun(Line) ->
                io:format("║   ~s~n", [Line])
            end, PlanPreview),
            case length(PlanLines) > 5 of
                true -> io:format("║   ... (~p more lines)~n", [length(PlanLines) - 5]);
                false -> ok
            end
    end,
    io:format("╚════════════════════════════════════════════════════════════╝~n~n"),
    {continue, History, build};

process_command(SessionId, History, "showplan" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    CurrentPlan = get_current_plan(),
    io:format("~n"),
    case byte_size(CurrentPlan) of
        0 ->
            io:format(coding_agent_ansi:dim("No plan has been created yet.") ++ "~n"),
            io:format(coding_agent_ansi:dim("Use /plan to enter plan mode and create a plan.") ++ "~n~n");
        _ ->
            io:format("~ts~n", [coding_agent_ansi:bright_cyan("═══════════════════════════════════════════════════════════════")]),
            io:format("~s~n", [coding_agent_ansi:bold(coding_agent_ansi:bright_yellow("                        CURRENT PLAN"))]),
            io:format("~ts~n", [coding_agent_ansi:bright_cyan("═══════════════════════════════════════════════════════════════")]),
            io:format("~s~n", [CurrentPlan]),
            io:format("═══════════════════════════════════════════════════════════════~n~n")
    end,
    {continue, History, Mode};

process_command(SessionId, History, "editplan" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    % Create temp file with current plan
    TempFile = "/tmp/coding_agent_plan.md",
    CurrentPlan = get_current_plan(),
    file:write_file(TempFile, CurrentPlan),
    
    % Get editor from environment
    Editor = os:getenv("EDITOR", "nano"),
    
    io:format("~n" ++ coding_agent_ansi:dim("Opening plan editor") ++ " (~s)...~n", [Editor]),
    io:format(coding_agent_ansi:dim("Save and exit when done.") ++ "~n~n"),
    
    % Run the editor
    Port = open_port({spawn, Editor ++ " " ++ TempFile}, [stream, eof]),
    wait_for_editor(Port),
    
    % Read the updated plan
    case file:read_file(TempFile) of
        {ok, NewPlan} ->
            set_current_plan(NewPlan),
            io:format("~n✓ Plan updated.~n"),
            io:format(coding_agent_ansi:dim("Use /showplan to view it.") ++ "~n~n");
        {error, Reason} ->
            io:format("~n✗ Failed to read plan: ~p~n~n", [Reason])
    end,
    {continue, History, Mode};

process_command(SessionId, History, "clearplan" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    set_current_plan(<<"">>),
    set_meticulous_steps([]),
    set_current_step_index(0),
    io:format("~n✓ Plan and steps cleared.~n~n"),
    {continue, History, Mode};

process_command(SessionId, History, "meticulous" ++ Rest, _Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    io:format("~n╔════════════════════════════════════════════════════════════╗~n"),
    io:format("║                 ENTERING METICULOUS MODE                    ║~n"),
    io:format("╠════════════════════════════════════════════════════════════╣~n"),
    io:format("║ In meticulous mode, the agent will:                       ║~n"),
    io:format("║   1. Discuss and refine the plan with you                  ║~n"),
    io:format("║   2. Break the plan into numbered steps                    ║~n"),
    io:format("║   3. Save each step as a separate plan file                 ║~n"),
    io:format("║   4. Execute steps one at a time with your approval         ║~n"),
    io:format("║                                                             ║~n"),
    io:format("║ Commands:                                                   ║~n"),
    io:format("║   /steps       - View all steps and current progress        ║~n"),
    io:format("║   /confirm      - Confirm plan, ready to execute            ║~n"),
    io:format("║   /exec         - Execute the next pending step              ║~n"),
    io:format("║   /skip <n>     - Skip step n                              ║~n"),
    io:format("║   /build        - Switch to build mode (unrestricted)       ║~n"),
    io:format("║   /plan         - Switch back to plan mode                  ║~n"),
    io:format("╚════════════════════════════════════════════════════════════╝~n~n"),
    set_current_mode(meticulous),
    {continue, History, meticulous};

process_command(SessionId, History, "steps" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Steps = get_meticulous_steps(),
    CurrentIdx = get_current_step_index(),
    case Steps of
        [] ->
            io:format("~n~ts~n", [coding_agent_ansi:dim("No steps defined yet.")]),
            io:format("~ts~n~n", [coding_agent_ansi:dim("Ask the agent to break the plan into steps in meticulous mode.")]);
        _ ->
            io:format("~n~ts~n", [coding_agent_ansi:bright_yellow("═══ Implementation Steps ═══")]),
            lists:foldl(fun({Idx, Step}, _) ->
                Title = maps:get(title, Step, <<"untitled">>),
                Desc = maps:get(description, Step, <<"">>),
                Marker = case Idx < CurrentIdx of
                    true -> coding_agent_ansi:bright_green("✓");
                    false -> case Idx =:= CurrentIdx of
                        true -> coding_agent_ansi:bright_yellow("▶");
                        false -> coding_agent_ansi:dim("○")
                    end
                end,
                io:format("  ~ts Step ~p: ~ts~n", [Marker, Idx + 1, Title]),
                case byte_size(Desc) > 0 of
                    true ->
                        DescPreview = case byte_size(Desc) > 120 of
                            true -> <<(binary:part(Desc, 0, 120))/binary, "...">>;
                            false -> Desc
                        end,
                        io:format("       ~ts~n", [coding_agent_ansi:dim(binary_to_list(DescPreview))]);
                    false -> ok
                end,
                Idx
            end, 0, lists:zip(lists:seq(0, length(Steps) - 1), Steps)),
            io:format("~n~ts~n~n", [coding_agent_ansi:bright_yellow("════════════════════════════")])
    end,
    {continue, History, Mode};

process_command(SessionId, History, "confirm" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Steps = get_meticulous_steps(),
    PlanText = get_current_plan(),
    case Steps of
        [] ->
            io:format("~n~ts No steps defined yet.~n", [coding_agent_ansi:bright_red("✗")]),
            io:format("~ts Ask the agent to break the plan into steps first.~n~n", [coding_agent_ansi:dim("")]);
        _ ->
            save_steps_to_files(),
            io:format("~n~ts Plan confirmed with ~p steps.~n", [coding_agent_ansi:bright_green("✓"), length(Steps)]),
            io:format("~ts Step files saved to ~ts~n", [coding_agent_ansi:dim(""), coding_agent_ansi:bright_white(?PLAN_DIR)]),
            io:format("~ts Use ~ts to execute the next step.~n~n", [coding_agent_ansi:dim(""), coding_agent_ansi:bright_white("/exec")])
    end,
    {continue, History, Mode};

process_command(SessionId, History, "exec" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    Steps = get_meticulous_steps(),
    CurrentIdx = get_current_step_index(),
    case Steps of
        [] ->
            io:format("~n~ts No steps to execute. Use /confirm first.~n~n", [coding_agent_ansi:bright_red("✗")]),
            {continue, History, Mode};
        _ when CurrentIdx >= length(Steps) ->
            io:format("~n~ts All steps completed! Use /build to continue freely.~n~n", [coding_agent_ansi:bright_green("✓")]),
            {continue, History, build};
        _ ->
            Step = lists:nth(CurrentIdx + 1, Steps),
            Title = maps:get(title, Step, <<"untitled">>),
            Desc = maps:get(description, Step, <<"">>),
            io:format("~n~ts Executing Step ~p/~p: ~ts~n", [coding_agent_ansi:bright_yellow("▶"), CurrentIdx + 1, length(Steps), Title]),
            io:format("~ts~n~n", [coding_agent_ansi:dim(binary_to_list(Desc))]),
            StepPrompt = iolist_to_binary([
                <<"[STEP EXECUTION] Execute step ">>, integer_to_binary(CurrentIdx + 1), <<" of ">>, integer_to_binary(length(Steps)), <<": ">>, Title, <<"\n\n">>,
                <<"Description: ">>, Desc, <<"\n\n">>,
                <<"Execute ONLY this step. Focus on completing this specific task.">>
            ]),
            set_current_step_index(CurrentIdx + 1),
            save_steps_to_files(),
            process_message(SessionId, History, binary_to_list(StepPrompt), build, 0),
            {continue, History, Mode}
    end;

process_command(SessionId, History, "skip " ++ NumStr, Mode) ->
    case catch list_to_integer(string:trim(NumStr)) of
        Num when is_integer(Num), Num > 0 ->
            Steps = get_meticulous_steps(),
            case Num > length(Steps) of
                true ->
                    io:format("~n~ts Step ~p does not exist.~n~n", [coding_agent_ansi:bright_red("✗"), Num]);
                false ->
                    set_current_step_index(Num),
                    io:format("~n~ts Skipping to step ~p.~n~n", [coding_agent_ansi:bright_green("✓"), Num])
            end;
        _ ->
            io:format("~n~ts Invalid step number. Use /skip <n>~n~n", [coding_agent_ansi:bright_red("✗")])
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "mcp" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case whereis(coding_agent_mcp_registry) of
        undefined ->
            io:format("~n~ts MCP system not started.~n~n", [coding_agent_ansi:bright_red("✗")]);
        _ ->
            Servers = coding_agent_mcp_registry:list_servers(),
            io:format("~n~ts~n", [coding_agent_ansi:bright_cyan("═══ MCP Servers ═══")]),
            case Servers of
                [] ->
                    io:format("  No MCP servers configured.~n"),
                    io:format("  Add servers to ~ts~n", [coding_agent_ansi:bright_white(".tarha/mcp_servers.json")]),
                    io:format("  Or use ~ts to add one.~n", [coding_agent_ansi:bright_white("/mcp-add <name>")]);
                _ ->
                    lists:foreach(fun({Name, Info, Status}) ->
                        StatusStr = case Status of
                            ready -> coding_agent_ansi:bright_green("ready");
                            initializing -> coding_agent_ansi:bright_yellow("init");
                            error -> coding_agent_ansi:bright_red("error");
                            _ -> coding_agent_ansi:dim(atom_to_list(Status))
                        end,
                        ToolCount = length(maps:get(tools, Info, [])),
                        ResCount = length(maps:get(resources, Info, [])),
                        Transport = maps:get(transport, Info, <<"">>),
                        io:format("  ~ts  ~ts  ~p tools, ~p resources  [~s]~n",
                                  [coding_agent_ansi:bright_white(binary_to_list(Name)), StatusStr,
                                   ToolCount, ResCount, Transport])
                    end, Servers)
            end,
            io:format("~ts~n~n", [coding_agent_ansi:bright_cyan("════════════════════")])
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "mcp-add " ++ NameStr, Mode) ->
    case whereis(coding_agent_mcp_registry) of
        undefined ->
            io:format("~n~ts MCP system not started.~n~n", [coding_agent_ansi:bright_red("✗")]),
            {continue, History, Mode};
        _ ->
            Name = list_to_binary(string:trim(NameStr)),
            Servers = coding_agent_config:get_mcp_servers(),
            case maps:get(Name, Servers, undefined) of
                undefined ->
                    io:format("~n~ts Server '~s' not found in config.~n", [coding_agent_ansi:bright_red("✗"), NameStr]),
                    io:format("  Add it to .tarha/mcp_servers.json first.~n~n");
                Config ->
                    case maps:get(disabled, Config, false) of
                        true ->
                            io:format("~n~ts Server '~s' is disabled in config.~n~n", [coding_agent_ansi:bright_yellow("!"), NameStr]);
                        false ->
                            FullConfig = Config#{name => Name},
                            io:format("~nStarting MCP server ~s...~n", [NameStr]),
                            case coding_agent_mcp_registry:start_server(FullConfig) of
                                {ok, _} ->
                                    io:format("~ts Server ~s started.~n~n", [coding_agent_ansi:bright_green("✓"), NameStr]);
                                {error, Reason} ->
                                    io:format("~ts Failed: ~p~n~n", [coding_agent_ansi:bright_red("✗"), Reason])
                            end
                    end
            end,
            {continue, History, Mode}
    end;

process_command(_SessionId, History, "mcp-remove " ++ NameStr, Mode) ->
    Name = list_to_binary(string:trim(NameStr)),
    case coding_agent_mcp_registry:stop_server(Name) of
        ok ->
            io:format("~n~ts Server ~s removed.~n~n", [coding_agent_ansi:bright_green("✓"), NameStr]);
        {error, not_found} ->
            io:format("~n~ts Server ~s not found.~n~n", [coding_agent_ansi:bright_red("✗"), NameStr])
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "mcp-tools" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case whereis(coding_agent_mcp_registry) of
        undefined ->
            io:format("~n~ts MCP system not started.~n~n", [coding_agent_ansi:bright_red("✗")]);
        _ ->
            MCPTools = coding_agent_mcp_registry:get_all_tools(),
            case MCPTools of
                [] ->
                    io:format("~n  No MCP tools available.~n~n");
                _ ->
                    io:format("~n~ts~n", [coding_agent_ansi:bright_cyan("═══ MCP Tools ═══")]),
                    lists:foreach(fun({Prefix, Tool}) ->
                        BaseName = maps:get(<<"name">>, Tool, <<"">>),
                        Desc = maps:get(<<"description">>, Tool, <<"">>),
                        FullName = <<Prefix/binary, BaseName/binary>>,
                        DescPreview = case byte_size(Desc) > 80 of
                            true -> <<(binary:part(Desc, 0, 80))/binary, "...">>;
                            false -> Desc
                        end,
                        io:format("  ~ts  ~ts~n", [coding_agent_ansi:bright_white(binary_to_list(FullName)), coding_agent_ansi:dim(binary_to_list(DescPreview))])
                    end, MCPTools),
                    io:format("~ts~n~n", [coding_agent_ansi:bright_cyan("════════════════════")])
            end
    end,
    {continue, History, Mode};

process_command(_SessionId, History, "mcp-resources" ++ Rest, Mode) when Rest =:= []; hd(Rest) =:= $\s; hd(Rest) =:= $\t ->
    case whereis(coding_agent_mcp_registry) of
        undefined ->
            io:format("~n~ts MCP system not started.~n~n", [coding_agent_ansi:bright_red("✗")]);
        _ ->
            Servers = coding_agent_mcp_registry:list_servers(),
            AllResources = lists:flatmap(fun({Name, Info, Status}) ->
                case Status of
                    ready ->
                        Resources = maps:get(resources, Info, []),
                        [{Name, R} || R <- Resources];
                    _ -> []
                end
            end, Servers),
            case AllResources of
                [] ->
                    io:format("~n  No MCP resources available.~n~n");
                _ ->
                    io:format("~n~ts~n", [coding_agent_ansi:bright_cyan("═══ MCP Resources ═══")]),
                    lists:foreach(fun({ServerName, R}) ->
                        Uri = maps:get(<<"uri">>, R, <<"">>),
                        Desc = maps:get(<<"description">>, R, <<"">>),
                        io:format("  ~ts:~ts  ~ts~n",
                                  [coding_agent_ansi:bright_white(binary_to_list(ServerName)),
                                   coding_agent_ansi:dim(binary_to_list(Uri)),
                                   coding_agent_ansi:dim(binary_to_list(Desc))])
                    end, AllResources),
                    io:format("~ts~n~n", [coding_agent_ansi:bright_cyan("════════════════════════")])
            end
    end,
    {continue, History, Mode};


process_command(SessionId, History, Unknown, Mode) ->
    io:format("~ts /~s~n~ts~n~n", [coding_agent_ansi:bright_red("Unknown command:"), Unknown, coding_agent_ansi:dim("Type /help for available commands.")]),
    {continue, History, Mode}.

wait_for_editor(Port) ->
    receive
        {Port, {data, _}} ->
            wait_for_editor(Port);
        {Port, eof} ->
            port_close(Port)
    end.

print_model_field(Map, Key, Label) ->
    case maps:get(Key, Map, undefined) of
        undefined -> ok;
        Value when is_binary(Value) -> io:format("  ~s: ~s~n", [Label, Value]);
        _ -> ok
    end.

process_message(SessionId, History, Input, Mode) ->
    process_message(SessionId, History, Input, Mode, 0).

process_message(SessionId, History, Input, Mode, RetryCount) when RetryCount >= 3 ->
    io:format("~n" ++ coding_agent_ansi:bright_red("Max retries exceeded. Please try again.") ++ "~n"),
    {continue, History, Mode};
process_message(SessionId, History, Input, Mode, RetryCount) ->
    Message = list_to_binary(Input),
    NewHistory = [Input | History],
    
    % Get mode-specific system prompt
    ModePrompt = get_mode_prompt(Mode),
    CurrentPlan = get_current_plan(),
    
    % Add mode and plan context to the message
    ModeContext = case Mode of
        plan ->
            PlanContext = case byte_size(CurrentPlan) of
                0 -> <<"">>;
                _ -> iolist_to_binary([<<"\n\nCURRENT PLAN:\n">>, CurrentPlan, <<"\n\n">>])
            end,
            iolist_to_binary([
                <<"\n[PLAN MODE] You are in plan mode. Your role is to:\n">>,
                <<"1. Discuss and refine implementation plans with the user\n">>,
                <<"2. Think through problems step by step\n">>,
                <<"3. Create detailed implementation plans\n">>,
                <<"4. Ask clarifying questions\n">>,
                <<"5. DO NOT execute any code or file operations - just discuss\n">>,
                <<"6. When the plan is ready, suggest using /build to implement it\n">>,
                PlanContext,
                <<"\n">>
            ]);
        build ->
            iolist_to_binary([
                <<"\n[BUILD MODE] You are in build mode. You can:\n">>,
                <<"1. Execute code and file operations\n">>,
                <<"2. Implement the plan you created\n">>,
                <<"3. Make changes to files\n">>,
                <<"\n">>
            ]);
        meticulous ->
            Steps = get_meticulous_steps(),
            StepIdx = get_current_step_index(),
            PlanText = get_current_plan(),
            StepsContext = case Steps of
                [] -> <<"No steps defined yet. Ask the agent to break the plan into steps.\n">>;
                _ ->
                    StepLines = lists:map(fun({Idx, S}) ->
                        Marker = case Idx < StepIdx of
                            true -> <<"✓">>;
                            false -> case Idx =:= StepIdx of
                                true -> <<"▶">>;
                                false -> <<"○">>
                            end
                        end,
                        iolist_to_binary([Marker, <<" Step ">>, integer_to_binary(Idx + 1), <<": ">>,
                                         maps:get(title, S, <<"untitled">>), <<"\n">>])
                    end, lists:zip(lists:seq(0, length(Steps) - 1), Steps)),
                    iolist_to_binary(StepLines)
            end,
            iolist_to_binary([
                <<"\n[METICULOUS MODE] You are in meticulous mode.\n">>,
                <<"1. First, discuss the plan with the user\n">>,
                <<"2. When the plan is agreed, break it into numbered steps\n">>,
                <<"3. Output each step as a structured block:\n">>,
                <<"   <<<STEP>>>\n   Title: <short title>\n   Description: <what to do>\n   Files: <affected files>\n   <<<ENDSTEP>>>\n">>,
                <<"4. After all steps, the user will confirm and execute one by one\n">>,
                <<"5. DO NOT execute any code or file operations yet\n">>,
                <<"\nCURRENT PLAN:\n">>, PlanText, <<"\n\nCURRENT STEPS:\n">>, StepsContext, <<"\n">>
            ])
    end,
    
    EnrichedMessage = iolist_to_binary([ModeContext, Message]),
    
    try
        SpinnerPid = start_spinner(),
        Result = try
            StreamCb = fun stream_callback/3,
            case coding_agent_session:ask_stream(SessionId, EnrichedMessage, StreamCb) of
                {ok, Response, _Thinking} ->
                    io:format("~n"),
                    case Mode of
                    meticulous ->
                        NewSteps = parse_steps_from_response(Response),
                        case NewSteps of
                            [] -> ok;
                            _ ->
                                ExistingSteps = get_meticulous_steps(),
                                AllSteps = ExistingSteps ++ NewSteps,
                                set_meticulous_steps(AllSteps),
                                io:format("~ts ~p step(s) detected and saved.~n",
                                          [coding_agent_ansi:bright_green("✓"), length(NewSteps)]),
                                io:format("~ts Use ~ts to view or ~ts to confirm.~n~n",
                                          [coding_agent_ansi:dim(""),
                                           coding_agent_ansi:bright_white("/steps"),
                                           coding_agent_ansi:bright_white("/confirm")])
                        end;
                    _ -> ok
                end,
                {continue, NewHistory, Mode};
                {error, session_not_found} ->
                    io:format("~n~ts~n", [coding_agent_ansi:bright_yellow("Session expired. Creating new session...")]),
                    {ok, {NewSessionId2, _}} = coding_agent_session:new(),
                    io:format("New session: ~ts~n~n", [coding_agent_ansi:bright_magenta(NewSessionId2)]),
                    process_message(NewSessionId2, NewHistory, Input, Mode, 0);
                {error, max_retries_exceeded} ->
                    io:format("~n~ts~n", [coding_agent_ansi:bright_red("Max retries exceeded. The request failed multiple times.")]),
                    io:format("  This usually means:~n"),
                    io:format("  - Model is overloaded or slow~n"),
                    io:format("  - Context is too long (use /trim to reduce)~n"),
                    io:format("  - Network issue to Ollama/cloud~n~n"),
                    {continue, History, Mode};
                {error, {http_error, Status, Body}} ->
                    io:format("~n~ts ~p: ~ts~n~n", [coding_agent_ansi:bright_red("HTTP Error"), Status, binary:part(Body, 0, min(200, byte_size(Body)))]),
                    {continue, History, Mode};
                {error, Reason2} ->
                    io:format("~n~ts ~p~n~n", [coding_agent_ansi:bright_red("Error:"), Reason2]),
                    {continue, History, Mode}
            end
        catch
            exit:{timeout, {gen_server, call, [_Pid2, Call, _Timeout]}} ->
                io:format("~n~ts~n", [coding_agent_ansi:bright_red("Request timed out")]),
                io:format("  Called: ~p~n", [element(1, Call)]),
                case RetryCount < 2 of
                    true ->
                        io:format("  ~ts (~p/3)...~n~n", [coding_agent_ansi:dim("Retrying"), RetryCount + 1]),
                        process_message(SessionId, NewHistory, Input, Mode, RetryCount + 1);
                    false ->
                        io:format("~n~ts~n", [coding_agent_ansi:bright_red("Max retries exceeded. The request failed multiple times.")]),
                        io:format("  This usually means:~n"),
                        io:format("  - Model is overloaded or slow~n"),
                        io:format("  - Context is too long (use /trim to reduce)~n"),
                        io:format("  - Network issue to Ollama/cloud~n~n"),
                        {continue, History, Mode}
                end;
            error:undef:StacktraceUndef ->
                [{M, F, A, _} | _] = StacktraceUndef,
                io:format("~n~ts~n", [coding_agent_ansi:bright_yellow("Undefined function error:")]),
                io:format("  ~p:~p/~p~n", [M, F, A]),
                io:format("~ts~n", [coding_agent_ansi:bright_yellow("Please recompile and restart.")]);
            Type2:Error2:Stacktrace2 ->
                io:format("~n~ts ~p:~p~n", [coding_agent_ansi:bright_red("Session crashed:"), Type2, Error2]),
                try
                    case whereis(coding_agent_healer) of
                        undefined -> ok;
                        _ ->
                            coding_agent_healer:report_crash(repl_crash, {Type2, Error2}, Stacktrace2, #{session_id => SessionId}),
                            io:format(coding_agent_ansi:dim("Crash logged.") ++ "~n")
                    end
                catch _:_ -> ok
                end,
                analyze_and_suggest_fix(Error2, Stacktrace2),
                io:format("~ts~n", [coding_agent_ansi:bright_yellow("Creating new session and continuing...")]),
                {ok, {NewSessionId3, _}} = coding_agent_session:new(),
                io:format("New session: ~ts~n~n", [coding_agent_ansi:bright_magenta(NewSessionId3)]),
                process_message(NewSessionId3, NewHistory, Input, Mode, 0)
        after
            stop_spinner(SpinnerPid)
        end,
        Result
    catch
        Type:Error:Stacktrace ->
            io:format("~n~s ~p:~p~n", [coding_agent_ansi:bright_red("** Command crashed:"), Type, Error]),
            {continue, History, Mode}
    end.

generate_crash_id() ->
    <<A:32, B:32>> = crypto:strong_rand_bytes(8),
    iolist_to_binary(io_lib:format("crash-~8.16.0b-~8.16.0b", [A, B])).

generate_crash_report_content(CrashInfo) ->
    Type = maps:get(type, CrashInfo, unknown),
    Error = maps:get(error, CrashInfo, unknown),
    Stacktrace = maps:get(stacktrace, CrashInfo, []),
    SessionId = maps:get(session_id, CrashInfo, undefined),
    Timestamp = maps:get(timestamp, CrashInfo, 0),
    
    SessionSection = case SessionId of
        undefined -> <<"">>;
        Sid -> io_lib:format("**Session ID:** ~s~n~n", [Sid])
    end,
    
    ErrorStr = io_lib:format("~p", [Error]),
    StackStr = format_stacktrace(Stacktrace),
    
    iolist_to_binary([
        <<"# Crash Report~n~n">>,
        io_lib:format("**Crash ID:** crash-~p~n~n", [Timestamp]),
        io_lib:format("**Timestamp:** ~p (UTC)~n~n", [Timestamp]),
        SessionSection,
        <<"**Error Type:** ">>, atom_to_binary(Type, utf8), <<"~n~n">>,
        <<"**Error:**~n~n```~n">>, ErrorStr, <<"~n```~n~n">>,
        <<"**Stacktrace:**~n~n```~n">>, StackStr, <<"~n```~n">>
    ]).

format_stacktrace([]) -> <<"">>;
format_stacktrace([{M, F, A, Info} | Rest]) when is_list(A) ->
    Line = io_lib:format("  ~p:~p/~p at ~s:~p~n", [
        M, F, length(A),
        proplists:get_value(file, Info, "unknown"),
        proplists:get_value(line, Info, 0)
    ]),
    [Line | format_stacktrace(Rest)];
format_stacktrace([{M, F, A, Info} | Rest]) ->
    Line = io_lib:format("  ~p:~p/~p at ~s:~p~n", [
        M, F, A,
        proplists:get_value(file, Info, "unknown"),
        proplists:get_value(line, Info, 0)
    ]),
    [Line | format_stacktrace(Rest)];
format_stacktrace([{M, F, A} | Rest]) ->
    Line = io_lib:format("  ~p:~p/~p~n", [M, F, A]),
    [Line | format_stacktrace(Rest)];
format_stacktrace([_ | Rest]) ->
    format_stacktrace(Rest).

analyze_and_suggest_fix(Error2, Stacktrace2) ->
    %% Show the error clearly
    io:format("~n" ++ coding_agent_ansi:bright_red("** Error:") ++ " ~p~n", [Error2]),
    io:format("~n" ++ coding_agent_ansi:bright_yellow("** Stacktrace:") ++ "~n"),
    lists:foreach(fun
        ({M, F, A, Info}) ->
            File = proplists:get_value(file, Info, "unknown"),
            Line = proplists:get_value(line, Info, 0),
            Arity = if is_list(A) -> length(A); true -> A end,
            io:format("    ~p:~p/~p at ~s:~p~n", [M, F, Arity, File, Line]);
        ({M, F, A}) ->
            Arity = if is_list(A) -> length(A); true -> A end,
            io:format("    ~p:~p/~p~n", [M, F, Arity]);
        (_) ->
            io:format("    (unknown location)~n")
    end, Stacktrace2),
    
    %% Suggest fix based on error type
    case Error2 of
        {undef, {Mod, Fun, Arity}} when is_atom(Mod), is_atom(Fun) ->
            %% Check if function exists in another module
            case find_function_in_modules(Mod, Fun, Arity) of
                {ok, CorrectMod} ->
                    io:format("~n" ++ coding_agent_ansi:bright_green("** SUGGESTED FIX:** Use") ++ " ~p:~p/~p instead of ~p:~p/~p~n~n",
                              [CorrectMod, Fun, Arity, Mod, Fun, Arity]);
                not_found ->
                    io:format("~n" ++ coding_agent_ansi:bright_green("** SUGGESTED FIX:** Function") ++ " ~p:~p/~p not found. Add -export or define it.~n~n",
                              [Mod, Fun, Arity])
            end;
        {badarg, _} ->
            io:format("~n" ++ coding_agent_ansi:bright_green("** SUGGESTED FIX:** Bad argument. Check function arguments.") ++ "~n~n", []);
        {badmatch, _} ->
            io:format("~n" ++ coding_agent_ansi:bright_green("** SUGGESTED FIX:** Pattern match failed. Check data structure.") ++ "~n~n", []);
        {case_clause, _} ->
            io:format("~n" ++ coding_agent_ansi:bright_green("** SUGGESTED FIX:** No case clause matched. Add missing case.") ++ "~n~n", []);
        _ ->
            io:format("~n" ++ coding_agent_ansi:bright_green("** Run /fix or /crashes for more details**") ++ "~n~n", [])
    end.

find_function_in_modules(_WrongMod, Fun, Arity) ->
    CommonModules = [lists, string, binary, file, filename, os, io, 
                     proplists, maps, sets, dict, queue, array,
                     re, unicode, calendar, timer, erlang],
    Found = lists:filter(fun(Mod) ->
        erlang:function_exported(Mod, Fun, Arity)
    end, CommonModules),
    case Found of
        [CorrectMod | _] -> {ok, CorrectMod};
        [] -> not_found
    end.

display_suggestion(CrashAnalysis) ->
    case maps:get(suggested_fix, CrashAnalysis, #{}) of
        #{hint := Hint} -> io:format(coding_agent_ansi:bright_cyan("Suggestion:") ++ " ~s~n", [Hint]);
        _ -> ok
    end.

report_error(Reason) ->
    % Don't log HTTP/API errors to crash report - they're handled by retry
    case is_http_error(Reason) of
        true ->
            io:format(coding_agent_ansi:dim("(API error, will retry automatically)") ++ "~n");
        false ->
            io:format("Error: ~p~n", [Reason]),
            case whereis(coding_agent_healer) of
                undefined -> ok;
                _ ->
                    Stacktrace = try throw(fake) catch _:_:St -> St end,
                    coding_agent_healer:report_crash(repl_error, Reason, Stacktrace),
                    io:format(coding_agent_ansi:dim("Error logged.") ++ "~n")
            end
    end.

is_http_error({http_error, _, _}) -> true;
is_http_error({status, _, _}) -> true;
is_http_error(max_retries_exceeded) -> true;
is_http_error(timeout) -> true;
is_http_error(_) -> false.

report_crash(Type, Error, Stacktrace, SessionId) when is_binary(SessionId) ->
    case whereis(coding_agent_healer) of
        undefined -> ok;
        _ ->
            coding_agent_healer:report_crash(repl_crash, {Type, Error}, Stacktrace, #{session_id => SessionId}),
            io:format(coding_agent_ansi:dim("Crash logged.") ++ "~n"),
            {_, CrashAnalysis} = coding_agent_healer:analyze_crash(Type, Stacktrace),
            case maps:get(suggested_fix, CrashAnalysis, #{}) of
                #{hint := Hint} -> io:format(coding_agent_ansi:bright_cyan("Suggestion:") ++ " ~s~n", [Hint]);
                _ -> ok
            end
    end.

report_crash(Type, Error, Stacktrace) ->
    report_crash(Type, Error, Stacktrace, <<>>).

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
    
    io:format(coding_agent_ansi:dim("Dumping context to") ++ " ~s...~n", [Filename]),
    
    Context = gather_context(SessionId, History),
    
    Content = case Format of
        markdown -> format_context_markdown(Context);
        json -> format_context_json(Context);
        text -> format_context_text(Context)
    end,
    
    case file:write_file(Filename, Content) of
        ok ->
            io:format(coding_agent_ansi:bright_green("✓ Context dumped to") ++ " ~s~n", [Filename]);
        {error, Reason} ->
            io:format(coding_agent_ansi:bright_red("✗ Failed to write file:") ++ " ~p~n", [Reason])
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
        Status = case Loaded of true -> "loaded"; false -> "unloaded" end,
        io_lib:format("~s: ~p~n", [Status, Name])
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
    % Check multiple locations where context length might be defined
    % 1. Top-level model_info field
    % 2. Nested model_info inside model_info
    % 3. Direct fields in details or parameters
    
    TopKeys = [<<"context_length">>, <<"num_ctx">>, <<"n_ctx">>],
    
    % Check top level first
    TopLevel = lists:foldl(fun(Key, Acc) ->
        case Acc of
            undefined -> maps:get(Key, ModelInfo, undefined);
            _ -> Acc
        end
    end, undefined, TopKeys),
    
    % Check model_info field (some models have it nested)
    NestedInfo = case maps:get(<<"model_info">>, ModelInfo, undefined) of
        Nested when is_map(Nested) ->
            lists:foldl(fun(Key, Acc) ->
                case Acc of
                    undefined -> maps:get(Key, Nested, undefined);
                    _ -> Acc
                end
            end, undefined, TopKeys);
        _ -> undefined
    end,
    
    % Check details field
    DetailsCtx = case maps:get(<<"details">>, ModelInfo, undefined) of
        Details when is_map(Details) ->
            lists:foldl(fun(Key, Acc) ->
                case Acc of
                    undefined -> maps:get(Key, Details, undefined);
                    _ -> Acc
                end
            end, undefined, TopKeys);
        _ -> undefined
    end,
    
    % Return first found
    find_first([TopLevel, NestedInfo, DetailsCtx]);
find_context_length(_) ->
    undefined.

find_first([undefined | Rest]) ->
    find_first(Rest);
find_first([Value | _]) ->
    Value;
find_first([]) ->
    undefined.

print_map_indented(Map, Indent) when is_map(Map) ->
    SortedKeys = lists:sort(maps:keys(Map)),
    lists:foreach(fun(Key) ->
        Value = maps:get(Key, Map),
        KeyStr = case is_binary(Key) of true -> binary_to_list(Key); false -> io_lib:format("~p", [Key]) end,
        case Value of
            NestedMap when is_map(NestedMap), map_size(NestedMap) > 0 ->
                io:format("~s~s:~n", [Indent, KeyStr]),
                print_map_indented(NestedMap, Indent ++ "  ");
            NestedList when is_list(NestedList), length(NestedList) > 0, is_list(hd(NestedList)) ->
                io:format("~s~s: [~n", [Indent, KeyStr]),
                lists:foreach(fun(Item) ->
                    case Item of
                        ItemMap when is_map(ItemMap) ->
                            io:format("~s  {~n", [Indent]),
                            print_map_indented(ItemMap, Indent ++ "    "),
                            io:format("~s  }~n", [Indent]);
                        _ ->
                            io:format("~s  ~p~n", [Indent, Item])
                    end
                end, NestedList),
                io:format("~s]~n", [Indent]);
            Bin when is_binary(Bin) ->
                Str = binary_to_list(Bin),
                io:format("~s~s: ~s~n", [Indent, KeyStr, Str]);
            Int when is_integer(Int) ->
                io:format("~s~s: ~p~n", [Indent, KeyStr, Int]);
            Float when is_float(Float) ->
                io:format("~s~s: ~p~n", [Indent, KeyStr, Float]);
            true ->
                io:format("~s~s: true~n", [Indent, KeyStr]);
            false ->
                io:format("~s~s: false~n", [Indent, KeyStr]);
            null ->
                io:format("~s~s: null~n", [Indent, KeyStr]);
            undefined ->
                io:format("~s~s: undefined~n", [Indent, KeyStr]);
            Other ->
                io:format("~s~s: ~p~n", [Indent, KeyStr, Other])
        end
    end, SortedKeys);
print_map_indented(_, _) ->
    ok.

print_response(<<>>) ->
    ok;
print_response(Content) when is_binary(Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:foreach(fun(Line) ->
        io:format("  ~s~n", [Line])
    end, Lines);
print_response(Content) ->
    print_response(iolist_to_binary(Content)).

stream_callback(Content, Thinking, #{thinking_shown := false}) when Thinking =/= <<>>, Thinking =/= undefined ->
    io:format("~s~s", [coding_agent_ansi:clear_line(), coding_agent_ansi:dim("Thinking...")]),
    io:format("~s", [coding_agent_ansi:clear_line()]),
    #{thinking_shown => true};
stream_callback(Content, _Thinking, #{thinking_shown := true}) when Content =/= <<>>, Content =/= undefined ->
    io:format("~ts~n", [coding_agent_ansi:bright_cyan("--- Response ---")]),
    io:format("~ts", [Content]),
    #{thinking_shown => content};
stream_callback(Content, _Thinking, #{thinking_shown := content}) when Content =/= <<>>, Content =/= undefined ->
    io:format("~ts", [Content]),
    #{thinking_shown => content};
stream_callback(_Content, _Thinking, Acc) ->
    Acc.

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

load_mcp_servers() ->
    case whereis(coding_agent_mcp_registry) of
        undefined -> ok;
        _ ->
            Servers = coding_agent_config:get_mcp_servers(),
            maps:foreach(fun(Name, Config) ->
                case maps:get(disabled, Config, false) of
                    true -> ok;
                    false ->
                        FullConfig = Config#{name => Name},
                        case coding_agent_mcp_registry:start_server(FullConfig) of
                            {ok, _} ->
                                io:format("[mcp] Started server ~s~n", [binary_to_list(Name)]);
                            {error, already_running} -> ok;
                            {error, Reason} ->
                                io:format("[mcp] Failed to start ~s: ~p~n", [binary_to_list(Name), Reason])
                        end
                end
            end, Servers)
    end.

-define(SPINNER_FRAMES, ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⦶", "⠦"]).
-define(SPINNER_INTERVAL, 80).

start_spinner() ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> spinner_loop(Parent, Ref, ?SPINNER_FRAMES, 0, erlang:monotonic_time(millisecond)) end),
    Pid.

spinner_loop(Parent, Ref, Frames, Idx, StartTime) ->
    Frame = lists:nth((Idx rem length(Frames)) + 1, Frames),
    Elapsed = (erlang:monotonic_time(millisecond) - StartTime) div 1000,
    io:format("\r~s ~ts ~s ~ps", [coding_agent_ansi:bright_cyan(Frame), coding_agent_ansi:dim("waiting for response"), coding_agent_ansi:dim(coding_agent_ansi:clear_line()), Elapsed]),
    receive
        stop -> ok
    after ?SPINNER_INTERVAL ->
        spinner_loop(Parent, Ref, Frames, Idx + 1, StartTime)
    end.

stop_spinner(Pid) when is_pid(Pid) ->
    Pid ! stop,
    io:format("\r~s", [coding_agent_ansi:clear_line()]),
    ok;
stop_spinner(_) ->
    ok.