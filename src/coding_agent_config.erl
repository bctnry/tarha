-module(coding_agent_config).
-export([
    model/0,
    ollama_host/0,
    ollama_model/0,
    max_iterations/0,
    sessions_dir/0,
    workspace/0,
    memory_max_size/0,
    memory_consolidate_threshold/0,
    session_max_messages/0,
    set_model/1,
    set_ollama_host/1,
    init_config/0,
    load_yaml/0,
    load_yaml/1,
    get_fallback_chain/0,
    get_retryable_errors/0,
    get_fallback_enabled/0,
    get_mcp_servers/0,
    get_mcp_servers/1
]).

%% @doc Centralized configuration for the coding agent.
%% All config values are read from application environment with sensible defaults.
%% Config priority (highest wins): env vars > application env > config.yaml > defaults.

%%===================================================================
%% Initialization
%%===================================================================

-spec init_config() -> ok.
init_config() ->
    %% Load YAML config first (lowest priority)
    case load_yaml() of
        ok -> ok;
        {error, Reason} ->
            io:format("[config] YAML loading skipped: ~p~n", [Reason]),
            ok
    end,
    %% Apply env var overrides (highest priority)
    apply_env_overrides(),
    ok.

-spec apply_env_overrides() -> ok.
apply_env_overrides() ->
    case os:getenv("OLLAMA_MODEL") of
        false -> ok;
        Model -> application:set_env(coding_agent, model, list_to_binary(Model))
    end,
    case os:getenv("OLLAMA_HOST") of
        false -> ok;
        Host -> application:set_env(coding_agent, ollama_host, Host)
    end,
    case os:getenv("TARHA_MAX_ITERATIONS") of
        false -> ok;
        MaxIter -> application:set_env(coding_agent, max_iterations, list_to_integer(MaxIter))
    end,
    case os:getenv("TARHA_WORKSPACE") of
        false -> ok;
        WS -> application:set_env(coding_agent, workspace, WS)
    end,
    ok.

%%===================================================================
%% YAML Loading
%%===================================================================

-spec load_yaml() -> ok | {error, term()}.
load_yaml() ->
    load_yaml("config.yaml").

-spec load_yaml(string()) -> ok | {error, term()}.
load_yaml(Path) ->
    case filelib:is_file(Path) of
        false ->
            {error, file_not_found};
        true ->
            try
                %% Try yamerl first
                case code:ensure_loaded(yamerl) of
                    {module, yamerl} ->
                        load_yaml_with_yamerl(Path);
                    _ ->
                        %% Fallback: simple line-based parser
                        load_yaml_simple(Path)
                end
            catch
                _:Reason ->
                    {error, {yaml_parse_error, Reason}}
            end
    end.

-spec load_yaml_with_yamerl(string()) -> ok | {error, term()}.
load_yaml_with_yamerl(Path) ->
    case yamerl:decode_file(Path) of
        {ok, [YamlDoc | _]} ->
            apply_yaml_config(YamlDoc);
        {ok, []} ->
            ok;
        {error, Reason} ->
            {error, {yamerl_decode_error, Reason}}
    end.

-spec apply_yaml_config(list()) -> ok.
apply_yaml_config(YamlDoc) when is_list(YamlDoc) ->
    %% yamerl returns nested proplists
    Ollama = proplists:get_value("ollama", YamlDoc, []),
    Agent = proplists:get_value("agent", YamlDoc, []),
    Memory = proplists:get_value("memory", YamlDoc, []),
    Session = proplists:get_value("session", YamlDoc, []),

    %% Apply ollama settings (only if not already set)
    maybe_set_env(coding_agent, model, proplists:get_value("model", Ollama)),
    maybe_set_env(coding_agent, ollama_host, proplists:get_value("host", Ollama)),
    maybe_set_env(coding_agent, ollama_timeout, proplists:get_value("timeout", Ollama)),

    %% Apply agent settings
    maybe_set_env(coding_agent, max_iterations, proplists:get_value("max_iterations", Agent)),
    maybe_set_env(coding_agent, workspace, proplists:get_value("workspace", Agent)),

    %% Apply memory settings
    maybe_set_env(coding_agent, memory_max_size, proplists:get_value("max_size", Memory)),
    maybe_set_env(coding_agent, memory_consolidate_threshold, proplists:get_value("consolidate_threshold", Memory)),

    %% Apply session settings
    maybe_set_env(coding_agent, session_max_messages, proplists:get_value("max_messages", Session)),

    ok.

-spec maybe_set_env(atom(), atom(), term()) -> ok.
maybe_set_env(_App, _Key, undefined) -> ok;
maybe_set_env(App, Key, Value) ->
    case application:get_env(App, Key) of
        undefined ->
            Val = case Value of
                V when is_binary(V) -> V;
                V when is_list(V) ->
                    %% yamerl returns strings; convert to binary for model, keep list for host
                    case Key of
                        model -> list_to_binary(V);
                        ollama_host -> V;
                        workspace -> V;
                        _ -> V
                    end;
                V -> V
            end,
            application:set_env(App, Key, Val);
        _ ->
            %% Already set (e.g. via sys.config or env var) — don't override
            ok
    end.

%% @doc Simple fallback YAML parser for basic key: value pairs.
%% Handles flat and one-level-nested structures only.
-spec load_yaml_simple(string()) -> ok | {error, term()}.
load_yaml_simple(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global, trim]),
            Parsed = parse_simple_yaml(Lines, <<>>, []),
            apply_simple_config(Parsed);
        {error, Reason} ->
            {error, Reason}
    end.

parse_simple_yaml([], _Section, Acc) -> lists:reverse(Acc);
parse_simple_yaml([Line | Rest], Section, Acc) ->
    %% Skip comments and empty lines
    Trimmed = string:trim(Line),
    case Trimmed of
        <<>> -> parse_simple_yaml(Rest, <<>>, Acc);
        <<"#", _/binary>> -> parse_simple_yaml(Rest, Section, Acc);
        _ ->
            case binary:split(Trimmed, <<":">>) of
                [Key, Value] ->
                    KeyStr = string:trim(Key),
                    ValStr = string:trim(Value),
                    case ValStr of
                        <<>> ->
                            %% New section
                            parse_simple_yaml(Rest, KeyStr, Acc);
                        _ ->
                            %% Key-value pair
                            Entry = {binary_to_list(Section), binary_to_list(KeyStr), parse_yaml_value(ValStr)},
                            parse_simple_yaml(Rest, Section, [Entry | Acc])
                    end;
                _ ->
                    parse_simple_yaml(Rest, Section, Acc)
            end
    end.

parse_yaml_value(<<"true">>) -> true;
parse_yaml_value(<<"false">>) -> false;
parse_yaml_value(Bin) ->
    case catch binary_to_integer(Bin) of
        Int when is_integer(Int) -> Int;
        _ -> binary_to_list(Bin)
    end.

apply_simple_config([]) -> ok;
apply_simple_config([{Section, Key, Value} | Rest]) ->
    Mapping = #{
        {"ollama", "model"} => {coding_agent, model},
        {"ollama", "host"} => {coding_agent, ollama_host},
        {"agent", "max_iterations"} => {coding_agent, max_iterations},
        {"agent", "workspace"} => {coding_agent, workspace},
        {"memory", "max_size"} => {coding_agent, memory_max_size},
        {"memory", "consolidate_threshold"} => {coding_agent, memory_consolidate_threshold},
        {"session", "max_messages"} => {coding_agent, session_max_messages}
    },
    case maps:get({Section, Key}, Mapping, undefined) of
        undefined -> ok;
        {App, EnvKey} ->
            maybe_set_env(App, EnvKey, Value)
    end,
    apply_simple_config(Rest).

%%===================================================================
%% Accessors
%%===================================================================

-spec model() -> binary().
model() ->
    case os:getenv("OLLAMA_MODEL") of
        false ->
            case application:get_env(coding_agent, model) of
                {ok, M} when is_binary(M) -> M;
                {ok, M} when is_list(M) -> list_to_binary(M);
                undefined -> ollama_model()
            end;
        Model -> list_to_binary(Model)
    end.

-spec ollama_host() -> string().
ollama_host() ->
    case os:getenv("OLLAMA_HOST") of
        false -> application:get_env(coding_agent, ollama_host, "http://localhost:11434");
        Host -> Host
    end.

-spec ollama_model() -> binary().
ollama_model() ->
    case application:get_env(coding_agent, ollama_model) of
        {ok, M} when is_list(M) -> list_to_binary(M);
        {ok, M} when is_binary(M) -> M;
        undefined -> <<"glm-5:cloud">>
    end.

-spec max_iterations() -> integer().
max_iterations() ->
    case os:getenv("TARHA_MAX_ITERATIONS") of
        false -> application:get_env(coding_agent, max_iterations, 100);
        Val -> list_to_integer(Val)
    end.

-spec sessions_dir() -> string().
sessions_dir() ->
    case application:get_env(coding_agent, sessions_dir) of
        {ok, Dir} -> Dir;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> filename:join(Cwd, ".tarha/sessions");
                _ -> ".tarha/sessions"
            end
    end.

-spec workspace() -> string().
workspace() ->
    case os:getenv("TARHA_WORKSPACE") of
        false -> application:get_env(coding_agent, workspace, ".");
        Val -> Val
    end.

-spec memory_max_size() -> integer().
memory_max_size() ->
    application:get_env(coding_agent, memory_max_size, 10000).

-spec memory_consolidate_threshold() -> integer().
memory_consolidate_threshold() ->
    application:get_env(coding_agent, memory_consolidate_threshold, 20).

-spec session_max_messages() -> integer().
session_max_messages() ->
    application:get_env(coding_agent, session_max_messages, 100).

get_fallback_enabled() ->
    application:get_env(coding_agent, fallback_enabled, true).

get_fallback_chain() ->
    case application:get_env(coding_agent, fallback_chain) of
        {ok, Chain} when is_list(Chain), length(Chain) > 0 -> Chain;
        _ ->
            Primary = model(),
            case application:get_env(coding_agent, fallback_model) of
                {ok, Fallback} when is_binary(Fallback), Fallback =/= Primary ->
                    [Primary, Fallback];
                {ok, Fallback} when is_list(Fallback), length(Fallback) > 0 ->
                    FB = list_to_binary(Fallback),
                    case FB =:= Primary of
                        true -> [Primary];
                        false -> [Primary, FB]
                    end;
                _ -> [Primary]
            end
    end.

get_retryable_errors() ->
    application:get_env(coding_agent, retry_on, [timeout, connection_error, server_error]).

%%===================================================================
%% Setters (for programmatic config changes)
%%===================================================================

-spec set_model(binary() | string()) -> ok.
set_model(Model) when is_binary(Model) ->
    application:set_env(coding_agent, model, Model),
    application:set_env(coding_agent, ollama_model, binary_to_list(Model));
set_model(Model) when is_list(Model) ->
    application:set_env(coding_agent, model, list_to_binary(Model)),
    application:set_env(coding_agent, ollama_model, Model).

-spec set_ollama_host(string()) -> ok.
set_ollama_host(Host) when is_list(Host) ->
    application:set_env(coding_agent, ollama_host, Host).

get_mcp_servers() ->
    Workspace = workspace(),
    get_mcp_servers(Workspace).

get_mcp_servers(Workspace) ->
    ConfigFile = filename:join(Workspace, ".tarha/mcp_servers.json"),
    case filelib:is_file(ConfigFile) of
        true ->
            case file:read_file(ConfigFile) of
                {ok, Content} ->
                    case jsx:is_json(Content) of
                        true ->
                            Decoded = jsx:decode(Content, [return_maps]),
                            Servers = maps:get(<<"mcpServers">>, Decoded, #{}),
                            maps:map(fun(_Name, Config) ->
                                normalize_mcp_config(Config)
                            end, Servers);
                        false ->
                            io:format("[config] Invalid JSON in ~s~n", [ConfigFile]),
                            #{}
                    end;
                {error, Reason} ->
                    io:format("[config] Error reading ~s: ~p~n", [ConfigFile, Reason]),
                    #{}
            end;
        false ->
            application:get_env(coding_agent, mcp_servers, #{})
    end.

normalize_mcp_config(Config) when is_map(Config) ->
    Command = maps:get(<<"command">>, Config, undefined),
    Args = maps:get(<<"args">>, Config, []),
    Env = maps:get(<<"env">>, Config, #{}),
    Url = maps:get(<<"url">>, Config, undefined),
    Transport = case {Command, Url} of
        {undefined, undefined} -> undefined;
        {_, undefined} -> stdio;
        {undefined, _} -> http
    end,
    Disabled = maps:get(<<"disabled">>, Config, false),
    Headers = maps:get(<<"headers">>, Config, []),
    Timeout = maps:get(<<"timeout">>, Config, 30000),
    #{
        command => if is_binary(Command) -> binary_to_list(Command); is_list(Command) -> Command; true -> undefined end,
        args => [if is_binary(A) -> binary_to_list(A); is_list(A) -> A end || A <- Args],
        env => maps:to_list(Env),
        url => if is_binary(Url) -> binary_to_list(Url); is_list(Url) -> Url; true -> undefined end,
        transport => Transport,
        disabled => Disabled,
        headers => Headers,
        timeout => Timeout
    };
normalize_mcp_config(_) ->
    #{}.
