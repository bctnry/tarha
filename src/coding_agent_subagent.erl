-module(coding_agent_subagent).
-behaviour(gen_server).

-export([start_link/1, spawn_agent/2, spawn_agent/3, get_status/1, await/2, kill/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(MAX_SUBAGENT_TURNS, 50).
-define(SUBAGENT_TIMEOUT_MS, 300000).

-record(state, {
    id :: binary(),
    parent_session_id :: binary(),
    subagent_session :: {binary(), pid()} | undefined,
    description :: binary(),
    mode :: build | plan | readonly,
    allowed_tools :: [binary()] | all,
    status :: running | completed | failed,
    result :: term(),
    started_at :: integer()
}).

-define(READONLY_TOOLS, [
    <<"read_file">>, <<"list_files">>, <<"file_exists">>,
    <<"grep_files">>, <<"find_files">>, <<"find_references">>, <<"get_callers">>,
    <<"git_status">>, <<"git_log">>, <<"git_diff">>,
    <<"detect_project">>, <<"list_models">>, <<"show_model">>,
    <<"list_backups">>, <<"undo_history">>,
    <<"list_skills">>, <<"load_skill">>,
    <<"get_self_modules">>, <<"analyze_self">>, <<"list_checkpoints">>,
    <<"review_changes">>, <<"http_request">>, <<"fetch_docs">>, <<"load_context">>,
    <<"hello">>
]).

-define(PLAN_TOOLS, ?READONLY_TOOLS).

-define(ALL_AGENT_DISALLOWED_TOOLS, [
    <<"subagent">>
]).

%%===================================================================
%% Public API
%%===================================================================

start_link(Args) ->
    gen_server:start_link(?MODULE, [Args], []).

spawn_agent(Prompt, Opts) ->
    spawn_agent(Prompt, Opts, ?SUBAGENT_TIMEOUT_MS).

spawn_agent(Prompt, Opts, Timeout) ->
    Description = maps:get(<<"description">>, Opts, <<"sub-agent">>),
    Mode = maps:get(<<"mode">>, Opts, build),
    AllowedTools = case maps:get(<<"tools">>, Opts, all) of
        all -> all;
        ToolList when is_list(ToolList) -> ToolList
    end,
    Args = #{
        description => Description,
        mode => Mode,
        allowed_tools => AllowedTools,
        prompt => Prompt
    },
    case coding_agent_session_sup:start_session(<<"subagent">>) of
        {ok, {SessionId, SessionPid}} ->
            {ok, Pid} = gen_server:start_link(?MODULE, [Args#{session_id => SessionId}]),
            case gen_server:call(Pid, {run, Prompt, SessionId, SessionPid}, Timeout) of
                {ok, Result} -> {ok, Result};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {session_start_failed, Reason}}
    end.

get_status(Pid) ->
    gen_server:call(Pid, get_status, 5000).

await(Pid, Timeout) ->
    case gen_server:call(Pid, await, Timeout) of
        {ok, Result} -> {ok, Result};
        {error, timeout} ->
            kill(Pid),
            {error, timeout};
        {error, Reason} -> {error, Reason}
    end.

kill(Pid) ->
    gen_server:cast(Pid, kill).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init([Args]) ->
    Mode = maps:get(mode, Args, build),
    Id = crypto:strong_rand_bytes(8),
    {ok, #state{
        id = Id,
        description = maps:get(description, Args, <<"sub-agent">>),
        mode = Mode,
        allowed_tools = maps:get(allowed_tools, Args, all),
        status = running,
        result = undefined,
        started_at = erlang:system_time(millisecond)
    }}.

handle_call({run, Prompt, SessionId, SessionPid}, _From, State) ->
    Mode = State#state.mode,
    AllowedTools = filter_tools_for_mode(Mode, State#state.allowed_tools),
    ToolDefs = filter_tool_defs(AllowedTools),
    SystemPrompt = build_subagent_prompt(Mode, State#state.description),
    case run_subagent(SessionId, SessionPid, Prompt, SystemPrompt, ToolDefs) of
        {ok, Response, _Thinking, _History} ->
            ToolCallCount = 0,
            Duration = erlang:system_time(millisecond) - State#state.started_at,
            Result = #{
                success => true,
                description => State#state.description,
                content => Response,
                tool_calls => ToolCallCount,
                duration_ms => Duration,
                mode => Mode
            },
            {reply, {ok, Result}, State#state{status = completed, result = Result}};
        {error, Reason} ->
            Result = #{
                success => false,
                description => State#state.description,
                error => iolist_to_binary(io_lib:format("~p", [Reason])),
                mode => Mode
            },
            {reply, {error, Result}, State#state{status = failed, result = Result}}
    end;

handle_call(get_status, _From, State) ->
    Status = #{
        id => State#state.id,
        description => State#state.description,
        mode => State#state.mode,
        status => State#state.status,
        duration_ms => erlang:system_time(millisecond) - State#state.started_at
    },
    {reply, {ok, Status}, State};

handle_call(await, _From, State) ->
    case State#state.status of
        completed -> {reply, {ok, State#state.result}, State};
        failed -> {reply, {error, State#state.result}, State};
        running -> {reply, {error, still_running}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(kill, State) ->
    {stop, killed, State#state{status = failed}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal functions
%%===================================================================

filter_tools_for_mode(readonly, _AllowedTools) ->
    ?READONLY_TOOLS;
filter_tools_for_mode(plan, _AllowedTools) ->
    ?PLAN_TOOLS;
filter_tools_for_mode(build, AllowedTools) ->
    case AllowedTools of
        all -> all;
        Tools -> 
            Disallowed = ?ALL_AGENT_DISALLOWED_TOOLS,
            [T || T <- Tools, not lists:member(T, Disallowed)]
    end.

filter_tool_defs(all) ->
    coding_agent_tools:tools();
filter_tool_defs(AllowedTools) ->
    lists:filter(fun(#{<<"function">> := #{<<"name">> := Name}}) ->
        lists:member(Name, AllowedTools)
    end, coding_agent_tools:tools()).

build_subagent_prompt(Mode, Description) ->
    ModeStr = case Mode of
        readonly -> <<"read-only research">>;
        plan -> <<"planning and discussion (no execution)">>;
        build -> <<"autonomous coding">>
    end,
    <<"You are a sub-agent performing a specific task in ", ModeStr/binary, " mode.\n\n"
      "Description: ", Description/binary, "\n\n"
      "IMPORTANT RULES:\n"
      "- You are a sub-agent with a specific task\n"
      "- Do NOT spawn further sub-agents\n"
      "- Complete your task and return the result\n"
      "- Be thorough but concise\n"
      "- If in plan mode, discuss your approach but do NOT execute any write operations\n"
      "- If in read-only mode, you can only read files and search, not modify anything\n">>.

run_subagent(SessionId, _SessionPid, Prompt, _SystemPrompt, ToolDefs) ->
    Mode = case ToolDefs of
        all -> build;
        Tools when is_list(Tools) ->
            ReadWriteTools = [<<"edit_file">>, <<"write_file">>, <<"run_command">>, <<"git_commit">>],
            case [T || T <- ReadWriteTools, lists:member(T, Tools)] of
                [] -> readonly;
                _ -> build
            end
    end,
    case Mode of
        readonly ->
            put(subagent_allowed_tools, ToolDefs),
            coding_agent_session:ask(SessionId, Prompt);
        _ ->
            put(subagent_allowed_tools, ToolDefs),
            coding_agent_session:ask(SessionId, Prompt)
    end.