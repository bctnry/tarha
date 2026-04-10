-module(coding_agent_plugins).
-behaviour(gen_server).

-export([start_link/0, start_link/1, load_plugins/0, load_plugins/1, get_tool_schemas/0, execute/2]).
-export([list_plugins/0, enable/1, disable/1, reload/1, get_prompts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(PLUGIN_DIR, ".tarha/plugins").
-define(BUILTIN_PLUGIN_DIR, "priv/plugins").
-define(PLUGIN_TIMEOUT, 30000).

-record(plugin, {
    name :: binary(),
    version :: binary(),
    description :: binary(),
    tools :: [map()],
    handler :: shell | module | http,
    command :: string() | undefined,
    module_name :: atom() | undefined,
    function_name :: atom() | undefined,
    url :: string() | undefined,
    headers :: map(),
    timeout :: integer(),
    prompt :: binary() | undefined,
    enabled :: boolean()
}).

-record(state, {
    workspace :: string(),
    plugins :: #{binary() => #plugin{}},
    tool_to_plugin :: #{binary() => binary()}
}).

start_link() ->
    start_link(undefined).

start_link(Workspace) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Workspace], []).

load_plugins() ->
    gen_server:call(?MODULE, load_plugins, 10000).

load_plugins(Workspace) ->
    gen_server:call(?MODULE, {load_plugins, Workspace}, 10000).

get_tool_schemas() ->
    gen_server:call(?MODULE, get_tool_schemas, 5000).

execute(ToolName, Args) ->
    gen_server:call(?MODULE, {execute, ToolName, Args}, ?PLUGIN_TIMEOUT).

list_plugins() ->
    gen_server:call(?MODULE, list_plugins, 5000).

enable(Name) ->
    gen_server:call(?MODULE, {enable, Name}, 5000).

disable(Name) ->
    gen_server:call(?MODULE, {disable, Name}, 5000).

reload(Name) ->
    gen_server:call(?MODULE, {reload, Name}, 10000).

get_prompts() ->
    gen_server:call(?MODULE, get_prompts, 5000).

init([Workspace]) ->
    WorkspaceDir = case Workspace of
        undefined -> case file:get_cwd() of {ok, D} -> D; _ -> "." end;
        W when is_list(W) -> W
    end,
    {ok, #state{workspace = WorkspaceDir, plugins = #{}, tool_to_plugin = #{}}}.

handle_call(load_plugins, _From, State) ->
    {Reply, NewState} = do_load_plugins(State),
    {reply, Reply, NewState};

handle_call({load_plugins, _Workspace}, _From, State) ->
    {Reply, NewState} = do_load_plugins(State),
    {reply, Reply, NewState};

handle_call(get_tool_schemas, _From, State = #state{plugins = Plugins}) ->
    Schemas = maps:fold(fun(_Name, Plugin, Acc) ->
        case Plugin#plugin.enabled of
            true -> Acc ++ Plugin#plugin.tools;
            false -> Acc
        end
    end, [], Plugins),
    {reply, Schemas, State};

handle_call({execute, ToolName, Args}, _From, State = #state{plugins = Plugins, tool_to_plugin = ToolToPlugin}) ->
    Result = case maps:get(ToolName, ToolToPlugin, undefined) of
        undefined -> #{<<"success">> => false, <<"error">> => <<"Unknown plugin tool">>};
        PluginName ->
            case maps:get(PluginName, Plugins, undefined) of
                undefined -> #{<<"success">> => false, <<"error">> => <<"Plugin not found">>};
                Plugin when Plugin#plugin.enabled =:= false ->
                    #{<<"success">> => false, <<"error">> => <<"Plugin is disabled">>};
                Plugin ->
                    execute_plugin_tool(ToolName, Args, Plugin)
            end
    end,
    {reply, Result, State};

handle_call(list_plugins, _From, State = #state{plugins = Plugins}) ->
    List = maps:fold(fun(_Name, Plugin, Acc) ->
        [#{
            name => Plugin#plugin.name,
            version => Plugin#plugin.version,
            description => Plugin#plugin.description,
            handler => Plugin#plugin.handler,
            enabled => Plugin#plugin.enabled,
            tool_count => length(Plugin#plugin.tools)
        } | Acc]
    end, [], Plugins),
    {reply, {ok, List}, State};

handle_call({enable, Name}, _From, State = #state{plugins = Plugins}) ->
    NameBin = if is_list(Name) -> list_to_binary(Name); is_binary(Name) -> Name end,
    NewPlugins = case maps:get(NameBin, Plugins, undefined) of
        undefined -> Plugins;
        Plugin -> maps:put(NameBin, Plugin#plugin{enabled = true}, Plugins)
    end,
    {reply, ok, State#state{plugins = NewPlugins}};

handle_call({disable, Name}, _From, State = #state{plugins = Plugins}) ->
    NameBin = if is_list(Name) -> list_to_binary(Name); is_binary(Name) -> Name end,
    NewPlugins = case maps:get(NameBin, Plugins, undefined) of
        undefined -> Plugins;
        Plugin -> maps:put(NameBin, Plugin#plugin{enabled = false}, Plugins)
    end,
    {reply, ok, State#state{plugins = NewPlugins}};

handle_call({reload, _Name}, _From, State) ->
    {Reply, NewState} = do_load_plugins(State),
    {reply, Reply, NewState};

handle_call(get_prompts, _From, State = #state{plugins = Plugins}) ->
    Prompts = maps:fold(fun(_Name, Plugin, Acc) ->
        case Plugin#plugin.enabled of
            true when Plugin#plugin.prompt =/= undefined ->
                [Plugin#plugin.prompt | Acc];
            _ -> Acc
        end
    end, [], Plugins),
    {reply, {ok, Prompts}, State};

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

%%===================================================================
%% Internal functions
%%===================================================================

do_load_plugins(_State = #state{workspace = Workspace}) ->
    PluginDirs = [
        filename:join(Workspace, ?PLUGIN_DIR),
        filename:join(code:priv_dir(coding_agent), "plugins")
    ],
    AllPlugins = lists:foldl(fun(Dir, Acc) ->
        case filelib:is_dir(Dir) of
            false -> Acc;
            true ->
                PluginDirs2 = filelib:wildcard(filename:join(Dir, "*")),
                lists:foldl(fun(PD, Acc2) ->
                    case load_plugin_from_dir(PD) of
                        {ok, Plugin} -> maps:put(Plugin#plugin.name, Plugin, Acc2);
                        {error, _Reason} -> Acc2
                    end
                end, Acc, PluginDirs2)
        end
    end, #{}, PluginDirs),
    ToolToPlugin = maps:fold(fun(Name, Plugin, Acc) ->
        ToolNames = [maps:get(<<"name">>, T, <<>>) || T <- Plugin#plugin.tools],
        lists:foldl(fun(TN, A) -> maps:put(TN, Name, A) end, Acc, ToolNames)
    end, #{}, AllPlugins),
    {ok, #state{plugins = AllPlugins, tool_to_plugin = ToolToPlugin, workspace = Workspace}}.

load_plugin_from_dir(Dir) ->
    ManifestFile = filename:join(Dir, "plugin.json"),
    case file:read_file(ManifestFile) of
        {error, Reason} -> {error, {manifest_read_error, Reason}};
        {ok, Content} ->
            try
                Decoded = jsx:decode(Content, [return_maps]),
                Name = maps:get(<<"name">>, Decoded, list_to_binary(filename:basename(Dir))),
                Version = maps:get(<<"version">>, Decoded, <<"1.0.0">>),
                Description = maps:get(<<"description">>, Decoded, <<>>),
                Tools = maps:get(<<"tools">>, Decoded, []),
                Handler = case maps:get(<<"handler">>, Decoded, <<"shell">>) of
                    <<"shell">> -> shell;
                    <<"module">> -> module;
                    <<"http">> -> http;
                    _Other -> shell
                end,
                Command = binary_to_list(maps:get(<<"command">>, Decoded, <<>>)),
                ModuleName = case maps:get(<<"module">>, Decoded, <<"">>) of
                    <<>> -> undefined;
                    ModBin ->
                        try binary_to_existing_atom(ModBin, utf8)
                        catch error:badarg -> undefined
                        end
                end,
                FunctionName = binary_to_atom(maps:get(<<"function">>, Decoded, <<"handle_tool">>), utf8),
                Url = binary_to_list(maps:get(<<"url">>, Decoded, <<>>)),
                Headers = maps:get(<<"headers">>, Decoded, #{}),
                Timeout = maps:get(<<"timeout">>, Decoded, ?PLUGIN_TIMEOUT),
                PromptFile = filename:join(Dir, "prompt.md"),
                Prompt = case file:read_file(PromptFile) of
                    {ok, P} -> P;
                    _ -> undefined
                end,
                {ok, #plugin{
                    name = Name,
                    version = Version,
                    description = Description,
                    tools = Tools,
                    handler = Handler,
                    command = Command,
                    module_name = ModuleName,
                    function_name = FunctionName,
                    url = Url,
                    headers = Headers,
                    timeout = Timeout,
                    prompt = Prompt,
                    enabled = true
                }}
            catch
                error:{badkey, Key} -> {error, {missing_field, Key}};
                error:badarg -> {error, invalid_json}
            end
    end.

execute_plugin_tool(ToolName, Args, Plugin) ->
    Timeout = Plugin#plugin.timeout,
    case Plugin#plugin.handler of
        shell -> execute_shell_tool(ToolName, Args, Plugin, Timeout);
        module -> execute_module_tool(ToolName, Args, Plugin);
        http -> execute_http_tool(ToolName, Args, Plugin, Timeout)
    end.

execute_shell_tool(_ToolName, Args, Plugin, Timeout) ->
    Command = Plugin#plugin.command,
    JsonInput = jsx:encode(Args),
    FullCmd = "echo '" ++ binary_to_list(unicode:characters_to_binary(JsonInput)) ++ "' | " ++ Command ++ " 2>&1",
    case run_with_timeout(FullCmd, Timeout) of
        {ok, Output} ->
            try jsx:decode(list_to_binary(Output), [return_maps]) of
                Result -> Result
            catch
                _:_ -> #{<<"success">> => true, <<"output">> => list_to_binary(Output)}
            end;
        {error, timeout} ->
            #{<<"success">> => false, <<"error">> => <<"Plugin command timed out">>};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end.

execute_module_tool(ToolName, Args, Plugin) ->
    Module = Plugin#plugin.module_name,
    Function = Plugin#plugin.function_name,
    try
        case erlang:function_exported(Module, Function, 2) of
            true -> Module:Function(ToolName, Args);
            false -> #{<<"success">> => false, <<"error">> => <<"Module function not found">>}
        end
    catch
        error:undef -> #{<<"success">> => false, <<"error">> => <<"Module not available">>};
        Class:Reason:_Stacktrace ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

execute_http_tool(_ToolName, Args, Plugin, _Timeout) ->
    Url = Plugin#plugin.url,
    Headers = Plugin#plugin.headers,
    case coding_agent_tools_command:http_request(Url, Args, Headers) of
        #{<<"success">> := true} = Result -> Result;
        #{<<"success">> := false, <<"error">> := Error} ->
            #{<<"success">> => false, <<"error">> => Error}
    end.

run_with_timeout(Cmd, Timeout) ->
    Pid = spawn(fun() ->
        Result = os:cmd(Cmd),
        exit({cmd_result, Result})
    end),
    MonRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MonRef, process, Pid, {cmd_result, Result}} ->
            {ok, Result};
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, Reason}
    after Timeout ->
        demonitor(MonRef, [flush]),
        exit(Pid, kill),
        {error, timeout}
    end.