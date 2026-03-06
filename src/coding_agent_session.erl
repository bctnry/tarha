-module(coding_agent_session).
-behaviour(gen_server).

-export([start_link/0, start_link/1, start_link/2, new/0, new/1, ask/2, ask/3]).
-export([history/1, clear/1, stop_session/1, sessions/0]).
-export([open_files/1, close_file/2, stats/1, ask_stream/3]).
-export([save_session/1, load_session/1, list_saved_sessions/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    id :: binary(),
    model :: binary(),
    messages :: list(),
    working_dir :: string(),
    open_files :: #{binary() => binary()},  % Path => Content cache
    total_tokens :: integer(),
    tool_calls :: integer()
}).

-define(MAX_ITERATIONS, 100).
-define(MAX_HISTORY, 100).
-define(MAX_TOKENS, 120000).
-define(MAX_TOOL_RETRIES, 3).
-define(SESSIONS_TABLE, coding_agent_sessions).
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
    gen_server:call(Session, {ask_stream, Message, Callback, Opts}, 300000);
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
    gen_server:call(Session, {ask, Message, Opts}, 300000);
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
    process_flag(trap_exit, true),
    {ok, #state{
        id = Id2,
        model = Model,
        messages = [],
        working_dir = WD,
        open_files = #{},
        total_tokens = 0,
        tool_calls = 0
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
    
    % Add skills if present
    WithSkills = case SkillsContext of
        <<>> -> WithMemory;
        _ -> <<WithMemory/binary, "\n\n# Skills\n\n", SkillsContext/binary>>
    end,
    
    % Add open files if present
    SystemContent = case FileContext of
        <<>> -> WithSkills;
        _ -> <<WithSkills/binary, "\n\nOpen files (cached in context):\n", FileContext/binary>>
    end,
    
    SystemMsg = #{<<"role">> => <<"system">>, <<"content">> => SystemContent},
    UserMsg = #{<<"role">> => <<"user">>, <<"content">> => MsgBin},
    ExistingHistory = trim_history(History),
    Messages = [SystemMsg | ExistingHistory] ++ [UserMsg],
    
    case run_agent_loop(Model, Messages, 0, OpenFiles) of
        {ok, Response, Thinking, NewHistory, FinalOpenFiles, TokensUsed} ->
            FinalHistory = trim_history(NewHistory, ?MAX_HISTORY),
            ReplyHistory = [{maps:get(<<"role">>, M), maps:get(<<"content">>, M, <<"">>)} || M <- lists:sublist(FinalHistory, 2, length(FinalHistory))],
            NewState = State#state{
                messages = FinalHistory,
                open_files = FinalOpenFiles,
                total_tokens = State#state.total_tokens + TokensUsed,
                tool_calls = State#state.tool_calls + 1
            },
            % Check if consolidation needed (async)
            maybe_trigger_consolidation(),
            % Auto-save session (async)
            maybe_save_session(NewState),
            {reply, {ok, Response, Thinking, ReplyHistory}, NewState};
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

handle_call(stats, _From, State = #state{total_tokens = Tokens, tool_calls = Calls}) ->
    {reply, {ok, #{
        <<"total_tokens_estimate">> => Tokens,
        <<"tool_calls">> => Calls,
        <<"message_count">> => length(State#state.messages)
    }}, State};

handle_call(clear, _From, State) ->
    {reply, ok, State#state{messages = [], open_files = #{}}};

handle_call(save_session, _From, State = #state{id = Id, model = Model, working_dir = WD, open_files = OpenFiles}) ->
    SessionData = #{
        id => Id,
        model => Model,
        working_dir => list_to_binary(WD),
        messages => State#state.messages,
        open_files => OpenFiles,
        total_tokens => State#state.total_tokens,
        tool_calls => State#state.tool_calls
    },
    case coding_agent_session_store:save_session(Id, SessionData) of
        ok -> {reply, {ok, Id}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({restore_state, Data}, _From, _State) ->
    NewState = #state{
        id = maps:get(id, Data, <<>>),
        model = maps:get(model, Data, <<"glm-5:cloud">>),
        messages = maps:get(messages, Data, []),
        working_dir = case maps:get(working_dir, Data, ".") of
            W when is_binary(W) -> binary_to_list(W);
            W when is_list(W) -> W;
            _ -> "."
        end,
        open_files = maps:get(open_files, Data, #{}),
        total_tokens = maps:get(total_tokens, Data, 0),
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

run_agent_loop(Model, Messages, Iteration, OpenFiles) when Iteration >= ?MAX_ITERATIONS ->
    {error, max_iterations_reached, Messages};
run_agent_loop(Model, Messages, Iteration, OpenFiles) ->
    Tools = coding_agent_tools:tools(),
    case coding_agent_ollama:chat_with_tools(Model, Messages, Tools) of
        {ok, #{<<"message">> := ResponseMsg}} ->
            handle_response(Model, Messages, ResponseMsg, Iteration, OpenFiles);
        {error, Reason} ->
            {error, Reason}
    end.

handle_response(Model, Messages, #{<<"tool_calls">> := ToolCalls} = ResponseMsg, Iteration, OpenFiles) ->
    Thinking = maps:get(<<"thinking">>, ResponseMsg, <<>>),
    AssistantMsg = #{
        <<"role">> => <<"assistant">>,
        <<"content">> => maps:get(<<"content">>, ResponseMsg, <<"">>),
        <<"tool_calls">> => ToolCalls
    },
    UpdatedMessages = Messages ++ [AssistantMsg],
    {ToolResults, NewOpenFiles} = execute_tool_calls(ToolCalls, OpenFiles),
    ToolMsg = #{<<"role">> => <<"tool">>, <<"content">> => ToolResults},
    MessagesWithResults = UpdatedMessages ++ [ToolMsg],
    
    % Estimate tokens
    MsgSize = estimate_message_size(MessagesWithResults),
    
    case run_agent_loop(Model, MessagesWithResults, Iteration + 1, NewOpenFiles) of
        {ok, Response, NewThinking, NewHistory, FinalOpenFiles, TokensUsed} ->
            CombinedThinking = case Thinking of
                <<>> -> NewThinking;
                _ -> <<Thinking/binary, "\n\n", NewThinking/binary>>
            end,
            {ok, Response, CombinedThinking, NewHistory, FinalOpenFiles, TokensUsed + MsgSize};
        {error, Reason} ->
            {error, Reason}
    end;

handle_response(_Model, Messages, #{<<"content">> := Content} = ResponseMsg, _Iteration, OpenFiles) when Content =/= <<>>, Content =/= nil ->
    Thinking = maps:get(<<"thinking">>, ResponseMsg, <<>>),
    AssistantMsg = #{<<"role">> => <<"assistant">>, <<"content">> => Content},
    NewHistory = Messages ++ [AssistantMsg],
    MsgSize = estimate_message_size(NewHistory),
    {ok, Content, Thinking, NewHistory, OpenFiles, MsgSize};

handle_response(_Model, _Messages, _ResponseMsg, _Iteration, _OpenFiles) ->
    {error, unexpected_response}.

estimate_message_size(Messages) ->
    lists:foldl(fun(Msg, Acc) ->
        Content = maps:get(<<"content">>, Msg, <<"">>),
        Acc + byte_size(Content)
    end, 0, Messages).

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
    {list_to_binary(io_lib:format("~p", [ResultList])), NewOpenFiles}.

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
    trim_history(History, ?MAX_TOKENS).

trim_history(History, MaxTokens) ->
    HistorySize = coding_agent_ollama:count_tokens(History),
    case HistorySize > MaxTokens of
        false -> History;
        true ->
            % Remove oldest messages until we're under limit
            % Keep system message (first) and last message
            case length(History) of
                N when N =< 2 -> History;
                _ ->
                    % Remove the oldest non-system message
                    [SysMsg | Rest] = History,
                    case Rest of
                        [] -> [SysMsg];
                        [Last] -> [SysMsg, Last];
                        _ ->
                            NewRest = lists:droplast(Rest),
                            Last = lists:last(Rest),
                            trim_history([SysMsg | NewRest] ++ [Last], MaxTokens)
                    end
            end
    end.

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

%% Auto-save session (async)
maybe_save_session(State = #state{id = Id, model = Model, working_dir = WD, open_files = OpenFiles}) ->
    spawn(fun() ->
        SessionData = #{
            id => Id,
            model => Model,
            working_dir => list_to_binary(WD),
            messages => State#state.messages,
            open_files => OpenFiles,
            total_tokens => State#state.total_tokens,
            tool_calls => State#state.tool_calls
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