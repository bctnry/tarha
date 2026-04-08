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
    set_ollama_host/1
]).

%% @doc Centralized configuration for the coding agent.
%% All config values are read from application environment with sensible defaults.
%% Config can be set via sys.config, config.yaml (if loaded), or programmatically.

%%===================================================================
%% Accessors
%%===================================================================

-spec model() -> binary().
model() ->
    case application:get_env(coding_agent, model) of
        {ok, M} when is_binary(M) -> M;
        {ok, M} when is_list(M) -> list_to_binary(M);
        undefined -> ollama_model()
    end.

-spec ollama_host() -> string().
ollama_host() ->
    application:get_env(coding_agent, ollama_host, "http://localhost:11434").

-spec ollama_model() -> binary().
ollama_model() ->
    case application:get_env(coding_agent, ollama_model) of
        {ok, M} when is_list(M) -> list_to_binary(M);
        {ok, M} when is_binary(M) -> M;
        undefined -> <<"glm-5:cloud">>
    end.

-spec max_iterations() -> integer().
max_iterations() ->
    application:get_env(coding_agent, max_iterations, 100).

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
    application:get_env(coding_agent, workspace, ".").

-spec memory_max_size() -> integer().
memory_max_size() ->
    application:get_env(coding_agent, memory_max_size, 10000).

-spec memory_consolidate_threshold() -> integer().
memory_consolidate_threshold() ->
    application:get_env(coding_agent, memory_consolidate_threshold, 20).

-spec session_max_messages() -> integer().
session_max_messages() ->
    application:get_env(coding_agent, session_max_messages, 100).

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
