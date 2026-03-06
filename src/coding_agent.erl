-module(coding_agent).
-behaviour(gen_server).

-export([start_link/0, run/1, run/2, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    model :: binary(),
    messages :: list()
}).

-define(MAX_ITERATIONS, 10).
-define(SYSTEM_PROMPT, <<"You are a coding assistant with access to tools. Use the tools to help the user.
Think carefully before acting. Plan your approach, then execute.
When you have completed the task, respond with your final answer.
Available tools:
- read_file: Read a file from the filesystem
- write_file: Write content to a file
- list_files: List files in a directory
- run_command: Execute a shell command
- grep_files: Search for a pattern in files

Always use absolute paths when reading or writing files.
Be careful with run_command - only use it when necessary.">>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

run(Task) ->
    run(Task, #{}).

run(Task, Opts) ->
    gen_server:call(?MODULE, {run, Task, Opts}, 300000).

stop() ->
    gen_server:stop(?MODULE).

init([]) ->
    Model0 = application:get_env(coding_agent, model, <<"glm-5:cloud">>),
    Model = if is_list(Model0) -> list_to_binary(Model0); true -> Model0 end,
    {ok, #state{model = Model, messages = []}}.

handle_call({run, Task, _Opts}, _From, State = #state{model = Model}) ->
    TaskBin = iolist_to_binary(Task),
    Messages = [
        #{<<"role">> => <<"system">>, <<"content">> => ?SYSTEM_PROMPT},
        #{<<"role">> => <<"user">>, <<"content">> => TaskBin}
    ],
    Result = run_agent_loop(Model, Messages, 0),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

run_agent_loop(Model, Messages, Iteration) when Iteration >= ?MAX_ITERATIONS ->
    {error, max_iterations_reached, Messages};
run_agent_loop(Model, Messages, Iteration) ->
    Tools = coding_agent_tools:tools(),
    case coding_agent_ollama:chat_with_tools(Model, Messages, Tools) of
        {ok, #{<<"message">> := ResponseMsg}} ->
            handle_response(Model, Messages, ResponseMsg, Iteration);
        {error, Reason} ->
            {error, Reason}
    end.

handle_response(Model, Messages, #{<<"tool_calls">> := ToolCalls} = ResponseMsg, Iteration) ->
    Thinking = maps:get(<<"thinking">>, ResponseMsg, <<>>),
    AssistantMsg = #{
        <<"role">> => <<"assistant">>,
        <<"content">> => maps:get(<<"content">>, ResponseMsg, <<"">>),
        <<"tool_calls">> => ToolCalls
    },
    UpdatedMessages = Messages ++ [AssistantMsg],
    ToolResults = execute_tool_calls(ToolCalls),
    ToolMsg = #{<<"role">> => <<"tool">>, <<"content">> => ToolResults},
    MessagesWithResults = UpdatedMessages ++ [ToolMsg],
    case run_agent_loop(Model, MessagesWithResults, Iteration + 1) of
        {ok, Response, NewThinking} ->
            CombinedThinking = case Thinking of
                <<>> -> NewThinking;
                _ -> <<Thinking/binary, "\n\n", NewThinking/binary>>
            end,
            {ok, Response, CombinedThinking};
        {error, Reason} ->
            {error, Reason}
    end;

handle_response(_Model, Messages, #{<<"content">> := Content} = ResponseMsg, _Iteration) when Content =/= <<>>, Content =/= nil ->
    Thinking = maps:get(<<"thinking">>, ResponseMsg, <<>>),
    {ok, Content, Thinking};

handle_response(_Model, _Messages, _ResponseMsg, _Iteration) ->
    {error, unexpected_response}.

execute_tool_calls(ToolCalls) when is_list(ToolCalls) ->
    Results = [execute_single_tool(TC) || TC <- ToolCalls],
    list_to_binary(io_lib:format("~p", [Results])).

execute_single_tool(#{<<"function">> := #{<<"name">> := Name, <<"arguments">> := Args}}) ->
    Result = coding_agent_tools:execute(Name, Args),
    #{<<"tool_call_id">> => Name, <<"result">> => Result};
execute_single_tool(_TC) ->
    #{<<"error">> => <<"Invalid tool call">>}.