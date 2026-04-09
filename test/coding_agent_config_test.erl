-module(coding_agent_config_test).
-include_lib("eunit/include/eunit.hrl").

%% Accessors return correct types
defaults_test() ->
    ?assert(is_binary(coding_agent_config:model())),
    ?assert(is_list(coding_agent_config:ollama_host())),
    ?assert(is_integer(coding_agent_config:max_iterations())),
    ?assert(is_list(coding_agent_config:workspace())),
    ?assert(is_integer(coding_agent_config:memory_max_size())),
    ?assert(is_integer(coding_agent_config:memory_consolidate_threshold())),
    ?assert(is_integer(coding_agent_config:session_max_messages())).

%% set_model / model round-trip
set_model_binary_test() ->
    coding_agent_config:set_model(<<"test-model">>),
    ?assertEqual(<<"test-model">>, coding_agent_config:model()),
    coding_agent_config:set_model(<<"glm-5:cloud">>).  % Reset

set_model_list_test() ->
    coding_agent_config:set_model("test-model-list"),
    ?assertEqual(<<"test-model-list">>, coding_agent_config:model()),
    coding_agent_config:set_model(<<"glm-5:cloud">>).  % Reset

%% set_ollama_host / ollama_host round-trip
set_ollama_host_test() ->
    coding_agent_config:set_ollama_host("http://test:11434"),
    ?assertEqual("http://test:11434", coding_agent_config:ollama_host()),
    coding_agent_config:set_ollama_host("http://localhost:11434").  % Reset

%% Environment variable overrides
env_override_model_test() ->
    os:putenv("OLLAMA_MODEL", "env-model"),
    ?assertEqual(<<"env-model">>, coding_agent_config:model()),
    os:unsetenv("OLLAMA_MODEL").

env_override_host_test() ->
    os:putenv("OLLAMA_HOST", "http://env-host:9999"),
    ?assertEqual("http://env-host:9999", coding_agent_config:ollama_host()),
    os:unsetenv("OLLAMA_HOST").

env_override_max_iterations_test() ->
    os:putenv("TARHA_MAX_ITERATIONS", "42"),
    ?assertEqual(42, coding_agent_config:max_iterations()),
    os:unsetenv("TARHA_MAX_ITERATIONS").

env_override_workspace_test() ->
    os:putenv("TARHA_WORKSPACE", "/tmp/test-ws"),
    ?assertEqual("/tmp/test-ws", coding_agent_config:workspace()),
    os:unsetenv("TARHA_WORKSPACE").

%% YAML loading — missing file
load_yaml_missing_file_test() ->
    ?assertMatch({error, file_not_found}, coding_agent_config:load_yaml("nonexistent.yaml")).

%% init_config doesn't crash
init_config_test() ->
    ?assertEqual(ok, coding_agent_config:init_config()).

%% ollama_model accessor
ollama_model_default_test() ->
    %% After set_model resets, ollama_model should reflect it
    coding_agent_config:set_model(<<"my-model">>),
    ?assertEqual(<<"my-model">>, coding_agent_config:ollama_model()),
    coding_agent_config:set_model(<<"glm-5:cloud">>).