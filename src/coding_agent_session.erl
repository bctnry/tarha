-module(coding_agent_session).
-behaviour(gen_server).

-compile({no_auto_import, [halt/1]}).

-export([start_link/0, start_link/1, start_link/2, new/0, new/1, ask/2, ask/3]).
-export([history/1, clear/1, stop_session/1, sessions/0]).
-export([open_files/1, close_file/2, stats/1, ask_stream/3, compact/1]).
-export([save_session/1, load_session/1, list_saved_sessions/0]).
-export([set_context_length/2, get_context_length/1]).
-export([halt/1, is_busy/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    id :: binary(),
    model :: binary(),
    context_length :: integer(),      % Model's max context window (from Ollama API)
    messages :: list(),
    working_dir :: string(),
    open_files :: #{binary() => binary()},  % Path => Content cache
    prompt_tokens :: integer(),      % Actual tokens from API
    completion_tokens :: integer(),  % Actual tokens from API  
    estimated_tokens :: integer(),    % Estimated when API doesn't provide counts
    tool_calls :: integer(),
    busy :: boolean()                 % Whether session is processing a request
}).

-define(MAX_ITERATIONS, 100).
-define(MAX_HISTORY, 50).  % Reduced from 100 - tool calls use lots of context
-define(MAX_HISTORY_SIZE, 100000).  % 100KB max history in bytes
-define(MAX_TOOL_RESULT_SIZE, 10000).  % 10KB max per tool result (was 20KB)
-define(DEFAULT_CONTEXT_LENGTH, 32768).  % Default if model info unavailable
-define(CONTEXT_USAGE_THRESHOLD, 0.85).  % Compact at 85% context usage
-define(COMPACTION_THRESHOLD, 150000).  % ~50KB tokens
-define(KEEP_RECENT_MESSAGES, 10).       % Messages to keep intact during compaction
-define(SUMMARIZE_TIMEOUT, 30000).       % 30s timeout for summarization LLM call
-define(ARCHIVE_DIR, ".tarha/sessions").
-define(CRASH_DIR, ".tarha/reports").
-define(MAX_TOOL_RETRIES, 3).
-define(SESSIONS_TABLE, coding_agent_sessions).

% Self-healing: When recovering from crash, agent reads crash report and fixes itself
-define(HEAL_PROMPT, <<"You just recovered from a crash. A crash report has been saved.

## What happened
You crashed while processing a request. The error, stacktrace, and context have been saved.

## Your task
Self-healing mode activated. You must fix yourself:

1. Read the crash report shown above using read_file
2. Analyze the error and stacktrace
3. Read the source file where the crash occurred using read_file  
4. Use edit_file to fix the bug
5. Run 'rebar3 compile' using bash to verify the fix
6. Report what was fixed

## Important
- Fix the ACTUAL root cause, don't just add try/catch wrappers
- The crash report is in .tarha/reports/
- After fixing, the code will be hot-reloaded automatically">>).
-define(SYSTEM_PROMPT, <<"You are an autonomous coding assistant. You CAN and SHOULD take multiple actions to complete tasks without asking for permission between steps.

## Your Capabilities

You have access to tools for:
- Reading, writing, editing files
- Running bash commands and build tools
- Searching code with grep and file patterns
- Working with git (status, diff, commit, etc.)

## How to Work

1. **PLAN FIRST**: Before acting, briefly think through your approach
2. **EXECUTE AUTONOMOUSLY**: Take multiple actions in sequence without waiting for user confirmation
3. **VERIFY**: After changes, check that they work (run tests, build, lint)
4. **REPORT**: When done, summarize what you did

## Multi-Step Workflows

For nontrivial tasks, you should:
- Read relevant files to understand context (use the Glob tool to find files)
- Make changes incrementally
- Test/verify after changes
- Report results

## Tool Selection

- Use `read_file` before `edit_file` (always read first)
- Use `edit_file` for targeted fixes, `write_file` for new files
- Use `bash` for running tests, builds, git commands
- Use `grep` to search for patterns
- Use `glob` to find files by pattern

## Important Rules

- ALWAYS use absolute paths when reading/writing files
- After editing files, suggest running relevant tests/linters
- For git commits, check status and diff first
- If a task requires multiple steps, do them all autonomously
- When genuinely stuck or need clarification, ask the user

## Context

Working directory will be provided in the system context.
Always use absolute paths when reading or writing files.">>).

-define(SKILL_PROMPT, <<"# Skills

You have access to skills that provide specialized knowledge. Skills are loaded from:
- Builtin skills (provided by the system)
- Workspace skills (user-defined in the skills/ directory)

When a skill is relevant to the user's request, use its guidance to help complete the task.
If you need to read a skill's full content, use the read_file tool on its SKILL.md file.">>).

sessions() ->
    case ets:whereis(?SESSIONS_TABLE) of
        undefined -> [];
        _ -> ets:tab2list(?SESSIONS_TABLE)
    end.

new() ->
    new(<<>>).

new(Id) when is_list(Id) ->
    new(list_to_binary(Id));
new(Id) ->
    Id2 = case Id of
        <<>> -> generate_id();
        _ -> Id
    end,
    case coding_agent_session_sup:start_session(Id2) of
        {ok, Pid} -> 
            ets:insert(?SESSIONS_TABLE, {Id2, Pid}),
            {ok, {Id2, Pid}};
        {error, {already_started, Pid}} -> 
            {ok, {Id2, Pid}}
    end.

ask(Session, Message) ->
    ask(Session, Message, #{}).

ask_stream(Session, Message, Callback) ->
    ask_stream(Session, Message, Callback, #{}).

ask_stream({Id, Pid}, Message, Callback, Opts) when is_binary(Id), is_pid(Pid) ->
    ask_stream(Pid, Message, Callback, Opts);
ask_stream(Session, Message, Callback, Opts) when is_pid(Session) ->
    gen_server:call(Session, {ask_stream, Message, Callback, Opts}, 120000);
ask_stream(Session, Message, Callback, Opts) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> ask_stream(Pid, Message, Callback, Opts);
        [] -> {error, session_not_found}
    end;
ask_stream(Session, Message, Callback, Opts) when is_list(Session) ->
    ask_stream(iolist_to_binary(Session), Message, Callback, Opts).

ask({Id, Pid}, Message, Opts) when is_binary(Id), is_pid(Pid) ->
    ask(Pid, Message, Opts);
ask(Session, Message, Opts) when is_pid(Session) ->
    gen_server:call(Session, {ask, Message, Opts}, 120000);
ask(Session, Message, Opts) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> ask(Pid, Message, Opts);
        [] -> {error, session_not_found}
    end;
ask(Session, Message, Opts) when is_list(Session) ->
    ask(iolist_to_binary(Session), Message, Opts).

history(Session) when is_pid(Session) ->
    gen_server:call(Session, history);
history(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> history(Pid);
        [] -> {error, session_not_found}
    end;
history({_, Pid}) ->
    history(Pid).

open_files(Session) when is_pid(Session) ->
    gen_server:call(Session, open_files);
open_files(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> open_files(Pid);
        [] -> {error, session_not_found}
    end;
open_files({_, Pid}) ->
    open_files(Pid).

close_file(Session, Path) when is_pid(Session) ->
    gen_server:call(Session, {close_file, Path});
close_file(Session, Path) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> close_file(Pid, Path);
        [] -> {error, session_not_found}
    end;
close_file({_, Pid}, Path) ->
    close_file(Pid, Path).

stats(Session) when is_pid(Session) ->
    gen_server:call(Session, stats);
stats(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> stats(Pid);
        [] -> {error, session_not_found}
    end;
stats({_, Pid}) ->
    stats(Pid).

clear(Session) when is_pid(Session) ->
    gen_server:call(Session, clear);
clear(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> clear(Pid);
        [] -> {error, session_not_found}
    end;
clear({_, Pid}) ->
    clear(Pid).

compact(Session) when is_pid(Session) ->
    gen_server:call(Session, compact, 120000);
compact(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> compact(Pid);
        [] -> {error, session_not_found}
    end;
compact({_, Pid}) ->
    compact(Pid).

set_context_length(Session, Length) when is_pid(Session) ->
    gen_server:call(Session, {set_context_length, Length});
set_context_length(Session, Length) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> set_context_length(Pid, Length);
        [] -> {error, session_not_found}
    end;
set_context_length({_, Pid}, Length) ->
    set_context_length(Pid, Length).

get_context_length(Session) when is_pid(Session) ->
    gen_server:call(Session, get_context_length);
get_context_length(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> get_context_length(Pid);
        [] -> {error, session_not_found}
    end;
get_context_length({_, Pid}) ->
    get_context_length(Pid).

stop_session(Session) when is_pid(Session) ->
    gen_server:stop(Session);
stop_session(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> stop_session(Pid);
        [] -> {error, session_not_found}
    end;
stop_session({Id, Pid}) ->
    ets:delete(?SESSIONS_TABLE, Id),
    stop_session(Pid).

%% @doc Halt the current LLM request for a session
halt(Session) when is_pid(Session) ->
    gen_server:call(Session, halt, 5000);
halt(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> halt(Pid);
        [] -> {error, session_not_found}
    end;
halt({_, Pid}) ->
    halt(Pid).

%% @doc Check if session is busy processing a request
is_busy(Session) when is_pid(Session) ->
    gen_server:call(Session, is_busy);
is_busy(Session) when is_binary(Session) ->
    case ets:lookup(?SESSIONS_TABLE, Session) of
        [{_, Pid}] -> is_busy(Pid);
        [] -> {error, session_not_found}
    end;
is_busy({_, Pid}) ->
    is_busy(Pid).

start_link() ->
    start_link(<<>>).

start_link(Id) ->
    start_link(Id, <<>>).

start_link(Id, WorkingDir) ->
    gen_server:start_link(?MODULE, [Id, WorkingDir], []).

init([Id, WorkingDir]) ->
    IdBin = if is_list(Id) -> list_to_binary(Id); true -> Id end,
    Model0 = application:get_env(coding_agent, model, <<"glm-5:cloud">>),
    Model = if is_list(Model0) -> list_to_binary(Model0); true -> Model0 end,
    WD0 = case WorkingDir of
        <<>> -> file:get_cwd();
        _ when is_binary(WorkingDir) -> {ok, binary_to_list(WorkingDir)};
        _ when is_list(WorkingDir) -> {ok, WorkingDir}
    end,
    WD = case WD0 of
        {ok, D} -> D;
        D when is_list(D) -> D;
        _ -> "."
    end,
    Id2 = case IdBin of
        <<>> -> generate_id();
        _ -> IdBin
    end,
    %% Get model's context length from Ollama API
    ContextLength = case coding_agent_ollama:get_model_context_length(Model) of
        Len when is_integer(Len), Len > 0 -> Len;
        _ -> ?DEFAULT_CONTEXT_LENGTH
    end,
    io:format("[session] Model ~s has context length ~p~n", [Model, ContextLength]),
    process_flag(trap_exit, true),
    {ok, #state{
        id = Id2,
        model = Model,
        context_length = ContextLength,
        messages = [],
        working_dir = WD,
        open_files = #{},
        prompt_tokens = 0,
        completion_tokens = 0,
        estimated_tokens = 0,
        tool_calls = 0,
        busy = false
    }}.

handle_call({ask, Message, _Opts}, _From, State = #state{model = Model, messages = History, working_dir = WD, id = Id, open_files = OpenFiles}) ->
    MsgBin = iolist_to_binary(Message),
    WDBin = list_to_binary(WD),
    
    % Build file context from open files
    FileContext = build_file_context(OpenFiles),
    
    % Get memory context
    MemoryContext = get_memory_context(),
    
    % Get skills context
    SkillsContext = get_skills_context(),
    
    % Get AGENTS.md context
    AgentsContext = get_agents_context(),
    
    % Check for recent crashes (self-healing)
    CrashContext = get_recent_crash_context(),
    
    % Build system prompt with all context sections
    ContextParts = [],
    
    % Base prompt
    BasePrompt = <<?SYSTEM_PROMPT/binary, "\n\nCurrent working directory: ", WDBin/binary, "\nSession ID: ", Id/binary>>,
    
    % Add AGENTS.md if present
    WithAgents = case AgentsContext of
        <<>> -> BasePrompt;
        _ -> <<BasePrompt/binary, "\n\n# Project Context (AGENTS.md)\n\n", AgentsContext/binary>>
    end,
    
    % Add memory if present
    WithMemory = case MemoryContext of
        <<>> -> WithAgents;
        _ -> <<WithAgents/binary, "\n\n", MemoryContext/binary>>
    end,
    
    % Add skills if present (only summary, not full content)
    WithSkills = case SkillsContext of
        <<>> -> WithMemory;
        _ -> <<WithMemory/binary, "\n\n# Available Skills\n\nSkills are available. Use read_file on skill's SKILL.md to load full instructions.\n\n", SkillsContext/binary>>
    end,
    
    % Add open files if present
    WithFiles = case FileContext of
        <<>> -> WithSkills;
        _ -> <<WithSkills/binary, "\n\nOpen files (cached in context):\n", FileContext/binary>>
    end,
    
    % Add crash report if recent crash detected (self-healing)
    SystemContent = case CrashContext of
        <<>> -> WithFiles;
        _ -> <<WithFiles/binary, "\n\n", ?HEAL_PROMPT/binary, "\n\n", CrashContext/binary>>
    end,
    
    SystemMsg = #{<<"role">> => <<"system">>, <<"content">> => SystemContent},
    UserMsg = #{<<"role">> => <<"user">>, <<"content">> => MsgBin},
    ExistingHistory = strip_system_messages(trim_history(History)),
    Messages = [SystemMsg | ExistingHistory] ++ [UserMsg],
    
    case run_agent_loop(Model, Messages, 0, OpenFiles, Id) of
        {ok, Response, Thinking, NewHistory, FinalOpenFiles, TokenInfo} ->
            FinalHistory = strip_system_messages(trim_history(NewHistory)),
            ReplyHistory = [{maps:get(<<"role">>, M), maps:get(<<"content">>, M, <<"">>)} || M <- lists:sublist(FinalHistory, 2, length(FinalHistory))],
            
            %% Extract token counts
            PromptUsed = maps:get(prompt_tokens, TokenInfo, 0),
            CompletionUsed = maps:get(completion_tokens, TokenInfo, 0),
            EstimatedUsed = maps:get(estimated_tokens, TokenInfo, 0),
            
            NewState = State#state{
                messages = FinalHistory,
                open_files = FinalOpenFiles,
                prompt_tokens = State#state.prompt_tokens + PromptUsed,
                completion_tokens = State#state.completion_tokens + CompletionUsed,
                estimated_tokens = State#state.estimated_tokens + EstimatedUsed,
                tool_calls = State#state.tool_calls + 1
            },
            % Check if consolidation needed (async)
            maybe_trigger_consolidation(),
            % Check if compaction needed
            CompactedState = maybe_compact_session(NewState),
            % Auto-save session (async)
            maybe_save_session(CompactedState),
            {reply, {ok, Response, Thinking, ReplyHistory}, CompactedState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(history, _From, State = #state{messages = Messages}) ->
    {reply, {ok, Messages}, State};

handle_call(open_files, _From, State = #state{open_files = OpenFiles}) ->
    FileList = maps:fold(fun(Path, _Content, Acc) -> [Path | Acc] end, [], OpenFiles),
    {reply, {ok, FileList}, State};

handle_call({close_file, Path}, _From, State = #state{open_files = OpenFiles}) ->
    PathBin = iolist_to_binary(Path),
    NewOpenFiles = maps:remove(PathBin, OpenFiles),
    {reply, ok, State#state{open_files = NewOpenFiles}};

handle_call(stats, _From, State = #state{prompt_tokens = PromptTokens, completion_tokens = CompletionTokens, estimated_tokens = EstimatedTokens, tool_calls = Calls, context_length = ContextLength, model = Model}) ->
    %% Get global token stats from Ollama client
    GlobalStats = coding_agent_ollama:get_token_stats(),
    SessionTotal = PromptTokens + CompletionTokens + EstimatedTokens,
    %% Calculate context usage percentage
    UsagePercent = case ContextLength > 0 of
        true -> (SessionTotal / ContextLength) * 100;
        false -> 0.0
    end,
    {reply, {ok, #{
        <<"session_prompt_tokens">> => PromptTokens,
        <<"session_completion_tokens">> => CompletionTokens,
        <<"session_estimated_tokens">> => EstimatedTokens,
        <<"session_total_tokens">> => SessionTotal,
        <<"context_length">> => ContextLength,
        <<"context_usage_percent">> => round(UsagePercent * 10) / 10,  % 1 decimal
        <<"tool_calls">> => Calls,
        <<"message_count">> => length(State#state.messages),
        <<"model">> => Model,
        <<"global_prompt_tokens">> => maps:get(prompt_tokens, GlobalStats, 0),
        <<"global_completion_tokens">> => maps:get(completion_tokens, GlobalStats, 0),
        <<"global_estimated_tokens">> => maps:get(estimated_tokens, GlobalStats, 0)
    }}, State};

handle_call(clear, _From, State) ->
    {reply, ok, State#state{messages = [], open_files = #{}}};

handle_call(get_context_length, _From, State = #state{context_length = ContextLength, prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET}) ->
    TotalTokens = PT + CT + ET,
    {reply, {ok, #{
        context_length => ContextLength,
        current_tokens => TotalTokens,
        usage_percent => case ContextLength > 0 of
            true -> round((TotalTokens / ContextLength) * 1000) / 10;  % 1 decimal
            false -> 0.0
        end
    }}, State};

handle_call({set_context_length, Length}, _From, State = #state{context_length = OldLength, prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET}) 
    when is_integer(Length), Length > 0 ->
    TotalTokens = PT + CT + ET,
    io:format("[session] Context length changed: ~p -> ~p (current usage: ~p tokens)~n", [OldLength, Length, TotalTokens]),
    {reply, {ok, #{old_length => OldLength, new_length => Length}}, State#state{context_length = Length}};
handle_call({set_context_length, Length}, _From, State) ->
    {reply, {error, {invalid_length, Length}}, State};

handle_call(halt, _From, State = #state{id = SessionId}) ->
    %% Halt any active LLM request for this session
    case coding_agent_request_registry:halt(SessionId) of
        ok ->
            io:format("[session] Halted request for session ~s~n", [SessionId]),
            {reply, ok, State};
        {error, not_found} ->
            {reply, {error, no_active_request}, State}
    end;

handle_call(is_busy, _From, State = #state{id = SessionId}) ->
    %% Check if there's an active request for this session
    case coding_agent_request_registry:get_request(SessionId) of
        {ok, _Ref} -> {reply, {ok, true}, State};
        {error, not_found} -> {reply, {ok, false}, State}
    end;

handle_call(compact, _From, State = #state{id = Id, messages = Messages, model = Model, prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET}) ->
    TotalTokens = PT + CT + ET,
    io:format("[session] Compacting session ~s (~p tokens)~n", [Id, TotalTokens]),
    ArchiveId = archive_session(State),
    case summarize_messages(Messages, Model) of
        {ok, SummaryText} ->
            SummaryMsg = #{
                <<"role">> => <<"system">>,
                <<"content">> => <<"This is a summary of the previous conversation:\n\n", SummaryText/binary>>
            },
            NewState = State#state{
                messages = [SummaryMsg],
                prompt_tokens = 0,
                completion_tokens = 0,
                estimated_tokens = byte_size(SummaryText) div 4
            },
            io:format("[session] Session compacted. Archived as ~s~n", [ArchiveId]),
            {reply, {ok, #{archived_as => ArchiveId, summary_size => byte_size(SummaryText)}}, NewState};
        {error, Reason} ->
            io:format("[session] Compaction failed: ~p~n", [Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call(save_session, _From, State = #state{id = Id, model = Model, context_length = ContextLength, working_dir = WD, open_files = OpenFiles, prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET, tool_calls = TC}) ->
    SessionData = #{
        id => Id,
        model => Model,
        context_length => ContextLength,
        working_dir => list_to_binary(WD),
        messages => State#state.messages,
        open_files => OpenFiles,
        prompt_tokens => PT,
        completion_tokens => CT,
        estimated_tokens => ET,
        total_tokens => PT + CT + ET,
        tool_calls => TC
    },
    case coding_agent_session_store:save_session(Id, SessionData) of
        ok -> {reply, {ok, Id}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({restore_state, Data}, _From, _State) ->
    Model = maps:get(model, Data, <<"glm-5:cloud">>),
    %% Get model's context length from Ollama API
    ContextLength = case maps:get(context_length, Data, undefined) of
        undefined ->
            case coding_agent_ollama:get_model_context_length(Model) of
                Len when is_integer(Len), Len > 0 -> Len;
                _ -> ?DEFAULT_CONTEXT_LENGTH
            end;
        Len when is_integer(Len), Len > 0 -> Len;
        _ -> ?DEFAULT_CONTEXT_LENGTH
    end,
    NewState = #state{
        id = maps:get(id, Data, <<>>),
        model = Model,
        context_length = ContextLength,
        messages = maps:get(messages, Data, []),
        working_dir = case maps:get(working_dir, Data, ".") of
            W when is_binary(W) -> binary_to_list(W);
            W when is_list(W) -> W;
            _ -> "."
        end,
        open_files = maps:get(open_files, Data, #{}),
        prompt_tokens = maps:get(prompt_tokens, Data, maps:get(total_tokens, Data, 0)),
        completion_tokens = maps:get(completion_tokens, Data, 0),
        estimated_tokens = maps:get(estimated_tokens, Data, 0),
        tool_calls = maps:get(tool_calls, Data, 0)
    },
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{id = Id}) ->
    ets:delete(?SESSIONS_TABLE, Id),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

build_file_context(OpenFiles) when map_size(OpenFiles) == 0 ->
    <<>>;
build_file_context(OpenFiles) ->
    maps:fold(fun(Path, Content, Acc) ->
        PathBin = iolist_to_binary(Path),
        case byte_size(Acc) + byte_size(Content) > 50000 of
            true -> Acc;
            false -> <<Acc/binary, "\n--- ", PathBin/binary, " ---\n", Content/binary>>
        end
    end, <<>>, OpenFiles).

%% Token counting now uses API-provided counts when available
run_agent_loop(_Model, Messages, Iteration, _OpenFiles, _SessionId) when Iteration >= ?MAX_ITERATIONS ->
    {error, max_iterations_reached, Messages};
run_agent_loop(Model, Messages, Iteration, OpenFiles, SessionId) ->
    Tools = coding_agent_tools:tools(),
    case coding_agent_ollama:chat_with_tools_cancellable(SessionId, Model, Messages, Tools) of
        {ok, #{<<"message">> := ResponseMsg} = Response} ->
            %% Extract actual token count from API response if available
            TokenInfo = maps:get(token_info, Response, #{}),
            PromptTokens = maps:get(prompt_tokens, TokenInfo, undefined),
            CompletionTokens = maps:get(completion_tokens, TokenInfo, undefined),
            IsEstimated = maps:get(is_estimated, TokenInfo, true),
            
            %% Build token tracking info
            TokenInfoMap = case {PromptTokens, CompletionTokens, IsEstimated} of
                {P, C, false} when is_integer(P), is_integer(C) ->
                    #{prompt_tokens => P, completion_tokens => C, estimated_tokens => 0};
                {P, C, true} when is_integer(P), is_integer(C) ->
                    #{prompt_tokens => P, completion_tokens => C, estimated_tokens => 0};
                _ ->
                    %% Fallback to estimate
                    EstTokens = coding_agent_ollama:count_tokens(Messages),
                    #{prompt_tokens => 0, completion_tokens => 0, estimated_tokens => EstTokens}
            end,
            handle_response(Model, Messages, ResponseMsg, Iteration, OpenFiles, TokenInfoMap, SessionId);
        {error, halted} ->
            {error, request_halted};
        {error, Reason} ->
            {error, Reason}
    end.

handle_response(Model, Messages, #{<<"tool_calls">> := ToolCalls} = ResponseMsg, Iteration, OpenFiles, TokenInfo, SessionId) ->
    Thinking = maps:get(<<"thinking">>, ResponseMsg, <<>>),
    display_thinking(Thinking),
    AssistantMsg = #{
        <<"role">> => <<"assistant">>,
        <<"content">> => maps:get(<<"content">>, ResponseMsg, <<>>),
        <<"tool_calls">> => ToolCalls
    },
    UpdatedMessages = Messages ++ [AssistantMsg],
    {ToolResults, NewOpenFiles} = execute_tool_calls(ToolCalls, OpenFiles),
    
    SummarizedResults = summarize_if_large(ToolResults, ?MAX_TOOL_RESULT_SIZE),
    ToolMsg = #{<<"role">> => <<"tool">>, <<"content">> => SummarizedResults},
    MessagesWithResults = UpdatedMessages ++ [ToolMsg],
    
    ToolResultTokens = coding_agent_ollama:count_tokens(SummarizedResults),
    UpdatedTokenInfo = TokenInfo#{
        estimated_tokens => maps:get(estimated_tokens, TokenInfo, 0) + ToolResultTokens
    },
    
    case run_agent_loop(Model, MessagesWithResults, Iteration + 1, NewOpenFiles, SessionId) of
        {ok, Response, NewThinking, NewHistory, FinalOpenFiles, MoreTokenInfo} ->
            CombinedThinking = case Thinking of
                <<>> -> NewThinking;
                _ -> <<Thinking/binary, "\n\n", NewThinking/binary>>
            end,
            MergedTokenInfo = #{
                prompt_tokens => maps:get(prompt_tokens, TokenInfo, 0) + maps:get(prompt_tokens, MoreTokenInfo, 0),
                completion_tokens => maps:get(completion_tokens, TokenInfo, 0) + maps:get(completion_tokens, MoreTokenInfo, 0),
                estimated_tokens => maps:get(estimated_tokens, UpdatedTokenInfo, 0) + maps:get(estimated_tokens, MoreTokenInfo, 0)
            },
            {ok, Response, CombinedThinking, NewHistory, FinalOpenFiles, MergedTokenInfo};
        {error, Reason} ->
            {error, Reason}
    end;

handle_response(_Model, Messages, #{<<"content">> := Content} = ResponseMsg, _Iteration, OpenFiles, TokenInfo, _SessionId) when Content =/= <<>>, Content =/= nil ->
    Thinking = maps:get(<<"thinking">>, ResponseMsg, <<>>),
    AssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => Content},
    NewHistory = Messages ++ [AssistantMsg],
    {ok, Content, Thinking, NewHistory, OpenFiles, TokenInfo};

handle_response(_Model, _Messages, _ResponseMsg, _Iteration, _OpenFiles, _TokenInfo, _SessionId) ->
    {error, unexpected_response}.

execute_tool_calls(ToolCalls, OpenFiles) when is_list(ToolCalls) ->
    Results = [execute_single_tool_with_retry(TC, OpenFiles) || TC <- ToolCalls],
    NewOpenFiles = lists:foldl(fun
        ({{#{<<"success">> := true, <<"file_cached">> := Path, <<"content">> := Content}}, _}, Acc) ->
            maps:put(Path, Content, Acc);
        ({#{<<"success">> := true, <<"file_opened">> := Path}, _}, Acc) ->
            % Remove from cache since content changed
            maps:remove(Path, Acc);
        (_, Acc) -> Acc
    end, OpenFiles, Results),
    ResultList = [R || {R, _} <- Results],
    SafeResults = limit_results(ResultList, ?MAX_TOOL_RESULT_SIZE),
    ResultBin = serialize_results(SafeResults),
    {ResultBin, NewOpenFiles}.

serialize_results(Results) ->
    try jsx:encode(Results)
    catch
        _:_ -> <<"[result serialization failed]">>
    end.

limit_results(Results, MaxSize) when is_list(Results) ->
    limit_results(Results, MaxSize, 0, []);
limit_results(Results, _MaxSize) ->
    Results.

limit_results([], _MaxSize, _CurrentSize, Acc) ->
    lists:reverse(Acc);
limit_results([Result | Rest], MaxSize, CurrentSize, Acc) when CurrentSize > MaxSize ->
    lists:reverse(Acc);
limit_results([#{<<"success">> := true, <<"output">> := Output} = Result | Rest], MaxSize, CurrentSize, Acc) ->
    OutputSize = case is_binary(Output) of
        true -> byte_size(Output);
        _ -> 0
    end,
    case CurrentSize + OutputSize of
        NewSize when NewSize > MaxSize ->
            % Truncate this result
            Truncated = case is_binary(Output) of
                true when byte_size(Output) > 5000 ->
                    <<First:5000/binary, _/binary>> = Output,
                    maps:put(<<"output">>, <<First/binary, "...">>, Result);
                _ -> Result
            end,
            lists:reverse([Truncated | Acc]);
        NewSize ->
            limit_results(Rest, MaxSize, NewSize, [Result | Acc])
    end;
limit_results([Result | Rest], MaxSize, CurrentSize, Acc) ->
    limit_results(Rest, MaxSize, CurrentSize, [Result | Acc]).

execute_single_tool_with_retry(TC, OpenFiles) ->
    execute_single_tool_with_retry(TC, OpenFiles, 0).

execute_single_tool_with_retry(TC, OpenFiles, RetryCount) when RetryCount >= ?MAX_TOOL_RETRIES ->
    % Max retries reached, return failure
    {#{<<"success">> => false, <<"error">> => <<"Max retries exceeded">>}, OpenFiles};
execute_single_tool_with_retry(TC, OpenFiles, RetryCount) ->
    case execute_single_tool(TC, OpenFiles) of
        {#{<<"success">> := false, <<"error">> := Error} = Result, NewOpenFiles} ->
            % Retry on failure
            case should_retry(Error) of
                true ->
                    timer:sleep(100 * (RetryCount + 1)),  % Exponential backoff
                    execute_single_tool_with_retry(TC, NewOpenFiles, RetryCount + 1);
                false ->
                    {Result, NewOpenFiles}
            end;
        Success ->
            Success
    end.

should_retry(<<"file not found">>) -> false;
should_retry(<<"permission denied">>) -> false;
should_retry(<<"syntax error">>) -> false;
should_retry(_) -> true.  % Retry on transient errors

execute_single_tool(#{<<"function">> := #{<<"name">> := Name, <<"arguments">> := Args}}, OpenFiles) ->
    % Print tool call for visibility
    io:format("  [tool] ~s", [Name]),
    case maps:size(Args) of
        0 -> io:format("~n");
        _ ->
            ArgPreview = try 
                Preview = iolist_to_binary(io_lib:format("~p", [Args])),
                case byte_size(Preview) of
                    Size when Size > 100 ->
                        <<Short:100/binary, _/binary>> = Preview,
                        <<Short/binary, "...">>;
                    _ -> Preview
                end
            catch _:_ -> <<"...">>
            end,
            io:format(" ~s~n", [ArgPreview])
    end,
    Result = coding_agent_tools:execute(Name, Args),
    
    % Cache file content if it was read successfully
    CachedResult = case Name of
        <<"read_file">> ->
            case Result of
                #{<<"success">> := true, <<"content">> := Content} ->
                    Path = maps:get(<<"path">>, Args),
                    Result#{<<"file_cached">> => Path};
                _ -> Result
            end;
        <<"write_file">> ->
            case Result of
                #{<<"success">> := true} ->
                    Path = maps:get(<<"path">>, Args),
                    % Remove from cache since content changed
                    Result#{<<"file_opened">> => Path};
                _ -> Result
            end;
        <<"edit_file">> ->
            case Result of
                #{<<"success">> := true} ->
                    Path = maps:get(<<"path">>, Args),
                    % Remove from cache since content changed
                    Result#{<<"file_opened">> => Path};
                _ -> Result
            end;
        _ -> Result
    end,
    {CachedResult, OpenFiles}.

generate_id() ->
    <<A:32, B:32, C:32>> = crypto:strong_rand_bytes(12),
    iolist_to_binary(io_lib:format("~8.16.0b-~8.16.0b-~8.16.0b", [A, B, C])).

trim_history(History) ->
    trim_history(History, ?MAX_HISTORY, ?MAX_HISTORY_SIZE).

%% Strip system messages from history to avoid duplication
strip_system_messages(History) when is_list(History) ->
    lists:filter(fun(Msg) ->
        case maps:get(<<"role">>, Msg, undefined) of
            <<"system">> -> false;
            _ -> true
        end
    end, History).

trim_history(History, MaxCount, MaxSize) ->
    % First trim by count
    TrimmedByCount = case length(History) > MaxCount of
        true -> lists:sublist(History, MaxCount);
        false -> History
    end,
    % Then trim by size (keep most recent, drop oldest)
    HistorySize = estimate_history_size(TrimmedByCount),
    case HistorySize > MaxSize of
        true -> trim_by_size(TrimmedByCount, MaxSize);
        false -> TrimmedByCount
    end.

estimate_history_size([]) -> 0;
estimate_history_size([Msg | Rest]) ->
    Content = maps:get(<<"content">>, Msg, <<>>),
    Size = case is_binary(Content) of
        true -> byte_size(Content);
        _ -> 0
    end,
    Size + estimate_history_size(Rest).

trim_by_size([], _MaxSize) -> [];
trim_by_size(History, MaxSize) ->
    % Drop oldest messages until under size
    case estimate_history_size(History) > MaxSize of
        true -> trim_by_size(tl(History), MaxSize);
        false -> History
    end.

%% Summarize tool results if they're too large
summarize_if_large(Results, MaxSize) when is_binary(Results) ->
    case byte_size(Results) > MaxSize of
        true ->
            % Extract key info and truncate
            <<First:(MaxSize div 2)/binary, _/binary>> = Results,
            <<First/binary, "\n... [result truncated due to size]">>;
        false -> Results
    end;
summarize_if_large(Results, MaxSize) when is_list(Results) ->
    % Convert to binary first
    ResultsBin = try jsx:encode(Results)
    catch _:_ -> iolist_to_binary(io_lib:format("~p", [Results]))
    end,
    summarize_if_large(ResultsBin, MaxSize).

%% Self-healing: Check for recent crash reports and include in context
get_recent_crash_context() ->
    CrashDir = ?CRASH_DIR,
    case filelib:is_dir(CrashDir) of
        false -> <<>>;
        true ->
            % Get all crash reports sorted by modification time (newest first)
            CrashFiles = filelib:wildcard(filename:join(CrashDir, "crash-*.md")),
            SortedFiles = lists:sort(fun(A, B) ->
                filelib:last_modified(A) > filelib:last_modified(B)
            end, CrashFiles),
            
            % Get the most recent crash
            case SortedFiles of
                [] -> <<>>;
                [MostRecent | _] ->
                    % Check if crash is recent (within last 60 seconds)
                    Mtime = filelib:last_modified(MostRecent),
                    Now = calendar:local_time(),
                    SecDiff = calendar:datetime_to_gregorian_seconds(Now) -
                               calendar:datetime_to_gregorian_seconds(Mtime),
                    case SecDiff < 60 of
                        true ->
                            % Recent crash - include in context
                            CrashPath = list_to_binary(MostRecent),
                            <<"\n\n# Recent Crash Detected\n\n"
                              "A crash occurred within the last 60 seconds.\n\n"
                              "Crash report: ", CrashPath/binary, "\n\n"
                              "Use `read_file \"", CrashPath/binary, "\"` to read the full crash report.\n">>;
                        false ->
                            <<>>
                    end
            end
    end.

%% Display thinking content before tool execution
display_thinking(<<>>) -> ok;
display_thinking(Thinking) when is_binary(Thinking) ->
    io:format("~n--- Thinking ---~n~s~n", [Thinking]);
display_thinking(_) -> ok.

get_memory_context() ->
    case whereis(coding_agent_conv_memory) of
        undefined -> <<>>;
        _ ->
            case coding_agent_conv_memory:get_context() of
                {ok, <<>>} -> <<>>;
                {ok, Context} -> Context;
                _ -> <<>>
            end
    end.

maybe_trigger_consolidation() ->
    case whereis(coding_agent_conv_memory) of
        undefined -> ok;
        _ ->
            spawn(fun() ->
                case coding_agent_conv_memory:should_consolidate() of
                    {ok, true, _Count} ->
                        coding_agent_conv_memory:consolidate();
                    _ -> ok
                end
            end)
    end.

get_skills_context() ->
    case whereis(coding_agent_skills) of
        undefined -> <<>>;
        _ ->
            case coding_agent_skills:build_skills_summary() of
                {ok, <<>>} -> <<>>;
                {ok, Summary} -> Summary;
                _ -> <<>>
            end
    end.

get_agents_context() ->
    Workspace = get_workspace(),
    AgentsFile = filename:join(Workspace, "AGENTS.md"),
    case file:read_file(AgentsFile) of
        {ok, Content} ->
            % Strip frontmatter if present
            strip_frontmatter(Content);
        _ -> <<>>
    end.

get_workspace() ->
    case file:get_cwd() of
        {ok, Dir} -> Dir;
        _ -> "."
    end.

strip_frontmatter(Content) when is_binary(Content) ->
    case binary:match(Content, <<"---">>) of
        {0, _} ->
            case binary:split(Content, <<"---">>, [global]) of
                [_, _, Rest | _] -> binary:strip(Rest);
                _ -> Content
            end;
        _ -> Content
    end;
strip_frontmatter(Content) -> Content.

%% Session compaction - summarize and archive old context
%% Uses model's context_length from Ollama API for smarter compaction
maybe_compact_session(State = #state{prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET, context_length = ContextLength}) ->
    TotalTokens = PT + CT + ET,
    %% Calculate threshold based on context length
    Threshold = case ContextLength > 0 of
        true -> round(ContextLength * ?CONTEXT_USAGE_THRESHOLD);
        false -> ?COMPACTION_THRESHOLD  % Fallback
    end,
    case TotalTokens > Threshold of
        true -> 
            io:format("[session] Context ~p/~p tokens (~p%), triggering compaction~n", 
                      [TotalTokens, ContextLength, round((TotalTokens / ContextLength) * 100)]),
            compact_session(State);
        false -> 
            State
    end.

compact_session(State = #state{id = Id, messages = Messages, model = Model, 
                                 prompt_tokens = PT, completion_tokens = CT, 
                                 estimated_tokens = ET, context_length = ContextLength}) ->
    TotalTokens = PT + CT + ET,
    io:format("[session] Compacting session ~s (~p/~p tokens, ~p%)~n", 
              [Id, TotalTokens, ContextLength, round((TotalTokens / max(ContextLength, 1)) * 100)]),
    
    ArchiveId = archive_session(State),
    
    Result = case split_messages(Messages, ?KEEP_RECENT_MESSAGES) of
        {[], _RecentMsgs} ->
            io:format("[session] All messages are recent, using sliding window~n"),
            KeepCount = max(5, round(length(Messages) * 0.5)),
            {ok, lists:sublist(Messages, KeepCount)};
        {OldMsgs, RecentMsgs} ->
            io:format("[session] Summarizing ~p old messages, keeping ~p recent~n", 
                      [length(OldMsgs), length(RecentMsgs)]),
            case summarize_messages_with_timeout(OldMsgs, Model, ?SUMMARIZE_TIMEOUT) of
                {ok, SummaryText} ->
                    SummaryMsg = #{
                        <<"role">> => <<"user">>,
                        <<"content">> => <<"[Context from previous conversation]\n", SummaryText/binary>>
                    },
                    io:format("[session] Session compacted. Archived as ~s~n", [ArchiveId]),
                    {ok, [SummaryMsg | RecentMsgs]};
                {error, timeout} ->
                    io:format("[session] Summarization timed out, using sliding window~n"),
                    KeepCount = length(RecentMsgs) + min(5, length(OldMsgs)),
                    {ok, lists:sublist(Messages, KeepCount)};
                {error, Reason} ->
                    io:format("[session] Summarization failed: ~p, using sliding window~n", [Reason]),
                    KeepCount = length(RecentMsgs) + min(5, length(OldMsgs)),
                    {ok, lists:sublist(Messages, KeepCount)}
            end
    end,
    
    case Result of
        {ok, NewMessages} ->
            NewTokenEst = lists:foldl(fun(M, Acc) ->
                Content = maps:get(<<"content">>, M, <<>>),
                byte_size(Content) div 4 + Acc
            end, 0, NewMessages),
            State#state{
                messages = NewMessages,
                prompt_tokens = 0,
                completion_tokens = 0,
                estimated_tokens = NewTokenEst
            };
        {error, _} ->
            io:format("[session] Compaction failed, keeping full context~n"),
            State
    end.

%% Split messages into old (to summarize) and recent (to keep intact)
split_messages(Messages, KeepCount) ->
    Total = length(Messages),
    case Total =< KeepCount of
        true -> {[], Messages};
        false ->
            OldCount = Total - KeepCount,
            OldMsgs = lists:sublist(Messages, OldCount),
            RecentMsgs = lists:nthtail(OldCount, Messages),
            {OldMsgs, RecentMsgs}
    end.

%% Summarize messages with timeout - falls back on failure
summarize_messages_with_timeout(Messages, Model, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Result = summarize_messages(Messages, Model),
        Parent ! {Ref, Result}
    end),
    receive
        {Ref, Result} -> Result
    after TimeoutMs ->
        exit(Pid, kill),
        {error, timeout}
    end.

archive_session(#state{id = Id, model = Model, context_length = ContextLength, messages = Messages, working_dir = WD, open_files = OpenFiles, prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET, tool_calls = Calls}) ->
    TotalTokens = PT + CT + ET,
    Timestamp = erlang:system_time(millisecond),
    DateTimeStr = format_datetime_utc(Timestamp),
    ArchiveId = <<Id/binary, "-archived-", DateTimeStr/binary>>,
    filelib:ensure_dir(?ARCHIVE_DIR ++ "/"),
    ArchivePath = filename:join(?ARCHIVE_DIR, <<ArchiveId/binary, ".json">>),
    ArchiveData = #{
        id => ArchiveId,
        original_id => Id,
        model => Model,
        context_length => ContextLength,
        working_dir => list_to_binary(WD),
        messages => Messages,
        open_files => OpenFiles,
        total_tokens => TotalTokens,
        prompt_tokens => PT,
        completion_tokens => CT,
        estimated_tokens => ET,
        tool_calls => Calls,
        context_usage_percent => case ContextLength > 0 of
            true -> round((TotalTokens / ContextLength) * 100 * 10) / 10;
            false -> 0.0
        end,
        archived_at => Timestamp,
        archived_at_utc => DateTimeStr
    },
    case file:write_file(ArchivePath, jsx:encode(ArchiveData)) of
        ok -> ArchiveId;
        _ -> <<>>
    end.

format_datetime_utc(TimestampMs) when is_integer(TimestampMs) ->
    Seconds = TimestampMs div 1000,
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", 
        [Year, Month, Day, Hour, Min, Sec]));
format_datetime_utc(_) ->
    <<"unknown">>.

summarize_messages([], _Model) ->
    {ok, <<"No previous conversation.">>};
summarize_messages(Messages, Model) ->
    % Build a summary prompt
    ConversationText = messages_to_text(Messages),
    SummaryPrompt = <<"Summarize the following conversation concisely, capturing:\n"
                      "1. Key topics discussed\n"
                      "2. Important decisions made\n"
                      "3. Files worked on\n"
                      "4. Current state/progress\n\n"
                      "Keep the summary under 2000 characters.\n\n"
                      "Conversation:\n", ConversationText/binary>>,
    
    case coding_agent_ollama:chat(Model, [
        #{<<"role">> => <<"system">>, <<"content">> => <<"You are a helpful assistant that summarizes conversations concisely.">>},
        #{<<"role">> => <<"user">>, <<"content">> => SummaryPrompt}
    ]) of
        {ok, #{<<"message">> := #{<<"content">> := Summary}}} when is_binary(Summary) ->
            {ok, Summary};
        {ok, _} ->
            {error, invalid_response};
        {error, Reason} ->
            {error, Reason}
    end.

messages_to_text(Messages) ->
    lists:foldl(fun(Msg, Acc) ->
        Role = maps:get(<<"role">>, Msg, <<"unknown">>),
        Content = maps:get(<<"content">>, Msg, <<"">>),
        RoleStr = case Role of
            <<"system">> -> <<"SYSTEM: ">>;
            <<"user">> -> <<"USER: ">>;
            <<"assistant">> -> <<"ASSISTANT: ">>;
            <<"tool">> -> <<"TOOL: ">>;
            _ -> <<"UNKNOWN: ">>
        end,
        % Truncate long content
        Truncated = case byte_size(Content) > 1000 of
            true ->
                <<Short:1000/binary, _/binary>> = Content,
                <<Short/binary, "... (truncated)">>;
            false -> Content
        end,
        <<Acc/binary, RoleStr/binary, Truncated/binary, "\n\n">>
    end, <<"">>, Messages).

%% Auto-save session (async)
maybe_save_session(State = #state{id = Id, model = Model, working_dir = WD, open_files = OpenFiles, prompt_tokens = PT, completion_tokens = CT, estimated_tokens = ET, tool_calls = TC, messages = Messages}) ->
    spawn(fun() ->
        SessionData = #{
            id => Id,
            model => Model,
            working_dir => list_to_binary(WD),
            messages => Messages,
            open_files => OpenFiles,
            prompt_tokens => PT,
            completion_tokens => CT,
            estimated_tokens => ET,
            total_tokens => PT + CT + ET,
            tool_calls => TC
        },
        coding_agent_session_store:save_session(Id, SessionData)
    end).

%% Session persistence API

save_session(SessionId) when is_binary(SessionId); is_list(SessionId) ->
    SessionIdBin = if is_list(SessionId) -> list_to_binary(SessionId); true -> SessionId end,
    case ets:lookup(?SESSIONS_TABLE, SessionIdBin) of
        [{_, Pid}] -> gen_server:call(Pid, save_session);
        [] -> {error, session_not_found}
    end.

load_session(SessionId) when is_binary(SessionId); is_list(SessionId) ->
    SessionIdBin = if is_list(SessionId) -> list_to_binary(SessionId); true -> SessionId end,
    case coding_agent_session_store:load_session(SessionIdBin) of
        {ok, Data} ->
            case coding_agent_session_sup:start_session(SessionIdBin) of
                {ok, Pid} ->
                    gen_server:call(Pid, {restore_state, Data}),
                    ets:insert(?SESSIONS_TABLE, {SessionIdBin, Pid}),
                    {ok, {SessionIdBin, Pid}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, not_found} ->
            {error, session_not_found};
        {error, Reason} ->
            {error, Reason}
    end.

list_saved_sessions() ->
    coding_agent_session_store:list_sessions().