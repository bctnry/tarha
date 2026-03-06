-module(coding_agent_conv_memory).
-behaviour(gen_server).

-export([start_link/0, start_link/1, stop/0]).
-export([get_memory/0, get_history/0, append_history/1, update_memory/1, get_context/0]).
-export([consolidate/0, consolidate/1, should_consolidate/0, set_window/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    workspace :: string(),
    memory_file :: string(),
    history_file :: string(),
    memory :: binary(),
    history :: binary(),
    window :: integer(),
    last_consolidated :: integer()
}).

-define(DEFAULT_WINDOW, 50).
-define(MIN_CONSOLIDATE_THRESHOLD, 20).

start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

stop() ->
    gen_server:stop(?MODULE).

init([Options]) ->
    Workspace = proplists:get_value(workspace, Options, get_default_workspace()),
    MemoryFile = filename:join([Workspace, "memory", "MEMORY.md"]),
    HistoryFile = filename:join([Workspace, "memory", "HISTORY.md"]),
    Window = proplists:get_value(window, Options, ?DEFAULT_WINDOW),
    
    MemoryDir = filename:join(Workspace, "memory"),
    filelib:ensure_dir(MemoryDir ++ "/"),
    
    Memory = read_file(MemoryFile, <<>>),
    History = read_file(HistoryFile, <<>>),
    
    {ok, #state{
        workspace = Workspace,
        memory_file = MemoryFile,
        history_file = HistoryFile,
        memory = Memory,
        history = History,
        window = Window,
        last_consolidated = 0
    }}.

get_default_workspace() ->
    case file:get_cwd() of
        {ok, Dir} -> Dir;
        _ -> "."
    end.

read_file(Path, Default) ->
    case file:read_file(Path) of
        {ok, Content} -> Content;
        _ -> Default
    end.

handle_call(get_memory, _From, State = #state{memory = Memory}) ->
    {reply, {ok, Memory}, State};

handle_call(get_history, _From, State = #state{history = History}) ->
    {reply, {ok, History}, State};

handle_call(get_context, _From, State = #state{memory = Memory}) ->
    Context = case Memory of
        <<>> -> <<>>;
        _ -> <<"## Long-term Memory\n", Memory/binary>>
    end,
    {reply, {ok, Context}, State};

handle_call({append_history, Entry}, _From, State = #state{history = History, history_file = File}) ->
    Timestamp = format_timestamp(erlang:system_time(millisecond)),
    NewEntry = case Entry of
        <<"[", _/binary>> -> Entry;
        _ -> <<"[", Timestamp/binary, "] ", Entry/binary>>
    end,
    NewHistory = case History of
        <<>> -> NewEntry;
        _ -> <<History/binary, "\n\n", NewEntry/binary>>
    end,
    file:write_file(File, NewHistory),
    {reply, ok, State#state{history = NewHistory}};

handle_call({update_memory, Content}, _From, State = #state{memory = OldMemory, memory_file = File}) ->
    case Content of
        OldMemory -> {reply, ok, State};
        _ ->
            file:write_file(File, Content),
            {reply, ok, State#state{memory = Content}}
    end;

handle_call(should_consolidate, _From, State) ->
    SessionCount = get_session_count(),
    SinceLast = SessionCount - State#state.last_consolidated,
    Should = SinceLast >= ?MIN_CONSOLIDATE_THRESHOLD,
    {reply, {ok, Should, SinceLast}, State};

handle_call(consolidate, _From, State) ->
    Result = do_consolidate(State),
    {reply, Result, State};

handle_call({consolidate, Options}, _From, State) ->
    Result = do_consolidate(State, Options),
    {reply, Result, State};

handle_call({set_window, Window}, _From, State) ->
    {reply, ok, State#state{window = Window}};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

get_memory() ->
    gen_server:call(?MODULE, get_memory).

get_history() ->
    gen_server:call(?MODULE, get_history).

get_context() ->
    gen_server:call(?MODULE, get_context).

append_history(Entry) when is_binary(Entry) ->
    gen_server:call(?MODULE, {append_history, Entry});
append_history(Entry) when is_list(Entry) ->
    append_history(iolist_to_binary(Entry)).

update_memory(Content) when is_binary(Content) ->
    gen_server:call(?MODULE, {update_memory, Content});
update_memory(Content) when is_list(Content) ->
    update_memory(iolist_to_binary(Content)).

should_consolidate() ->
    gen_server:call(?MODULE, should_consolidate).

consolidate() ->
    gen_server:call(?MODULE, consolidate, 120000).

consolidate(Options) ->
    gen_server:call(?MODULE, {consolidate, Options}, 120000).

set_window(Window) ->
    gen_server:call(?MODULE, {set_window, Window}).

get_session_count() ->
    case ets:whereis(coding_agent_sessions) of
        undefined -> 0;
        Table ->
            try ets:info(Table, size) of
                N when is_integer(N) -> N;
                _ -> 0
            catch
                _:_ -> 0
            end
    end.

format_timestamp(Ms) when is_integer(Ms) ->
    Seconds = Ms div 1000,
    {{Year, Month, Day}, {Hour, Min, _Sec}} = calendar:now_to_universal_time({Seconds div 1000000, Seconds rem 1000000, 0}),
    iolist_to_binary(io_lib:format("~4.10.0B-~2.10.0B-~2.10.0B ~2.10.0B:~2.10.0B", [Year, Month, Day, Hour, Min])).

do_consolidate(State) ->
    do_consolidate(State, #{}).

do_consolidate(State, Options) ->
    Window = maps:get(window, Options, State#state.window),
    ArchiveAll = maps:get(archive_all, Options, false),
    
    KeepCount = Window div 2,
    
    OldMessages = get_old_messages(ArchiveAll, KeepCount),
    
    case OldMessages of
        [] -> {ok, nothing_to_consolidate};
        _ ->
            Prompt = build_consolidation_prompt(OldMessages, State#state.memory),
            case call_llm_for_consolidation(Prompt) of
                {ok, #{<<"history_entry">> := HistoryEntry, <<"memory_update">> := MemoryUpdate}} ->
                    append_history(HistoryEntry),
                    update_memory(MemoryUpdate),
                    {ok, consolidated};
                {ok, Result} ->
                    case maps:get(<<"history_entry">>, Result, undefined) of
                        undefined -> {error, missing_history_entry};
                        Entry ->
                            append_history(Entry),
                            case maps:get(<<"memory_update">>, Result, undefined) of
                                undefined -> {ok, history_only};
                                Update -> 
                                    update_memory(Update),
                                    {ok, consolidated}
                            end
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

get_old_messages(ArchiveAll, KeepCount) ->
    case ets:whereis(coding_agent_sessions) of
        undefined -> [];
        Table ->
            try
                Sessions = ets:tab2list(Table),
                AllMessages = lists:foldl(fun({_Id, Data}, Acc) ->
                    case Data of
                        #{messages := Msgs} when is_list(Msgs) -> Acc ++ Msgs;
                        _ -> Acc
                    end
                end, [], Sessions),
                case ArchiveAll of
                    true -> AllMessages;
                    false when length(AllMessages) =< KeepCount -> [];
                    false -> lists:sublist(AllMessages, 1, length(AllMessages) - KeepCount)
                end
            catch
                _:_ -> []
            end
    end.

build_consolidation_prompt(OldMessages, CurrentMemory) ->
    Lines = lists:map(fun(Msg) ->
        Content = maps:get(<<"content">>, Msg, <<>>),
        Role = maps:get(<<"role">>, Msg, <<"unknown">>),
        ContentPreview = case byte_size(Content) of
            N when N > 200 -> <<(binary:part(Content, 0, 200))/binary, "...">>;
            _ -> Content
        end,
        <<(role_to_binary(Role))/binary, ": ", ContentPreview/binary>>
    end, OldMessages),
    
    MemorySection = case CurrentMemory of
        <<>> -> <<"(empty)">>;
        _ -> CurrentMemory
    end,
    
    iolist_to_binary([<<"Process this conversation and extract:\n",
        "1. A history_entry: A paragraph (2-5 sentences) summarizing key events/decisions/topics. Start with [YYYY-MM-DD HH:MM].\n",
        "2. A memory_update: Full updated long-term memory as markdown. Include all existing facts plus new ones.\n\n",
        "## Current Long-term Memory\n", MemorySection/binary, "\n\n",
        "## Conversation to Process\n",
        (iolist_to_binary(lists:join(<<"\n">>, Lines)))/binary, "\n\n",
        "Return a JSON object with 'history_entry' and 'memory_update' fields.">>]).

role_to_binary(<<"user">>) -> <<"USER">>;
role_to_binary(<<"assistant">>) -> <<"ASSISTANT">>;
role_to_binary(<<"system">>) -> <<"SYSTEM">>;
role_to_binary(R) when is_binary(R) -> binary:to_upper(R);
role_to_binary(R) when is_atom(R) -> role_to_binary(atom_to_binary(R, utf8));
role_to_binary(R) -> iolist_to_binary(io_lib:format("~p", [R])).

call_llm_for_consolidation(Prompt) ->
    Model = application:get_env(coding_agent, model, <<"glm-5:cloud">>),
    OllamaHost = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    
    ConsolidateTool = #{
        <<"type">> => <<"function">>,
        <<"function">> => #{
            <<"name">> => <<"save_memory">>,
            <<"description">> => <<"Save the memory consolidation result to persistent storage.">>,
            <<"parameters">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"history_entry">> => #{
                        <<"type">> => <<"string">>,
                        <<"description">> => <<"A paragraph (2-5 sentences) summarizing key events/decisions/topics. Start with [YYYY-MM-DD HH:MM].">>
                    },
                    <<"memory_update">> => #{
                        <<"type">> => <<"string">>,
                        <<"description">> => <<"Full updated long-term memory as markdown. Include all existing facts plus new ones.">>
                    }
                },
                <<"required">> => [<<"history_entry">>, <<"memory_update">>]
            }
        }
    },
    
    Messages = [
        #{<<"role">> => <<"system">>, <<"content">> => <<"You are a memory consolidation agent. Call the save_memory tool with your consolidation of the conversation.">>},
        #{<<"role">> => <<"user">>, <<"content">> => Prompt}
    ],
    
    case coding_agent_ollama:chat(#{messages => Messages, model => Model, tools => [ConsolidateTool], host => OllamaHost}) of
        {ok, #{<<"tool_calls">> := [ToolCall | _]}} ->
            Args = maps:get(<<"arguments">>, ToolCall, #{}),
            {ok, Args};
        {ok, _} ->
            {error, no_tool_call};
        {error, Reason} ->
            {error, Reason}
    end.