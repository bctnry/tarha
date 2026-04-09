-module(coding_agent_tools_command_test).
-include_lib("eunit/include/eunit.hrl").

%% Basic command execution
run_command_echo_test() ->
    Result = coding_agent_tools:execute(<<"run_command">>, #{<<"command">> => <<"echo hello">>}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

%% Command with working directory
run_command_with_cwd_test() ->
    Result = coding_agent_tools:execute(<<"run_command">>, #{
        <<"command">> => <<"pwd">>,
        <<"working_dir">> => <<".">>
    }),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

%% Missing command argument — dispatch may crash, so catch
run_command_missing_args_test() ->
    Result = (catch coding_agent_tools:execute(<<"run_command">>, #{})),
    %% Either returns error map or crashes — both are acceptable for missing args
    ?assertNotMatch(#{<<"success">> := true}, Result).

%% HTTP request test (skip if no network)
http_request_test_() ->
    {timeout, 15, fun() ->
        case os:getenv("SKIP_NETWORK_TESTS") of
            false ->
                Result = coding_agent_tools:execute(<<"http_request">>, #{
                    <<"url">> => <<"https://httpbin.org/get">>,
                    <<"method">> => <<"GET">>
                }),
                ?assertEqual(true, maps:get(<<"success">>, Result));
            _ ->
                ok
        end
    end}.